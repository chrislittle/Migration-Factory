#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WORKLOAD-1 (AVD half): a tag on an AVD host is not enough to protect it.
# Converting a session host in place breaks the pool it belongs to,
# and the AVDHostpool tag - the only guard before this - is customer-editable,
# easily absent, and copied onto non-members by cloned templates.
#
# The authoritative record is the DesktopVirtualization provider itself:
# session hosts are child resources of the host pool, each carrying the VM's
# ARM resource id. Personal and Pooled (multi-session) pools record membership
# identically - hostPoolType changes assignment semantics, never the record -
# so one enumeration covers both.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:Resp([int]$Status, $Body) {
        [pscustomobject]@{ StatusCode = $Status; Content = ($Body | ConvertTo-Json -Depth 10) }
    }
    function Script:InvRow {
        param([string]$Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1', $Tags = $null)
        [pscustomobject]@{
            id = $Id; name = ($Id -split '/')[-1]; resourceGroup = 'rg'; location = 'centralus'
            sku = 'Standard_D4s_v5'; gen = 'V2'; os = 'Windows'; osVersion = '2022-datacenter'
            imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter-g2'
            vmssId = ''; hibernationEnabled = $false; securityType = ''
            tags = $Tags; nics = @(); dataDiskCount = 0; maxResourceVolumeMB = 0
        }
    }
}

Describe 'WORKLOAD-1: the provider enumeration' {
    # The mock speaks the whole ARM surface the enumerator touches: per-sub
    # host pools, per-pool session hosts - and
    # nextLink paging, because ignoring it silently drops hosts past the
    # first page at exactly the fleet scale this tool exists for.
    BeforeAll {
        function Script:Page($Body) { [pscustomobject]@{ StatusCode = 200; Content = ($Body | ConvertTo-Json -Depth 10) } }
    }

    It 'finds a session host whose POOL lives in a DIFFERENT subscription than the VM' {
        # The common enterprise layout: pool object in a management sub, VMs
        # in a workloads sub. The first version of the enumerator only looked
        # where the scanned VMs lived and found nothing - the exact scenario
        # in which the check would not work.
        # SCAN-SCOPE-READS-1: the management subscription is found only when
        # it is IN THE SCAN SCOPE - the scan reads no subscription outside it.
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                if ($Path -match '/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.DesktopVirtualization/hostPools\?') {
                    [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(
                        @{ id = '/subscriptions/11111111-2222-3333-4444-555555555555/rg/hp1'; name = 'hp1'; properties = @{ hostPoolType = 'Pooled' } }
                    ) } | ConvertTo-Json -Depth 10) }
                }
                elseif ($Path -match 'hp1/sessionHosts') {
                    [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(
                        @{ name = 'sh1'; properties = @{ resourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/rg/providers/Microsoft.Compute/virtualMachines/AVD-1' } }
                    ) } | ConvertTo-Json -Depth 10) }
                }
                else {
                    # every other sub: provider not registered
                    [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' }
                }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000', '11111111-2222-3333-4444-555555555555')
            $r.Verified | Should -BeTrue
            $r.Ids.ContainsKey('/subscriptions/00000000-0000-0000-0000-000000000000/rg/providers/microsoft.compute/virtualmachines/avd-1') | Should -BeTrue
            $r.Detail | Should -Match '2 subscription'
        }
    }

    It 'follows nextLink - a session host on page TWO is still found' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                if ($Uri -and ([string]$Uri) -match 'page2') {
                    [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(
                        @{ name = 'sh-paged'; properties = @{ resourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/rg/providers/Microsoft.Compute/virtualMachines/avd-paged' } }
                    ) } | ConvertTo-Json -Depth 10) }
                }
                elseif ($Path -match '/hostPools\?') {
                    [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(
                        @{ id = '/subscriptions/00000000-0000-0000-0000-000000000000/rg/hp1'; name = 'hp1' }
                    ) } | ConvertTo-Json -Depth 10) }
                }
                else {
                    # sessionHosts page 1, with a nextLink
                    [pscustomobject]@{ StatusCode = 200; Content = (@{
                        value = @(@{ name = 'sh1'; properties = @{ resourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/rg/providers/Microsoft.Compute/virtualMachines/avd-1' } })
                        nextLink = 'https://management.azure.com/page2'
                    } | ConvertTo-Json -Depth 10) }
                }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000')
            $r.Verified | Should -BeTrue
            $r.Ids.Count | Should -Be 2
            $r.Ids.ContainsKey('/subscriptions/00000000-0000-0000-0000-000000000000/rg/providers/microsoft.compute/virtualmachines/avd-paged') | Should -BeTrue
        }
    }

    It 'a subscription with the provider NOT REGISTERED is a verified empty - no AVD is a real answer' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000')
            $r.Verified | Should -BeTrue
            $r.Ids.Count | Should -Be 0
        }
    }

    It 'a REFUSED pool listing is NOT verified - cannot read it, cannot claim "no AVD members"' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000')
            $r.Verified | Should -BeFalse
            $r.Detail | Should -Match 'CANNOT be verified'
        }
    }

    It 'the subscriptions under a management group refusing is NOT verified - pools may exist where we never looked' {
        # SCAN-SCOPE-READS-1: this replaced the identity's subscription list,
        # which read beyond the scan scope.
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' }
            }
            Mock Invoke-VmfResourceGraphQuery { throw 'Resource Graph query failed: HTTP 403' }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000') -ManagementGroup 'mg-contoso'
            $r.Verified | Should -BeFalse
            $r.Detail | Should -Match 'mg-contoso'
        }
    }
}

