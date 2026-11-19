#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-REMOVE-RECOVER-1: no restore rebuilds a machine, and Rebuild this
# machine is gone.
#
# It was decided on 2026-11-07 to remove the rebuild around the same disks
# (Path B). REBUILD-REMOVE-PLAN-1 stopped every new plan from giving it, and
# REBUILD-REMOVE-ACCEPT-1 removed its acceptances. Two ways to rebuild a
# machine were still reachable from the machine panel:
#
#   - Rebuild this machine (Restore-VmfVmShell, the engine operation rebuild,
#     its button, its timer resume), for a machine a rebuild left with no
#     definition in Azure;
#   - Restore this machine from the first copy on a machine an earlier version
#     moved by Path B (RestoreRebuild.ps1, -AcceptIdentityLoss), which deleted
#     the definition and built it again on the original size.
#
# THE RULE NOW. No move deletes a definition, so no new machine can need either.
# Restore this machine of a machine moved in place stays as it was. A restore
# from the first copy of a machine an earlier version rebuilt - not on its
# original size now - is refused before any change, in words that say why and
# what the other copy does. A restore job an earlier version started that
# rebuilds the machine is never resumed: it stops with words. A put-back job of
# kind rebuild (Rebuild this machine) on an old record gives up at once, keeps
# the copies, and starts no engine. No installs exist in the wild, so old
# records only need to stay readable.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:sub = "/subscriptions/$($script:subId)/resourceGroups/rg-app/providers/Microsoft.Compute"
    $script:vmId = "$($script:sub)/virtualMachines/win-01"
    $script:original = 'Standard_D4ds_v4'
    $script:target = 'Standard_D4ds_v6'

    # The target a move started on (STATE-TARGET-1). -Path B is a move an
    # earlier version made by the rebuild around the same disks.
    function Global:RrStarted([string]$Path = 'B') {
        $method = if ($Path -eq 'B') { 'rebuild' } else { 'in-place' }
        [pscustomobject]@{ path = $Path; series = 'v6'; acceleratedNetworking = ''; diskUpgrade = ''
            size = $script:target; controller = 'NVMe'
            target = [pscustomobject]@{ size = $script:target; controller = 'NVMe'; diskArch = 'nvme-temp'; tempDisks = 1
                choice = [pscustomobject]@{ option = 'v6'; source = 'person'; method = $method } } }
    }
    # A Windows machine moved from D4ds_v4 to D4ds_v6, both copies taken.
    # -NoStarted leaves the record of the started move out, so the plan entry's
    # path decides; -PlanPath is that path.
    function Global:RrRun {
        param([string]$Path = 'B', [string]$PlanPath = 'A', [switch]$NoStarted, [switch]$NoPrepared)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rrr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $entry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; path = $PlanPath; wave = 'w1'
            target = [pscustomobject]@{ size = $script:target; controller = 'NVMe'; diskArch = 'nvme-temp' } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; orig = $script:original
            tgt = $(if ($NoStarted) { $null } else { Global:RrStarted $Path }); entry = $entry; noPrep = [bool]$NoPrepared } {
            param($rp, $id, $sub, $orig, $tgt, $entry, $noPrep)
            Initialize-VmfRun -RunPath $rp -RunId 'rrr' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rrr' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $captured = [pscustomobject]@{
                vmConfig = [pscustomobject]@{ name = 'win-01'; size = $orig; controller = 'SCSI'; location = 'centralus'; osType = 'Windows'; zones = @(); capacityReservationGroupId = $null
                    osDisk = [pscustomobject]@{ name = 'win-01-os'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/win-01-os"; deleteOption = 'Delete' }
                    dataDisks = @(); tags = @{}; nics = @()
                    identity = [pscustomobject]@{ type = 'SystemAssigned'; principalId = '11111111-1111-1111-1111-111111111111' } } }
            if ($tgt) { $captured | Add-Member -NotePropertyName startedTarget -NotePropertyValue $tgt }
            $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue $captured
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{
                    snapshotId = $(if ($noPrep) { $null } else { "$sub/snapshots/win-01-prepared" }); cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/snapshots/win-01-pristine"; pristineSnapshotLocked = $true })
            $doc.state = 'MIGRATED'
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @($entry) }) -Depth 24
        }
        $rp
    }
    function Global:RrDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:RrLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    # A restore job an earlier version started, on the record, stopped at
    # -Phase. The size it read before it changed anything is -SizeNow.
    function Global:RrOldJob($rp, [string]$Phase = 'shellDeleted', [string]$SizeNow = $script:target, [string]$Kind = 'restore') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; ph = $Phase; sn = $SizeNow; k = $Kind } {
            param($rp, $id, $sub, $ph, $sn, $k)
            # As an earlier version wrote it: a restore that accepted an
            # identity loss, or a Rebuild this machine (kind rebuild), which no
            # writer of this version takes - so that one is written as stored.
            $opts = if ($k -eq 'restore') { @{ from = 'pristine'; diskNaming = 'new'; acceptPreserveRisk = $false; snapshotId = $null; acceptIdentityLoss = $true } }
                    else { @{ diskSource = 'disks'; as = 'original' } }
            $token = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-old' -StartedBy 'lead@example.com' -Note 'earlier version' `
                -Stamp '202611070800' -Options $opts `
                -Before ([pscustomobject][ordered]@{ osDisk = [pscustomobject]@{ name = 'win-01-os'; id = "$sub/disks/win-01-os"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; controller = 'NVMe' }
                    dataDisks = @(); sizeNow = $sn; planPath = '' })
            Save-VmfPutBackJobStep -Token $token -Phase $ph -MustWrite
            if ($k -ne 'restore') {
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc.putBackJob.kind = $k
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
    }
    # Azure for a restore. Every call that changes the machine or makes a disk
    # is recorded in order.
    function Global:RrMockAzure {
        $global:rrr = @{ calls = [System.Collections.Generic.List[string]]::new(); sizeNow = $script:target }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rrr.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:rrr.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:rrr.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { $global:rrr.sizeNow }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'win-01-os'; id = "$($script:sub)/disks/win-01-os"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:rrr.calls.Add("create:$DiskName"); "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:rrr.calls.Add("os:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:rrr.calls.Add('data'); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:rrr.calls.Add('an'); $true }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { $global:rrr.calls.Add('type') }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:rrr.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'win-01' } }
        # The two calls a rebuild made. Neither may happen.
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
    }
}
AfterAll {
    Remove-Item 'function:\RrStarted', 'function:\RrRun', 'function:\RrDoc', 'function:\RrLog', 'function:\RrOldJob', 'function:\RrMockAzure' -ErrorAction SilentlyContinue
    Remove-Variable rrr -Scope Global -ErrorAction SilentlyContinue
    Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'vmf-rrr-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'REBUILD-REMOVE-RECOVER-1: no restore takes an acceptance of an identity loss' {
    It 'Restore-VmfVm has no -AcceptIdentityLoss' {
        (Get-Command Restore-VmfVm).Parameters.Keys | Should -Not -Contain 'AcceptIdentityLoss'
    }
    It 'the restore job records no acceptance of an identity loss' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1')
        $code | Should -Not -Match 'acceptIdentityLoss|AcceptIdentityLoss'
        $code | Should -Match 'New-VmfPutBackJob' -Because 'the file under test is the real restore'
    }
}

Describe 'REBUILD-REMOVE-RECOVER-1: Rebuild this machine and the restore that rebuilds are gone' {
    It 'the module exports no Restore-VmfVmShell, and has no file for it' {
        Get-Command Restore-VmfVmShell -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $manifest = Import-PowerShellDataFile (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1')
        @($manifest.FunctionsToExport) | Should -Not -Contain 'Restore-VmfVmShell'
        @($manifest.FunctionsToExport) | Should -Contain 'Restore-VmfVm' -Because 'the manifest under test is the real one'
        Test-Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVmShell.ps1') | Should -BeFalse
    }
    It 'the files of the restore that rebuilds and of Rebuild this machine from the copies are gone: <f>' -ForEach @(
        @{ f = 'RestoreRebuild.ps1' }, @{ f = 'RecoverAllDisks.ps1' }) {
        Test-Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' $f) | Should -BeFalse
    }
    It '<f> no longer exists' -ForEach @(
        @{ f = 'Test-VmfRestoreRebuilds' }, @{ f = 'Invoke-VmfRestoreRebuild' }, @{ f = 'Assert-VmfRestoreRebuildable' },
        @{ f = 'New-VmfRestoreRebuildDisks' }, @{ f = 'Assert-VmfRestoreIdentityAccepted' }, @{ f = 'Remove-VmfDefinitionForRebuild' },
        @{ f = 'ConvertTo-VmfPlainCapture' }, @{ f = 'New-VmfRecoveryDisks' }, @{ f = 'Add-VmfRecoveryDiskRecord' }, @{ f = 'Get-VmfUnusedRecoveryDisks' }) {
        InModuleScope VmMigrationFactory -Parameters @{ f = $f } { param($f) Get-Command $f -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
    }
    # REBUILD-REMOVE-ENGINE-1 deleted Remove-VmfFailedDefinition with the Path B
    # rollback, its last caller (RebuildRemoveEngine.Tests.ps1).
    It 'the helper the in-place restore still uses is kept: <f>' -ForEach @(
        @{ f = 'Remove-VmfDiskForResume' }) {
        InModuleScope VmMigrationFactory -Parameters @{ f = $f } { param($f) Get-Command $f -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty }
    }
    It 'no put-back job or hold is of kind rebuild' {
        InModuleScope VmMigrationFactory {
            @((Get-Command New-VmfPutBackJob).Parameters['Kind'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues) | Should -Not -Contain 'rebuild'
            @((Get-Command Get-VmfMachineLeaseHolder).Parameters['Kind'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues) | Should -Not -Contain 'rebuild'
        }
    }
}

Describe 'REBUILD-REMOVE-RECOVER-1: the engine has no operation rebuild' {
    BeforeAll { $script:entry = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') }
    It 'the entry point has no branch for it and reads none of its settings' {
        $script:entry | Should -Not -Match "'rebuild'\s*\{"
        $script:entry | Should -Not -Match 'Restore-VmfVmShell|VMF_REBUILD_AS|VMF_ACCEPT_IDENTITY_LOSS'
        $script:entry | Should -Match "'restore'\s*\{" -Because 'the file under test is the real entry point'
    }
    It 'the restore reads VMF_DISK_SOURCE only as the copy it restores from' {
        $script:entry | Should -Match '\$restoreParams\.From = \$env:VMF_DISK_SOURCE'
        @(($script:entry -split "`n") | Where-Object { $_ -match 'VMF_DISK_SOURCE' }) | Should -HaveCount 1
    }
}

