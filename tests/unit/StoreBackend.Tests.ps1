#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI, so there is a stand-in to mock. TEST-AZURE-GUARD-1:
    # defined BEFORE the guard, which now blocks Get-AzAccessToken too.
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # In-memory fake of the Azure Blob data plane behind the single HTTP seam
    # (Invoke-VmfStorageRequest). Implements exactly the semantics the store
    # relies on: If-None-Match:* exclusive create, append blobs, prefix list.
    function Global:Install-FakeBlobService {
        $script:blobs = @{}          # path -> @{ Content; Type }
        $script:containerExists = $false
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = $u.AbsolutePath.TrimStart('/')   # container/prefix/rel
            $query = $u.Query

            if ($query -match 'restype=container' -and $query -match 'comp=list') {
                $prefix = [uri]::UnescapeDataString(([regex]::Match($query, 'prefix=([^&]+)')).Groups[1].Value)
                $container = ($path -split '/')[0]
                $names = $script:blobs.Keys |
                    Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { "<Name>$($_.Substring($container.Length + 1))</Name>" }
                return [pscustomobject]@{ StatusCode = 200; Content = "<EnumerationResults>$($names -join '')</EnumerationResults>"; Headers = @{} }
            }
            if ($query -match 'restype=container') {
                $code = if ($script:containerExists) { 409 } else { $script:containerExists = $true; 201 }
                return [pscustomobject]@{ StatusCode = $code; Content = ''; Headers = @{} }
            }
            if ($query -match 'comp=appendblock') {
                if (-not $script:blobs.ContainsKey($path)) { return [pscustomobject]@{ StatusCode = 404; Content = 'no blob'; Headers = @{} } }
                $script:blobs[$path].Content += $Body
                return [pscustomobject]@{ StatusCode = 201; Content = ''; Headers = @{} }
            }
            switch ($Method) {
                'PUT' {
                    if ($Headers['If-None-Match'] -eq '*' -and $script:blobs.ContainsKey($path)) {
                        return [pscustomobject]@{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} }
                    }
                    # LEASE-HEARTBEAT-RACE-1: a lease renewal is a write with
                    # If-Match on the ETag of the text it read, as blob storage
                    # gives one on every read.
                    if ($Headers['If-Match'] -and (-not $script:blobs.ContainsKey($path) -or $script:blobs[$path].ETag -ne $Headers['If-Match'])) {
                        return [pscustomobject]@{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} }
                    }
                    $script:blobs[$path] = @{ Content = [string]$Body; Type = $Headers['x-ms-blob-type']; ETag = '"' + [guid]::NewGuid().ToString('N') + '"' }
                    return [pscustomobject]@{ StatusCode = 201; Content = ''; Headers = @{ ETag = $script:blobs[$path].ETag } }
                }
                'GET' {
                    if (-not $script:blobs.ContainsKey($path)) { return [pscustomobject]@{ StatusCode = 404; Content = 'BlobNotFound'; Headers = @{} } }
                    return [pscustomobject]@{ StatusCode = 200; Content = $script:blobs[$path].Content; Headers = @{ ETag = $script:blobs[$path].ETag } }
                }
                'HEAD' {
                    $code = if ($script:blobs.ContainsKey($path)) { 200 } else { 404 }
                    return [pscustomobject]@{ StatusCode = $code; Content = ''; Headers = @{} }
                }
                'DELETE' {
                    if ($Headers -and $Headers['If-Match'] -and $script:blobs.ContainsKey($path) -and $script:blobs[$path].ETag -ne $Headers['If-Match']) {
                        return [pscustomobject]@{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} }
                    }
                    $code = if ($script:blobs.ContainsKey($path)) { $script:blobs.Remove($path); 202 } else { 404 }
                    return [pscustomobject]@{ StatusCode = $code; Content = ''; Headers = @{} }
                }
            }
            [pscustomobject]@{ StatusCode = 500; Content = "unhandled: $Method $Uri"; Headers = @{} }
        }
    }
}

AfterAll { Remove-Item 'function:\Install-FakeBlobService', 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue }

