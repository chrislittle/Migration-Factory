# REBUILD-MOVE-HOST-1, 2026-11-11: a machine on an Azure Dedicated Host,
# and a machine with hibernation enabled, are outside the scope of this tool.
#
# The scan excludes both (Get-VmfAssessmentRecord). A plan made from an older
# assessment can still hold such a machine, and a person can place a machine
# on a host or enable hibernation after the scan. So PRECHECK judges the
# machine it has just read, beside the other out-of-scope stops: before any
# stop a person can accept, any RunCommand, any start and the capture. It
# reads nothing more from Azure - the fields come with the machine
# (Get-VmfVmConfig), read by the same function the capture uses
# (Get-VmfRebuildSettingsFromVm).
#
# A hibernated machine has hibernation enabled (Microsoft's Hibernation
# overview, prerequisites: hibernation must be enabled on the VM), so this
# stop also comes first for every hibernated machine. The earlier stop for a
# hibernated power state (machineHibernated) is gone.

function Get-VmfHostHibernationStop {
    <#
    .SYNOPSIS
        The stop at Checking for a machine on a dedicated host or with
        hibernation enabled, or $null. PURE: the machine as Get-VmfVmConfig
        returned it.
    .OUTPUTS
        A handler stop (@{ Next; Reason; Detail; MachineState }), or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Vm)
    $settings = Get-VmfRebuildSettingsFromVm -Vm $Vm
    $hostName = ([string]$settings.hostId -split '/') | Select-Object -Last 1
    $groupName = ([string]$settings.hostGroupId -split '/') | Select-Object -Last 1
    if ($hostName -or $groupName) {
        $where = @(if ($hostName) { "on the dedicated host '$hostName'" }; if ($groupName) { "in the host group '$groupName'" }) -join ' '
        return @{ Next = 'NEEDS_DECISION'; Reason = 'dedicatedHost'; MachineState = 'untouched'
                  Detail = "This machine is $where. A machine on a dedicated host is outside the scope of this tool. Nothing on the machine changed." }
    }
    if ($settings.hibernationEnabled) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'hibernationEnabled'; MachineState = 'untouched'
                  Detail = 'Hibernation is enabled on this machine. A machine with hibernation enabled is outside the scope of this tool. Nothing on the machine changed.' }
    }
    $null
}