Describe 'REBUILD-REMOVE-RECOVER-1: the service starts no rebuild' {
    It 'the start of the engine has no operation rebuild, and none of its inputs' {
        $cmd = Get-Command Invoke-VmfFacadeStartEngine
        $ops = @($cmd.Parameters['Operation'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues)
        $ops | Should -Contain 'restore' -Because 'otherwise this reads nothing'
        $ops | Should -Not -Contain 'rebuild'
        foreach ($p in 'RebuildAs', 'AcceptIdentityLoss') { $cmd.Parameters.Keys | Should -Not -Contain $p }
        $sources = @($cmd.Parameters['DiskSource'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues)
        $sources | Should -Not -Contain 'disks' -Because 'only a rebuild built a machine from the disks it ran on'
        $sources | Should -Contain 'pristine'
    }
    It 'a POST to engine/rebuild is refused before anything starts' {
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob { throw 'no engine may start' }
        { Invoke-VmfFacadeStartEngine -Principal ([pscustomobject]@{ Identity = 'op@example.com'; Roles = @('Vmf.Operator') }) -Operation 'rebuild' -RunId 'r1' -VmId $script:vmId -Note 'n' } |
            Should -Throw
        Should -Invoke -ModuleName FacadeCore Get-VmfFacadeEngineJob -Times 0
    }
    It 'the start route refuses no removed input by name, and reads none of the inputs from the body' {
        $route = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1')
        $route | Should -Not -Match '\$body\.acceptIdentityLoss|\$params\.AcceptIdentityLoss|RebuildAs|\$body\.as\b|acceptIdentityLoss|NoRemovedEngineInput'
        $route | Should -Match 'Invoke-VmfFacadeStartEngine @params' -Because 'the route under test is the real one'
    }
    It 'FacadeCore names no rebuild operation in its code: no busy list, no override and no resume of one' {
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Not -Match "Operation -eq 'rebuild'|-Operation @\([^)]*'rebuild'|VMF_REBUILD_AS|VMF_ACCEPT_IDENTITY_LOSS|RebuildAs|AcceptIdentityLoss"
        $core | Should -Match "-Operation @\('restore', 'finish'\)" -Because 'the busy lists under test are the real ones'
    }
}

Describe 'REBUILD-REMOVE-RECOVER-1: the Migrations page offers no rebuild' {
    BeforeAll { $script:page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js') }
    It 'there is no Rebuild this machine button, dialog or call' {
        $script:page | Should -Not -Match 'askRebuild|rebuildOffered|rebuild-btn|engine/rebuild'
        $script:page | Should -Match 'engine/restore' -Because 'the page under test is the real one'
    }
    It 'the restore dialog sends no acceptance of an identity loss, and asks for none' {
        $script:page | Should -Not -Match 'acceptIdentityLoss|restoreIdentityWords|restoreIdAccept|restoreIdMissing'
    }
}
