#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WORKLOAD-1: a firewall must never be migrated in place, and before this rule
# nothing detected one - an NVA is a standalone VM with no vmssId, no platform
# tag and an ordinary resource group, so the tool would assess it Ready and
# plan an in-place conversion of a firewall.
#
# The formal source is Microsoft's own built-in policy for
# marketplace NVAs affected by MANA. The data file is GENERATED from the
# fetched definition, and these tests hold the two halves together - the
# generated list stays faithful to its source, and the detector applies it the
# way the policy does: publisher AND offer, both gates.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:catalog = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'nva-offers.json') -Raw | ConvertFrom-Json
    function Script:Nva([string]$pub, [string]$offer) {
        InModuleScope VmMigrationFactory -Parameters @{ p = $pub; o = $offer } {
            Test-VmfNvaImage -Publisher $p -Offer $o
        }
    }
}

Describe 'WORKLOAD-1: the data file is the policy, with its provenance' {
    It 'records WHERE it came from, with a version a re-fetch can diff' {
        $script:catalog.source.policyDefinitionId | Should -Match 'e87a87f5-e6dd-4919-be21-abb0a4ea4630'
        $script:catalog.source.version | Should -Be '1.4.0'
        $script:catalog.source.retrievedUtc | Should -Not -BeNullOrEmpty
    }

    It 'carries the full lists, not a curated excerpt' {
        # The generation step is the guarantee; these counts are the tripwire.
        # If a regenerate against a NEWER policy version changes them, this
        # test forces the version field to move with it.
        @($script:catalog.publishers).Count | Should -Be 44
        @($script:catalog.offerPatterns).Count | Should -Be 179
    }

    It 'names the vendors an operator would expect to find' {
        foreach ($p in 'paloaltonetworks', 'fortinet', 'checkpoint', 'f5-networks', 'cisco') {
            @($script:catalog.publishers) | Should -Contain $p
        }
    }
}

Describe 'WORKLOAD-1: the detector applies BOTH gates, the way the policy does' {
    It 'a real firewall image is an NVA' {
        foreach ($case in @(
            @{ p = 'paloaltonetworks'; o = 'vmseries-flex' },
            @{ p = 'fortinet';         o = 'fortinet_fortigate-vm_v5' },
            @{ p = 'checkpoint';       o = 'check-point-cg-r8120' },
            @{ p = 'netgate';          o = 'pfsense-plus-fw-vpn-router' })) {
            $v = Script:Nva $case.p $case.o
            $v.IsNva | Should -BeTrue -Because "$($case.p)/$($case.o) is a marketplace appliance"
            $v.Detail | Should -Match 'appliance image'
        }
    }

    It 'a wildcarded publisher entry matches the way the list intends' {
        (Script:Nva 'zscaler-private-access' 'zia-connector').IsNva | Should -BeTrue
    }

    It 'the offer patterns alone prove NOTHING - the publisher gate is load-bearing' {
        # win*, linux*, vm* and ubuntu* are all in the offer list. Without the
        # publisher gate, every machine in every fleet would be "an NVA". This
        # is the test that fails if anyone ever relaxes the allOf to an anyOf.
        (Script:Nva 'MicrosoftWindowsServer' 'WindowsServer').IsNva | Should -BeFalse
        (Script:Nva 'Canonical' '0001-com-ubuntu-server-jammy').IsNva | Should -BeFalse
        (Script:Nva 'MicrosoftSQLServer' 'sql2022-ws2022').IsNva | Should -BeFalse
    }

    It 'a known vendor with a non-matching offer is NOT an NVA, and the detail says which half missed' {
        $v = Script:Nva 'cisco' 'zzz-no-such-offer'
        $v.IsNva | Should -BeFalse
        $v.Detail | Should -Match 'matches no appliance offer pattern'
    }

    It 'an empty publisher is NOT JUDGED - no marketplace record, no verdict' {
        # Custom and gallery images have no publisher; inventing a verdict from
        # nothing is the DRIVER-1 mistake. The custom-image flow already routes
        # those to explicit human acceptance.
        (Script:Nva '' '').IsNva | Should -BeFalse
        (Script:Nva '' '').Detail | Should -Match 'no marketplace image record'
    }
}

