#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1'
}

Describe 'Invoke-VmfGuestScriptOnVm audit trail' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-go-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'go-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'go-test' -VmId $id | Out-Null
        }
        # Real Get-VmfGuestScript (manifest + hash verify); only the RunCommand is mocked.
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
            '{"schema":"vmf.guest/2","script":"nvme-check.sh","version":"1.0.0","result":"READY","checks":[{"name":"a","status":"PASS"}]}'
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'appends audit entries across MULTIPLE calls with disk round-trips (P1-6 regression)' {
        # The bug: assignment from an if-expression collapsed a 1-element array to
        # a scalar PSObject, so the SECOND append crashed with op_Addition.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            1..3 | ForEach-Object {
                Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-check.sh' -ResourceGroupName 'rg-lab' `
                    -VmName 'vm1' -VmId $id -RunPath $rp | Out-Null
            }
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            @($doc.guestExecutions).Count | Should -Be 3
            foreach ($e in @($doc.guestExecutions)) {
                $e.script | Should -Be 'nvme-check.sh'
                $e.sha256 | Should -Match '^[0-9a-f]{64}$'
                $e.result | Should -Be 'READY'
                $e.evidenceRef | Should -Match '^evidence/runcmd-'
            }
        }
    }

    It 'writes evidence files for every execution' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-check.sh' -ResourceGroupName 'rg-lab' `
                -VmName 'vm1' -VmId $id -RunPath $rp | Out-Null
            Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-check.sh' -ResourceGroupName 'rg-lab' `
                -VmName 'vm1' -VmId $id -RunPath $rp | Out-Null
            @(Get-ChildItem (Join-Path $rp 'evidence') -Filter 'runcmd-*').Count | Should -Be 2
        }
    }

    It 'returns the parsed contract document' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            $doc = Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-check.sh' -ResourceGroupName 'rg-lab' `
                -VmName 'vm1' -VmId $id -RunPath $rp
            $doc.result | Should -Be 'READY'
            @($doc.checks).Count | Should -Be 1
        }
    }
}

Describe 'PREP-ROLLBACK-1 (review F3): a script that changes the guest is on record BEFORE it runs' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-go-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'go-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'go-test' -VmId $id | Out-Null
        }
        $global:goRp = $script:runPath
        $global:goSeen = $null
        # What the record held while the script ran.
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
            # The first run only: RUNCMD-REPLAY-1 runs the neutral script after it.
            if ($null -eq $global:goSeen) { $global:goSeen = @((& (Get-Module VmMigrationFactory) { param($rp) Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1' } $global:goRp).guestExecutions | Where-Object { $_ }) }
            if ($ScriptString -match 'neutral-mark\.sh') { return '{"schema":"vmf.guest/2","script":"neutral-mark.sh","version":"1.0.0","result":"READY","checks":[]}' }
            if ($global:goThrow) { throw 'Run command timed out after 60 seconds.' }
            '{"schema":"vmf.guest/2","script":"nvme-fix.sh","version":"1.0.0","result":"FIXED","checks":[{"name":"a","status":"FIXED"}]}'
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Variable goRp, goSeen, goThrow -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the entry says STARTED while the script runs, and the SAME entry takes the result after' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-fix.sh' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp | Out-Null
        }
        @($global:goSeen).Count | Should -Be 1
        $global:goSeen[0].result | Should -Be 'STARTED'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { Read-VmfStateDoc -RunPath $rp -VmId $id }
        # RUNCMD-REPLAY-1: the neutral script that follows a changing one has
        # its own entry, after it; the changing script still has ONE.
        @($doc.guestExecutions | Where-Object script -EQ 'nvme-fix.sh').Count | Should -Be 1 -Because 'replaced, not added'
        @($doc.guestExecutions | ForEach-Object script) | Should -Be @('nvme-fix.sh', 'neutral-mark.sh')
        $doc.guestExecutions[0].result | Should -Be 'FIXED'
        $doc.guestExecutions[0].evidenceRef | Should -Be $global:goSeen[0].evidenceRef
    }

    It 'a script that throws leaves its STARTED entry - it may have changed the machine' {
        $global:goThrow = $true
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            { Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-fix.sh' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp } | Should -Throw
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            # RUNCMD-REPLAY-1: the neutral script still runs after it.
            @($doc.guestExecutions | ForEach-Object script) | Should -Be @('nvme-fix.sh', 'neutral-mark.sh')
            $doc.guestExecutions[0].result | Should -Be 'STARTED'
            Get-VmfGuestChangeThisAttempt -Doc $doc | Should -Be 'mayHaveChanged'
        }
    }

    It 'a script that only reads gets its entry after it ran, as before' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-check.sh' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp | Out-Null
        }
        @($global:goSeen).Count | Should -Be 0
    }

    It 'every script the engine treats as a change is in the list, and none that only reads' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Set-NvmeReady.ps1', 'Move-Pagefile.ps1', 'Install-TempDiskInit.ps1', 'nvme-fix.sh', 'temp-disk-setup.sh', 'kernel-update.sh', 'Install-ManaDriver.ps1') {
                $script:VmfGuestChangerScripts | Should -Contain $s
                Get-VmfGuestScript -Name $s | Should -Not -BeNullOrEmpty -Because "$s is a shipped script"
            }
            foreach ($s in 'Test-NvmeReady.ps1', 'nvme-check.sh', 'mana-check.sh', 'Test-ManaReady.ps1', 'Test-GuestValidation.ps1') {
                $script:VmfGuestChangerScripts | Should -Not -Contain $s
            }
        }
    }
}