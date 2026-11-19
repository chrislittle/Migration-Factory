#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CLAIM-AT-PLAN-1. Lab install, 2026-11-05: a new migration let a person add a
# machine that another migration still held, choose its target, check the
# quota, accept, sign off and press Start - and only then did the start check
# (Test-VmfVmClaims) refuse it. The machine ran, and billed, through five steps
# that could not end in a start.
#
# So Choose the machines asks the SAME question first: the service's run
# summary carries the machines of the run's assessment that another live
# migration holds (Get-VmfHeldMachines), answered by Test-VmfVmClaims - the rule
# the start check uses - so the two never disagree. A listing of the claims
# comes first, so a machine nobody holds costs no read.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # With -Uri, so a later file's mock that filters on -Uri still matches (TEST-STUB-URI-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:vm1 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
    $script:vm2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'
    $script:vm3 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm3'

    function Script:NewStore {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-claimplan-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root
    }
    function Script:NewRun([string]$Store, [string]$Id) {
        $rp = Join-Path $Store $Id
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $Id } { Initialize-VmfRun -RunPath $rp -RunId $id | Out-Null }
        $rp
    }
}

Describe 'CLAIM-AT-PLAN-1: which machines another migration holds' {
    BeforeEach {
        $script:store = Script:NewStore
        $script:older = Script:NewRun $script:store 'older-migration'
        $script:scan = Script:NewRun $script:store 'new-scan'
    }
    AfterEach { if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force } }

    It 'names a machine a live migration holds, with that migration, and no free machine' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:older; s = $script:scan; vm1 = $script:vm1; vm2 = $script:vm2 } {
            (New-VmfVmClaim -RunPath $o -VmId $vm1 -RunId 'older-migration').Granted | Should -BeTrue
            $held = @(Get-VmfHeldMachines -RunPath $s -VmIds @($vm1, $vm2) -RunId 'new-scan')
            $held.Count | Should -Be 1
            $held[0].vmId | Should -Be $vm1
            $held[0].name | Should -Be 'vm1'
            $held[0].heldBy | Should -Be 'older-migration'
        }
    }

    It 'gives the vmId as the caller wrote it, so the page finds its own row' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:older; s = $script:scan; vm1 = $script:vm1 } {
            New-VmfVmClaim -RunPath $o -VmId $vm1 -RunId 'older-migration' | Out-Null
            $upper = $vm1 -replace '/rg/', '/RG/'
            $held = @(Get-VmfHeldMachines -RunPath $s -VmIds @($upper) -RunId 'new-scan')
            $held.Count | Should -Be 1 -Because 'a claim is one name for one machine, whatever the letter case (VMID-CASE-1)'
            $held[0].vmId | Should -BeExactly $upper
        }
    }

    It 'does not name a machine this run holds itself' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:older; vm1 = $script:vm1 } {
            New-VmfVmClaim -RunPath $o -VmId $vm1 -RunId 'older-migration' | Out-Null
            @(Get-VmfHeldMachines -RunPath $o -VmIds @($vm1) -RunId 'older-migration').Count | Should -Be 0
        }
    }

    It 'does not name a machine whose migration is gone - the rule the start check uses' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:older; vm1 = $script:vm1 } {
            New-VmfVmClaim -RunPath $o -VmId $vm1 -RunId 'older-migration' | Out-Null
        }
        Remove-Item $script:older -Recurse -Force
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:scan; vm1 = $script:vm1 } {
            @(Get-VmfHeldMachines -RunPath $s -VmIds @($vm1) -RunId 'new-scan').Count | Should -Be 0
            (Test-VmfVmClaims -RunPath $s -Entries @([pscustomobject]@{ vmId = $vm1 }) -RunId 'new-scan').Pass | Should -BeTrue
        }
    }

    It 'finds a claim made under its older name (VMID-CASE-1)' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:older; s = $script:scan } {
            # The older name read the resource group only where the id says
            # 'resourceGroups' in that case, so this id's older name is not its
            # name in another letter case: only the older name finds it.
            $mixed = '/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/RG-Apps/providers/Microsoft.Compute/virtualMachines/App01'
            $scope = Get-VmfClaimScopePath -RunPath $s
            $legacy = Get-VmfClaimLegacyRelPath -VmId $mixed
            $legacy | Should -Not -BeNullOrEmpty
            $legacy.ToLowerInvariant() | Should -Not -Be (Get-VmfClaimRelPath -VmId $mixed) -Because 'the test needs an older name that differs by more than letter case'
            Write-VmfStoreJson -RunPath $scope -RelPath $legacy -Depth 6 -Document ([ordered]@{
                    schemaVersion = 1; vmId = $mixed; runId = 'older-migration'; runPath = $o })
            $held = @(Get-VmfHeldMachines -RunPath $s -VmIds @($mixed) -RunId 'new-scan')
            $held.Count | Should -Be 1
            $held[0].heldBy | Should -Be 'older-migration'
        }
    }

    It 'reads no claim for a machine the listing does not name' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:older; s = $script:scan; vm1 = $script:vm1; vm2 = $script:vm2; vm3 = $script:vm3 } {
            New-VmfVmClaim -RunPath $o -VmId $vm1 -RunId 'older-migration' | Out-Null
            Mock Get-VmfVmClaim { $null }
            Get-VmfHeldMachines -RunPath $s -VmIds @($vm1, $vm2, $vm3) -RunId 'new-scan' | Out-Null
            Should -Invoke Get-VmfVmClaim -Times 1 -Exactly -Because 'a page of a thousand machines must not cost a thousand reads'
            Should -Invoke Get-VmfVmClaim -Times 1 -Exactly -ParameterFilter { $VmId -eq $vm1 }
        }
    }

    It 'reads every machine when the listing is one full page, which may be short' {
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:scan; vm1 = $script:vm1; vm2 = $script:vm2; vm3 = $script:vm3 } {
            Mock Get-VmfStoreNames { @(1..5000 | ForEach-Object { "other-$_.claim" }) }
            Mock Get-VmfVmClaim { $null }
            Get-VmfHeldMachines -RunPath $s -VmIds @($vm1, $vm2, $vm3) -RunId 'new-scan' | Out-Null
            Should -Invoke Get-VmfVmClaim -Times 3 -Exactly -Because 'blob storage gives 5,000 names a page: a full page is not proof the machine is free'
        }
    }

    It 'gives nothing for no machines, and reads nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:scan } {
            Mock Get-VmfStoreNames { throw 'must not list' }
            @(Get-VmfHeldMachines -RunPath $s -VmIds @() -RunId 'new-scan').Count | Should -Be 0
        }
    }
}

