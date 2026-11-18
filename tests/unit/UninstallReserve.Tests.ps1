#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# UNINSTALL-RESERVE-1: removing the product names the capacity reservations it
# leaves billing.
#
# `azd down` deletes the product's resource group, and with it every record of
# a reservation. Reservations live in the MACHINES' resource groups (CAPRG-1),
# so they survive and keep billing with nothing left that knows about them.
# The rule for safety copies (FIND-COPY-1): the removal TELLS, it does
# not stop - with a command that still works after the product is gone. Now
# every reservation group and reservation carries a tag to find it by, and the
# removal hook lists them.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:down = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1')
    $script:downText = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1') -Raw
}

Describe 'UNINSTALL-RESERVE-1: every reservation the product makes carries a tag to find it by' {
    It 'the tags: one literal to search for, the run and the wave, and the store when there is one' {
        InModuleScope VmMigrationFactory {
            $t = Get-VmfReservationTags -RunId 'run-1' -Wave 'w1' -RunPath 'azblob://acct/cont/run-1'
            $t.vmfCapacityReservation | Should -Be 'true'
            $t.vmfRun | Should -Be 'run-1'
            $t.vmfWave | Should -Be 'w1'
            $t.vmfStore | Should -Be 'acct'
            (Get-VmfReservationTags -RunId 'run-1' -Wave 'w1' -RunPath 'C:\runs\run-1').ContainsKey('vmfStore') | Should -BeFalse -Because 'an absent tag is better than a made-up one'
        }
    }

    It 'the group and the reservation are both created with them' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfAzContextForSubscription { $null }
            Mock Get-AzCapacityReservationGroup { $null }
            Mock New-AzCapacityReservationGroup { [pscustomobject]@{ Id = '/g'; Tags = @{ vmfCapacityReservation = 'true' } } }
            Mock New-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r' } }
            $script:getCalls = 0
            Mock Get-AzCapacityReservation { $script:getCalls++; if ($script:getCalls -eq 1) { $null } else { [pscustomobject]@{ Id = '/g/r'; ProvisioningState = 'Succeeded' } } }
            $tags = @{ vmfCapacityReservation = 'true'; vmfRun = 'run-1' }
            New-VmfCapacityReservation -ResourceGroupName 'rg' -GroupName 'vmf-run-1-w1-00000000' -Location 'centralus' `
                -Size 'Standard_D2s_v6' -Quantity 2 -SubscriptionId '00000000-0000-0000-0000-000000000000' -Tags $tags | Out-Null
            Should -Invoke New-AzCapacityReservationGroup -Times 1 -Exactly -ParameterFilter { $Tag.vmfCapacityReservation -eq 'true' -and $Tag.vmfRun -eq 'run-1' }
            Should -Invoke New-AzCapacityReservation -Times 1 -Exactly -ParameterFilter { $Tag.vmfCapacityReservation -eq 'true' }
        }
    }

    It 'a refused tag costs the label, never the reservation (the safety-copy rule)' {
        InModuleScope VmMigrationFactory {
            # A customer policy that denies unknown tag names: every create
            # WITH a tag is refused, and the same create without one works.
            Mock Get-VmfAzContextForSubscription { $null }
            Mock Get-AzCapacityReservationGroup { $null }
            Mock New-AzCapacityReservationGroup { throw 'RequestDisallowedByPolicy' } -ParameterFilter { $null -ne $Tag }
            Mock New-AzCapacityReservationGroup { [pscustomobject]@{ Id = '/g' } } -ParameterFilter { $null -eq $Tag }
            Mock New-AzCapacityReservation { throw 'RequestDisallowedByPolicy' } -ParameterFilter { $null -ne $Tag }
            Mock New-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r' } } -ParameterFilter { $null -eq $Tag }
            $script:getCalls = 0
            Mock Get-AzCapacityReservation { $script:getCalls++; if ($script:getCalls -eq 1) { $null } else { [pscustomobject]@{ Id = '/g/r'; ProvisioningState = 'Succeeded' } } }
            $made = New-VmfCapacityReservation -ResourceGroupName 'rg' -GroupName 'vmf-run-1-w1-00000000' -Location 'centralus' `
                -Size 'Standard_D2s_v6' -Quantity 2 -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -Tags @{ vmfCapacityReservation = 'true' } -WarningVariable warned -WarningAction SilentlyContinue
            $made.GroupId | Should -Be '/g'
            $made.ReservationId | Should -Be '/g/r'
            ($warned -join ' ') | Should -Match 'refused with its tags'
        }
    }

    It 'a tag a policy removed after the create is said, not assumed (POLICY-REVERT-1)' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfAzContextForSubscription { $null }
            Mock Get-AzCapacityReservationGroup { $null }
            Mock New-AzCapacityReservationGroup { [pscustomobject]@{ Id = '/g'; Tags = @{} } }
            Mock New-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r' } }
            $script:getCalls = 0
            Mock Get-AzCapacityReservation { $script:getCalls++; if ($script:getCalls -eq 1) { $null } else { [pscustomobject]@{ Id = '/g/r'; ProvisioningState = 'Succeeded' } } }
            New-VmfCapacityReservation -ResourceGroupName 'rg' -GroupName 'vmf-run-1-w1-00000000' -Location 'centralus' `
                -Size 'Standard_D2s_v6' -Quantity 2 -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -Tags @{ vmfCapacityReservation = 'true' } -WarningVariable warned -WarningAction SilentlyContinue | Out-Null
            ($warned -join ' ') | Should -Match 'did not keep its tags'
        }
    }

    It 'the wave reservation passes the tags for its run and wave' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfWaveReservation.ps1')
        $code | Should -Match '-Tags \(Get-VmfReservationTags -RunId \$claim\.runId -Wave \$claim\.wave -RunPath \$OutPath\)'
    }
}

Describe 'UNINSTALL-RESERVE-1: the removal names the reservations it leaves billing, and does not stop' {
    It 'searches by the tag, and by the vmf- name for a group whose tag a policy removed' {
        $script:down | Should -Match 'az resource list --tag vmfCapacityReservation=true --subscription \$subscription -o json'
        $script:down | Should -Match 'az resource list --resource-type Microsoft\.Compute/capacityReservationGroups --subscription \$subscription -o json'
        $script:down | Should -Match "-like 'vmf-\*'"
    }

    It 'prints the command that still works after the product is gone' {
        $script:downText | Should -Match "Write-Host '     az resource list --tag vmfCapacityReservation=true -o table'"
    }

    It 'OLD-VERSION-READERS-REMOVE-6: says a group can have no tag because a policy removed it - every group this version makes is tagged' {
        $script:downText | Should -Match "A policy in your subscription can remove the tag\. The name of each group starts with vmf-:"
        $script:downText | Should -Not -Match 'before (this|the) tag'
    }

    It 'a count it could not make is said as such - never a made-up zero (DRILL-F)' {
        $script:down | Should -Match 'reservationCannotCount'
        $script:downText | Should -Match 'capacity reservation groups this product made, in \$\(if \(\$subscription\) \{ "subscription \$subscription" \} else \{ "the install''s subscription" \}\): \$groupCount'
    }

    Context 'run with a stand-in for az' {
        BeforeAll {
            # The section itself, run: a text match cannot tell "not counted"
            # from a made-up zero, because both print the same line.
            $section = [regex]::Match($script:downText, "(?s)Write-Step 'Capacity reservations'.*?(?=# TEARDOWN-1)").Value
            # INSTALL-THROTTLE-RETRY-2: the listings go through the step helper.
            . (Join-Path $script:repoRoot 'infra' 'Invoke-VmfAzStep.ps1')
            $script:runSection = [scriptblock]::Create("function Write-Step { param(`$Name) }`n" + $section)
        }

        It 'a listing that fails is said as not counted, never as 0' {
            function az { $global:LASTEXITCODE = 1 }
            $subscription = '00000000-0000-0000-0000-000000000000'
            $said = . $script:runSection 6>&1 | Out-String
            $said | Should -Match 'capacity reservation groups this product made, in subscription 00000000-0000-0000-0000-000000000000: not counted, because'
            $said | Should -Not -Match 'this product made, in subscription \S+: 0'
        }

        It 'one listing that fails makes the number a floor, and says which search failed' {
            function az {
                if ($args -contains '--tag') { $global:LASTEXITCODE = 1; return }
                $global:LASTEXITCODE = 0
                ConvertTo-Json -Depth 5 -InputObject @(@{ id = '/g/2'; name = 'vmf-run-0-w2-bbbb'; resourceGroup = 'rg-b'; type = 'Microsoft.Compute/capacityReservationGroups'; tags = $null })
            }
            $subscription = '00000000-0000-0000-0000-000000000000'
            $said = . $script:runSection 6>&1 | Out-String
            $said | Should -Match 'this product made, in subscription 00000000-0000-0000-0000-000000000000: at least 1, because the search by tag failed'
        }

        It 'counts and names the tagged groups and the vmf- groups whose tag a policy removed, once each, and nobody else''s' {
            function az {
                $global:LASTEXITCODE = 0
                $ours = @{ id = '/g/1'; name = 'vmf-run-1-w1-aaaa'; resourceGroup = 'rg-a'; type = 'Microsoft.Compute/capacityReservationGroups'; tags = @{ vmfCapacityReservation = 'true' } }
                if ($args -contains '--tag') { ConvertTo-Json -InputObject @($ours) -Depth 5 }
                else {
                    ConvertTo-Json -Depth 5 -InputObject @(
                        $ours,
                        @{ id = '/g/2'; name = 'vmf-run-0-w2-bbbb'; resourceGroup = 'rg-b'; type = 'Microsoft.Compute/capacityReservationGroups'; tags = $null },
                        @{ id = '/g/3'; name = 'contoso-crg'; resourceGroup = 'rg-c'; type = 'Microsoft.Compute/capacityReservationGroups'; tags = $null })
                }
            }
            $subscription = '00000000-0000-0000-0000-000000000000'
            $said = . $script:runSection 6>&1 | Out-String
            $said | Should -Match 'capacity reservation groups this product made, in subscription 00000000-0000-0000-0000-000000000000: 2'
            $said | Should -Match 'vmf-run-1-w1-aaaa \(resource group rg-a\)'
            $said | Should -Match 'vmf-run-0-w2-bbbb \(resource group rg-b\)'
            $said | Should -Not -Match 'contoso-crg'
        }
    }

    It 'it tells; it never stops the removal (FIND-COPY-1)' {
        $section = [regex]::Match($script:down, "(?s)Write-Step 'Capacity reservations'.*?(Write-Step|\z)").Value
        $section | Should -Not -BeNullOrEmpty
        $section | Should -Not -Match '\bexit\s+1|\bthrow\b'
    }
}
