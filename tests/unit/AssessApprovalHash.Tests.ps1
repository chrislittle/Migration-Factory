#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ASSESS-APPROVAL-HASH-1 (Claude Security scan, finding F13): planning takes
# only an approval of the scan it plans from.
#
# Before this, Approve-VmfAssessment recorded the hash of the scan the approver
# read, and nothing ever compared it: New-VmfPlan and New-VmfTargetAdvice asked
# only that approval.json was there. Invoke-VmfAssessment refused a run that
# already held a scan when it STARTED, then wrote assessment.json at the end
# with no condition - so two scans started on one run id (Back, then Start
# looking, on the wizard's wait) both passed the start check, and the second
# to finish replaced the first, also after somebody approved the first. A
# migration could then be planned from a scan no approver read.
#
# What these tests hold:
#   - New-VmfPlan and New-VmfTargetAdvice refuse an approval whose
#     assessmentHash is not the version (PLANVER-2) of the assessment text
#     they read, and accept an approval as 1.0.0 wrote it;
#   - Approve-VmfAssessment takes the version the page was shown and refuses
#     another with '409: ...', writing nothing; the service requires it, and
#     its route answers 409 for it;
#   - a scan never replaces another: the final write is create-only;
#   - the service refuses a second scan of a run while Azure lists one.

BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI, so the service tests mock a stand-in, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'assessapprovalhash'

    $script:who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }

    # The text of one finished scan. -Stamp is when it was made, so two scans
    # of one run differ.
    function Global:AahScan {
        param([string]$RunPath, [string]$Stamp = '2026-11-22T00:00:00Z')
        [ordered]@{ schemaVersion = 17; runId = (Split-Path $RunPath -Leaf); generatedUtc = $Stamp
            scope = @{ subscriptions = @() }; summary = @{}; vms = @() } | ConvertTo-Json -Depth 10
    }
    function Global:AahNew {
        $rp = Join-Path $script:temp "aah-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp } { param($p)
            Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $rp 'assessment.json'), (AahScan -RunPath $rp))
        $rp
    }
    # The version the service issues for the stored assessment (PLANVER-2).
    function Global:AahVersion([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ p = $RunPath } { param($p)
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath 'assessment.json'))
        }
    }
    # SHA-256 of the file's text, worked out here, not by the product: what a
    # 1.0.0 approval holds.
    function Global:AahSha([string]$File) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText($File))) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $sha.Dispose() }
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Invoke-AzRestMethod', 'function:\AahScan', 'function:\AahNew', 'function:\AahVersion', 'function:\AahSha', 'function:\AahExec' -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
}

