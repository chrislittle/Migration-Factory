#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SAP-1, 2026-09-19. Raised by Microsoft's 24 July rewrite, which put a gate
# ABOVE the readiness checklist: "Only sizes on the SAP-certified list are
# supported, regardless of platform readiness."
#
# That list is SAP Note 1928533, behind an SAP Service Marketplace login. This
# product cannot fetch it, ship it or keep it current, so it can never say
# whether a target size is certified. The ruling: block, like a network
# virtual appliance. There is no acceptance - the certification is SAP's to
# give, not an operator's.
#
# THE CONSTRAINT THIS FILE EXISTS FOR (2026-09-19): nothing the SAP
# detection finds may block a normal VM. A block with no way past turns a
# false positive into somebody's machine that cannot be migrated at all. So
# every signal must be a POSITIVE ASSERTION THAT SAP IS HERE, and the ordinary
# machines below must stay clean no matter which way the evidence is prodded.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Global:SapRow {
        param(
            [string]$Publisher = 'MicrosoftWindowsServer',
            [string]$Offer = 'WindowsServer',
            [string]$License = '',
            [string]$Name = 'vm1'
        )
        [pscustomobject]@{
            id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            sku = 'Standard_D2ds_v4'; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
            imagePublisher = $Publisher; imageOffer = $Offer; imageSku = '2022-datacenter-g2'
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = 2
            tags = $null; identityType = 'None'; identityPrincipalId = ''
            adeOsDiskEnabled = ''; licenseType = $License
        }
    }
    function Global:SapSku {
        [pscustomobject]@{
            Name = 'Standard_D2ds_v4'; ResourceType = 'virtualMachines'; Family = 'StandardDDSv4Family'
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' },
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
            )
            Restrictions = @()
        }
    }
}
AfterAll { Remove-Item 'function:\SapRow', 'function:\SapSku' -ErrorAction SilentlyContinue }

Describe 'SAP-1: each signal is a statement about SAP' {

    It 'the Azure VM extension for SAP solutions blocks the machine it is on' {
        InModuleScope VmMigrationFactory {
            $vm = SapRow
            $map = @{ ([string]$vm.id).ToLowerInvariant() = 'the Azure VM extension for SAP solutions is installed (Microsoft.AzureCAT.AzureEnhancedMonitoring/MonitorX64Linux)' }
            $rec = Get-VmfAssessmentRecord -Vm $vm -SkuEntry (SapSku) -SapSystemVms $map
            $rec.blockers | Should -Contain 'sap-needs-a-certified-size'
            ($rec.notes -join ' ') | Should -Match 'extension for SAP solutions'
        }
    }

    It 'an SAP licence type blocks it, and names which one' {
        InModuleScope VmMigrationFactory {
            $checked = 0
            foreach ($lic in @('RHEL_SAPAPPS', 'RHEL_SAPHA', 'RHEL_BASESAPAPPS', 'RHEL_BASESAPHA', 'SLES_SAP')) {
                $rec = Get-VmfAssessmentRecord -Vm (SapRow -License $lic) -SkuEntry (SapSku) -SapSystemVms @{}
                $rec.blockers | Should -Contain 'sap-needs-a-certified-size' -Because "$lic puts the machine on SAP repositories"
                ($rec.notes -join ' ') | Should -Match $lic
                $checked++
            }
            $checked | Should -Be 5 -Because 'a loop that ran no cases proves nothing'
        }
    }

    It 'an SAP marketplace image blocks it, for both vendors and every SUSE service pack' {
        InModuleScope VmMigrationFactory {
            $cases = @(
                @{ P = 'RedHat'; O = 'rhel-sap-apps' }
                @{ P = 'RedHat'; O = 'rhel-sap-ha' }
                @{ P = 'SUSE';   O = 'sles-sap-15-sp5' }
                @{ P = 'SUSE';   O = 'sles-sap-15-sp7-hardened' }
                @{ P = 'SUSE';   O = 'sles-sap-16-0-x86-64' }
                @{ P = 'SUSE';   O = 'sles-sap-12-sp5' }
            )
            $checked = 0
            foreach ($c in $cases) {
                $rec = Get-VmfAssessmentRecord -Vm (SapRow -Publisher $c.P -Offer $c.O) -SkuEntry (SapSku) -SapSystemVms @{}
                $rec.blockers | Should -Contain 'sap-needs-a-certified-size' -Because "$($c.P)/$($c.O) is an SAP product"
                $checked++
            }
            $checked | Should -Be 6 -Because 'a loop that ran no cases proves nothing'
        }
    }
}