Describe 'run store behaves identically on both backends (STORE-1)' {
    # Same behavioral assertions against the file backend and the azblob
    # backend (fake service) - the contract, not the implementation.
    BeforeEach {
        $script:filePath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-store-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Install-FakeBlobService
    }
    AfterEach { if (Test-Path $script:filePath) { Remove-Item $script:filePath -Recurse -Force } }

    It 'json roundtrip, missing-doc null, exclusive create, list, remove (<backend>)' -TestCases @(
        @{ backend = 'file' }, @{ backend = 'azblob' }
    ) {
        $runPath = if ($backend -eq 'file') { $script:filePath } else { 'azblob://acct/cont/run1' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $runPath } {
            Initialize-VmfStore -RunPath $rp

            Read-VmfStoreJson -RunPath $rp -RelPath 'state/none.json' | Should -BeNullOrEmpty
            Test-VmfStoreItem -RunPath $rp -RelPath 'state/none.json' | Should -BeFalse

            Write-VmfStoreJson -RunPath $rp -RelPath 'state/a.json' -Document @{ x = 1; nested = @{ y = 'z' } }
            (Read-VmfStoreJson -RunPath $rp -RelPath 'state/a.json').nested.y | Should -Be 'z'
            Test-VmfStoreItem -RunPath $rp -RelPath 'state/a.json' | Should -BeTrue

            # exclusive create: exactly one winner
            Write-VmfStoreJsonExclusive -RunPath $rp -RelPath 'leases/l1.lease' -Document @{ w = 'w1' } | Should -BeTrue
            Write-VmfStoreJsonExclusive -RunPath $rp -RelPath 'leases/l1.lease' -Document @{ w = 'w2' } | Should -BeFalse
            (Read-VmfStoreJson -RunPath $rp -RelPath 'leases/l1.lease').w | Should -Be 'w1'

            Write-VmfStoreJson -RunPath $rp -RelPath 'state/b.json' -Document @{ x = 2 }
            Write-VmfStoreJson -RunPath $rp -RelPath 'state/b.txt' -Document @{ x = 3 }
            $names = Get-VmfStoreNames -RunPath $rp -Folder 'state' -Extension '.json'
            @($names) | Sort-Object | Should -Be @('a.json', 'b.json')

            Remove-VmfStoreItem -RunPath $rp -RelPath 'state/a.json'
            Remove-VmfStoreItem -RunPath $rp -RelPath 'state/a.json'   # idempotent
            Test-VmfStoreItem -RunPath $rp -RelPath 'state/a.json' | Should -BeFalse
        }
    }

    It 'line append + read-back preserves order and survives concurrent-style appends (<backend>)' -TestCases @(
        @{ backend = 'file' }, @{ backend = 'azblob' }
    ) {
        $runPath = if ($backend -eq 'file') { $script:filePath } else { 'azblob://acct/cont/run1' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $runPath } {
            Initialize-VmfStore -RunPath $rp
            Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl' | Should -BeNullOrEmpty
            1..5 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
            $lines = Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
            @($lines).Count | Should -Be 5
            ($lines[4] | ConvertFrom-Json).n | Should -Be 5
        }
    }

    It 'leases work end-to-end over azblob: contention, heartbeat ownership, watchdog expiry' {
        $rp = 'azblob://acct/cont/run1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            Initialize-VmfStore -RunPath $rp
            $vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'

            (New-VmfLease -RunPath $rp -VmId $vm -WorkerId 'w1').workerId | Should -Be 'w1'
            New-VmfLease -RunPath $rp -VmId $vm -WorkerId 'w2' | Should -BeNullOrEmpty

            { Update-VmfLeaseHeartbeat -RunPath $rp -VmId $vm -WorkerId 'w2' } | Should -Throw '*held by*'
            Update-VmfLeaseHeartbeat -RunPath $rp -VmId $vm -WorkerId 'w1'

            @(Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds 3600).Count | Should -Be 0
            @(Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds -5).Count | Should -Be 1

            { Remove-VmfLease -RunPath $rp -VmId $vm -WorkerId 'w2' } | Should -Throw '*Refusing*'
            Remove-VmfLease -RunPath $rp -VmId $vm -WorkerId 'w1'
            New-VmfLease -RunPath $rp -VmId $vm -WorkerId 'w2' | Should -Not -BeNullOrEmpty
        }
    }

    It 'state docs + events + run manifest flow over azblob unchanged' {
        $rp = 'azblob://acct/cont/run1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            (Initialize-VmfRun -RunPath $rp -RunId 'blobrun').runId | Should -Be 'blobrun'
            $vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            (New-VmfStateDoc -RunPath $rp -RunId 'blobrun' -VmId $vm).state | Should -Be 'PLANNED'
            (Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'PRECHECK' -Outcome ok).state | Should -Be 'PRECHECK'
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).history.Count | Should -Be 2

            Write-VmfEvent -RunPath $rp -Step 'test' -Outcome ok -VmId $vm -Detail 'hello'
            (Read-VmfEvents -RunPath $rp -Step 'test')[0].detail | Should -Be 'hello'
        }
    }

    It 'Read-VmfJsonDocument reads local paths AND azblob document URIs' {
        InModuleScope VmMigrationFactory -Parameters @{ fp = $script:filePath } {
            Initialize-VmfStore -RunPath 'azblob://acct/cont/run1'
            Write-VmfStoreJson -RunPath 'azblob://acct/cont/run1' -RelPath 'plan.json' -Document @{ kind = 'blob' }
            (Read-VmfJsonDocument -Path 'azblob://acct/cont/run1/plan.json').kind | Should -Be 'blob'

            New-Item -ItemType Directory -Path $fp -Force | Out-Null
            @{ kind = 'file' } | ConvertTo-Json | Set-Content (Join-Path $fp 'plan.json')
            (Read-VmfJsonDocument -Path (Join-Path $fp 'plan.json')).kind | Should -Be 'file'
        }
    }

    It 'store handles: file backend returns paths, azblob returns document URIs' {
        InModuleScope VmMigrationFactory -Parameters @{ fp = $script:filePath } {
            Get-VmfStoreItemHandle -RunPath $fp -RelPath 'plan.json' | Should -Be (Join-Path $fp 'plan.json')
            Get-VmfStoreItemHandle -RunPath 'azblob://acct/cont/run1' -RelPath 'plan.json' |
                Should -Be 'azblob://acct/cont/run1/plan.json'
        }
    }

    It 'rejects a malformed azblob path loudly' {
        InModuleScope VmMigrationFactory {
            { Get-VmfStoreContext -RunPath 'azblob://acct-only' } | Should -Throw '*expected azblob*'
        }
    }
}

