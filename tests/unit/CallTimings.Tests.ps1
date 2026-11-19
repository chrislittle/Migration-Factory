#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERF-TELEMETRY-1: the service records the time of each call it makes to the
# run store and to Azure Resource Manager, so a slow page or a slow timer pass
# can be split into store time, ARM time and the service's own time.
#
# WHY A TRACE LINE AND NOT A DEPENDENCY RECORD. Microsoft's PowerShell worker
# has no API for a custom dependency: OpenTelemetry output to Application
# Insights "isn't currently supported for PowerShell apps"
# (learn.microsoft.com/azure/azure-functions/opentelemetry-howto, PowerShell
# pivot), and the classic SDK route is documented for C#, JavaScript and Python
# only (functions-monitoring, "Dependencies"). What the worker DOES carry is
# the information stream: Write-Information lands in `traces` at the
# Information level (functions-reference-powershell, "Logging"), with the
# invocation's operation_Id. So each invocation writes ONE line that holds
# its calls, and a query joins it to `requests` by operation_Id.
#
# WHY ONE LINE PER INVOCATION AND NOT ONE PER CALL. A schedule pass makes
# about a thousand store calls (a 60 s pass at about 50 ms a read), every five
# minutes. One trace row per call would be about 300,000 rows a day, more
# than the workspace's 0.2 GB daily cap on its own. One line per invocation,
# with the slowest calls named inside it, is about 7,200 rows a day.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_FakeBlobService.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: stand-ins to mock, defined BEFORE the guard.
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # The fake sink: every line the service would write to Application
    # Insights lands here instead.
    function Global:Reset-TimingSink {
        $global:VmfTestTimingLines = [System.Collections.Generic.List[string]]::new()
    }
    function Global:Get-TimingRecord {
        @($global:VmfTestTimingLines) | ForEach-Object {
            $_ | Should -Match '^VMF-CALLS \{'
            $_.Substring('VMF-CALLS '.Length) | ConvertFrom-Json -Depth 10
        }
    }
    function Global:New-TimingViewer {
        $doc = @{ auth_typ = 'aad'; claims = @(@{ typ = 'preferred_username'; val = 'viewer@example.com' }, @{ typ = 'roles'; val = 'Vmf.Viewer' }) } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
    $script:secretToken = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.secret-token-value'
}
AfterAll { Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue }

Describe 'PERF-TELEMETRY-1: one timing line per invocation, from the store seam' {
    BeforeEach {
        Reset-TimingSink
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { $global:VmfTestTimingLines.Add($Message) }
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = $script:secretToken } }
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            $code = if ($Uri -like '*missing*') { 404 } else { 200 }
            [pscustomobject]@{ StatusCode = $code; Content = '{}'; Headers = @{} }
        }
        # Every call is "slow" here, so each one is named in the line and its
        # fields can be read.
        InModuleScope VmMigrationFactory { $script:VmfCallTimingSlowMs = 0; $script:VmfCallTimingInterimMs = 600000 }
    }
    AfterEach {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimingSlowMs = 1000; $script:VmfCallTimingInterimMs = 240000; $script:VmfCallTimings = $null
        }
    }

    It 'records nothing when no invocation started the timings (the engine, a test, a script)' {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimings = $null
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/runs/r1/run.json'
            Complete-VmfCallTimings
        }
        $global:VmfTestTimingLines.Count | Should -Be 0
    }

    It 'writes one line with each store call: kind, operation, target, status, time and success' {
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/runs/r1/run.json'
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/runs/r1/missing.json'
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c?restype=container&comp=list&prefix=runs%2Fr1%2F'
            $null = Invoke-VmfStorageRequest -Method PUT -Uri 'https://acct.blob.core.windows.net/c/runs/r1/state/vm-a.json' -Body '{}'
            Complete-VmfCallTimings
        }
        $global:VmfTestTimingLines.Count | Should -Be 1
        $rec = Get-TimingRecord
        $rec.v | Should -Be 1
        $rec.partial | Should -BeFalse
        $rec.store.n | Should -Be 4
        $rec.store.fail | Should -Be 0 -Because 'a 404 is an answer: the page asked for a document that does not exist'
        $rec.ops.'store read'.n | Should -Be 2
        $rec.ops.'store list'.n | Should -Be 1
        $rec.ops.'store write'.n | Should -Be 1
        $rec.token.n | Should -Be 4 -Because 'each store call asks for a token first, and that time is its own figure'
        @($rec.slow).Count | Should -Be 4
        $first = @($rec.slow | Where-Object { $_.target -eq 'runs/r1/run.json' })
        $first.Count | Should -Be 1
        $first[0].k | Should -Be 'store'
        $first[0].op | Should -Be 'read'
        $first[0].status | Should -Be 200
        $first[0].ok | Should -BeTrue
        $first[0].ms | Should -BeGreaterOrEqual 0
        @($rec.slow | Where-Object { $_.target -eq 'runs/r1/missing.json' })[0].status | Should -Be 404
        @($rec.slow | Where-Object { $_.op -eq 'list' })[0].target | Should -Be 'runs/r1/'
    }

    It 'gives the total, the longest call, and the time that was the service itself' {
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/c/a.json' -Status 200 -DurationMs 300
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/c/b.json' -Status 200 -DurationMs 700
            Add-VmfCallTiming -Kind arm -Method GET -Target '/subscriptions?api-version=2022-12-01' -Status 200 -DurationMs 250
            $sum = Get-VmfCallTimingSummary -ElapsedMs 2000
            $sum.store.n | Should -Be 2
            $sum.store.ms | Should -Be 1000
            $sum.store.max | Should -Be 700
            $sum.arm.ms | Should -Be 250
            $sum.ms | Should -Be 2000
            $sum.other | Should -Be 750 -Because 'the service''s own share is what is left after the store and ARM'
        }
    }

    It 'counts reads sent at once as calls, but their side-by-side time once, as the batch''s wall time' {
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            foreach ($i in 1..3) {
                Add-VmfCallTiming -Kind store -Method GET -Target "https://acct.blob.core.windows.net/c/r$i.json" -Status 200 -DurationMs 300 -Overlapped
            }
            Add-VmfCallTiming -Kind store -Operation 'many' -DurationMs 350 -TimeOnly
            $sum = Get-VmfCallTimingSummary -ElapsedMs 1000
            $sum.store.n | Should -Be 3
            $sum.store.ms | Should -Be 350 -Because 'three reads of 300 ms side by side took 350 ms of the call, not 900'
            $sum.store.max | Should -Be 300
            $sum.ops['store read'].n | Should -Be 3
            $sum.ops['store read'].ms | Should -Be 900
            $sum.ops['store many'].n | Should -Be 1
            $sum.other | Should -Be 650
            @($sum.slow).Count | Should -Be 3 -Because 'the batch itself is not a call'
        }
    }

    It 'resets at the start of each invocation, because runspaces are reused' {
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/one.json'
            # The finally of that invocation never ran (a worker shut down).
            Start-VmfCallTimings
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/two.json'
            Complete-VmfCallTimings
            # And after the line is written, nothing is recorded until the next start.
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/three.json'
            Complete-VmfCallTimings
        }
        $global:VmfTestTimingLines.Count | Should -Be 1
        (Get-TimingRecord).store.n | Should -Be 1
        @((Get-TimingRecord).slow)[0].target | Should -Be 'two.json'
    }

    It 'records a call that threw as a failure with no status, and still throws it to the caller' {
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest { throw 'connection reset' }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            { Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' } | Should -Throw '*connection reset*'
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.store.n | Should -Be 1
        $rec.store.fail | Should -Be 1
        @($rec.slow)[0].status | Should -Be 0
        @($rec.slow)[0].ok | Should -BeFalse
    }

    It 'counts a create that lost (409) and a version that moved (412) as answers, not failures' {
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            $code = if ($Uri -like '*lease*') { 409 } else { 412 }
            [pscustomobject]@{ StatusCode = $code; Content = ''; Headers = @{} }
        }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            $null = Invoke-VmfStorageRequest -Method PUT -Uri 'https://acct.blob.core.windows.net/c/runs/r1/leases/vm-a.json' -Body '{}'
            $null = Invoke-VmfStorageRequest -Method PUT -Uri 'https://acct.blob.core.windows.net/c/runs/r1/plan.json' -Body '{}'
            Complete-VmfCallTimings
        }
        (Get-TimingRecord).store.n | Should -Be 2
        (Get-TimingRecord).store.fail | Should -Be 0
    }

    It 'counts a refused store call (403, 500) as a failure' {
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest { [pscustomobject]@{ StatusCode = 403; Content = ''; Headers = @{} } }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json'
            Complete-VmfCallTimings
        }
        (Get-TimingRecord).store.fail | Should -Be 1
        @((Get-TimingRecord).slow)[0].ok | Should -BeFalse
    }

    It 'names only slow or failed calls, and at most ten, keeping the slowest' {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimingSlowMs = 1000
            Start-VmfCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/c/fast.json' -Status 200 -DurationMs 40
            foreach ($i in 1..12) {
                Add-VmfCallTiming -Kind store -Method GET -Target "https://acct.blob.core.windows.net/c/slow$i.json" -Status 200 -DurationMs (1000 + $i * 100)
            }
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.store.n | Should -Be 13
        @($rec.slow).Count | Should -Be 10
        @($rec.slow.target) | Should -Not -Contain 'fast.json'
        @($rec.slow.target) | Should -Not -Contain 'slow1.json'
        @($rec.slow.target) | Should -Not -Contain 'slow2.json'
        @($rec.slow.target) | Should -Contain 'slow12.json'
        $rec.slowDropped | Should -Be 2
    }

    It 'writes a partial line once when an invocation runs long, so a pass that times out is still measured' {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimingInterimMs = 0
            Start-VmfCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/c/a.json' -Status 200 -DurationMs 10
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/c/b.json' -Status 200 -DurationMs 10
            Complete-VmfCallTimings
        }
        $global:VmfTestTimingLines.Count | Should -Be 2
        $recs = @(Get-TimingRecord)
        $recs[0].partial | Should -BeTrue
        $recs[0].store.n | Should -Be 1
        $recs[1].partial | Should -BeFalse
        $recs[1].store.n | Should -Be 2
    }
}

