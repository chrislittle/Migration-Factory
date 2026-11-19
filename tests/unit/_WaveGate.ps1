# RETRY-GATE-1: a retry is refused while the machine's wave would fail the
# engine's start gates (Get-VmfWaveStartGate). A test that retries a machine
# for some OTHER reason has to open those gates first, the way a person does:
# acknowledge the run, accept each wave's settings, sign off the plan.
#
# The plan sign-off, as "Sign off all" does it: since WAVE-APPROVE-1 it writes
# one approval per wave, each signing its own wave. Since the rule of
# 2026-10-10 only an approver accepting the decision a machine waits for
# carries its wave's approval and this v3 sign-off past the decision's write;
# any other decision saves the change and asks again for the wave's approval.

function Open-VmfTestWaveGate {
    <#
    .SYNOPSIS
        Pass every start gate for every wave of the plan at PlanPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        # Only these waves, when a test needs another wave left closed.
        [Parameter()][string[]]$Wave
    )
    $plan = Get-Content $PlanPath -Raw | ConvertFrom-Json -Depth 24
    $waves = if ($Wave) { $Wave } else { @($plan.entries | ForEach-Object { [string]$_.wave } | Where-Object { $_ } | Sort-Object -Unique) }
    Confirm-VmfRunAcknowledgement -RunPath $RunPath -AcknowledgedBy 'operator@example.com' | Out-Null
    # REBUILD-REMOVE-ACCEPT-1: no box for a rebuild or an identity loss any
    # more - a plan that rebuilds a machine is refused, so a test that opens
    # the gates plans its machines in place.
    foreach ($w in $waves) {
        Confirm-VmfWaveOptions -RunPath $RunPath -PlanPath $PlanPath -Wave $w -AcceptedBy 'operator@example.com' -Note 'test' -Confirm:$false | Out-Null
    }
    Approve-VmfPlan -RunPath $RunPath -PlanPath $PlanPath -Note 'test' `
        -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
}
