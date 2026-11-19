#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VERIFY-FP-1 part 3: the evidence record - each machine read before the move
# and after it, kept, and compared by one rule.
#
# Scope set 2026-09-28: the record holds what the product
# already reads (Azure's view of the machine, the Instance Metadata Service,
# the guest's storage, boot bus, temporary disk and network driver), before and
# after. Listening ports and services were dropped. It is NEVER a pass or a
# fail: a reading that fails its check already stops the move and restores the
# machine, so the record only says what is the same and what changed.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:vmBefore = [pscustomobject]@{
        size = 'Standard_D2ds_v4'; controller = 'SCSI'
        osDisk = [pscustomobject]@{ name = 'app01_OsDisk_1' }
        dataDisks = @([pscustomobject]@{ name = 'app01-data1'; lun = 1 }, [pscustomobject]@{ name = 'app01-data0'; lun = 0 })
        nics = @([pscustomobject]@{ id = '/n/1'; primary = $true; acceleratedNetworking = $true })
        securityProfile = [pscustomobject]@{ securityType = 'TrustedLaunch'; secureBootEnabled = $true; vTpmEnabled = $true }
    }
    $script:vmAfter = $script:vmBefore | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $script:vmAfter.size = 'Standard_D2ds_v6'; $script:vmAfter.controller = 'NVMe'
    $script:imdsBefore = [pscustomobject]@{ reached = 'yes'; vmSize = 'Standard_D2ds_v4'; securityType = 'TrustedLaunch'; secureBoot = 'true'; vtpm = 'true' }
    $script:imdsAfter = [pscustomobject]@{ reached = 'yes'; vmSize = 'Standard_D2ds_v6'; securityType = 'TrustedLaunch'; secureBoot = 'true'; vtpm = 'true' }
    # What Test-GuestValidation.ps1 really reports, before and after a move
    # from a size with a SCSI temporary disk: stornvme is stopped on SCSI and
    # running on NVMe, guest prep moves the page file off D:, and D: changes.
    $script:guest = { param($bus, $temp, $svc, $vols, $page) [pscustomobject]@{ checks = @(
        [pscustomobject]@{ name = 'boot disk bus'; status = 'INFO'; detail = $bus }
        [pscustomobject]@{ name = 'stornvme service'; status = 'INFO'; detail = $svc }
        [pscustomobject]@{ name = 'volumes'; status = 'INFO'; detail = $vols }
        [pscustomobject]@{ name = 'nvme temp disk D:'; status = 'INFO'; detail = $temp }
        [pscustomobject]@{ name = 'pagefile'; status = 'INFO'; detail = $page }
        [pscustomobject]@{ name = 'storage pools'; status = 'INFO'; detail = 'none' }) } }
    $script:gBefore = & $script:guest 'SCSI' 'D: on SCSI' 'Stopped' 'C:127GB:NTFS D:16GB:NTFS E:64GB:NTFS' 'D:\pagefile.sys'
    $script:gAfter = & $script:guest 'NVMe' 'D: on NVMe' 'Running' 'C:127GB:NTFS D:110GB:NTFS E:64GB:NTFS' 'C:\pagefile.sys'
}

