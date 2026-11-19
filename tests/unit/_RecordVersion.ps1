# OLD-VERSION-READERS-REMOVE-7 and OLD-STATE-READERS-FINISH-1: the version a
# hand-made record in a test carries.
#
# The engine reads a plan entry and a state document of the current version
# only (ConvertTo-VmfSupportedPlan, Read-VmfStateDoc): nothing is public before
# 1.0 (2026-11-11), so no store holds a record an earlier version wrote.
# A fixture stands in for what a writer of this version writes, so it carries
# the version the writer gives - read from the module, so the next contract
# bump changes one line in the module and none here.
#
# USE IT ONLY ON A RECORD THE TEST BUILDS BY HAND. Never stamp what a real
# writer (New-VmfPlan, Set-VmfMachineTarget, New-VmfStateDoc, a decision)
# wrote: a record of theirs with another version is a writer gap, and the
# test must fail on it.
#
# Global, like _RecordShape.ps1, so a fixture built inside InModuleScope can
# call it too. Not named *.Tests.ps1 on purpose: Pester discovers only test
# files.

function global:Get-VmfTestPlanEntryVersion {
    & @(Get-Module VmMigrationFactory)[0] { Get-VmfPlanSchemaVersion }
}

function global:Get-VmfTestStateVersion {
    & @(Get-Module VmMigrationFactory)[0] { $script:VmfStateDocSchemaVersion }
}

function global:Set-VmfTestPlanVersion {
    # A hand-made plan (an object or a hashtable, with entries): every entry
    # gets the version the engine writes. Returns the plan.
    param($Plan)
    $v = Get-VmfTestPlanEntryVersion
    $entries = if ($Plan -is [System.Collections.IDictionary]) { $Plan['entries'] } else { $Plan.entries }
    foreach ($e in @($entries)) {
        if ($null -eq $e) { continue }
        if ($e -is [System.Collections.IDictionary]) { $e['schemaVersion'] = $v }
        else { $e | Add-Member -NotePropertyName schemaVersion -NotePropertyValue $v -Force }
    }
    $Plan
}

function global:Set-VmfTestAnDecision {
    # OLD-STATE-READERS-FINISH-1: a hand-made record that a test takes into
    # CONVERTING or VALIDATING holds the accelerated networking decision
    # GUEST_PREP saves on every move (captured.acceleratedNetworking) - the
    # policy of the plan entry (Get-VmfPolicy) and whether the move is an
    # NVMe conversion, as Resolve-VmfAcceleratedNetworkingForMove gives them
    # for a machine with nothing to stop. Only a record with no decision is
    # changed. Never use it on a record a real GUEST_PREP wrote.
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$VmId, [Parameter(Mandatory)]$PlanEntry)
    & @(Get-Module VmMigrationFactory)[0] {
        param($rp, $id, $plan)
        $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
        if (-not $doc) { return }
        $captured = if ($doc.PSObject.Properties['captured'] -and $doc.captured) { $doc.captured } else { [pscustomobject]@{} }
        if ($captured -is [System.Collections.IDictionary]) { $captured = [pscustomobject]$captured }
        if ($captured.PSObject.Properties['acceleratedNetworking'] -and $captured.acceleratedNetworking) { return }
        $captured | Add-Member -NotePropertyName acceleratedNetworking -Force -NotePropertyValue ([pscustomobject]@{
                policy = (Get-VmfPolicy -PlanEntry $plan -Name 'acceleratedNetworking')
                expectFabric = ((Get-VmfMoveKind -PlanEntry $plan) -eq 'nvme-conversion'); manaDriver = 'present'; detail = '' })
        $doc | Add-Member -NotePropertyName captured -NotePropertyValue $captured -Force
        Write-VmfStateDoc -RunPath $rp -Document $doc
    } $RunPath $VmId $PlanEntry
}