Describe 'NVA-PLAN-1: the Marketplace purchase plan is judged with the same list' {
    # Microsoft's Compute REST API and ARM template reference for
    # Microsoft.Compute/virtualMachines, Plan.product: "Specifies the product
    # of the image from the marketplace. This is the same value as Offer under
    # the imageReference element." So the plan publisher and product go
    # through the SAME two gates as the image publisher and offer. A machine
    # made from a gallery copy of an appliance image has no publisher or offer
    # on imageReference, but Azure keeps the plan.
    BeforeAll {
        function Script:NvaPlan([string]$pub, [string]$offer, [string]$planPub, [string]$planProduct) {
            InModuleScope VmMigrationFactory -Parameters @{ a = $pub; b = $offer; c = $planPub; d = $planProduct } {
                Test-VmfNvaImage -Publisher $a -Offer $b -PlanPublisher $c -PlanProduct $d
            }
        }
    }

    It 'a gallery image with an appliance plan is an NVA, and the evidence names the plan fields' {
        $v = Script:NvaPlan '' '' 'paloaltonetworks' 'vmseries-flex'
        $v.IsNva | Should -BeTrue
        $v.Sign | Should -Be 'plan'
        @($v.Evidence | Where-Object { $_.field -eq 'plan.publisher' }).value | Should -Be 'paloaltonetworks'
        @($v.Evidence | Where-Object { $_.field -eq 'plan.product' }).value | Should -Be 'vmseries-flex'
        @($v.Evidence | Where-Object { $_.field -like 'imageReference.*' }).Count | Should -Be 0
        $v.Detail | Should -Match 'purchase plan'
    }

    It 'the plan passes BOTH gates: an appliance product under an ordinary publisher is not an NVA' {
        # ubuntu* and win* are in the offer list; the publisher gate holds them.
        (Script:NvaPlan '' '' 'canonical' 'ubuntu-pro').IsNva | Should -BeFalse
        (Script:NvaPlan '' '' 'microsoftwindowsserver' 'windowsserver').IsNva | Should -BeFalse
        # A known vendor with a product the list does not name is not one either.
        $v = Script:NvaPlan '' '' 'cisco' 'zzz-no-such-offer'
        $v.IsNva | Should -BeFalse
        $v.Detail | Should -Match 'matches no appliance offer pattern'
    }

    It 'a plan with only one half judges nothing' {
        (Script:NvaPlan '' '' 'paloaltonetworks' '').IsNva | Should -BeFalse
        (Script:NvaPlan '' '' '' 'vmseries-flex').IsNva | Should -BeFalse
    }

    It 'case is ignored in the plan, as Azure ignores it' {
        (Script:NvaPlan '' '' 'PaloAltoNetworks' 'VMSeries-Flex').IsNva | Should -BeTrue
        # And a space around a value is not part of it, as in the storage
        # appliance rule.
        # 'twistlock' is an exact entry on both lists, so each space counts.
        (Script:NvaPlan '' '' ' twistlock' 'twistlock').IsNva | Should -BeTrue
        (Script:NvaPlan '' '' 'twistlock' 'twistlock ').IsNva | Should -BeTrue
    }

    It 'the image is judged first: a machine on both says image' {
        $v = Script:NvaPlan 'fortinet' 'fortinet_fortigate-vm_v5' 'fortinet' 'fortinet_fortigate-vm_v5'
        $v.IsNva | Should -BeTrue
        $v.Sign | Should -Be 'image'
        @($v.Evidence | Where-Object { $_.field -eq 'imageReference.publisher' }).value | Should -Be 'fortinet'
        @($v.Evidence | Where-Object { $_.field -eq 'imageReference.offer' }).value | Should -Be 'fortinet_fortigate-vm_v5'
    }

    It 'an ordinary image does not hide an appliance plan' {
        # A machine whose image record names an ordinary offer and whose plan
        # names an appliance is judged by the plan too.
        $v = Script:NvaPlan 'canonical' 'ubuntu-server' 'netgate' 'pfsense-plus-fw-vpn-router'
        $v.IsNva | Should -BeTrue
        $v.Sign | Should -Be 'plan'
    }

    It 'no image and no plan is not judged, as before' {
        $v = Script:NvaPlan '' '' '' ''
        $v.IsNva | Should -BeFalse
        $v.Sign | Should -BeNullOrEmpty
        @($v.Evidence).Count | Should -Be 0
        $v.Detail | Should -Match 'no marketplace image record'
    }
}

Describe 'WORKLOAD-1: assessment blocks what the detector finds' {
    BeforeAll {
        $script:rules = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1') -Raw
    }

    It 'an NVA is BLOCKED with the vendor path named, not planned in place' {
        $script:rules | Should -Match 'nva-requires-parallel-deployment'
        $script:rules | Should -Match 'Test-VmfNvaImage'
        $script:rules | Should -Match 'parallel appliance capacity'
    }

    It 'the rule reads the IMAGE, never a tag' {
        $ruleBlock = [regex]::Match($script:rules, '(?s)network virtual appliances \(WORKLOAD-1\).*?TRUST-1').Value
        $ruleBlock | Should -Match 'imagePublisher'
        $ruleBlock | Should -Not -Match '\$Vm\.tags' -Because 'the rule: no tag decides behaviour'
    }
}
