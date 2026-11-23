#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SCAN-PARTIAL-SUBS-1: one subscription whose sizes cannot be read no longer
# stops the scan of every other subscription.
#
# Decided 2026-11-08: the scan finishes for every other subscription; a read
# that fails for a reason other than RBAC is tried again first; and the user
# is shown WHY it failed and how to fix it.
#
# What these tests hold:
#   - a temporary failure is tried again by the product's one retry
#     (Invoke-VmfAzOperation), and a read that recovers leaves no trace;
#   - a failure that remains for one subscription and region does not stop
#     the scan: the other subscriptions finish, and the assessment is saved;
#   - the subscription is recorded as not read, with Azure's reason (status,
#     error code, message), the kind of failure, and the role and action the
#     permission map says the read needs, on the subscription;
#   - its machines stay in the assessment and are held (Blocked,
#     sizes-not-read) - never shown as able to move, never dropped;
#   - the page and the report say which subscription, why and how to fix it.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:subOk = '00000000-0000-0000-0000-000000000000'
    $script:subNo = '11111111-2222-3333-4444-555555555555'

    function Global:SpRow([string]$Sub, [string]$Name, [string]$Location = 'centralus') {
        [pscustomobject]@{
            id = "/subscriptions/$Sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"; name = $Name; resourceGroup = 'rg-app'; location = $Location; zones = $null
            sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'; osName = 'ubuntu'; osVersionRunning = '22.04'
            imagePublisher = 'Canonical'; imageOffer = '0001-com-ubuntu-server-jammy'; imageSku = '22_04-lts-gen2'; imageId = ''
            communityGalleryImageId = ''; sharedGalleryImageId = ''; planPublisher = ''; planProduct = ''
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; dataDisks = @()
            tags = $null; identityType = 'None'; identityPrincipalId = ''; adeOsDiskEnabled = ''; licenseType = ''
            osDiskManagedId = "/subscriptions/$Sub/resourceGroups/rg-app/providers/Microsoft.Compute/disks/$Name-os"
        }
    }
    function Global:SpSku([string]$Name = 'Standard_D2s_v4') {
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '16384' }) }
    }
    # Azure's refusal of the size list, the way an Az cmdlet throws it: the
    # ARM body in ErrorDetails, where Resolve-VmfOperationError finds the code.
    # Redacted: the ids in Azure's words are placeholders.
    function Global:SpRefusal([string]$Sub) {
        $er = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Operation returned an invalid status code ''Forbidden'''), 'AuthorizationFailed',
            [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
        $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
            ('{"error":{"code":"AuthorizationFailed","message":"The client ''<placeholder>'' does not have authorization to perform action ''Microsoft.Compute/skus/read'' over scope ''/subscriptions/' + $Sub + ''' or the scope is invalid."}}'))
        $er
    }
    # Every read the scan makes besides the size list, answered, so each test
    # changes only the size list.
    function Global:SpScan([object[]]$Rows) {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $text = InModuleScope VmMigrationFactory -Parameters @{ rows = $Rows; out = $out; subs = @($script:subOk, $script:subNo) } {
            param($rows, $out, $subs)
            Mock Get-VmfFleetInventory { , @($rows) }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{}; Types = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Invoke-VmfAssessment -Scope @{ Subscriptions = $subs } -OutPath $out | Out-Null
            Get-Content (Join-Path $out 'assessment.json') -Raw
        }
        $log = (Get-ChildItem $out -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
        @{ Text = $text; Doc = ($text | ConvertFrom-Json -Depth 30); Log = $log }
    }
}
AfterAll {
    Remove-Item function:SpRow, function:SpSku, function:SpRefusal, function:SpScan -ErrorAction SilentlyContinue
}

