# DECIDE-1: which plan lever carries a stop's DECISION, and who may pull it.
#
# In Public/ because the FACADE calls it, and the module exports only what is
# in this folder. It needs no reachability exemption: the facade IS the app's
# path, and the decision it gates is the control on the parked machine's
# panel, which posts to POST /runs/{runId}/vms/resolve.
#
# It sits beside Get-VmfStopReasons (Private/engine/StopReasons.ps1), which
# reads and caches the table this reads from.

function Get-VmfDecisionLevers {
    <#
    .SYNOPSIS
        DECIDE-1: the plan levers that carry a stop's DECISION, and whether
        accepting one needs the approver role.
    .DESCRIPTION
        A stop can carry a CHOICE: a known consequence a person may accept for
        ONE machine, written onto that machine's plan entry as a policy lever.

        DECIDE-2 separated this from the retry kind. All three of the wave's
        "stop and ask" gates carry a choice, and two of them also have a real
        correction - move the files off the temporary disk, patch the kernel -
        so they keep retry `afterFix` and offer BOTH. Only the identity stop
        has no correction at all, which is what `decision` means. Reading the
        retry kind to find the choices therefore missed two of the three.

        The reason, the lever and the role are read from ONE place -
        data/stop-reasons.json - rather than being three facts that have to
        agree. Before this they agreed nowhere: the lever existed in the
        engine, the API accepted it, and the dashboard never sent it, so the
        choice was reachable from a command line and not from the product.

        Returns a hashtable keyed by lever name, each value
        @{ accept = <value>; approver = <bool>; code = <reason code> }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][string]$Path)

    $map = @{}
    foreach ($r in @((Get-VmfStopReasons -Path $Path).reasons)) {
        # The BLOCK is the record of a choice, not the retry kind - see above.
        if (-not $r.PSObject.Properties['decide']) { continue }
        $map[[string]$r.decide.lever] = @{
            accept   = [string]$r.decide.accept
            approver = [bool]$r.decide.approver
            code     = [string]$r.code
        }
    }
    $map
}