Describe 'PERF-TELEMETRY-1: nothing secret is recorded' {
    BeforeEach {
        Reset-TimingSink
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { $global:VmfTestTimingLines.Add($Message) }
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = $script:secretToken } }
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest { [pscustomobject]@{ StatusCode = 200; Content = '{}'; Headers = @{} } }
        InModuleScope VmMigrationFactory { $script:VmfCallTimingSlowMs = 0 }
    }
    AfterEach { InModuleScope VmMigrationFactory { $script:VmfCallTimingSlowMs = 1000; $script:VmfCallTimings = $null } }

    It 'records no token, no account, no query string and no signature' {
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/runs/r1/plan.json?sv=2023-11-03&sig=SIGNATUREVALUE&se=2030-01-01'
            $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c?restype=container&comp=list&prefix=runs%2F&marker=NEXTMARKER'
            Complete-VmfCallTimings
        }
        $line = $global:VmfTestTimingLines[0]
        $line | Should -Not -Match 'secret-token-value'
        $line | Should -Not -Match 'eyJ0eXAi'
        $line | Should -Not -Match 'SIGNATUREVALUE'
        $line | Should -Not -Match 'sig='
        $line | Should -Not -Match 'NEXTMARKER'
        $line | Should -Not -Match 'Bearer'
        $line | Should -Not -Match 'acct'
        $line | Should -Not -Match 'blob\.core'
        @((Get-TimingRecord).slow.target) | Should -Contain 'runs/r1/plan.json'
    }

    It 'redacts a store address that is not a blob in a storage account' {
        InModuleScope VmMigrationFactory {
            ConvertTo-VmfCallTarget -Kind store -Target 'https://evil.example.com/c/x.json?code=ABC' | Should -Be '<redacted>'
            ConvertTo-VmfCallTarget -Kind store -Target 'not a uri' | Should -Be '<redacted>'
            ConvertTo-VmfCallTarget -Kind store -Target 'https://acct.blob.core.windows.net/c/a%20b/x.json?x=1' | Should -Be 'a b/x.json'
        }
    }

    It 'names an ARM call by its resource type, never by a subscription, a group or a resource name' {
        InModuleScope VmMigrationFactory {
            $id = '/subscriptions/aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e/resourceGroups/rg-contoso/providers/Microsoft.App/jobs/job-contoso'
            ConvertTo-VmfCallTarget -Kind arm -Target "$id/start?api-version=2025-01-01" |
                Should -Be 'subscriptions/{}/resourceGroups/{}/providers/Microsoft.App/jobs/{}/start'
            ConvertTo-VmfCallTarget -Kind arm -Target "$id/executions?api-version=2025-01-01" |
                Should -Be 'subscriptions/{}/resourceGroups/{}/providers/Microsoft.App/jobs/{}/executions'
            ConvertTo-VmfCallTarget -Kind arm -Target '/subscriptions?api-version=2022-12-01' | Should -Be 'subscriptions'
            ConvertTo-VmfCallTarget -Kind arm -Target '/subscriptions/aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e/resourcegroups?api-version=2021-04-01' |
                Should -Be 'subscriptions/{}/resourcegroups'
            ConvertTo-VmfCallTarget -Kind arm -Target '/providers/Microsoft.Management/managementGroups?api-version=2021-04-01' |
                Should -Be 'providers/Microsoft.Management/managementGroups'
            # A nextLink is a whole address with a skip token in its query.
            ConvertTo-VmfCallTarget -Kind arm -Target "https://management.azure.com$id/executions?api-version=2025-01-01&`$skiptoken=TOKENVALUE" |
                Should -Be 'subscriptions/{}/resourceGroups/{}/providers/Microsoft.App/jobs/{}/executions'
            ConvertTo-VmfCallTarget -Kind arm -Target 'https://evil.example.com/x?y=1' | Should -Be '<redacted>'
        }
    }
}