Describe 'WORKLOAD-1: the rule prefers the provider over the tag' {
    It 'a machine the provider lists is EXCLUDED - with or without any tag' {
        $vm = Script:InvRow
        $map = @{ ([string]$vm.id).ToLowerInvariant() = 'pool-prod' }
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; m = $map } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -AvdSessionHosts $m
        }
        $rec.classification | Should -Be 'Excluded'
        @($rec.notes) -join ' ' | Should -Match "host pool 'pool-prod'"
        @($rec.notes) -join ' ' | Should -Match 'DesktopVirtualization provider'
    }

    It 'the AVD tag decides NOTHING - the provider is the only AVD signal' {
        # No tag decides anything, and there is no tag signal for AVD. A
        # machine wearing the AVDHostpool tag that the provider does not list
        # is an ordinary machine - the tag is somebody's label, not a fact.
        $vm = Script:InvRow -Tags ([pscustomobject]@{ AVDHostpool = 'hp1' })
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; m = @{} } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -AvdSessionHosts $m
        }
        $rec.classification | Should -Not -Be 'Excluded'
        @($rec.notes) -join ' ' | Should -Not -Match 'tag'
    }

    It 'NO tag branch remains anywhere in the platform guard - both reviews are done' {
        # The AVD tag went first (no tag signal for AVD), and the AKS review
        # (2026-08-28) retired the last one: the cluster's own
        # nodeResourceGroup declaration replaced the aks-managed-poolName tag
        # and the MC_* naming convention together. ManagedGroups.Tests.ps1
        # asserts the replacement; this asserts the absence.
        $rules = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1') -Raw
        $rules | Should -Not -Match 'AVDHostpool'
        $rules | Should -Not -Match "-contains 'aks-managed-poolName'"
    }

    It 'a machine BUILT for AVD is excluded even when no pool lists it' {
        # The product touches nothing built for AVD, even outside a pool. The VM
        # object carries no DesktopVirtualization marker - the IMAGE is the
        # signal: multi-session SKUs exist only for AVD.
        $vm = Script:InvRow
        $vm.imagePublisher = 'MicrosoftWindowsDesktop'
        $vm.imageOffer = 'windows-11'
        $vm.imageSku = 'win11-23h2-avd'
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; m = @{} } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -AvdSessionHosts $m
        }
        $rec.classification | Should -Be 'Excluded'
        @($rec.notes) -join ' ' | Should -Match 'multi-session image'
        @($rec.notes) -join ' ' | Should -Match 'even when not registered'
        @($rec.notes) -join ' ' | Should -Match 'SERVER operating systems only'
    }

    It 'a single-session client-OS image is excluded too - it cannot be ruled out as a personal host' {
        $vm = Script:InvRow
        $vm.imagePublisher = 'microsoftwindowsdesktop'   # case must not matter
        $vm.imageOffer = 'windows-11'
        $vm.imageSku = 'win11-23h2-ent'
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; m = @{} } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -AvdSessionHosts $m
        }
        $rec.classification | Should -Be 'Excluded'
        @($rec.notes) -join ' ' | Should -Match 'client operating system'
        @($rec.notes) -join ' ' | Should -Match 'SERVER operating systems only'
    }

    It 'a CUSTOM-image machine RUNNING a client OS is excluded - the agent tells on it (scope rule)' {
        # Every Windows client OS is outside the scope of this tool.
        # A custom image has no marketplace record, but the agent reports the
        # running OS name through instanceView regardless of image source.
        $vm = Script:InvRow
        $vm | Add-Member -NotePropertyName osName -NotePropertyValue 'Windows 11 Enterprise' -Force
        $vm.imagePublisher = ''; $vm.imageOffer = ''; $vm.imageSku = ''
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; m = @{} } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -AvdSessionHosts $m
        }
        $rec.classification | Should -Be 'Excluded'
        @($rec.notes) -join ' ' | Should -Match "running 'Windows 11 Enterprise'"
    }

    It 'a SERVER OS name is NOT caught by the client rule - Windows Server 2019 contains "Windows 1"-adjacent digits' {
        # The regex must not misfire on server names: "Windows Server 2019
        # Datacenter" carries no client marker and must pass.
        $vm = Script:InvRow
        $vm | Add-Member -NotePropertyName osName -NotePropertyValue 'Windows Server 2022 Datacenter' -Force
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; m = @{} } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -AvdSessionHosts $m
        }
        @($rec.notes) -join ' ' | Should -Not -Match 'client operating system'
    }

    It 'the stated residual - a deallocated custom-image machine - is blocked by the image check' {
        # A deallocated custom-image client VM reports no osName and no
        # marketplace record: undetectable as client Windows. Every custom
        # image blocks the machine (image-not-supported), and nothing
        # overrides it since DRIFT-12, so the residual cannot move.
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher '' -Offer '' -Sku '' -ImageId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/images/win-client'
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'custom-image'
        }
    }

    It 'no provider record, no tag: an ordinary machine is NOT excluded' {
        $vm = Script:InvRow
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -AvdSessionHosts @{}
        }
        $rec.classification | Should -Not -Be 'Excluded'
    }
}

