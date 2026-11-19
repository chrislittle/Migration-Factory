#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RETRY-MSG-1 - "An error occurred while sending the request." tells nobody anything.
#
# In the PERM-2 drill, the run went forward but showed red error rows.
# The entire explanation behind those red rows was .NET's generic
# HttpRequestException message. Reading it is where this started; measuring what
# else that message was breaking is where it ended.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # The exact shape the drill produced: a generic outer message wrapping the
    # cause. Built rather than described, so the test cannot drift from reality.
    function Global:NewWrappedHttpError {
        param([int]$SocketError = 10054)
        $inner = [System.Net.Sockets.SocketException]::new($SocketError)
        [System.Net.Http.HttpRequestException]::new('An error occurred while sending the request.', $inner)
    }
}
AfterAll { Remove-Item 'function:\NewWrappedHttpError' -ErrorAction SilentlyContinue }

Describe 'RETRY-MSG-1: what the operator is told' {
    It 'does not stop at the outermost message' {
        $e = NewWrappedHttpError
        InModuleScope VmMigrationFactory -Parameters @{ err = $e } {
            $r = Resolve-VmfOperationError -ErrorRecord $err
            $r.Message | Should -Not -Be 'An error occurred while sending the request.'
            # The cause, in the words the operating system used for it.
            $r.Message | Should -Match 'forcibly closed|reset|connection'
        }
    }

    It 'puts the status code and the Azure error code FIRST, where they survive truncation' {
        $ex = [System.Exception]::new('the request failed')
        $rec = [System.Management.Automation.ErrorRecord]::new($ex, 'x', 'InvalidOperation', $null)
        $rec.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
            '{"error":{"code":"QuotaExceeded","message":"Operation could not be completed as it results in exceeding approved quota."}}')
        InModuleScope VmMigrationFactory -Parameters @{ r = $rec } {
            $out = Resolve-VmfOperationError -ErrorRecord $r
            $out.ErrorCode | Should -Be 'QuotaExceeded'
            $out.Message   | Should -BeLike 'QuotaExceeded*'
            $out.Message   | Should -Match 'exceeding approved quota'
        }
    }

    It 'never throws, whatever it is handed - it runs inside a catch block' {
        # An exception raised while describing an exception destroys the error
        # being reported and replaces it with a worse one.
        InModuleScope VmMigrationFactory {
            foreach ($junk in @($null, '', 'a bare string', 42, @{ not = 'an error' }, [pscustomobject]@{ a = 1 })) {
                { Resolve-VmfOperationError -ErrorRecord $junk } | Should -Not -Throw
                (Resolve-VmfOperationError -ErrorRecord $junk).Message | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'terminates on a deep exception chain' {
        # A worker that hangs formatting an error message is worse than the error.
        InModuleScope VmMigrationFactory {
            $deep = [System.Exception]::new('innermost')
            foreach ($i in 1..40) { $deep = [System.Exception]::new("layer$i", $deep) }
            $r = Resolve-VmfOperationError -ErrorRecord $deep
            $r.Message | Should -Not -BeNullOrEmpty
            # Depth-capped at 8, so the innermost layers are never reached.
            $r.Message | Should -Not -Match 'innermost'
        }
    }
}

Describe 'RETRY-MSG-1: the defect the message was HIDING' {
    It 'a transient failure wrapped in a generic message is now retried' {
        # THE REAL FIND. The classifier read the same impoverished string the
        # operator did, matched no pattern, called a socket reset permanent, and
        # threw on attempt 1 with the retry budget untouched. What recovered in
        # the drill was the state machine re-running the whole step - which is
        # far more expensive, and surfaces as a failure.
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            $result = Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation {
                $script:calls++
                if ($script:calls -lt 3) {
                    throw ([System.Net.Http.HttpRequestException]::new(
                        'An error occurred while sending the request.',
                        [System.Net.Sockets.SocketException]::new(10054)))
                }
                'recovered'
            }
            $result | Should -Be 'recovered'
            $script:calls | Should -Be 3
        }
    }

    It 'and a REAL status code decides both ways' {
        # The old patterns matched '500' and '503' as bare substrings, so a 403
        # whose request id happened to contain 503 read as transient. A status
        # code that is actually present is better evidence than any wording.
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfOperationError -ErrorRecord ([System.Net.Http.HttpRequestException]::new(
                'Forbidden (request id 8b503500-0000)', $null, [System.Net.HttpStatusCode]::Forbidden))
            $r.StatusCode | Should -Be 403

            $script:calls = 0
            {
                Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation {
                    $script:calls++
                    throw ([System.Net.Http.HttpRequestException]::new(
                        'Forbidden (request id 8b503500-0000)', $null, [System.Net.HttpStatusCode]::Forbidden))
                }
            } | Should -Throw
            $script:calls | Should -Be 1 -Because 'a 403 is not transient however its request id reads'
        }
    }

    It 'a 429 carried only as a status code is retried' {
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            $r = Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation {
                $script:calls++
                if ($script:calls -lt 2) {
                    throw ([System.Net.Http.HttpRequestException]::new(
                        'the service is busy', $null, [System.Net.HttpStatusCode]::TooManyRequests))
                }
                'ok'
            }
            $r | Should -Be 'ok'
            $script:calls | Should -Be 2
        }
    }
}