Describe 'SCAN-PARTIAL-SUBS-1: one subscription refused, the others finish' {
    BeforeAll {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            if ($SubscriptionId -eq '11111111-2222-3333-4444-555555555555') { throw (SpRefusal $SubscriptionId) }
            , @(SpSku)
        }
        $script:r = SpScan @((SpRow $script:subOk 'vm-ok'), (SpRow $script:subNo 'vm-no'), (SpRow $script:subNo 'vm-no2'))
        $script:entry = @($script:r.Doc.notRead | Where-Object { $_.subject -eq 'sizes' })
    }

    It 'the scan finishes and saves an assessment that matches its schema' {
        $script:r.Text | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') | Should -BeTrue
        $script:r.Doc.schemaVersion | Should -Be 17
    }

    It 'every machine is in it - none of the refused subscription is dropped' {
        @($script:r.Doc.vms).Count | Should -Be 3
        @($script:r.Doc.vms.name) | Should -Contain 'vm-no'
        @($script:r.Doc.vms.name) | Should -Contain 'vm-no2'
    }

    It 'the machines of the refused subscription are held, never shown as able to move' {
        foreach ($n in 'vm-no', 'vm-no2') {
            $vm = @($script:r.Doc.vms | Where-Object name -eq $n)[0]
            $vm.classification | Should -Be 'Blocked' -Because "$n has sizes nobody read"
            @($vm.blockers) | Should -Contain 'sizes-not-read'
        }
        $script:r.Doc.summary.Blocked | Should -Be 2
    }

    It 'the machine of the subscription that was read is judged as before' {
        $vm = @($script:r.Doc.vms | Where-Object name -eq 'vm-ok')[0]
        @($vm.blockers) | Should -Not -Contain 'sizes-not-read'
        $vm.classification | Should -Be 'ReadyAfterPrep'
        $vm.sourceTempDisks | Should -Be 1 -Because 'its catalog was read and gave the temporary disk'
    }

    It 'the subscription is recorded once, with its region and the number of its machines' {
        $script:entry.Count | Should -Be 1
        $script:entry[0].subscriptionId | Should -Be $script:subNo
        $script:entry[0].location | Should -Be 'centralus'
        $script:entry[0].machineCount | Should -Be 2
    }

    It 'WHY: Azure''s reason - its error code, its words, and the kind of failure' {
        $script:entry[0].reason | Should -Be 'permission'
        $script:entry[0].errorCode | Should -Be 'AuthorizationFailed'
        $script:entry[0].detail | Should -Match 'does not have authorization'
        $script:entry[0].detail | Should -Match 'Microsoft\.Compute/skus/read'
    }

    It 'HOW TO FIX: the role and the action the permission map names, on the subscription' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $op = @($map.operations | Where-Object cmdlet -eq 'Get-AzComputeResourceSku')[0]
        $script:entry[0].requiredRole | Should -Be $map.roles.($op.role).roleName
        $script:entry[0].requiredAction | Should -Be $op.actions[0]
        $script:entry[0].scope | Should -Be "/subscriptions/$($script:subNo)"
    }

    It 'the run log says which subscription was not read, as a warning, not a failure of the scan' {
        $script:r.Log | Should -Match ([regex]::Escape($script:subNo))
        $script:r.Log | Should -Match '"outcome":\s*"warn"'
    }
}

Describe 'SCAN-PARTIAL-SUBS-1: the retry the product already has' {
    It 'a temporary failure is tried again, and a read that recovers leaves no trace' {
        $global:spCalls = 0
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            if ($SubscriptionId -eq '11111111-2222-3333-4444-555555555555') {
                $global:spCalls++
                if ($global:spCalls -eq 1) { throw 'Resource list failed: HTTP 503 - Service Unavailable' }
            }
            , @(SpSku)
        }
        $r = SpScan @((SpRow $script:subOk 'vm-ok'), (SpRow $script:subNo 'vm-no'))
        $global:spCalls | Should -Be 2 -Because 'Invoke-VmfAzOperation tried the read again'
        @($r.Doc.notRead | Where-Object { $_.subject -eq 'sizes' }).Count | Should -Be 0
        @($r.Doc.vms | Where-Object name -eq 'vm-no')[0].blockers | Should -Not -Contain 'sizes-not-read'
        Remove-Variable -Name spCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a temporary failure that does not end is recorded after the retries, with its status, as other' {
        $global:spCalls = 0
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            if ($SubscriptionId -eq '11111111-2222-3333-4444-555555555555') { $global:spCalls++; throw 'Resource list failed: HTTP 503 - Service Unavailable' }
            , @(SpSku)
        }
        $r = SpScan @((SpRow $script:subOk 'vm-ok'), (SpRow $script:subNo 'vm-no'))
        $global:spCalls | Should -Be 4 -Because 'the four attempts of Invoke-VmfAzOperation'
        $e = @($r.Doc.notRead | Where-Object { $_.subject -eq 'sizes' })
        $e.Count | Should -Be 1
        $e[0].reason | Should -Be 'other'
        $e[0].statusCode | Should -Be 503
        Remove-Variable -Name spCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the scan uses the one retry, and builds no second one' {
        $code = Get-VmfCodeOnly -Text (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'MachineCatalog.ps1') -Raw)
        $code | Should -Match 'Invoke-VmfAzOperation'
        $code | Should -Not -Match '(?i)for\s*\(\s*\$attempt|Start-Sleep'
    }

    It 'every subscription refused: the assessment is still saved, every machine held' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { throw (SpRefusal $SubscriptionId) }
        $r = SpScan @((SpRow $script:subOk 'vm-ok'), (SpRow $script:subNo 'vm-no'))
        @($r.Doc.vms | Where-Object classification -eq 'Blocked').Count | Should -Be 2
        @($r.Doc.notRead | Where-Object { $_.subject -eq 'sizes' }).Count | Should -Be 2
    }
}