Describe 'ASSESS-APPROVAL-HASH-1: planning holds to the scan that was approved' {
    BeforeEach {
        $script:rp = AahNew
        $script:mig = Join-Path $script:temp "aah-mig-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }

    It 'New-VmfPlan refuses an approval of another scan, and creates nothing' {
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf $script:who | Out-Null
        # Another scan of the same run, after the approval.
        [System.IO.File]::WriteAllText((Join-Path $script:rp 'assessment.json'), (AahScan -RunPath $script:rp -Stamp '2026-11-22T01:00:00Z'))
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig } |
            Should -Throw "The approval of assessment '$(Split-Path $script:rp -Leaf)' is for a different scan of these machines. The product cannot plan a migration from it.*"
        Test-Path $script:mig | Should -BeFalse -Because 'a refused plan creates no migration'
    }

    It 'New-VmfPlan refuses an approval that names no scan' {
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf $script:who | Out-Null
        $file = Join-Path $script:rp 'approval.json'
        $doc = Get-Content $file -Raw | ConvertFrom-Json
        $doc.assessmentHash = ''
        $doc | ConvertTo-Json -Depth 6 | Set-Content $file
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig } |
            Should -Throw '*is for a different scan of these machines*'
    }

    It 'New-VmfPlan plans from the scan that was approved' {
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf $script:who | Out-Null
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig } | Should -Not -Throw
    }

    It 'New-VmfPlan accepts an approval as 1.0.0 wrote it' {
        # 1.0.0's Approve-VmfAssessment: schemaVersion 1, and assessmentHash the
        # SHA-256 of the stored text (Get-VmfDocumentVersion, unchanged since).
        [ordered]@{ schemaVersion = 1; assessmentId = (Split-Path $script:rp -Leaf)
            approvedBy = [ordered]@{ identity = 'approver@example.com'; tenantId = '00000000-0000-0000-0000-000000000000' }
            approvedUtc = '2026-11-19T10:00:00.0000000Z'; assessmentHash = (AahSha (Join-Path $script:rp 'assessment.json'))
            note = 'reviewed'; blockedAtApproval = 1 } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:rp 'approval.json')
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig } | Should -Not -Throw
    }

    It 'New-VmfTargetAdvice refuses an approval of another scan, before it reads any size from Azure' {
        Mock -ModuleName VmMigrationFactory Read-VmfMachineCatalogs { throw 'reached the size catalog' }
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf $script:who | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:rp 'assessment.json'), (AahScan -RunPath $script:rp -Stamp '2026-11-22T01:00:00Z'))
        { New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') } |
            Should -Throw "The approval of assessment '$(Split-Path $script:rp -Leaf)' is for a different scan of these machines.*"
        Test-Path (Join-Path $script:rp 'target-advice.json') | Should -BeFalse
    }

    It 'New-VmfTargetAdvice goes on for the scan that was approved, and for a 1.0.0 approval' {
        Mock -ModuleName VmMigrationFactory Read-VmfMachineCatalogs { throw 'reached the size catalog' }
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf $script:who | Out-Null
        { New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') } | Should -Throw 'reached the size catalog'
        $doc = Get-Content (Join-Path $script:rp 'approval.json') -Raw | ConvertFrom-Json
        $doc.schemaVersion = 1
        $doc.assessmentHash = AahSha (Join-Path $script:rp 'assessment.json')
        $doc | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:rp 'approval.json')
        { New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') } | Should -Throw 'reached the size catalog'
    }
}

