function Confirm-VmfRunAcknowledgement {
    <#
    .SYNOPSIS
        IAC-2: record that a named person accepted what a migration does to
        infrastructure-as-code definitions.

    .DESCRIPTION
        Migrating a machine changes what a definition in Terraform, Bicep,
        Pulumi, ARM templates or Ansible holds: its size, the disk controller for
        v6 and v7, accelerated networking, and - for a rebuild - the machine
        resource itself; a rollback or a restore gives it new disks. The words a
        person accepts are Get-VmfIacStatement's. Reconciling that is the
        customer's to do, and this records that they were told.

        The product used to try to DETECT which machines were IaC-managed, from a
        handful of tag keys, and stop them. It could not tell one IaC platform
        from another and read a differently-tagged estate as unmanaged - a guess
        wired to a decision. This replaces it.

        The STATEMENT the person saw is stored with the acceptance, so if the
        wording changes later the record still says what THIS person agreed to.

    .PARAMETER Statement
        The exact words shown. Defaults to the engine's own wording so a caller
        cannot accidentally record an acceptance of something softer.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$AcknowledgedBy,
        [Parameter()][string]$Statement,
        [Parameter()][string]$Note
    )

    $ErrorActionPreference = 'Stop'
    if (-not $Statement) { $Statement = Get-VmfIacStatement }
    if (-not $PSCmdlet.ShouldProcess($RunPath, 'record the infrastructure-as-code acknowledgement')) { return }

    $doc = [ordered]@{
        schemaVersion   = 1
        runId           = (Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 4).runId
        topic           = 'infrastructure-as-code'
        acknowledgedBy  = $AcknowledgedBy
        acknowledgedUtc = (Get-Date).ToUniversalTime().ToString('o')
        statement       = $Statement
        note            = $Note
    }
    Write-VmfStoreJson -RunPath $RunPath -RelPath 'acknowledgements/infrastructure-as-code.json' -Document $doc -Depth 6
    # STEP-LOG-4: written after the acknowledgement is saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'acknowledgement' -Outcome ok `
        -Detail "infrastructure-as-code drift acknowledged by $AcknowledgedBy"
    # APPROVE-GROUP-1: the list on the Migrations page says what the next wave
    # waits for. Never throws, and does nothing for a run with no plan yet.
    Update-VmfRunSummary -RunPath $RunPath -Reason 'acknowledged' | Out-Null
    [pscustomobject]$doc
}
