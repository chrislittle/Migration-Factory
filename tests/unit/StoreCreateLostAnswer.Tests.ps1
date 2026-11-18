#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# STORE-CREATE-LOST-ANSWER-1: a create-only store write whose answer was lost
# read as somebody else's.
#
# Write-VmfStoreTextExclusive creates a document only if it is not there
# (If-None-Match: * on blob storage). Invoke-VmfStorageRequest sends a request
# again when no answer came. When the store wrote the first PUT and its answer
# was lost, the second PUT met the document and the store answered 409 or 412,
# and the write gave $false: "another writer created it". The writer was this
# caller. A worker then left the machine, and its own lease held the machine
# until the lease expired.
#
# A caller whose text holds its writer's id and the time (-UniqueText) now
# reads the document after a 409 or 412, and a document that holds its own
# text (Get-VmfDocumentVersion, PLANVER-2) is its own create - the way
# Write-VmfTextDocumentIfVersion reads back after a 412 (PLAN-WRITE-RACE-1).
# Without -UniqueText, a 409 or 412 stays $false: a text two writers can write
# the same would let both creators win.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:runPath = 'azblob://acct/cont/run-1'
    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/rg-app/providers/microsoft.compute/virtualmachines/app-01'

    # The store as Azure keeps it, behind the one HTTP seam. A PUT whose URI
    # matches $global:ScLose is written, and its answer never reaches the
    # service (a timeout on the client). $global:ScOther is the text another
    # writer creates while that PUT waits; the PUT is then not written.
    function Global:Initialize-ScStore {
        $global:ScBlobs = @{}
        $global:ScTags = @{}
        $global:ScLose = $null
        $global:ScOther = $null
        $global:ScConflict = 409
        $global:ScPuts = [System.Collections.Generic.List[string]]::new()
        $global:ScGetCode = $null
    }
    function Global:Get-ScKey([string]$Uri) { ([uri]$Uri).AbsolutePath }
    function Global:Set-ScBlob([string]$RelUri, [string]$Text) {
        $key = Get-ScKey "https://acct.blob.core.windows.net/cont/$RelUri"
        $global:ScBlobs[$key] = $Text
        $global:ScTags[$key] = '"0x' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '"'
    }
}