Describe 'ASSESS-APPROVAL-HASH-1: an approval names the scan the page showed' {
    BeforeEach { $script:rp = AahNew }

    It 'Approve-VmfAssessment refuses another version with 409, and writes no approval' {
        $shown = AahVersion $script:rp
        [System.IO.File]::WriteAllText((Join-Path $script:rp 'assessment.json'), (AahScan -RunPath $script:rp -Stamp '2026-11-22T01:00:00Z'))
        { Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf $script:who -ExpectedAssessmentHash $shown } |
            Should -Throw "409: Assessment '$(Split-Path $script:rp -Leaf)' changed after the page showed it, so the product recorded no approval.*"
        Test-Path (Join-Path $script:rp 'approval.json') | Should -BeFalse
    }

    It 'Approve-VmfAssessment records the version the page showed' {
        $shown = AahVersion $script:rp
        $r = Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf $script:who -ExpectedAssessmentHash $shown
        $r.AssessmentHash | Should -BeExactly $shown
        (Get-Content (Join-Path $script:rp 'approval.json') -Raw | ConvertFrom-Json).assessmentHash | Should -BeExactly $shown
    }

    It 'the service requires the version, and passes it to the approval' {
        $principal = [pscustomobject]@{ Identity = 'approver@example.com'; TenantId = 't'; Roles = @('Vmf.Approver') }
        (Get-Command Invoke-VmfFacadeApproveAssessment).Parameters['AssessmentHash'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory |
            Should -Contain $true
        { Invoke-VmfFacadeApproveAssessment -Principal $principal -StorePath $script:rp -AssessmentHash ('0' * 64) } |
            Should -Throw '409: *changed after the page showed it*'
        Test-Path (Join-Path $script:rp 'approval.json') | Should -BeFalse
        $r = Invoke-VmfFacadeApproveAssessment -Principal $principal -StorePath $script:rp -AssessmentHash (AahVersion $script:rp)
        $r.AssessmentHash | Should -BeExactly (AahVersion $script:rp)
    }

    It 'the route requires the version from the page, and answers 409 for a changed assessment' {
        $code = Get-VmfCodeOnly -Text (Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostApproveAssessment' 'run.ps1') -Raw) -Language powershell
        $code | Should -Match "if \(-not \`$body\.assessmentHash\) \{ throw '400: the assessment version being approved is required' \}"
        $code | Should -Match "AssessmentHash = \(\[string\]\`$body\.assessmentHash\)"
        $code | Should -Match "-match '\^409'\) \{ \[HttpStatusCode\]::Conflict \}"
    }
}

Describe 'ASSESS-APPROVAL-HASH-1: a scan never replaces another scan' {
    It 'a scan that finds a scan saved while it ran keeps that scan, and saves nothing' {
        $out = Join-Path $script:temp "aah-scan-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $other = AahScan -RunPath $out -Stamp '2026-11-22T02:00:00Z'
        $thrown = InModuleScope VmMigrationFactory -Parameters @{ out = $out; other = $other } {
            param($out, $other)
            # The other scan of this run finishes while this one reads Azure.
            Mock Get-VmfFleetInventory { [System.IO.File]::WriteAllText((Join-Path $out 'assessment.json'), $other); , @() }
            Mock Get-VmfSkuCatalog { , @() }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{}; Types = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            try { Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out -RunId (Split-Path $out -Leaf) | Out-Null; $null }
            catch { $_.Exception.Message }
        }
        $thrown | Should -Be ("'$(Split-Path $out -Leaf)' has another scan, saved while this scan ran. The product keeps that scan and does not save this one. " +
            'Scan again under a different name to get a new scan.')
        [System.IO.File]::ReadAllText((Join-Path $out 'assessment.json')) | Should -BeExactly $other -Because 'the scan saved first stays as it was'
    }

    It 'a scan whose own create landed, and whose answer was lost, is saved - not reported as another scan' {
        # Review finding: Invoke-VmfStorageRequest sends a PUT again when no
        # answer came. When the first PUT landed, the second meets this scan's
        # own text and blob storage answers 409. -UniqueText reads it back and
        # knows its own create (STORE-CREATE-LOST-ANSWER-1); without it the
        # scan would stop with "has another scan" over its own result. Here
        # the final write goes to blob storage as Azure answers it (the one
        # HTTP seam), with the first PUT's answer lost.
        $out = Join-Path $script:temp "aah-lost-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $result = InModuleScope VmMigrationFactory -Parameters @{ out = $out } {
            param($out)
            $global:AahBlobs = @{}
            $global:AahPuts = 0
            $global:AahLose = $true
            Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'aah-token' } }
            Mock Send-VmfStorageHttpRequest {
                $key = ([uri]$Uri).AbsolutePath
                $empty = [byte[]]@()
                if ($Method -in @('GET', 'HEAD')) {
                    if (-not $global:AahBlobs.ContainsKey($key)) { return [pscustomobject]@{ StatusCode = 404; Content = $empty; Headers = @{} } }
                    [byte[]]$bytes = if ($Method -eq 'GET') { [System.Text.Encoding]::UTF8.GetBytes($global:AahBlobs[$key]) } else { $empty }
                    return [pscustomobject]@{ StatusCode = 200; Content = $bytes; Headers = @{ ETag = @('"0x1"') } }
                }
                $global:AahPuts++
                if ($Headers['If-None-Match'] -eq '*' -and $global:AahBlobs.ContainsKey($key)) {
                    return [pscustomobject]@{ StatusCode = 409; Content = $empty; Headers = @{} }
                }
                $global:AahBlobs[$key] = [System.Text.Encoding]::UTF8.GetString($Body)
                if ($global:AahLose) { $global:AahLose = $false; throw [System.TimeoutException]::new('No answer from the run store in 20 seconds: the request timed out.') }
                [pscustomobject]@{ StatusCode = 201; Content = $empty; Headers = @{} }
            }
            # The final write only, through the real create-only write, to the
            # blob store above. The scan's own -UniqueText goes through as given.
            Mock Write-VmfStoreJsonExclusive -ParameterFilter { $RelPath -eq 'assessment.json' } {
                Write-VmfStoreTextExclusive -RunPath 'azblob://acct/cont/aah-run' -RelPath 'assessment.json' `
                    -Content ($Document | ConvertTo-Json -Depth 24) -UniqueText:$UniqueText
            }
            Mock Get-VmfFleetInventory { , @() }
            Mock Get-VmfSkuCatalog { , @() }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{}; Types = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            $thrown = try { Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out -RunId 'aah-run' | Out-Null; $null }
                      catch { $_.Exception.Message }
            @{ Thrown = $thrown; Puts = $global:AahPuts; Saved = $global:AahBlobs['/cont/aah-run/assessment.json'] }
        }
        Remove-Variable -Name AahBlobs, AahPuts, AahLose -Scope Global -ErrorAction SilentlyContinue
        $result.Thrown | Should -BeNullOrEmpty -Because 'the document the store holds is this scan''s own'
        $result.Puts | Should -Be 2 -Because 'the first PUT landed and its answer was lost; the second met it and the store answered 409'
        ($result.Saved | ConvertFrom-Json).runId | Should -Be 'aah-run'
    }

    It 'the final write of a scan is create-only' {
        $code = Get-VmfCodeOnly -Text (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1') -Raw) -Language powershell
        $code | Should -Not -Match "Write-VmfStoreJson -RunPath \`$OutPath -RelPath 'assessment\.json'"
        $code | Should -Match "Write-VmfStoreJsonExclusive -RunPath \`$OutPath -RelPath 'assessment\.json'"
    }
}

Describe 'ASSESS-APPROVAL-HASH-1: one scan of a run at a time' {
    BeforeAll {
        $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; TenantId = 't'; Roles = @('Vmf.Operator') }
        function Global:AahExec([string]$Status, [string]$Op, [string]$Run, [string]$Project) {
            $envs = @(@{ name = 'VMF_OPERATION'; value = $Op }, @{ name = 'VMF_RUN_ID'; value = $Run })
            if ($Project) { $envs += @{ name = 'VMF_PROJECT'; value = $Project } }
            @{ name = "exec-$Status-$Op"; properties = @{ status = $Status; template = @{ containers = @(@{ env = $envs }) } } }
        }
    }
    BeforeEach {
        $script:root = Join-Path $script:temp "aah-svc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:Executions = @()
        $script:starts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($script:Executions) } | ConvertTo-Json -Depth 12) }
        }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST' -and $Path -match '/start\?') {
                $script:starts.Add($Payload)
                return [pscustomobject]@{ StatusCode = 202; Content = (@{ name = "exec-$($script:starts.Count)"; id = 'x' } | ConvertTo-Json) }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'refuses a scan while Azure lists a scan of the same run as <Status>, before any start' -ForEach @(
        @{ Status = 'Running' }, @{ Status = 'Processing' }) {
        $script:Executions = @((AahExec $Status 'assess' 'scan-1' 'alpha'))
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'scan-1' -Project 'alpha' -ScopeSubs @('00000000-0000-0000-0000-000000000000') } |
            Should -Throw '400: The product scans the machines of this assessment now. Wait until the scan ends.'
        $script:starts.Count | Should -Be 0 -Because 'the refusal comes before any start'
    }

    It 'starts while only another run, a scan that ended or another operation is listed' {
        $script:Executions = @((AahExec 'Running' 'assess' 'scan-2' 'alpha'), (AahExec 'Running' 'assess' 'scan-1' 'beta'),
            (AahExec 'Succeeded' 'assess' 'scan-1' 'alpha'), (AahExec 'Failed' 'assess' 'scan-1' 'alpha'),
            (AahExec 'Running' 'advise' 'scan-1' 'alpha'))
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'scan-1' -Project 'alpha' -ScopeSubs @('00000000-0000-0000-0000-000000000000')
        $r.execution | Should -Be 'exec-1'
        $script:starts.Count | Should -Be 1
    }
}