Describe 'PERF-TELEMETRY-1: telemetry never fails the call' {
    BeforeEach {
        Reset-TimingSink
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'fake-token' } }
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"x":1}'; Headers = @{} } }
    }
    AfterEach { InModuleScope VmMigrationFactory { $script:VmfCallTimings = $null } }

    It 'a sink that throws does not fail the invocation' {
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { throw 'Application Insights is down' }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            (Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/a.json').Content | Should -Be '{"x":1}'
            { Complete-VmfCallTimings } | Should -Not -Throw
        }
    }

    It 'a broken record does not fail the store call it measures' {
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { $global:VmfTestTimingLines.Add($Message) }
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimings = 'not a record'
            (Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/a.json').Content | Should -Be '{"x":1}'
            { Add-VmfCallTiming -Kind store -Method GET -Target 'x' -Status 200 -DurationMs 1 } | Should -Not -Throw
            { Complete-VmfCallTimings } | Should -Not -Throw
        }
    }

    It 'a start or an end that fails does not fail the function (the facade wrappers)' {
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { throw 'down' }
        Mock -ModuleName VmMigrationFactory Start-VmfCallTimings { throw 'broken' }
        { Start-VmfFacadeCallTimings } | Should -Not -Throw
        Mock -ModuleName VmMigrationFactory Complete-VmfCallTimings { throw 'broken' }
        { Complete-VmfFacadeCallTimings } | Should -Not -Throw
    }

    It 'the real sink writes to the information stream, which the worker sends to traces' {
        $records = InModuleScope VmMigrationFactory { Write-VmfCallTimingLine -Message 'VMF-CALLS {"v":1}' 6>&1 }
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 1
        [string]@($records)[0].MessageData | Should -Be 'VMF-CALLS {"v":1}'
    }
}

