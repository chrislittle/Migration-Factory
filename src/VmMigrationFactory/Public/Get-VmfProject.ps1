function Get-VmfProject {
    <#
    .SYNOPSIS
        PROJECT-1: read one project, or list the projects in a store.
    .DESCRIPTION
        Listing is derived from what is actually in the store - a prefix holding
        a `project.json` IS a project - rather than from an index that can drift
        from it.

        PERF-PROJECTS-LIST-1: the list reads project.json only in the folders
        that hold one (Get-VmfStoreFoldersHolding), and reads those together
        (Read-VmfStoreTextMany), at most 8 in flight on blob storage. It read
        every top-level folder, one after another, and the first step of
        Assess and migrate waited for all of them. A listing or a read the
        store refuses throws; it never drops a project from the list.
    .PARAMETER StorePath
        The container root to list, or the project's own path to read one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][string]$ProjectId
    )

    $root = $StorePath.TrimEnd('/', '\')
    if ($ProjectId) {
        $path = "$root/$ProjectId"
        $doc = Read-VmfStoreJson -RunPath $path -RelPath 'project.json' -Depth 6
        if (-not $doc) { return @() }
        return , ([pscustomobject]@{
            ProjectId = [string]$doc.projectId; Name = [string]$doc.name
            CreatedUtc = [string]$doc.createdUtc; CreatedBy = [string]$doc.createdBy
            Scope = $doc.scope; Note = [string]$doc.note; ProjectPath = $path
        })
    }

    $holding = @(Get-VmfStoreFoldersHolding -StorePath $root -Folder @(Get-VmfStorePrefixes -StorePath $StorePath) -Name 'project.json')
    $paths = @($holding | ForEach-Object { "$root/$_" })
    $texts = Read-VmfStoreTextMany -Items @($paths | ForEach-Object { [pscustomobject]@{ RunPath = $_; RelPath = 'project.json' } })
    @(for ($i = 0; $i -lt $paths.Count; $i++) {
        # A document that went between the listing and the read is not a
        # project, as it was not when the reads went one by one.
        if ($null -eq $texts[$i]) { continue }
        $doc = $texts[$i] | ConvertFrom-Json -Depth 6
        if ($doc) {
            [pscustomobject]@{
                ProjectId = [string]$doc.projectId; Name = [string]$doc.name
                CreatedUtc = [string]$doc.createdUtc; CreatedBy = [string]$doc.createdBy
                Scope = $doc.scope; Note = [string]$doc.note; ProjectPath = $paths[$i]
            }
        }
    })
}