Describe 'VERIFY-FP-1 part 3: one side of the record' {
    It 'reads Azure, the Instance Metadata Service and the guest into named readings' {
        InModuleScope VmMigrationFactory -Parameters @{ vm = $script:vmBefore; imds = $script:imdsBefore; g = $script:gBefore } {
            param($vm, $imds, $g)
            $s = ConvertTo-VmfEvidenceSide -VmConfig $vm -Imds $imds -Guest $g -Fabric ([pscustomobject]@{ fabric = 'mlx5' })
            $s['azure.size'] | Should -Be 'Standard_D2ds_v4'
            $s['azure.controller'] | Should -Be 'SCSI'
            $s['azure.osDisk'] | Should -Be 'app01_OsDisk_1'
            $s['azure.dataDisks'] | Should -Be 'LUN 0, LUN 1' -Because 'in LUN order, whatever order Azure listed them'
            $s['azure.acceleratedNetworking'] | Should -Be 'On'
            $s['azure.secureBootVtpm'] | Should -Be 'On, On'
            $s['imds.answered'] | Should -Be 'Yes'
            $s['imds.size'] | Should -Be 'Standard_D2ds_v4'
            $s['guest.bootBus'] | Should -Be 'SCSI'
            $s['guest.volumes'] | Should -Be 'C:127GB:NTFS D:16GB:NTFS E:64GB:NTFS'
            $s['guest.storageGroups'] | Should -Be 'None'
            $s['guest.acceleratedNetworkingDriver'] | Should -Be 'mlx5'
        }
    }

    It 'something that was not read is null, never a made-up value' {
        InModuleScope VmMigrationFactory {
            $s = ConvertTo-VmfEvidenceSide -VmConfig $null -Imds ([pscustomobject]@{ reached = 'unknown' }) -Guest $null -Fabric $null
            $s['azure.size'] | Should -BeNullOrEmpty
            $s['imds.answered'] | Should -BeNullOrEmpty -Because 'unknown is not an answer'
            $s['guest.bootBus'] | Should -BeNullOrEmpty
        }
    }
}

Describe 'VERIFY-FP-1 part 3: the comparison' {
    BeforeAll {
        $script:rows = InModuleScope VmMigrationFactory -Parameters @{ vb = $script:vmBefore; va = $script:vmAfter; ib = $script:imdsBefore; ia = $script:imdsAfter
                                                                      gb = $script:gBefore; ga = $script:gAfter } {
            param($vb, $va, $ib, $ia, $gb, $ga)
            $b = ConvertTo-VmfEvidenceSide -VmConfig $vb -Imds $ib -Guest $gb -Fabric ([pscustomobject]@{ fabric = 'mlx5' })
            $a = ConvertTo-VmfEvidenceSide -VmConfig $va -Imds $ia -Guest $ga -Fabric ([pscustomobject]@{ fabric = 'mana' })
            $plan = [pscustomobject]@{ assessment = [pscustomobject]@{ sourceDiskArch = 'scsi-temp' } }
            Compare-VmfEvidence -Before $b -After $a -Planned (Get-VmfEvidencePlanned -PlanEntry $plan -Doc $null)
        }
        $script:row = { param($key) @($script:rows | Where-Object key -eq $key)[0] }
    }

    It 'what the move is meant to change is "planned" - nothing on a normal move reads as "changed"' {
        @($script:rows | Where-Object result -eq 'changed').Count | Should -Be 0 -Because 'a normal move must not look like something to chase'
        foreach ($k in 'azure.size', 'azure.controller', 'imds.size', 'guest.bootBus', 'guest.nvmeDriver', 'guest.tempDisk', 'guest.acceleratedNetworkingDriver', 'guest.pageFile', 'guest.volumes') {
            (& $script:row $k).result | Should -Be 'planned' -Because $k
        }
    }

    It 'what stayed is "same"' {
        foreach ($k in 'azure.osDisk', 'azure.dataDisks', 'imds.securityType', 'guest.storageGroups') {
            (& $script:row $k).result | Should -Be 'same' -Because $k
        }
    }

    It 'what a move plans depends on the machine: a size with no SCSI temporary disk does not move the page file' {
        InModuleScope VmMigrationFactory {
            $plain = [pscustomobject]@{ assessment = [pscustomobject]@{ sourceDiskArch = 'diskless' } }
            $keep = [pscustomobject]@{ captured = [pscustomobject]@{ acceleratedNetworking = [pscustomobject]@{ policy = 'preserve' } } }
            $turn = [pscustomobject]@{ captured = [pscustomobject]@{ acceleratedNetworking = [pscustomobject]@{ policy = 'ensureOn' } } }
            @(Get-VmfEvidencePlanned -PlanEntry $plain -Doc $keep).Count | Should -Be 0
            Get-VmfEvidencePlanned -PlanEntry $plain -Doc $turn | Should -Contain 'azure.acceleratedNetworking'
            $r = @(Compare-VmfEvidence -Before ([ordered]@{ 'guest.pageFile' = 'D:\pagefile.sys' }) -After ([ordered]@{ 'guest.pageFile' = 'C:\pagefile.sys' }) -Planned (Get-VmfEvidencePlanned -PlanEntry $plain -Doc $keep))
            $r[0].result | Should -Be 'changed'
        }
    }

    It 'an unset disk controller is Azure''s default, SCSI - not "not read"' {
        InModuleScope VmMigrationFactory {
            (ConvertTo-VmfEvidenceSide -VmConfig ([pscustomobject]@{ size = 'Standard_D2s_v4'; controller = $null }) -Imds $null -Guest $null -Fabric $null)['azure.controller'] | Should -Be 'SCSI'
        }
    }

    It 'anything else that differs is "changed" - a fact, never a pass or a fail' {
        InModuleScope VmMigrationFactory {
            $r = @(Compare-VmfEvidence -Before ([ordered]@{ 'guest.volumes' = 'C: E:' }) -After ([ordered]@{ 'guest.volumes' = 'C:' }))
            $r[0].result | Should -Be 'changed'
            @($r | Where-Object { $_.result -in 'pass', 'fail', 'ok', 'failed' }).Count | Should -Be 0
        }
    }

    It 'a side not read is "notRead", and a reading neither side has is left out' {
        InModuleScope VmMigrationFactory {
            $r = @(Compare-VmfEvidence -Before ([ordered]@{ 'guest.bootBus' = $null; 'guest.pageFile' = $null }) -After ([ordered]@{ 'guest.bootBus' = 'NVMe'; 'guest.pageFile' = $null }))
            $r.Count | Should -Be 1
            $r[0].result | Should -Be 'notRead'
        }
    }

    It 'every row names its group and a label a person reads' {
        foreach ($r in $script:rows) {
            $r.group | Should -BeIn @('azure', 'imds', 'guest')
            $r.label | Should -Not -BeNullOrEmpty
            $r.label | Should -Not -Match '\.' -Because 'a label is words, not a key'
        }
    }

    It 'the same letters in another case are the same reading' {
        InModuleScope VmMigrationFactory {
            (Compare-VmfEvidence -Before ([ordered]@{ 'azure.osDisk' = 'App01_OsDisk_1' }) -After ([ordered]@{ 'azure.osDisk' = 'app01_osdisk_1' }))[0].result | Should -Be 'same'
        }
    }
}