Describe 'CLAIM-AT-PLAN-1: the run summary carries the held machines' {
    BeforeEach {
        $script:store = Script:NewStore
        $script:older = Script:NewRun $script:store 'older-migration'
        $script:scan = Script:NewRun $script:store 'new-scan'
        @{ vms = @(@{ vmId = $script:vm1; name = 'vm1' }, @{ vmId = $script:vm2; name = 'vm2' }) } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:scan 'assessment.json')
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:older; vm1 = $script:vm1 } {
            New-VmfVmClaim -RunPath $o -VmId $vm1 -RunId 'older-migration' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force } }

    It 'names each machine of the assessment that another migration holds, when asked' {
        $s = Get-VmfFacadeRunSummary -StorePath $script:scan -IncludeHeld
        @($s.held).Count | Should -Be 1
        @($s.held)[0].vmId | Should -Be $script:vm1
        @($s.held)[0].heldBy | Should -Be 'older-migration'
    }

    It 'reads an assessment shaped like a real one, with each machine''s workload evidence (HELD-READ-DEPTH-1)' {
        # Final lab, 2026-11-13: the read took a depth of 4, a real assessment
        # nests vms[].workload.evidence[] six deep, and every plan showed "The
        # page could not read which machines other migrations hold".
        $doc = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'assessment.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $vmA = $doc.vms[0] | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $vmB = $doc.vms[0] | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $vmA.vmId = $script:vm1
        $vmB.vmId = $script:vm2
        foreach ($vm in @($vmA, $vmB)) {
            $vm.workload = [pscustomobject]@{ type = 'cluster-or-database'; evidence = @([pscustomobject]@{ field = 'resourceGroup.managedBy'; value = $null }) }
        }
        $doc.vms = @($vmA, $vmB)
        $text = $doc | ConvertTo-Json -Depth 40
        { $text | ConvertFrom-Json -Depth 5 } | Should -Throw -Because 'the fixture must nest past the depth that failed in the lab'
        Set-Content -Path (Join-Path $script:scan 'assessment.json') -Value $text

        $s = Get-VmfFacadeRunSummary -StorePath $script:scan -IncludeHeld -WarningVariable warned -WarningAction SilentlyContinue
        @($warned).Count | Should -Be 0 -Because 'a real assessment must be read without a failure'
        $null -eq $s.held | Should -BeFalse -Because 'null tells the page the held machines are not known'
        @($s.held).Count | Should -Be 1
        @($s.held)[0].vmId | Should -Be $script:vm1
    }

    It 'asks under the id of the run the summary is for' {
        Mock -ModuleName VmMigrationFactory Get-VmfHeldMachines { @() }
        Get-VmfFacadeRunSummary -StorePath $script:scan -IncludeHeld | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfHeldMachines -Times 1 -Exactly -ParameterFilter {
            $RunId -eq 'new-scan' -and @($VmIds).Count -eq 2 }
    }

    It 'is an empty list when nothing is held, and null when the claims could not be read' {
        Remove-Item (Join-Path $script:store 'vmf-claims') -Recurse -Force
        $free = Get-VmfFacadeRunSummary -StorePath $script:scan -IncludeHeld
        $free.PSObject.Properties.Name | Should -Contain 'held'
        @($free.held).Count | Should -Be 0
        ($free | ConvertTo-Json -Depth 10 | ConvertFrom-Json).held.GetType().IsArray | Should -BeTrue -Because 'the page reads an empty list as nothing held'

        Mock -ModuleName VmMigrationFactory Get-VmfHeldMachines { throw 'the store refused the listing' }
        $unknown = Get-VmfFacadeRunSummary -StorePath $script:scan -IncludeHeld
        $unknown.PSObject.Properties.Name | Should -Contain 'held'
        $unknown.held | Should -BeNullOrEmpty
        $null -eq $unknown.held | Should -BeTrue -Because 'unknown is never read as free'
        $unknown.runId | Should -Be 'new-scan' -Because 'a claims read that fails must not cost the summary'
    }
    It 'a plain summary reads no claim and carries no held list - the Reports page asks for one per run' {
        Mock -ModuleName VmMigrationFactory Get-VmfHeldMachines { throw 'must not be read' }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames { @() } -ParameterFilter { $RunPath -like '*vmf-claims*' }
        $plain = Get-VmfFacadeRunSummary -StorePath $script:scan
        $plain.PSObject.Properties.Name | Should -Not -Contain 'held'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfHeldMachines -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfStoreNames -Times 0 -Exactly -ParameterFilter { $RunPath -like '*vmf-claims*' }
    }

    It 'the endpoint asks for the held list only on held=1, on the same route and role gate' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $endpoint = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'GetRunSummary' 'run.ps1')
        $endpoint | Should -Match "\[string\]\`$Request\.Query\.held -eq '1'"
        $endpoint | Should -Match 'Get-VmfFacadeRunSummary -StorePath \$store -IncludeHeld:\$includeHeld'
        $endpoint | Should -Match "Assert-VmfFacadeRole -Principal \`$principal -AnyOf @\('Vmf\.Viewer', 'Vmf\.Approver', 'Vmf\.Operator', 'Vmf\.Admin'\)"
        $wiz = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js') -Raw
        $wiz | Should -Match "withProject\(\{ held: 1 \}, run\)" -Because 'Choose the machines is the one reader that asks'
    }
}