Describe 'WORKLOAD-1: the assessment wires it in, fail-safe' {
    BeforeAll {
        $script:assess = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1') -Raw
    }

    It 'enumerates once per assessment and passes the map to every record' {
        $script:assess | Should -Match 'Get-VmfAvdSessionHostIds'
        $script:assess | Should -Match '-AvdSessionHosts \$avdSessionHosts'
    }

    It 'an unverified enumeration STOPS the scan and names the fix - never proceeds with less' {
        # Anything refused or not verified on the AVD check blocks the scan
        # until it is fixed. An assessment produced without this check could
        # classify a session host Ready, and everything downstream trusts the
        # assessment. The scan is read-only and free - refusing costs a role
        # grant and a re-run.
        $script:assess | Should -Match 'throw "Cannot verify which machines are AVD session hosts'
        # MANUAL-REVIEW-1: the fix is the Admin page choice, not a grant named by its actions.
        $script:assess | Should -Match 'The VMF Assessment role holds this read. On the Admin page, give the product Assess access to this place'
        $script:assess | Should -Match 'Nothing has been assessed'
        $script:assess | Should -Not -Match 'weak tag signal'
    }

    It 'the refusal is REAL: an assessment against a refusing provider throws' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfFleetInventory { , @([pscustomobject]@{
                id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                name = 'vm1'; resourceGroup = 'rg'; location = 'centralus'; sku = 'Standard_D4s_v5'
            }) }
            Mock Get-VmfSkuCatalog { , @() }
            # CLUSTER-DETECT-1: one read of the interfaces gives accelerated networking and the cluster hints.
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; Verified = $false; Detail = 'HTTP 403' } }
            # SAP-1: the scan asks this too, and refuses when it cannot be answered.
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-avd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                { Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out } |
                    Should -Throw -ExpectedMessage '*Cannot verify which machines are AVD session hosts*'
            }
            finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
        }
    }

    It 'subscriptions come from the scope and the machines found, and a management-group scope is passed on' {
        # SCAN-SCOPE-READS-1: ScanScopeReads.Tests.ps1 runs the whole scan and
        # proves no subscription outside the scope is read.
        $script:assess | Should -Match "-split '/'\)\[2\]"
        $script:assess | Should -Match '\$avdArgs\.ManagementGroup = \[string\]\$Scope\.ManagementGroup'
    }
}

# PROGRESS-1: the wizard shows what a scan is doing while it runs, and the
# count it shows has to come from a FIELD.
#
# The sentence "discovered 312 VMs" is for a person. A page that read the
# number back out of it would break the moment somebody improved the wording,
# and it would break silently - the screen would say "Found undefined
# machines" and the scan would look broken when it was fine.
Describe 'PROGRESS-1: the discovered count travels as data, not only as prose' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:assessCode = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1')
        $script:wizardCode = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'dashboard' 'wizard.html')
    }

    It 'the engine puts the count in the event as a field' {
        $script:assessCode | Should -Match '-Data @\{ discovered = \$discovered \}'
        # and still says it in words, because the run log is read by people too
        $script:assessCode | Should -Match '"discovered \$discovered VMs"'
    }

    It 'the field name is one Write-VmfEvent will actually keep' {
        # Write-VmfEvent DROPS a Data key that collides with a reserved one,
        # silently. A count called `detail` would vanish with no error.
        $log = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'Private' 'logging' 'EventLog.ps1')
        $reserved = [regex]::Match($log, "\`$k -notin @\(([^)]*)\)").Groups[1].Value
        $reserved | Should -Not -BeNullOrEmpty
        $reserved | Should -Not -Match "'discovered'"
    }

    It 'and the page reads the field, never the sentence' {
        $script:wizardCode | Should -Match "typeof e\.discovered === 'number'"
        $script:wizardCode | Should -Not -Match 'discovered \(\d\+\) VMs'
        $script:wizardCode | Should -Not -Match "detail.*match.*discovered"
    }

    It 'a failure stops the watch rather than asking for ever' {
        $script:wizardCode | Should -Match "if \(p\.kind === 'failed'\)"
        $script:wizardCode | Should -Match 'clearInterval\(poll\); poll = null;'
    }
}