Describe 'VERIFY-FP-1 part 3: the record is kept on the machine' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-evid-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app01'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            param($rp, $vm)
            Initialize-VmfRun -RunPath $rp -RunId 'evid' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'evid' -VmId $vm -Wave 'w1' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'both sides are written to the state document, with when' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            param($rp, $vm)
            Save-VmfEvidence -RunPath $rp -VmId $vm -Before ([ordered]@{ 'azure.size' = 'Standard_D2s_v4' }) -After ([ordered]@{ 'azure.size' = 'Standard_D2s_v6' })
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc.evidence.before.'azure.size' | Should -Be 'Standard_D2s_v4'
            $doc.evidence.after.'azure.size' | Should -Be 'Standard_D2s_v6'
            $doc.evidence.takenUtc | Should -Not -BeNullOrEmpty
        }
    }

    It 'the state document with a record is valid against its contract' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId; root = $script:repoRoot } {
            param($rp, $vm, $root)
            Save-VmfEvidence -RunPath $rp -VmId $vm -Before ([ordered]@{ 'azure.size' = 'Standard_D2s_v4'; 'guest.bootBus' = $null }) -After ([ordered]@{ 'azure.size' = 'Standard_D2s_v6'; 'guest.bootBus' = 'NVMe' })
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $schema = Get-Content (Join-Path $root 'schemas' 'vm-state.schema.json') -Raw
            ($doc | ConvertTo-Json -Depth 30) | Test-Json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue
        }
    }
}