Describe 'SCAN-PARTIAL-SUBS-1: the kind of failure, from Azure''s answer' {
    It 'a refusal is a permission failure: by status, by Azure''s code, or by the status in its words' {
        InModuleScope VmMigrationFactory {
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = 403; ErrorCode = $null; Message = 'x' } | Should -Be 'permission'
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = $null; ErrorCode = 'AuthorizationFailed'; Message = 'x' } | Should -Be 'permission'
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = $null; ErrorCode = 'LinkedAuthorizationFailed'; Message = 'x' } | Should -Be 'permission'
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = $null; ErrorCode = $null; Message = 'Status: 403 (Forbidden)' } | Should -Be 'permission'
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = $null; ErrorCode = $null; Message = 'Code: AuthorizationFailed - no access' } | Should -Be 'permission'
        }
    }

    It 'a subscription Azure cannot find is its own kind' {
        InModuleScope VmMigrationFactory {
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = 404; ErrorCode = 'SubscriptionNotFound'; Message = 'x' } | Should -Be 'subscriptionNotFound'
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = $null; ErrorCode = $null; Message = 'SubscriptionNotFound: The subscription was not found.' } | Should -Be 'subscriptionNotFound'
        }
    }

    It 'anything else is other - never guessed to be a permission' {
        InModuleScope VmMigrationFactory {
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = 503; ErrorCode = $null; Message = 'x' } | Should -Be 'other'
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = $null; ErrorCode = $null; Message = 'vm-403-app could not be read' } | Should -Be 'other' -Because 'a number in a name is not a status'
            Get-VmfReadFailureReason -ErrorInfo @{ StatusCode = 404; ErrorCode = 'ResourceNotFound'; Message = 'x' } | Should -Be 'other'
            Get-VmfReadFailureReason -ErrorInfo $null | Should -Be 'other'
        }
    }

    It 'the role and the action come from the map, never from this code' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sp-map-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        try {
            [ordered]@{ roles = @{ assess = @{ roleName = 'Some Other Role' } }
                operations = @(@{ cmdlet = 'Get-AzComputeResourceSku'; role = 'assess'; actions = @('Microsoft.Compute/skus/read') }) } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp
            $a = InModuleScope VmMigrationFactory -Parameters @{ tmp = $tmp } { param($tmp) Get-VmfOperationAccess -Cmdlet 'Get-AzComputeResourceSku' -Path $tmp }
            $a.Role | Should -Be 'Some Other Role'
            @($a.Actions) | Should -Be @('Microsoft.Compute/skus/read')
            InModuleScope VmMigrationFactory -Parameters @{ tmp = $tmp } { param($tmp) Get-VmfOperationAccess -Cmdlet 'Get-AzNothing' -Path $tmp } | Should -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'SCAN-PARTIAL-SUBS-1: the machine record' {
    It 'a machine whose sizes were not read is held, and says so instead of guessing from the name' {
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = (SpRow $script:subNo 'vm-no') } {
            param($v) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -SizesNotRead -ResourceGroupOwners @{} -ManagedPlatformGroups @{} -AvdSessionHosts @{} -SapSystemVms @{}
        }
        $rec.classification | Should -Be 'Blocked'
        @($rec.blockers) | Should -Contain 'sizes-not-read'
        (@($rec.notes) -join ' ') | Should -Not -Match 'name-based'
    }

    It 'a machine whose catalog was read but lacks its size is NOT held for it - that is the name rule, as before' {
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = (SpRow $script:subOk 'vm-ok') } {
            param($v) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -ResourceGroupOwners @{} -ManagedPlatformGroups @{} -AvdSessionHosts @{} -SapSystemVms @{}
        }
        @($rec.blockers) | Should -Not -Contain 'sizes-not-read'
    }

    It 'a platform-managed machine stays Excluded' {
        $row = SpRow $script:subNo 'vm-ss'
        $row.vmssId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/virtualMachineScaleSets/ss'
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $row } {
            param($v) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -SizesNotRead -ResourceGroupOwners @{} -ManagedPlatformGroups @{} -AvdSessionHosts @{} -SapSystemVms @{}
        }
        $rec.classification | Should -Be 'Excluded'
    }
}

