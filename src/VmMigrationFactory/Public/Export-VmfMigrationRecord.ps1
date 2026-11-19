function Export-VmfMigrationRecord {
    <#
    .SYNOPSIS
        ATTEST-1: the full record of one migration, built now from the store,
        kept for another 90 days in vmf-records/, and returned.
    .DESCRIPTION
        For the Administrator role - engineering and change management - to
        keep as the record of the change. Every decision a named person made;
        for every machine its configuration before and after, every step with
        its time and result, every guest script with its hash, its safety
        copies and any restore; and the whole activity log. It asks Azure for
        nothing. See schemas/migration-record.schema.json.

        RECORD-DELETE-1: refused with a 409 when a delete of the migration has
        started to remove it - its run.json is gone, or the kept record is the
        one the delete kept. That record is the one to read.
    .EXAMPLE
        Export-VmfMigrationRecord -RunPath $run -GeneratedBy 'admin@contoso.com' | ConvertTo-Json -Depth 24
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][string]$GeneratedBy
    )
    $who = if ($GeneratedBy) { $GeneratedBy } else { try { (Get-VmfSignedInIdentity).Identity } catch { 'unknown' } }
    New-VmfMigrationRecord -RunPath $RunPath -Reason 'downloaded' -GeneratedBy $who -RefuseWhileDeleting
}