Describe 'STORE-CREATE-LOST-ANSWER-1: a create whose answer was lost' {
    BeforeEach {
        Initialize-ScStore
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'create-token' } }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            $key = Get-ScKey $Uri
            $h = @{}; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
            $empty = [byte[]]@()
            if ($Method -in @('GET', 'HEAD')) {
                if ($global:ScGetCode) {
                    # A refusal whose body holds the stored text: only the code can tell the two apart.
                    [byte[]]$body = if ($global:ScBlobs.ContainsKey($key)) { [System.Text.Encoding]::UTF8.GetBytes($global:ScBlobs[$key]) } else { $empty }
                    return [pscustomobject]@{ StatusCode = $global:ScGetCode; Content = $body; Headers = @{} }
                }
                if (-not $global:ScBlobs.ContainsKey($key)) { return [pscustomobject]@{ StatusCode = 404; Content = $empty; Headers = @{} } }
                [byte[]]$bytes = if ($Method -eq 'GET') { [System.Text.Encoding]::UTF8.GetBytes($global:ScBlobs[$key]) } else { $empty }
                return [pscustomobject]@{ StatusCode = 200; Content = $bytes; Headers = @{ ETag = @($global:ScTags[$key]) } }
            }
            if ($Method -eq 'DELETE') {
                $null = $global:ScBlobs.Remove($key)
                return [pscustomobject]@{ StatusCode = 202; Content = $empty; Headers = @{} }
            }
            $global:ScPuts.Add($key)
            $text = [System.Text.Encoding]::UTF8.GetString($Body)
            $lose = $global:ScLose -and $key -like $global:ScLose
            if ($lose) {
                $global:ScLose = $null
                if ($null -ne $global:ScOther) {
                    # Another writer created it first; this PUT is refused,
                    # and its answer is lost too.
                    $global:ScBlobs[$key] = $global:ScOther
                    $global:ScTags[$key] = '"0xother"'
                    throw [System.TimeoutException]::new('No answer from the run store in 20 seconds: the request timed out.')
                }
            }
            if ($h['If-None-Match'] -eq '*' -and $global:ScBlobs.ContainsKey($key)) {
                return [pscustomobject]@{ StatusCode = $global:ScConflict; Content = $empty; Headers = @{} }
            }
            if ($h['If-Match'] -and $h['If-Match'] -ne $global:ScTags[$key]) {
                return [pscustomobject]@{ StatusCode = 412; Content = $empty; Headers = @{} }
            }
            $global:ScBlobs[$key] = $text
            $global:ScTags[$key] = '"0x' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '"'
            if ($lose) { throw [System.TimeoutException]::new('No answer from the run store in 20 seconds: the request timed out.') }
            [pscustomobject]@{ StatusCode = 201; Content = $empty; Headers = @{} }
        }
    }
    AfterEach { Remove-Variable -Name ScBlobs, ScTags, ScLose, ScOther, ScConflict, ScPuts, ScGetCode -Scope Global -ErrorAction SilentlyContinue }

    Context 'the create itself' {
        It 'a unique text that landed, sent again after its timeout, is this call''s create (store answers <code>)' -ForEach @(@{ code = 409 }, @{ code = 412 }) {
            $global:ScConflict = $code
            $global:ScLose = '*/run-1/doc.json'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w1","t":"2026-11-11T10:00:00.1234567Z"}' -UniqueText
            } | Should -BeTrue
            $global:ScPuts.Count | Should -Be 2 -Because 'the first PUT timed out on the client and was sent again, and the store answered with a conflict'
        }

        It 'without -UniqueText the same conflict stays $false: two writers of one text must not both win' {
            $global:ScLose = '*/run-1/doc.json'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w1"}'
            } | Should -BeFalse
            $global:ScPuts.Count | Should -Be 2
        }

        It 'another writer''s text, met after the timeout, is still $false' {
            $global:ScLose = '*/run-1/doc.json'
            $global:ScOther = '{"w":"w2","t":"2026-11-11T10:00:00.7654321Z"}'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w1","t":"2026-11-11T10:00:00.1234567Z"}' -UniqueText
            } | Should -BeFalse
            $global:ScBlobs['/cont/run-1/doc.json'] | Should -Be $global:ScOther
        }

        It 'a document that is there before the create, with another text, is $false with one PUT' {
            Set-ScBlob 'run-1/doc.json' '{"w":"w2"}'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w1"}' -UniqueText
            } | Should -BeFalse
            $global:ScPuts.Count | Should -Be 1
        }

        It 'a read back that finds nothing (removed in between) is $false' {
            Set-ScBlob 'run-1/doc.json' '{"w":"w2"}'
            $global:ScGetCode = 404
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w2"}' -UniqueText
            } | Should -BeFalse
        }

        It 'a read back the store refuses is $false, as before - never a create it cannot show' {
            Set-ScBlob 'run-1/doc.json' '{"w":"w1"}'
            $global:ScGetCode = 403
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w1"}' -UniqueText
            } | Should -BeFalse
        }

        It 'a read back that gets no answer is $false, as before - not an error from a create' {
            Set-ScBlob 'run-1/doc.json' '{"w":"w1"}'
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest -ParameterFilter { $Method -eq 'GET' } { throw 'State store request got no answer.' }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w1"}' -UniqueText
            } | Should -BeFalse
        }

        It 'Write-VmfStoreJsonExclusive passes -UniqueText on' {
            $global:ScLose = '*/run-1/doc.json'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfStoreJsonExclusive -RunPath $rp -RelPath 'doc.json' -Document ([ordered]@{ w = 'w1'; t = '2026-11-11T10:00:00.1234567Z' }) -UniqueText
            } | Should -BeTrue
        }

        It 'the file backend is as it was: a second create of the same text is $false' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-scla-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                InModuleScope VmMigrationFactory -Parameters @{ rp = $dir } {
                    Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w1"}' -UniqueText | Should -BeTrue
                    Write-VmfStoreTextExclusive -RunPath $rp -RelPath 'doc.json' -Content '{"w":"w1"}' -UniqueText | Should -BeFalse
                }
            }
            finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'the callers' {
        It 'a worker''s lease whose answer was lost is its lease: the worker keeps the machine' {
            $global:ScLose = '*/run-1/leases/*'
            $lease = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1'
            }
            $lease | Should -Not -BeNullOrEmpty -Because 'the lease in the store is the one this worker wrote'
            $lease.workerId | Should -Be 'w1'
            $global:ScPuts.Count | Should -Be 2
        }

        It 'another worker''s lease met after the timeout is still not this worker''s' {
            $global:ScLose = '*/run-1/leases/*'
            $global:ScOther = '{"schemaVersion":1,"vmId":"x","workerId":"w2","acquiredUtc":"2026-11-11T10:00:00.0000000Z","heartbeatUtc":"2026-11-11T10:00:00.0000000Z"}'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1'
            } | Should -BeNullOrEmpty
        }

        It 'a first claim whose answer was lost is granted to this migration, not read as another''s' {
            $global:ScLose = '*/vmf-claims/*'
            $claim = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                New-VmfVmClaim -RunPath $rp -VmId $id -RunId 'run-1'
            }
            $claim.Granted | Should -BeTrue
            $claim.HeldBy | Should -Be 'run-1'
            $claim.Detail | Should -Be 'claimed' -Because 'the create is this migration''s own, not a claim it found'
        }

        It 'the first record of a migration whose answer was lost is kept, not refused as written again' {
            Set-ScBlob 'run-1/run.json' '{"runId":"run-1"}'
            $global:ScLose = '*/records/*'
            { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                    Save-VmfRecordUnlessDeleting -RunPath $rp -Scope 'azblob://acct/cont/records' -Name 'run-1.json' `
                        -Record ([ordered]@{ runId = 'run-1'; reason = 'download'; generatedUtc = '2026-11-11T10:00:00.1234567Z' }) -ExpectedVersion ''
                } } | Should -Not -Throw
            $global:ScPuts.Count | Should -Be 2
        }

        It 'a first record that meets another record after the timeout is still refused' {
            Set-ScBlob 'run-1/run.json' '{"runId":"run-1"}'
            $global:ScLose = '*/records/*'
            $global:ScOther = '{"runId":"run-1","reason":"waveEnded","generatedUtc":"2026-11-11T09:59:59.0000000Z"}'
            { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                    Save-VmfRecordUnlessDeleting -RunPath $rp -Scope 'azblob://acct/cont/records' -Name 'run-1.json' `
                        -Record ([ordered]@{ runId = 'run-1'; reason = 'download'; generatedUtc = '2026-11-11T10:00:00.1234567Z' }) -ExpectedVersion ''
                } } | Should -Throw '409: The record of this migration was written again*'
        }

        It 'the first list of machines whose answer was lost is saved, not refused as somebody else''s' {
            $advice = InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } {
                [ordered]@{ schemaVersion = (Get-VmfTargetAdviceSchemaVersion); assessmentId = 'run-1'; assessmentHash = 'h1'
                    machines = @([ordered]@{ vmId = $id; name = 'app-01'; sourceSize = 'Standard_D2ds_v4'; options = @([ordered]@{ series = 'Dsv6'; supported = $true }) }) } |
                    ConvertTo-Json -Depth 10
            }
            Set-ScBlob 'run-1/target-advice.json' $advice
            $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ t = $advice } { Get-VmfDocumentVersion -Text $t }
            $global:ScLose = '*/run-1/machine-choices.json'
            $saved = Set-VmfMachineChoice -RunPath $script:runPath -Machines @($script:vmId) -ExpectedAdviceVersion $adviceVersion `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
            $saved.Chosen | Should -Be 1
            $global:ScPuts.Count | Should -Be 2
        }

        It 'the first run-status.json whose answer was lost is the document written, not built and written again' {
            $global:ScLose = '*/run-1/run-status.json'
            $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                Write-VmfRunStatusDocument -RunPath $rp -PlanPath "$rp/plan.json" -Reason 'waveRunning' `
                    -Live ([ordered]@{ wave = 'w1'; updatedUtc = '2026-11-11T10:00:00.1234567Z'; stateCounts = [ordered]@{ PLANNED = 1 } })
            }
            $doc.wave | Should -Be 'w1'
            @($global:ScPuts | Where-Object { $_ -like '*/run-status.json' }).Count | Should -Be 2 -Because 'the PUT sent again met its own text: no third write'
        }
    }
}