Describe 'SAP-1: nothing here can block a normal machine' {
    # The constraint above, as its own rule. A block has no way past, so a
    # machine that is not SAP must stay clean however the evidence is prodded.

    It 'an ordinary Windows machine is not blocked' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (SapRow) -SkuEntry (SapSku) -SapSystemVms @{}
            $rec.blockers | Should -Not -Contain 'sap-needs-a-certified-size'
        }
    }

    It 'and neither is plain RHEL, plain SLES, or a non-SAP licence type' {
        InModuleScope VmMigrationFactory {
            $cases = @(
                @{ What = 'plain RHEL';           Vm = (SapRow -Publisher 'RedHat' -Offer 'RHEL') }
                @{ What = 'RHEL HA, not SAP';     Vm = (SapRow -Publisher 'RedHat' -Offer 'rhel-ha') }
                @{ What = 'plain SLES';           Vm = (SapRow -Publisher 'SUSE' -Offer 'sles-15-sp7') }
                @{ What = 'SLES basic';           Vm = (SapRow -Publisher 'SUSE' -Offer 'sles-15-sp7-basic') }
                @{ What = 'SLES for HPC licence'; Vm = (SapRow -License 'SLES_HPC') }
                @{ What = 'RHEL base licence';    Vm = (SapRow -License 'RHEL_BASE') }
                @{ What = 'RHEL EUS licence';     Vm = (SapRow -License 'RHEL_EUS') }
                @{ What = 'a BYOS licence';       Vm = (SapRow -License 'SLES_BYOS') }
                @{ What = 'Windows licence';      Vm = (SapRow -License 'Windows_Server') }
                @{ What = 'a custom image';       Vm = (SapRow -Publisher '' -Offer '') }
            )
            $checked = 0
            foreach ($c in $cases) {
                $rec = Get-VmfAssessmentRecord -Vm $c.Vm -SkuEntry (SapSku) -SapSystemVms @{}
                $rec.blockers | Should -Not -Contain 'sap-needs-a-certified-size' -Because "$($c.What) is not a statement that SAP is here"
                $checked++
            }
            $checked | Should -Be 10 -Because 'a loop that ran no cases proves nothing'
        }
    }

    It 'the SUSE offer is a PREFIX, so a name that merely contains it is not a match' {
        # `sles-sap` is the product name and the offer begins with it. Matching
        # it anywhere in the string - *sap* - would catch names that are not
        # the product, which is a normal machine blocked with no way past.
        InModuleScope VmMigrationFactory {
            $cases = @('mysles-sap-15-sp7', 'sap-sles-15-sp7', 'sles-15-sp7-sap-tools', 'not-sles-sap')
            $checked = 0
            foreach ($offer in $cases) {
                $rec = Get-VmfAssessmentRecord -Vm (SapRow -Publisher 'SUSE' -Offer $offer) -SkuEntry (SapSku) -SapSystemVms @{}
                $rec.blockers | Should -Not -Contain 'sap-needs-a-certified-size' -Because "SUSE/$offer is not the SLES for SAP product"
                $checked++
            }
            $checked | Should -Be 4 -Because 'a loop that ran no cases proves nothing'
        }
    }

    It 'and the Red Hat offers are matched whole, not as a stem' {
        InModuleScope VmMigrationFactory {
            foreach ($offer in @('rhel-sap-apps-preview', 'my-rhel-sap-ha', 'rhel-sap')) {
                $rec = Get-VmfAssessmentRecord -Vm (SapRow -Publisher 'RedHat' -Offer $offer) -SkuEntry (SapSku) -SapSystemVms @{}
                $rec.blockers | Should -Not -Contain 'sap-needs-a-certified-size' -Because "RedHat/$offer is not one of the two documented offers"
            }
        }
    }

    It 'the offer alone is not evidence - the publisher gates it' {
        # Anybody can publish an offer called sles-sap-something. The signal is
        # the vendor's product, not a string.
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (SapRow -Publisher 'somebody-else' -Offer 'sles-sap-15-sp7') -SkuEntry (SapSku) -SapSystemVms @{}
            $rec.blockers | Should -Not -Contain 'sap-needs-a-certified-size'
        }
    }

    It 'and the licence match is the WHOLE value, never a substring of a longer one' {
        # RHEL_SAPAPPS_SOMETHING and NOT_SLES_SAP are different licence types
        # that happen to contain an SAP one. Matching loosely would block a
        # machine on a licence Azure has never heard of.
        InModuleScope VmMigrationFactory {
            $checked = 0
            foreach ($near in @('RHEL_SAPAPPS_SOMETHING', 'NOT_SLES_SAP', 'SAP', 'RHEL_SAP')) {
                $rec = Get-VmfAssessmentRecord -Vm (SapRow -License $near) -SkuEntry (SapSku) -SapSystemVms @{}
                $rec.blockers | Should -Not -Contain 'sap-needs-a-certified-size' -Because "$near is not one of the five documented values"
                $checked++
            }
            $checked | Should -Be 4 -Because 'a loop that ran no cases proves nothing'
        }
    }

    It 'but the same value in another case is still that value' {
        # Azure documents these in upper case. A machine carrying the same
        # licence differently cased is on the same SAP repositories, so the
        # comparison is case-insensitive ON THE WHOLE VALUE - which is what
        # the test above holds it to.
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (SapRow -License 'sles_sap') -SkuEntry (SapSku) -SapSystemVms @{}
            $rec.blockers | Should -Contain 'sap-needs-a-certified-size'
        }
    }
}