Describe 'PERF-TELEMETRY-1: ARM calls' {
    BeforeEach {
        Reset-TimingSink
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { $global:VmfTestTimingLines.Add($Message) }
        InModuleScope VmMigrationFactory { $script:VmfCallTimingSlowMs = 0 }
    }
    AfterEach { InModuleScope VmMigrationFactory { $script:VmfCallTimingSlowMs = 1000; $script:VmfCallTimings = $null; $script:VmfCallTimingArmDepth = 0 } }

    It 'the facade''s own ARM calls are recorded, with the facade''s mocks still in force' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"name":"rg-a","location":"centralus"}]}' }
        }
        Start-VmfFacadeCallTimings
        $principal = New-TimingViewer
        $groups = @(Get-VmfFacadeResourceGroupList -Principal $principal -SubscriptionId 'aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e')
        Complete-VmfFacadeCallTimings
        $groups.Count | Should -Be 1
        Should -Invoke -ModuleName FacadeCore Invoke-AzRestMethod -Times 1 -Exactly
        $rec = Get-TimingRecord
        $rec.arm.n | Should -Be 1
        $rec.arm.fail | Should -Be 0
        @($rec.slow)[0].status | Should -Be 200
        @($rec.slow)[0].ok | Should -BeTrue
        $rec.ops.'arm GET'.n | Should -Be 1
        @($rec.slow)[0].k | Should -Be 'arm'
        @($rec.slow)[0].target | Should -Be 'subscriptions/{}/resourcegroups'
        $global:VmfTestTimingLines[0] | Should -Not -Match 'aaaa0a0a'
    }

    It 'a facade ARM call that throws is a failure, and the error still reaches the caller' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'AuthorizationFailed' }
        Start-VmfFacadeCallTimings
        $principal = New-TimingViewer
        { Get-VmfFacadeResourceGroupList -Principal $principal -SubscriptionId 'aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e' } | Should -Throw '*AuthorizationFailed*'
        Complete-VmfFacadeCallTimings
        (Get-TimingRecord).arm.fail | Should -Be 1
    }

    It 'each page of an ARM list is one call' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[1],"nextLink":"https://management.azure.com/subscriptions/x/providers/A.B/c?page=2"}' }
        }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Uri } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[2]}' }
        }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            $r = Get-VmfArmList -Path '/subscriptions/x/providers/A.B/c?api-version=1'
            $r.Items.Count | Should -Be 2
            Complete-VmfCallTimings
        }
        (Get-TimingRecord).arm.n | Should -Be 2
        (Get-TimingRecord).arm.fail | Should -Be 0
        # The second page is named from its nextLink, without the query.
        @((Get-TimingRecord).slow.target) | Should -Be @('subscriptions/{}/providers/A.B/c', 'subscriptions/{}/providers/A.B/c')
    }

    It 'the daily cleanup''s reads of a safety copy and a disk are ARM calls, and a 404 there is an answer' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = '' } }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            Test-VmfSnapshotExists -SnapshotId '/subscriptions/aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e/resourceGroups/rg-a/providers/Microsoft.Compute/snapshots/snap-a' | Should -BeFalse
            (Get-VmfManagedDiskAttachment -DiskId '/subscriptions/aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e/resourceGroups/rg-a/providers/Microsoft.Compute/disks/disk-a').Exists | Should -BeFalse
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.arm.n | Should -Be 2
        $rec.arm.fail | Should -Be 0 -Because 'a copy that is already gone is an answer, not a failed call'
        @($rec.slow.target) | Should -Contain 'subscriptions/{}/resourceGroups/{}/providers/Microsoft.Compute/snapshots/{}'
    }

    It 'the preview feature read is two ARM calls' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"displayName":"Contoso","properties":{"state":"Registered"}}' } }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            $null = Get-VmfPreviewFeatureState -SubscriptionId 'aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e'
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.arm.n | Should -Be 2
        $global:VmfTestTimingLines[0] | Should -Not -Match 'aaaa0a0a'
    }

    It 'an Azure operation is one ARM call by its name, and the calls inside it are not counted twice' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            $null = Invoke-VmfAzOperation -Name 'skuCatalog' -Operation {
                Get-VmfArmList -Path '/subscriptions/x/providers/A.B/c?api-version=1'
                Invoke-VmfAzOperation -Name 'innerRead' -Operation { 1 }
            }
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.arm.n | Should -Be 1
        $rec.ops.'arm skuCatalog'.n | Should -Be 1
        $rec.ops.Keys | Should -Not -Contain 'arm innerRead'
        $rec.arm.fail | Should -Be 0
    }

    It 'an Azure operation that fails each try is a failure on each try, and later ARM calls still count' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            { Invoke-VmfAzOperation -Name 'readThing' -MaxAttempts 2 -BaseDelayMs 1 -Operation { throw 'HTTP 503 ServiceUnavailable' } } | Should -Throw
            $null = Get-VmfArmList -Path '/subscriptions/x/providers/A.B/c?api-version=1'
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.arm.n | Should -Be 3
        $rec.arm.fail | Should -Be 2
        $rec.ops.'arm GET'.n | Should -Be 1 -Because 'a failed operation must not leave later ARM calls uncounted'
    }
}