Describe 'RETRY-MSG-1: what reaches the run store' {
    It 'the failure event carries the status and error code as DATA, not only prose' {
        # A dashboard cannot filter on a sentence. RETRY-UI-1 needs these.
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-err-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp } {
                Initialize-VmfRun -RunPath $p -RunId 'err' -Kind 'migration' | Out-Null
                try {
                    Invoke-VmfAzOperation -Name 'probe' -BaseDelayMs 1 -MaxAttempts 1 -RunPath $p -Operation {
                        throw ([System.Net.Http.HttpRequestException]::new(
                            'nope', $null, [System.Net.HttpStatusCode]::Forbidden))
                    }
                }
                catch { }
                $ev = @(Read-VmfEvents -RunPath $p | Where-Object { $_.step -eq 'azureops:probe' -and $_.outcome -eq 'fail' })
                $ev.Count | Should -BeGreaterThan 0
                # Write-VmfEvent merges Data keys FLAT into the event, alongside
                # attempt and transient - not nested under a 'data' object.
                $ev[-1].statusCode | Should -Be 403
                $ev[-1].transient  | Should -BeFalse
                $ev[-1].detail     | Should -BeLike 'HTTP 403*'
            }
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}

Describe 'AZOP-RETRY-MATCH-1: a number in a name is not a status code' {
    # The text fallback matched '500' and '503' as bare substrings, so an error
    # with no status code - a string a caller threw - read as temporary when a
    # subscription, a resource group, a machine or a request id held those
    # digits. Such an error was tried again with waits, up to four times,
    # inside the machine's change window. Now the status comes from the error
    # object, or from the place a message puts it, and never from a bare number.

    It 'an error that is not temporary, with <Name>, is tried once' -ForEach @(
        @{ Name = '500 and 503 in the names and a request id'
           Text = "AuthorizationFailed: The client does not have authorization over scope '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-app-503/providers/Microsoft.Compute/virtualMachines/vm-500'. Request id 8b503500-0000." }
        @{ Name = '429 and 504 in the names'
           Text = "OperationNotAllowed: machine 'vm-429' on disk 'disk-504' cannot be resized now." }
        @{ Name = 'a 404 put in its place, and 503 in the disk name'
           Text = "Reading disk '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/disks/disk-503' failed with 404: {`"error`":{`"code`":`"ResourceNotFound`"}}" }
        @{ Name = 'an Az StatusCode line of 409, and 500 in the machine name'
           Text = "Long running operation failed.`nErrorCode: OperationNotAllowed`nErrorMessage: Machine vm-500 cannot change now.`nStatusCode: 409`nReasonPhrase: Conflict" }
        @{ Name = 'the FIRST status in the text, 409, before a 503 in the content'
           Text = "Capacity reservation disassociation PATCH for 'vm1' returned 409: the service said HTTP 503 earlier" }
        @{ Name = 'a 403 in its place, even when the content says timed out'
           Text = 'Store read failed: HTTP 403 the request timed out at the proxy' }
        @{ Name = 'a 404 from Azure.Core, and 503 in the disk name'
           Text = "Service request failed.`nStatus: 404 (Not Found)`n`nContent: disk disk-503 was not found, the request timed out" }
        @{ Name = 'HTTP and 500 joined in a host name'
           Text = "AuthorizationFailed: the proxy http500.example.com refused the request." }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ text = $Text } {
            $script:calls = 0
            { Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation { $script:calls++; throw $text } } | Should -Throw
            $script:calls | Should -Be 1 -Because 'a number in a name is not a status code, and a 4xx in its place is an answer'
        }
    }

    It 'a real <Name>, written in the message, is tried again' -ForEach @(
        @{ Name = '503 after failed with';   Text = "Reading disk 'disk1' failed with 503: Service Unavailable" }
        @{ Name = '503 after HTTP';          Text = 'Store read failed: HTTP 503' }
        @{ Name = '503 from .NET';           Text = 'Response status code does not indicate success: 503 (Service Unavailable).' }
        @{ Name = '503 from a web request';  Text = 'The remote server returned an error: (503) Server Unavailable.' }
        @{ Name = '500 on an Az StatusCode line'; Text = "ErrorCode: InternalExecutionError`nErrorMessage: An internal error occurred.`nStatusCode: 500`nReasonPhrase: Internal Server Error" }
        @{ Name = '502 after returned status'; Text = "Update-AzVM for 'vm1' returned status '502'." }
        @{ Name = '504 in brackets before a colon'; Text = "Azure refused the instant access copy 'c1' of 'd1' (504): gateway" }
        @{ Name = '429 on an Az StatusCode line'; Text = "ErrorCode: TooManyRequests`nStatusCode: 429`nReasonPhrase: Too Many Requests" }
        @{ Name = '429 after status code';   Text = 'Response status code 429 (TooManyRequests)' }
        @{ Name = '503 after status code';   Text = 'The request ended with status code 503.' }
        @{ Name = '503 from Azure.Core';     Text = "Service request failed.`nStatus: 503 (Service Unavailable)`n`nContent: busy for vm-1" }
        @{ Name = '503 after returned, in quotes'; Text = "Capacity reservation association update for 'vm1' returned '503'." }
        @{ Name = '503 after returned, before a colon'; Text = "Capacity reservation disassociation PATCH for 'vm1' returned 503: busy" }
        @{ Name = 'ServiceUnavailable code from AutoRest'; Text = "Operation returned an invalid status code 'ServiceUnavailable'" }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ text = $Text } {
            $script:calls = 0
            $r = Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation {
                $script:calls++
                if ($script:calls -lt 3) { throw $text }
                'recovered'
            }
            $r | Should -Be 'recovered'
            $script:calls | Should -Be 3
        }
    }

    It 'an Azure error code with no status code is tried again: <Code>' -ForEach @(
        @{ Code = 'ServerTimeout' }, @{ Code = 'TooManyRequests' }, @{ Code = 'InternalServerError' }
    ) {
        $ex = [System.Exception]::new('the request failed for vm-1')
        $rec = [System.Management.Automation.ErrorRecord]::new($ex, 'x', 'InvalidOperation', $null)
        $rec.ErrorDetails = [System.Management.Automation.ErrorDetails]::new("{`"error`":{`"code`":`"$Code`",`"message`":`"later`"}}")
        InModuleScope VmMigrationFactory -Parameters @{ r = $rec } {
            $err = Resolve-VmfOperationError -ErrorRecord $r
            $v = Get-VmfTransientVerdict -ErrorInfo $err
            $v.Transient | Should -BeTrue
            $v.Source    | Should -Be 'code'
        }
    }

    It 'a real status code on the error object decides before any text' {
        InModuleScope VmMigrationFactory {
            $err = Resolve-VmfOperationError -ErrorRecord ([System.Net.Http.HttpRequestException]::new(
                "Reading disk 'd1' failed with 503: retry", $null, [System.Net.HttpStatusCode]::Forbidden))
            $v = Get-VmfTransientVerdict -ErrorInfo $err
            $v.Transient  | Should -BeFalse
            $v.StatusCode | Should -Be 403
            $v.Source     | Should -Be 'status'
        }
    }

    It 'the verdict names the status it read from the text, and its source' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "Reading disk 'disk-500' failed with 503: busy")
            $v.Transient  | Should -BeTrue
            $v.StatusCode | Should -Be 503
            $v.Source     | Should -Be 'text-status'
        }
    }

    It 'a status needs exactly three digits: <Text>' -ForEach @(
        @{ Text = 'Store read failed: HTTP 5030' }
        @{ Text = "Reading disk 'd1' failed with 50300: x" }
        @{ Text = 'StatusCode: 503a-77' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ text = $Text } {
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord $text)
            $v.Transient | Should -BeFalse
            $v.StatusCode | Should -BeNullOrEmpty
        }
    }

    It 'an Azure error code inside a longer name is not that code' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "OperationNotAllowed: machine 'vmServiceUnavailableX' is locked.")
            $v.Transient | Should -BeFalse
        }
    }

    It 'only a throttle is a throttle: a 429 or TooManyRequests, never a 503' {
        InModuleScope VmMigrationFactory {
            (Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "StatusCode: 429`nReasonPhrase: Too Many Requests")).Throttle | Should -BeTrue
            (Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "Operation returned an invalid status code 'TooManyRequests'")).Throttle | Should -BeTrue
            (Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord 'Store read failed: HTTP 503')).Throttle | Should -BeFalse
            (Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "Reading disk 'disk-429' failed with 503: busy")).Throttle | Should -BeFalse
        }
    }

    It 'a word in a name is not that word: <Name>' -ForEach @(
        @{ Name = 'timeout in a quoted machine name'
           Text = "AuthorizationFailed: machine 'vm-timeout-01' cannot be changed by this identity." }
        @{ Name = 'throttle in a resource id'
           Text = 'AuthorizationFailed: no write over /subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-throttle/providers/Microsoft.Compute/virtualMachines/vm1 for this identity.' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ text = $Text } {
            $script:calls = 0
            { Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation { $script:calls++; throw $text } } | Should -Throw
            $script:calls | Should -Be 1
        }
    }

    It 'the words outside a name still count, beside a quoted name' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "The operation on 'vm-1' timed out, and the server couldn't answer.")
            $v.Transient | Should -BeTrue
            $v.Source    | Should -Be 'words'
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "The request for 'vm-1' was throttled.")
            $v.Throttle  | Should -BeTrue
        }
    }

    It 'with no status, a temporary error whose name holds 429 or throttle is no throttle' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "The operation timed out for disk 'disk-429'.")
            $v.Transient | Should -BeTrue
            $v.Throttle  | Should -BeFalse
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord "The operation timed out for disk 'disk-throttle'.")
            $v.Transient | Should -BeTrue
            $v.Throttle  | Should -BeFalse            # And a name with no quotes: 429 is still only a part of it.
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord 'The operation timed out for disk-429.')
            $v.Transient | Should -BeTrue
            $v.Throttle  | Should -BeFalse
        }
    }

    It 'a temporary error with 429 only in a name tells no other worker to wait' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-thr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Initialize-VmfRun -RunPath $rp -RunId 'thr' -Kind 'migration' | Out-Null
                Mock Write-VmfThrottleSignal { }
                $script:calls = 0
                Invoke-VmfAzOperation -Name 'probe' -BaseDelayMs 1 -RunPath $rp -Operation {
                    $script:calls++
                    if ($script:calls -lt 2) { throw "Reading disk 'disk-429' failed with 503: busy" }
                    'ok'
                } | Should -Be 'ok'
                Should -Invoke Write-VmfThrottleSignal -Times 0 -Exactly
            }
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}

