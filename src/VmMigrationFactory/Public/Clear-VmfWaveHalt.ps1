function Clear-VmfWaveHalt {
    <#
    .SYNOPSIS
        Clear a wave halt (breaker trip or operator halt) so the next
        Start-VmfWave invocation grants leases again. An audited operator
        action: the halt CAUSE should be understood and addressed first -
        clearing a halt does not fix whatever tripped it.
    .OUTPUTS
        WasHalted ($true when a halt was actually cleared) + the recorded
        halt reason, for the operator's log.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Note,
        [Parameter()][string]$ClearedBy = [Environment]::UserName
    )

    $halt = Read-VmfStoreJson -RunPath $RunPath -RelPath 'halt.flag' -Depth 4
    if (-not $halt) {
        return [pscustomobject]@{ WasHalted = $false; HaltReason = $null; ClearedBy = $ClearedBy }
    }

    Remove-VmfStoreItem -RunPath $RunPath -RelPath 'halt.flag'
    # STEP-LOG-4: written after the halt is removed, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'wave' -Outcome warn `
        -Detail "HALT CLEARED by ${ClearedBy}: $Note (halt was: $($halt.reason), since $($halt.haltedUtc))"
    # APPROVE-GROUP-1: the list shows a paused migration. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -Reason 'resumed' | Out-Null
    # SCHEDULE-PASS-DUE-1: after Resume the five-minute pass starts again what
    # the brake held, so it checks this run. Never throws.
    Add-VmfRunScheduleDue -RunPath $RunPath -Reason 'resume' | Out-Null

    [pscustomobject]@{
        WasHalted  = $true
        HaltReason = [string]$halt.reason
        HaltedUtc  = [string]$halt.haltedUtc
        ClearedBy  = $ClearedBy
        Note       = $Note
    }
}