# REPORT-GAP-1: the scan records what it could not read, and every surface a
# person reads says so.
#
# A scan that carries on with less than it asked for is correct - it must not
# guess. What was wrong is that it then said nothing: the value was dropped, a
# line went into the run log, and the report omitted the subject. A customer
# read an assessment with a hole in it and no way to know the hole was there.
Describe 'REPORT-GAP-1: what the scan could not read reaches the reader' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:assess = Get-VmfCodeOnly -Path (Join-Path $root 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1')
        # SCAN-PARTIAL-SUBS-1: the subject 'sizes' is written by Get-VmfSizesNotRead,
        # which the scan calls, so its subjects are the scan's too.
        $script:assessAll = $script:assess + "`n" + (Get-VmfCodeOnly -Path (Join-Path $root 'src' 'VmMigrationFactory' 'Private' 'assess' 'SizesNotRead.ps1'))
        $script:reportCaller = Get-VmfCodeOnly -Path (Join-Path $root 'src' 'VmMigrationFactory' 'Public' 'New-VmfReport.ps1')
        # SCAN-PARTIAL-SUBS-1: the words moved to ConvertTo-VmfNotReadReportHtml.
        $script:report = $script:reportCaller + "`n" + (Get-VmfCodeOnly -Path (Join-Path $root 'src' 'VmMigrationFactory' 'Private' 'report' 'NotReadReport.ps1'))
        $script:shared = Get-VmfCodeOnly -Path (Join-Path $root 'src' 'dashboard' 'assessment-report.js')
        $script:wizard = Get-VmfCodeOnly -Path (Join-Path $root 'src' 'dashboard' 'wizard.html')
        $script:assessPage = Get-VmfCodeOnly -Path (Join-Path $root 'src' 'dashboard' 'assessments.html')
    }

    It 'the assessment document carries the list' {
        $script:assess | Should -Match 'notRead\s+= @\(\$notRead\)'
        $script:assess | Should -Match "subject = 'acceleratedNetworking'"
    }

    It 'the subject is a KEY, so no reader has to match on English' {
        # The run log sentence is written for somebody reading a log. If a page
        # had to find the subject inside it, improving the wording would break
        # every reader, silently.
        $script:assess | Should -Match 'subject = '
        $script:shared | Should -Match 'acceleratedNetworking:'
        $script:report | Should -Match "'acceleratedNetworking'"
    }

    It 'every subject the engine can record has words on the page AND in the report' {
        # The failure this prevents: a new subject is added to the engine, and
        # a customer sees a raw key - or nothing at all.
        $subjects = @([regex]::Matches($script:assessAll, "subject\s*=\s*'([A-Za-z0-9_]+)'") |
            ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
        $subjects.Count | Should -BeGreaterThan 0
        foreach ($s in $subjects) {
            # A subject with its own renderer (sizes) is matched by its key.
            $script:shared | Should -Match "$s\s*:|'$s'" -Because "the shared renderer must have words for $s"
            $script:report | Should -Match "'$s'\s*\{" -Because "the customer report must have words for $s - a case of its own"
        }
    }

    It 'all three places a person reads it are wired' {
        $script:wizard | Should -Match 'notReadHtml\(assessment\?\.notRead\)'
        $script:assessPage | Should -Match 'notReadHtml\(row\.notRead\)'
        $script:assessPage | Should -Match 'notRead: doc\?\.notRead'
        $script:report | Should -Match 'What this scan could not read'
        $script:reportCaller | Should -Match 'ConvertTo-VmfNotReadReportHtml -NotRead \$notRead'
    }

    It 'the report reads the field safely on an assessment written before it existed' {
        # This module runs under Set-StrictMode, where reading a member that
        # does not exist THROWS - so an old assessment would break the report
        # rather than simply having nothing to say.
        $script:report | Should -Match "PSObject\.Properties\['notRead'\]"
    }
}
