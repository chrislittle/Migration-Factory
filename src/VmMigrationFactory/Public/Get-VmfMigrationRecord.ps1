function Get-VmfMigrationRecord {
    <#
    .SYNOPSIS
        ATTEST-1: the migration records kept in the store - including those of
        migrations that have since been deleted - or one of them by name.
    .DESCRIPTION
        Without -Name: one line per record - its name, run, project, when and
        why it was written, and until when it is kept. With -Name: the record.
        A record is kept for 90 days after it was last written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][string]$Name
    )
    if (-not $Name) { return @(Get-VmfKeptMigrationRecords -StorePath $StorePath) }
    # A name is a file name in one folder, never a path.
    if ($Name -notmatch '^[A-Za-z0-9\-]+\.json$') { throw "400: '$Name' is not the name of a migration record." }
    $r = Read-VmfStoreJson -RunPath (Get-VmfRecordScope -StorePath $StorePath) -RelPath $Name -Depth 24
    if (-not $r) { throw "404: there is no migration record called '$Name'. Records are kept for 90 days." }
    $r
}