Describe 'CLAIM-AT-PLAN-1 review: a full listing page is told by every name it holds' {
    It 'reads every machine when the page is full of names, even if fewer than 5,000 are claims' {
        $store = Script:NewStore
        try {
            $scan = Script:NewRun $store 'new-scan'
            InModuleScope VmMigrationFactory -Parameters @{ s = $scan; vm1 = $script:vm1; vm2 = $script:vm2 } {
                # The claim folder also holds deletions.jsonl, so a full page can name 4,999 claims.
                Mock Get-VmfStoreNames {
                    $all = @(1..4999 | ForEach-Object { "other-$_.claim" }) + 'deletions.jsonl'
                    @($all | Where-Object { -not $Extension -or $_.EndsWith($Extension) })
                }
                Mock Get-VmfVmClaim { $null }
                Get-VmfHeldMachines -RunPath $s -VmIds @($vm1, $vm2) -RunId 'new-scan' | Out-Null
                Should -Invoke Get-VmfVmClaim -Times 2 -Exactly
            }
        }
        finally { Remove-Item $store -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'CLAIM-AT-PLAN-1 review: the way to free a held machine is true for a machine left changed' {
    It 'the start check and Choose the machines say one true sentence' {
        $words = 'after that migration migrates it, or skips or stops it with no change on it, or after you delete that migration'
        $why = InModuleScope VmMigrationFactory -Parameters @{ vm = $script:vm1 } {
            $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-claimplan-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                $a = Join-Path $store 'older'; $b = Join-Path $store 'newer'
                Initialize-VmfRun -RunPath $a -RunId 'older' | Out-Null; Initialize-VmfRun -RunPath $b -RunId 'newer' | Out-Null
                New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'newer' | Out-Null
                Get-VmfOtherRunClaimRefusal -RunPath $a -VmId $vm
            }
            finally { Remove-Item $store -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $why | Should -BeLike "*$words."
        $why | Should -Not -Match 'stop or delete that migration' -Because 'a stop keeps the claim of a machine left changed (SKIP-CHANGED-FREED-1)'
        $wiz = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js') -Raw
        $wiz | Should -Match ([regex]::Escape("mHeld: 'The migration {run} holds this machine. It is free $words.'"))
        $manual = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'plan.md') -Raw
        $manual | Should -Match ([regex]::Escape("The machine is free $words."))
    }
}