Describe 'document handles are read handle-aware everywhere' {
    It 'no module code reads a document HANDLE parameter with Get-Content' {
        # PlanPath / AssessmentPath may be azblob:// URIs since
        # STORE-1 - Get-Content on them dies. REH-2 found Test-VmfQuota
        # still doing it; this guard closes the class.
        $srcRoot = Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory'
        $hits = Get-ChildItem $srcRoot -Recurse -Filter '*.ps1' |
            Select-String -Pattern 'Get-Content\s+\$(PlanPath|AssessmentPath)'
        @($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'storage HTTP seam (no fake service - real Invoke-VmfStorageRequest)' {
    It 'decodes byte[] responses as UTF-8 (octet-stream blobs, live-smoke regression)' {
        # The HTTP seam gives byte[] Content (pwsh did too, for
        # application/octet-stream GETs); [string]([byte[]]) is space-joined
        # numbers, which corrupted every blob read in the first live smoke.
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'fake-token' } }
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            [pscustomobject]@{
                StatusCode = 200
                Content    = [System.Text.Encoding]::UTF8.GetBytes('{"x":1}')
                Headers    = @{}
            }
        }
        InModuleScope VmMigrationFactory {
            $resp = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/b.json'
            $resp.Content | Should -Be '{"x":1}'
        }
    }
}

Describe 'STORE-2: the state store retries like everything else does' {
    # Found live: a connection timeout writing an event after SAFETY_COPY killed
    # the UX-STUCK-1 drill, on a machine that had migrated perfectly well. Every
    # ARM call in the engine has bounded retries with backoff; the state store,
    # written at every checkpoint of every machine, had none.
    BeforeAll {
        $script:storeSrc = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsStorage.ps1') -Raw
    }

    It 'retries at all' {
        $script:storeSrc | Should -Match '\$maxAttempts'
        $script:storeSrc | Should -Match 'for \(\$attempt = 1; \$attempt -le \$maxAttempts'
    }

    It 'retries a connection failure - the case that actually happened' {
        # No response at all: timeout, reset, DNS. The catch has to retry rather
        # than rethrow on the first attempt.
        $script:storeSrc | Should -Match '(?s)catch \{.{0,200}\$transient = \$true'
    }

    It 'retries the server saying "later", and nothing else' {
        $script:storeSrc | Should -Match '429, 500, 502, 503, 504'
        # A 403 or 404 is an ANSWER. Retrying an answer burns the wave's window.
        $script:storeSrc | Should -Not -Match '403, 404'
    }

    It 'backs off, with jitter, so a struggling account is not hammered' {
        $script:storeSrc | Should -Match 'Math\]::Pow\(2, \$attempt - 1\)'
        $script:storeSrc | Should -Match 'Get-Random'
    }

    It 'still surfaces a final non-transient status to the caller' {
        # Callers branch on StatusCode - a 404 from a missing blob is normal and
        # must reach them, not become an exception.
        $script:storeSrc | Should -Match 'if \(\$resp\) \{ break \}'
    }
}
