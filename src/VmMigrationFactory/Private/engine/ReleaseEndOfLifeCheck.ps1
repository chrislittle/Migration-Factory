# EOL-RELEASE-AN-1 (decided 2026-11-14): Checking stops a Linux machine
# whose release is past its vendor's end of standard support, until an
# approver accepts it for that machine (onReleaseEndOfLife = proceed, the
# mechanism of the temporary disk files: a stop with a decide block in
# data/stop-reasons.json, Resolve-VmfDecision).
#
# Judged from the plan entry - the release the scan read, which the plan
# carries (New-VmfPlan: runningOsName, runningOsVersion, the image) - on the
# day the machine runs, so a release whose date passes after the scan still
# stops. Nothing is read from Azure or from the machine.

function Get-VmfReleaseEndOfLifeStop {
    <#
    .SYNOPSIS
        The stop for a Linux release past its vendor's end of standard support
        at Checking, or $null. PURE.
    .OUTPUTS
        A handler stop (@{ Next; Reason; Detail; MachineState }), or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter()][datetime]$Now = [datetime]::UtcNow
    )
    $assessment = $PlanEntry.assessment
    if (-not $assessment -or [string]$assessment.os -notmatch '^(?i)linux$') { return $null }
    $accepted = Get-VmfPolicy -PlanEntry $PlanEntry -Name 'onReleaseEndOfLife'
    if ([string]::Equals([string]$accepted, 'proceed', [System.StringComparison]::Ordinal)) { return $null }
    $eol = Get-VmfLinuxReleaseEol -Release (Get-VmfLinuxRelease -Vm $assessment) -Now $Now
    if ($eol.Status -ne 'past') { return $null }
    @{ Next = 'NEEDS_DECISION'; Reason = 'linuxReleaseEndOfLife'; MachineState = 'untouched'
       Detail = "$($eol.Text) Nothing on the machine changed." }
}