Describe 'VERIFY-FP-1 part 3: where the engine takes the readings' {
    BeforeAll {
        $script:sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $script:prep = [regex]::Match($script:sm, '(?s)function Invoke-VmfStepGuestPrep.*?\n\}').Value
        $script:val = [regex]::Match($script:sm, '(?s)function Invoke-VmfStepValidating.*?\n\}').Value
    }

    It 'guest prep reads the guest with the validation script BEFORE it changes anything, once, as a reading' {
        $i = $script:prep.IndexOf('guestBefore')
        $i | Should -BeGreaterThan 0
        foreach ($change in 'Set-NvmeReady', 'nvme-fix', 'Move-Pagefile', 'Install-TempDiskInit', 'Test-NvmeReady') {
            $j = $script:prep.IndexOf($change)
            if ($j -ge 0) { $i | Should -BeLessThan $j -Because "the reading comes before $change" }
        }
        $script:prep | Should -Match 'captured\.PSObject\.Properties\[''guestBefore''\]' -Because 'a resume does not read it again'
        $script:prep | Should -Match '-RunPath \$Context\.RunPath -AsReading'
    }

    It 'validating keeps the after readings and saves the record before the machine is migrated' {
        $script:val | Should -Match 'Save-VmfEvidence'
        $script:val.IndexOf('Save-VmfEvidence') | Should -BeLessThan $script:val.LastIndexOf("Next = 'MIGRATED'")
        $script:val | Should -Match 'Get-VmfVmCapture -Vm'
    }

    It 'a record that cannot be written never stops the move' {
        # STEP-LOG-1: the warning goes through Write-VmfStepLine now, so a
        # warning that cannot be written does not stop the move either.
        $script:val | Should -Match '(?s)try \{\s*\$evDoc = .*?Save-VmfEvidence .*?\}\s*catch \{\s*if \(\$_\.Exception\.Message -match ''abandon this VM''\) \{ throw \}\s*Write-VmfStepLine[^\r\n]*-Outcome warn'
    }
}

Describe 'VERIFY-FP-1 part 3: the migration record carries the evidence' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-evrec-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:rp = "$($script:root)/mig-ev"
        $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/web'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmId } {
            param($rp, $vm)
            Initialize-VmfRun -RunPath $rp -RunId 'mig-ev' -Kind 'migration' -FromAssessment 'scan-1' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'mig-ev' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            Save-VmfEvidence -RunPath $rp -VmId $vm `
                -Before ([ordered]@{ 'azure.size' = 'Standard_D2s_v4'; 'azure.controller' = 'SCSI'; 'azure.osDisk' = 'web_OsDisk_1'; 'guest.bootBus' = $null }) `
                -After ([ordered]@{ 'azure.size' = 'Standard_D2s_v6'; 'azure.controller' = 'NVMe'; 'azure.osDisk' = 'web_OsDisk_1'; 'guest.bootBus' = 'NVMe' })
        }
        @{ schemaVersion = 1; assessmentRunId = 'scan-1'; entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; path = 'A'
            assessment = @{ sourceSize = 'Standard_D2s_v4'; os = 'Linux' }; target = @{ size = 'Standard_D2s_v6'; controller = 'NVMe' } }) } |
            ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:rp 'plan.json')
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'each machine has its rows, and "now" is what Azure said after the move' {
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        $m = @($r.machines)[0]
        $m.now.size | Should -Be 'Standard_D2s_v6'
        $m.now.basis | Should -Be 'read from Azure after the move'
        $rows = @($m.evidence.rows)
        (@($rows | Where-Object key -eq 'azure.size'))[0].result | Should -Be 'planned'
        (@($rows | Where-Object key -eq 'azure.osDisk'))[0].result | Should -Be 'same'
        (@($rows | Where-Object key -eq 'guest.bootBus'))[0].result | Should -Be 'notRead'
    }

    # REPORT-AUTO-1 made it version 3; the evidence rows are unchanged.
    It 'the record is valid against its contract, version 3' {
        Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com' | Out-Null
        $file = Join-Path $script:root 'vmf-records' 'mig-ev.json'
        $schema = Join-Path $script:repoRoot 'schemas' 'migration-record.schema.json'
        Get-Content $file -Raw | Test-Json -SchemaFile $schema | Should -BeTrue
        (Get-Content $file -Raw | ConvertFrom-Json).schemaVersion | Should -Be 5
    }
}

