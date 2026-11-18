# AVSET-NOTE-1: what PRECHECK tells an operator about a machine in an
# availability set - worked out from what Azure said, and nothing more.
#
# The note used to say, on EVERY member of EVERY set, that starting the machine
# "can fail until every machine in the set is stopped" - and then that the
# product converts them one at a time with the others running. It warned
# against the product's own strategy, stated a condition as a likely outcome,
# and was more certain than the comment beside it, which called the rule "not
# established yet". A lab run disproved it as stated: two machines in one
# set, v4 to v6, one at a time with the other running, both moved.
#
# Microsoft's resize page makes the rule conditional: the whole set must be
# stopped only when the new size "isn't available on the hardware cluster
# currently hosting" it. So the engine asks the set's own available-sizes list,
# and this says only what that answer supports. A list that could not be read
# is UNKNOWN - never read as either answer.

function Get-VmfAvailabilitySetNote {
    <#
    .SYNOPSIS
        The PRECHECK note for a machine that shares an availability set: an
        outcome (info or warn) and a sentence. Pure.
    .PARAMETER OfferedSizes
        The set's available sizes, or $null when Azure could not be asked.
    .PARAMETER DefinitelyRunning
        AVSET-NOT-OFFERED-STOP-1: the other machines that Azure SAYS run - a
        power state Azure did not give is not one. $Running also counts those.
    .OUTPUTS
        Outcome 'stop' only when Azure is definite on both: the hardware of the
        set does not offer the target size, and another machine of it runs.
        The caller then stops the machine at Checking, untouched.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Others,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Names,
        [Parameter(Mandatory)][int]$Running,
        [Parameter()][int]$DefinitelyRunning = 0,
        [Parameter()][AllowEmptyString()][string]$TargetSize,
        [Parameter()][AllowNull()][string[]]$OfferedSizes
    )

    $shares = "This machine shares an availability set with $Others other $(if ($Others -eq 1) { 'machine' } else { 'machines' }): $Names."
    $known = ($null -ne $OfferedSizes) -and $TargetSize
    if (-not $known) {
        return [pscustomobject]@{
            Outcome = 'warn'
            Detail  = ("$shares Azure did not say if the hardware that hosts the set offers $(if ($TargetSize) { $TargetSize } else { 'the new size' }). " +
                       'If it does not, Azure can refuse to start this machine until every machine in the set is stopped.')
        }
    }
    if (@($OfferedSizes | Where-Object { $_ -ieq $TargetSize }).Count) {
        return [pscustomobject]@{
            Outcome = 'info'
            Detail  = ("$shares The hardware that hosts the set offers $TargetSize, so the machines move one at a time and the others keep running. " +
                       'Azure can still refuse a start if that hardware has no free capacity.')
        }
    }
    # AVSET-NOT-OFFERED-STOP-1 (2026-11-14): Microsoft's resize page -
    # when the hardware does not offer the new size, "then you need to
    # deallocate all VMs in the availability set to resize the VM". With
    # another machine of the set running, Azure refuses the size inside the
    # change window and the machine rolls back. So Checking stops it before any
    # change, with the same words. A power state Azure did not give, or no
    # other machine running, keeps the warning (AVSET-NOTE-1).
    [pscustomobject]@{
        Outcome = $(if ($DefinitelyRunning -gt 0) { 'stop' } else { 'warn' })
        Detail  = ("$shares The hardware that hosts the set does not offer $TargetSize. " +
                   "Azure can refuse to start this machine until every machine in the set is stopped, and $Running of them $(if ($Running -eq 1) { 'is' } else { 'are' }) running or could not be checked.")
    }
}

function Get-VmfAvailabilitySetUnknownNote {
    <#
    .SYNOPSIS
        MISSING-READ-2: the PRECHECK note for a machine in an availability set
        when Azure did not give the other machines in it. Pure.
    .DESCRIPTION
        A read of the set that failed used to be "no other members", so the
        machine got no note at all. Unknown is not "none": the note says
        Azure did not give them, and only the set's available sizes - when
        Azure gave them - can make it an info line.
    .PARAMETER OfferedSizes
        The set's available sizes, or $null when Azure could not be asked.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowEmptyString()][string]$TargetSize,
        [Parameter()][AllowNull()][string[]]$OfferedSizes
    )

    $unknown = 'This machine is in an availability set, and Azure did not give the other machines in it.'
    $size = if ($TargetSize) { $TargetSize } else { 'the new size' }
    if ($TargetSize -and ($null -ne $OfferedSizes) -and @($OfferedSizes | Where-Object { $_ -ieq $TargetSize }).Count) {
        return [pscustomobject]@{
            Outcome = 'info'
            Detail  = ("$unknown The hardware that hosts the set offers $TargetSize, so the other machines can keep running. " +
                       'Azure can still refuse a start if that hardware has no free capacity.')
        }
    }
    [pscustomobject]@{
        Outcome = 'warn'
        Detail  = ("$unknown If the hardware that hosts the set does not offer $size, " +
                   'Azure can refuse to start this machine until every machine in the set is stopped.')
    }
}