Describe 'LINUX-TRANSIENT-1: the engine runs in a Linux container, and .NET writes the Linux words there' {
    # Measured in a lab session (2026-11-04), from the engine's own events. The
    # list of temporary words held only the Windows socket wordings, so each of
    # these was permanent on attempt 1. The third one stopped a rollback with
    # the machine deallocated on its new size, until a person restored it.

    It 'a Linux socket error the engine wrote is tried again: <Name>' -ForEach @(
        @{ Name = 'a connection reset by peer, at the stop step'
           Text = '104 - An error occurred while sending the request. -> Unable to read data from the transport connection: Connection reset by peer' }
        @{ Name = 'an address that could not be assigned, at the rollback size change'
           Text = '99 - The operation was canceled. -> Cannot assign requested address (management.azure.com:443)' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ text = $Text } {
            $script:calls = 0
            $r = Invoke-VmfAzOperation -Name 'rollback:revertSize' -BaseDelayMs 1 -Operation {
                $script:calls++
                if ($script:calls -lt 3) { throw $text }
                'recovered'
            }
            $r | Should -Be 'recovered'
            $script:calls | Should -Be 3 -Because 'a socket error on Linux is as temporary as the same error on Windows'
        }
    }

    It 'the Linux wording alone is temporary: <Words>' -ForEach @(
        @{ Words = 'Unable to read data from the transport connection: Connection reset by peer.' }
        @{ Words = 'Cannot assign requested address (management.azure.com:443)' }
        @{ Words = 'Network is unreachable (management.azure.com:443)' }
        @{ Words = 'Connection refused (management.azure.com:443)' }
        @{ Words = 'Connection timed out (management.azure.com:443)' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ words = $Words } {
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord $words)
            $v.Transient | Should -BeTrue
            $v.Source    | Should -Be 'words'
            $v.Throttle  | Should -BeFalse -Because 'a socket error is about this call, not the subscription'
        }
    }

    It 'the error chain HttpClient builds on Linux is read to its cause, and tried again' {
        # The shape .NET gives: a cancel that wraps the socket failure. The
        # classifier reads the whole chain (RETRY-MSG-1), so the inner words decide.
        $inner = [System.Net.Http.HttpRequestException]::new('Cannot assign requested address (management.azure.com:443)')
        $e = [System.Threading.Tasks.TaskCanceledException]::new('The operation was canceled.', $inner)
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $script:calls = 0
            $r = Invoke-VmfAzOperation -Name 'rollback:revertSize' -BaseDelayMs 1 -Operation {
                $script:calls++
                if ($script:calls -lt 2) { throw $e }
                'recovered'
            }
            $r | Should -Be 'recovered'
            $script:calls | Should -Be 2
        }
    }

    It 'an HttpClient cancel with no cause is a timeout, and is tried again' {
        # A TaskCanceledException from HttpClient is how .NET reports a request
        # that took too long. Nothing in the engine cancels an Azure request
        # for a person: a stop of a run is read between the steps.
        $e = [System.Threading.Tasks.TaskCanceledException]::new('The operation was canceled.')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord $e)
            $v.Transient | Should -BeTrue
            $v.Source    | Should -Be 'words'
        }
    }

    It 'a stopped pipeline is not a timeout: a person stopped it' {
        $e = [System.Management.Automation.PipelineStoppedException]::new()
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            (Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord $e)).Transient | Should -BeFalse
        }
    }

    It 'an Azure answer with a status code still decides, whatever the Linux words say' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord 'Store read failed: HTTP 403 Connection reset by peer')
            $v.Transient | Should -BeFalse
            $v.Source    | Should -Be 'text-status'
        }
    }
}