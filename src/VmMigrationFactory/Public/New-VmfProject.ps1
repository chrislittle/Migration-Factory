function New-VmfProject {
    <#
    .SYNOPSIS
        PROJECT-1: create the container that holds an assessment and the
        migrations planned from it.
    .DESCRIPTION
        A project is the larger container that holds an assessment and the
        migrations in it, now that assessment and migration are split.

        The split made it necessary. Before this, an assessment and
        the migrations planned from it were one piece of work with nothing
        saying so except a `fromAssessment` field pointing backwards. There was
        no name for the engagement and nowhere to see "this estate, assessed
        three times over two months, with two migrations run from it".

        A project is a PREFIX in the store, and its runs live under it:

            <project>/project.json
            <project>/<assessmentId>/assessment.json
            <project>/<migrationId>/plan.json

        That is what makes run names unique WITHIN a project rather than
        globally - so a second scan of the same estate can be called "September"
        instead of having to invent something.

        It also carries the SCOPE once, so a re-scan is a re-scan rather than a
        fresh decision about what to look at.

        THE NAME IS STORED HERE AND NOWHERE ELSE. Copying it onto every member
        run would be a name that can disagree with itself.
    .PARAMETER StorePath
        The container root - `azblob://<account>/<container>` or a local folder.
        The project becomes a prefix beneath it.
    .PARAMETER ProjectId
        The prefix. Lower-case and hyphenated because it is a path segment.
    .PARAMETER Name
        What a person calls it. This is the display string.
    .EXAMPLE
        New-VmfProject -StorePath azblob://vmfstate/vmf-runs -ProjectId contoso-exit -Name 'Contoso datacentre exit'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)]
        # CASE-SENSITIVE on purpose. ValidatePattern ignores case by DEFAULT, so
        # this accepted 'UPPER' - and a blob prefix IS case-sensitive, so the id
        # written into the path would then not be the id the contract describes.
        # Caught by its own test.
        [ValidatePattern('^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$', Options = 'None')]
        [string]$ProjectId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()][AllowNull()]$Scope,
        [Parameter()][string]$Note,
        # The facade creates on behalf of the validated browser user; its own
        # identity is a managed identity and stamping that would be a lie.
        [Parameter()][hashtable]$OnBehalfOf
    )

    $projectPath = "$($StorePath.TrimEnd('/', '\'))/$ProjectId"

    # A project that already exists is NOT recreated. Overwriting its document
    # would rename somebody's engagement and rewrite who created it, while its
    # runs carried on underneath - the same reasoning that refuses to overwrite
    # an assessment.
    if (Test-VmfStoreItem -RunPath $projectPath -RelPath 'project.json') {
        $existing = Read-VmfStoreJson -RunPath $projectPath -RelPath 'project.json' -Depth 6
        throw ("A project called '$ProjectId' already exists here" +
               "$(if ($existing.name) { " ('$($existing.name)')" }). Use it, or pick another id.")
    }

    if (-not $PSCmdlet.ShouldProcess($projectPath, 'create a project')) { return }

    $who = if ($OnBehalfOf) { $OnBehalfOf } else { Get-VmfSignedInIdentity }
    $doc = [ordered]@{
        schemaVersion = 1
        projectId     = $ProjectId
        name          = $Name
        createdUtc    = (Get-Date).ToUniversalTime().ToString('o')
        createdBy     = $who.Identity
    }
    if ($Scope) {
        $doc.scope = [ordered]@{
            # SCAN-SCOPE-NULL-1: a request with no list gives null, and @($null)
            # is a list with one null in it, which the schema refuses.
            subscriptions   = @(@($Scope.subscriptions   ?? $Scope.Subscriptions) | Where-Object { $_ })
            managementGroup = [string]($Scope.managementGroup ?? $Scope.ManagementGroup)
            resourceGroups  = @(@($Scope.resourceGroups  ?? $Scope.ResourceGroups) | Where-Object { $_ })
        }
        if (-not $doc.scope.managementGroup) { $doc.scope.managementGroup = $null }
    }
    else { $doc.scope = $null }
    if ($Note) { $doc.note = $Note }

    Write-VmfStoreJson -RunPath $projectPath -RelPath 'project.json' -Document $doc -Depth 6

    [pscustomobject]@{
        ProjectId   = $ProjectId
        Name        = $Name
        ProjectPath = $projectPath
        CreatedBy   = $who.Identity
    }
}