Describe 'SCAN-PARTIAL-SUBS-1: the target options hold the machine too' {
    It 'a machine held for sizes-not-read has no supported option on any series, and the reason says why' {
        $vm = [pscustomobject]@{
            vmId = "/subscriptions/$($script:subNo)/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m"
            name = 'm'; location = 'centralus'; classification = 'Blocked'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'; dataDiskCount = 0
            nicCount = 1; acceleratedNicCount = 0; platformManaged = $false; blockers = @('sizes-not-read'); prepNeeded = @() }
        $cat = @{ centralus = @{ 'Standard_D2s_v5' = (SpSku 'Standard_D2s_v5'); 'Standard_D2s_v6' = (SpSku 'Standard_D2s_v6') } }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($vm) }; c = $cat } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c -RegionsNotRead @()
        }
        $m = @($advice.machines)[0]
        @($m.options | Where-Object { $_.supported }).Count | Should -Be 0
        foreach ($o in @($m.options)) { @($o.notSupported) | Should -Contain 'sizes-not-read' -Because "option $($o.option)" }
        $advice.schemaVersion | Should -Be 34
        ($advice | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }
}

Describe 'SCAN-PARTIAL-SUBS-1: the contract (assessment v14)' {
    It 'one place holds the version: 14, and 13 is still read' {
        InModuleScope VmMigrationFactory {
            Get-VmfAssessmentSchemaVersion | Should -Be 17
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 13 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 18 }) } | Should -Throw '*understands up to 17*'
        }
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json -Depth 30
        $s.properties.schemaVersion.const | Should -Be 17
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'assessment v13 -> v14, target-advice v29 -> v30 \(2026-11-08, SCAN-PARTIAL-SUBS-1\)'
    }

    It 'a sizes entry (v14 and later) must name its subscription, region and kind of failure' {
        $schema = Join-Path $script:repoRoot 'schemas' 'assessment.schema.json'
        $base = { param($nr, $v) ([ordered]@{ schemaVersion = $v; runId = 'r'; generatedUtc = 'now'; scope = @{}; summary = @{}; notRead = @($nr); vms = @() } | ConvertTo-Json -Depth 8) }
        $good = [ordered]@{ subject = 'sizes'; detail = 'x'; subscriptionId = $script:subNo; location = 'centralus'; reason = 'permission'
            statusCode = 403; errorCode = 'AuthorizationFailed'; machineCount = 2; requiredRole = 'VMF Assessment'; requiredAction = 'Microsoft.Compute/skus/read'; scope = "/subscriptions/$($script:subNo)" }
        (& $base $good 17) | Test-Json -SchemaFile $schema | Should -BeTrue
        $bad = [ordered]@{ subject = 'sizes'; detail = 'x' }
        (& $base $bad 17) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue | Should -BeFalse
        $badReason = [ordered]@{} + $good; $badReason.reason = 'rbac'
        (& $base $badReason 17) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue | Should -BeFalse
        # An older subject keeps its old shape.
        (& $base ([ordered]@{ subject = 'clusterHints'; detail = 'x' }) 17) | Test-Json -SchemaFile $schema | Should -BeTrue
    }
}

Describe 'SCAN-PARTIAL-SUBS-1: the person is told which, why, and how to fix it' {
    It 'the blocker has words, and its fix is a new assessment' {
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $b = $reasons.blockers.'sizes-not-read'
        $b | Should -Not -BeNullOrEmpty
        $b.whatToDo | Should -Match 'new assessment'
        @($b.appliesTo) | Should -Be @('v5', 'v6', 'v7')
    }

    It 'the customer report names the subscription, Azure''s words, and the role to give' {
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:subNo } {
            param($sub)
            $html = ConvertTo-VmfNotReadReportHtml -NotRead @(
                [pscustomobject]@{ subject = 'sizes'; detail = 'AuthorizationFailed - <no access>'; subscriptionId = $sub; location = 'centralus'; reason = 'permission'
                    statusCode = 403; errorCode = 'AuthorizationFailed'; machineCount = 2; requiredRole = 'VMF Assessment'; requiredAction = 'Microsoft.Compute/skus/read'; scope = "/subscriptions/$sub" })
            $html | Should -Match ([regex]::Escape($sub))
            $html | Should -Match 'centralus'
            $html | Should -Match 'AuthorizationFailed'
            $html | Should -Match '&lt;no access&gt;' -Because 'Azure''s words are encoded'
            $html | Should -Match 'VMF Assessment'
            $html | Should -Match 'Microsoft\.Compute/skus/read'
            $html | Should -Match 'new assessment'
            $html | Should -Not -Match 'Everything else here is not affected' -Because 'the machines of that subscription are affected'
            ([regex]::Matches($html, 'AuthorizationFailed')).Count | Should -Be 1 -Because 'the code is in Azure''s words already, so it is said once'
        }
    }

    It 'the report keeps its old words for the old subjects' {
        InModuleScope VmMigrationFactory {
            $html = ConvertTo-VmfNotReadReportHtml -NotRead @([pscustomobject]@{ subject = 'clusterHints'; detail = 'x' })
            $html | Should -Match 'Cluster hints'
            $html | Should -Match 'Everything else here is not affected'
            ConvertTo-VmfNotReadReportHtml -NotRead @() | Should -BeNullOrEmpty
        }
    }
}
