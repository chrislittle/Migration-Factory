# BATCH-CYCLECLOUD-SIGNAL-1, 2026-11-03: Checking asks again whether a machine
# is a node of an Azure CycleCloud cluster.
#
# The scan excludes such a machine (Test-VmfCycleCloudNode, by the tags
# CycleCloud documents). A plan made from an assessment before that rule has
# the machine as a standalone machine, and a cluster can add a node after the
# scan. So PRECHECK judges the machine it has just read, with the scan's own
# rule, beside the other out-of-scope stops: before any stop a person can
# accept, any RunCommand and any start. It reads nothing more from Azure -
# the tags come with the machine (Get-VmfVmConfig).
#
# A file of its own, not WorkloadCheck.ps1: one rule, one place, and the
# other workload checks there are another item's.

function Get-VmfCycleCloudStop {
    <#
    .SYNOPSIS
        The stop for a node of an Azure CycleCloud cluster at Checking, or
        $null. PURE: the machine as Get-VmfVmConfig returned it.
    .OUTPUTS
        A handler stop (@{ Next; Reason; Detail; MachineState }), or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Vm)
    $verdict = Test-VmfCycleCloudNode -Tags (Get-VmfRecordField -Object $Vm -Name 'Tags')
    if (-not $verdict.IsNode) { return $null }
    @{ Next = 'NEEDS_DECISION'; Reason = 'cycleCloudNode'; MachineState = 'untouched'
       Detail = "This machine is in an Azure CycleCloud cluster, found by the tags $(Get-VmfCycleCloudEvidenceText -Verdict $verdict). CycleCloud makes and changes the machines of its cluster. The product does not move a machine that a service manages. Nothing on the machine changed." }
}