Describe 'VERIFY-FP-1 part 3: a machine tried again is read again' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-evid-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app01'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            param($rp, $vm)
            Initialize-VmfRun -RunPath $rp -RunId 'evid' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'evid' -VmId $vm -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ guestBefore = [pscustomobject]@{ checks = @() }
                    imdsBefore = [pscustomobject]@{ reached = 'yes'; vmSize = 'Standard_D2s_v4' } }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a person''s retry from the first step drops the first guest reading' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            param($rp, $vm)
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).captured.PSObject.Properties['guestBefore'] | Should -BeNullOrEmpty
        }
    }

    It 'the automatic rollback keeps it - with no pristine copy, the guest prep is still there' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            param($rp, $vm)
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK'
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).captured.PSObject.Properties['guestBefore'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'any retry drops the record of an earlier pass' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            param($rp, $vm)
            Save-VmfEvidence -RunPath $rp -VmId $vm -Before ([ordered]@{ 'azure.size' = 'a' }) -After ([ordered]@{ 'azure.size' = 'b' })
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'VALIDATING'
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).PSObject.Properties['evidence'] | Should -BeNullOrEmpty
        }
    }

    It 'armed again after guest prep, it is kept - the machine is not untouched' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            param($rp, $vm)
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'VALIDATING'
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).captured.PSObject.Properties['guestBefore'] | Should -Not -BeNullOrEmpty
        }
    }

    # IMDS-KEEP-1: GUEST_PREP keeps a known Instance Metadata Service reading
    # over an unknown one - inside ONE attempt. A person's retry from the first
    # step is a complete new run (SAFETY-RETRY-1) on a machine that may have
    # been rolled back since, so it asks again from nothing, as the guest
    # reading beside it does.
    It 'IMDS-KEEP-1: a person''s retry from the first step drops the Instance Metadata Service reading' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            param($rp, $vm)
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).captured.PSObject.Properties['imdsBefore'] | Should -BeNullOrEmpty
        }
    }

    It 'IMDS-KEEP-1: the automatic rollback, and a retry that only validates again, keep it (<From>)' -ForEach @(
        @{ From = 'PRECHECK'; New = $false }, @{ From = 'VALIDATING'; New = $true }) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId; from = $From; new = $New } {
            param($rp, $vm, $from, $new)
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From $from -NewAttempt:$new
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).captured.imdsBefore.reached | Should -Be 'yes'
        }
    }
}

Describe 'VERIFY-FP-1 part 3: a reading is not a check' {
    It 'the audit entry of a run taken only to read says READING, whatever the script said' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-evid-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                param($rp)
                $vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app01'
                Initialize-VmfRun -RunPath $rp -RunId 'evid' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'evid' -VmId $vm -Wave 'w1' | Out-Null
                Mock Invoke-VmfRunCommand { '{"schema":"vmf.guest/2","script":"guest-validate.sh","version":"1.0.0","result":"FAIL","checks":[{"name":"fstab device names","status":"FAIL","detail":"contains /dev/sd*"}],"facts":{}}' }
                Invoke-VmfGuestScriptOnVm -ScriptName 'guest-validate.sh' -ResourceGroupName 'rg-app' -VmName 'app01' -VmId $vm -RunPath $rp -AsReading | Out-Null
                (@((Read-VmfStateDoc -RunPath $rp -VmId $vm).guestExecutions)[-1]).result | Should -Be 'READING'
            }
        } finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }

    It 'the machine panel shows a reading as a reading, not as a problem' {
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')
        # PREP-ROLLBACK-1: the pill is drawn by guestRunPill now
        # (tests/js/guest-run-pill.test.js runs it).
        $page | Should -Match "if \(g\?\.result === 'READING'\) \{ return ``<span class=`"pill quiet`""
        $page | Should -Match 'const pill = guestRunPill\(g, running\);'
    }
}