Describe 'SAP-1: the lookup answers, or says it could not' {

    It 'the extension query asks for both publishers and all three extension types' {
        InModuleScope VmMigrationFactory {
            $script:VmfSapExtensionQuery | Should -Match 'Microsoft\.AzureCAT\.AzureEnhancedMonitoring'
            $script:VmfSapExtensionQuery | Should -Match 'Microsoft\.OSTCExtensions'
            $script:VmfSapExtensionQuery | Should -Match 'MonitorX64Linux'
            $script:VmfSapExtensionQuery | Should -Match 'MonitorX64Windows'
            $script:VmfSapExtensionQuery | Should -Match 'AzureEnhancedMonitorForLinux'
        }
    }

    It 'the inventory query reads the licence type AND carries it through' {
        $discovery = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Discovery.ps1') -Raw
        $discovery | Should -Match 'licenseType = tostring\(properties\.licenseType\)'
        $projection = [regex]::Match($discovery, '(?s)\| project (.+?)\| order by').Groups[1].Value
        $projection | Should -Match 'licenseType'
    }

    It 'SAP-2: detecting SAP grants the identity NOTHING new' {
        # The first version asked for four Microsoft.Workloads reads. The
        # parent one returns properties.configuration, which for a system
        # deployed through Azure Center for SAP solutions carries a per-tier
        # osProfile - documented as holding adminUsername, adminPassword and
        # sshKeyPair.privateKey. Whether ARM redacts those was never proven,
        # and a grant is not justified by assuming it does.
        $map = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $all = @($map.operations | ForEach-Object { $_.actions })
        $all.Count | Should -BeGreaterThan 20 -Because 'the permission map was read, not an empty object'
        @($all | Where-Object { $_ -like 'Microsoft.Workloads/*' }).Count | Should -Be 0
    }

    It 'and the scan does not ask anybody to grant one' {
        $scan = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1') -Raw
        $scan | Should -Not -Match 'Microsoft\.Workloads'
    }

    It 'and nothing in the module reads the SAP provider any more' {
        $sap = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsSap.ps1') -Raw
        # The comment explains WHY it is gone, so the check drives the code.
        $code = Get-VmfCodeOnly -Path (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsSap.ps1')
        $code | Should -Not -Match 'sapVirtualInstances'
        $sap | Should -Match '(?i)osProfile' -Because 'the reason it was dropped stays written down'
    }

    It 'and a scan that cannot verify SAP membership refuses, rather than assessing' {
        # The AVD contract, for the same reason: an assessment that could call
        # an SAP machine Ready is worse than no assessment.
        $scan = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1') -Raw
        $scan | Should -Match 'Cannot verify which machines belong to SAP systems'
        $scan | Should -Match 'if \(-not \$sapResult\.Verified\)'
    }
}

Describe 'SAP-1: the words tell an operator what to do instead' {

    It 'the reason names SAP Note 1928533 and says this tool cannot read it' {
        $reasons = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $r = $reasons.blockers.'sap-needs-a-certified-size'
        $r | Should -Not -BeNullOrEmpty
        $r.meaning | Should -Match '1928533'
        $r.meaning | Should -Match '(?i)cannot read it'
        $r.whatToDo | Should -Match '(?i)does not move SAP machines'
    }
}