Describe 'PERF-TELEMETRY-1: every function of the service writes its line' {
    It '<name> starts the timings before its body and writes them in a finally' -ForEach @(
        Get-ChildItem (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'facade' 'app') -Recurse -Filter 'run.ps1' |
            ForEach-Object { @{ name = $_.Directory.Name; file = $_.FullName } }
    ) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $top = @($ast.EndBlock.Statements)
        $tryIndex = [array]::FindLastIndex([object[]]$top, [Predicate[object]] { param($s) $s -is [System.Management.Automation.Language.TryStatementAst] })
        $tryIndex | Should -BeGreaterOrEqual 0
        $try = $top[$tryIndex]
        $before = @($top[0..($tryIndex)] | Select-Object -SkipLast 1 | ForEach-Object { $_.Extent.Text })
        ($before -join "`n") | Should -Match '(?m)^Start-VmfFacadeCallTimings\s*$'
        $try.Finally | Should -Not -BeNullOrEmpty
        $try.Finally.Extent.Text | Should -Match 'Complete-VmfFacadeCallTimings'
        # And nothing runs after the finally that the line would miss.
        ($top.Count - 1) | Should -Be $tryIndex
    }
}

Describe 'PERF-TELEMETRY-1: the reads sent together (Invoke-VmfStorageGetMany)' {
    BeforeAll {
        $script:manyDir = Join-Path (New-VmfTestTemp -Prefix 'calltimings') 'c'
        New-Item -ItemType Directory -Path $script:manyDir | Out-Null
        foreach ($i in 1..6) { Set-Content (Join-Path $script:manyDir "doc$i.json") -Value "{`"n`":$i}" -NoNewline -Encoding utf8NoBOM }
        $script:manySvc = [VmfFakeBlobService]::new($script:manyDir, 20)
        $script:manySvc.RequireToken = 'Bearer many-token'
        $script:ManyUri = { param($name) "$($script:manySvc.BaseUri)cont/$name" }
    }
    AfterAll { $script:manySvc.Dispose(); Remove-VmfTestTemp }
    BeforeEach {
        Reset-TimingSink
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { $global:VmfTestTimingLines.Add($Message) }
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'many-token' } }
    }
    AfterEach { InModuleScope VmMigrationFactory { $script:VmfCallTimings = $null } }

    It 'counts each read as a store call, one token, and the batch''s wall time once' {
        $uris = @(1..6 | ForEach-Object { & $script:ManyUri "doc$_.json" }) + @(& $script:ManyUri 'nothing.json')
        InModuleScope VmMigrationFactory -Parameters @{ u = $uris } {
            Start-VmfCallTimings
            $out = Invoke-VmfStorageGetMany -Uri $u -Limit 4
            $out.Count | Should -Be 7
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.store.n | Should -Be 7
        $rec.store.fail | Should -Be 0 -Because 'a document that is not there is an answer'
        $rec.token.n | Should -Be 1
        $rec.ops.'store read'.n | Should -Be 7
        $rec.ops.'store read many'.n | Should -Be 1
        $rec.store.ms | Should -Be $rec.ops.'store read many'.ms -Because 'the reads ran side by side: the store''s share is the batch''s wall time'
        $rec.store.ms | Should -BeLessOrEqual $rec.ms
    }

    It 'a read that gets no answer at all is a failed call with no status' {
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest { throw 'connection refused' }
        $uris = @('http://127.0.0.1:1/cont/doc1.json')
        InModuleScope VmMigrationFactory -Parameters @{ u = $uris } {
            Start-VmfCallTimings
            { Invoke-VmfStorageGetMany -Uri $u -Limit 4 } | Should -Throw '*connection refused*'
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.store.n | Should -Be 2 -Because 'the read sent together, and the same read sent again one at a time'
        $rec.store.fail | Should -Be 2
        @($rec.slow | Where-Object { $_.status -eq 0 }).Count | Should -Be 2
    }

    It 'a read the service answers "later" is a failed call, and the read sent again is counted too' {
        $script:manySvc.FailFirst['doc5.json'] = 1
        $uris = @((& $script:ManyUri 'doc5.json'), (& $script:ManyUri 'doc6.json'))
        InModuleScope VmMigrationFactory -Parameters @{ u = $uris } {
            Start-VmfCallTimings
            $out = Invoke-VmfStorageGetMany -Uri $u -Limit 4
            $out[0].StatusCode | Should -Be 200
            Complete-VmfCallTimings
        }
        $rec = Get-TimingRecord
        $rec.store.n | Should -Be 3
        $rec.store.fail | Should -Be 1
        $rec.store.ms | Should -BeGreaterOrEqual $rec.ops.'store read many'.ms
    }
}
