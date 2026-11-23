# STORE-RESERVED-NAMES-1. The store holds folders beside the runs that are
# not runs, and the product keeps records in them that a delete must never
# take: `vmf-records` (the kept migration records, ATTEST-1), `vmf-claims`
# (the machine claims of RUN-CLAIM-1 and deletions.jsonl, the log of who
# deleted which migration) and `logs` (an event log the product itself can
# leave beside the runs - see tests/fixtures/not-a-run-folders.json).
#
# Every walk of the store already knew those names. Nothing that CREATED or
# DELETED a prefix asked them, so a project or a run could be NAMED after one:
# a project called vmf-records was created as vmf-records/project.json, and
# its delete then removed every kept record; a run started as vmf-records, or
# under the id of a project, was deleted with everything under it.
#
# This file is the ONE list, and the checks that refuse a name or an address
# before anything is written or deleted. The refusals live in the ENGINE
# (New-VmfProject, Remove-VmfProject, Initialize-VmfRun, Remove-VmfRun,
# Remove-VmfStorePrefix) so the service cannot forget them; the service asks
# the same functions earlier, before it starts anything.

function Get-VmfNotARunFolders {
    <#
    .SYNOPSIS
        The names of the store folders that are not runs. The one list.
    .DESCRIPTION
        The service (Test-VmfFacadeRunFolder), the engine's walks of the store
        and every refusal below read this. The browser cannot read the engine,
        so `runFolderIsRun` in help.js holds its own copy, and
        tests/fixtures/not-a-run-folders.json is the fixture both copies are
        held to (StoreReservedNames.Tests.ps1, run-folders.test.js).
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    @('vmf-claims', 'logs', 'vmf-records')
}

function Test-VmfReservedStoreName {
    <#
    .SYNOPSIS
        Is this one path segment the name of a folder the product keeps?
    .DESCRIPTION
        Matched WHOLE (`logs-of-war` is a name a person may use) and without
        regard to letter case: a refusal costs nothing, and a name that differs
        from a kept folder only in case is too close to be worth the doubt.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    $Name -in @(Get-VmfNotARunFolders)
}

function Assert-VmfStoreNameAllowed {
    <#
    .SYNOPSIS
        Throws when a project id or a run id is the name of a folder the
        product keeps.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Name)
    if (Test-VmfReservedStoreName -Name $Name) {
        throw "400: The product keeps its own records in the folder '$Name'. Use a different name."
    }
}

function Get-VmfStoreAddressNames {
    <#
    .SYNOPSIS
        The path segments of a store address that a person named - the ones to
        hold against the list.
    .DESCRIPTION
        On blob storage, every segment after the container: the project and the
        run (`azblob://acct/cont/<project>/<run>`). On the file store there is
        no container, so the root is not known from the path: only the last
        segment is a name a person gave. The service and the engine both run on
        blob storage; the file store is for tests and development.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$RunPath)
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'azblob') { return @($ctx.Prefix -split '/' | Where-Object { $_ }) }
    @(($RunPath.TrimEnd([char]0x2F, [char]0x5C) -split '[/\\]')[-1])
}

function Get-VmfStoreLeaf {
    # The last segment of a store address, for the words of a refusal.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RunPath)
    ($RunPath.TrimEnd([char]0x2F, [char]0x5C) -split '[/\\]')[-1]
}

function Assert-VmfRunNames {
    <#
    .SYNOPSIS
        Throws when any name in a run's address is a folder the product keeps.
        Pure: no store call.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    foreach ($n in @(Get-VmfStoreAddressNames -RunPath $RunPath)) { Assert-VmfStoreNameAllowed -Name $n }
}

function Assert-VmfNotProject {
    <#
    .SYNOPSIS
        Throws when the address of a run is a PROJECT - its prefix holds
        project.json.
    .DESCRIPTION
        A run id with no project that is the id of a project addresses the
        project's root: a start there writes run.json beside project.json, and
        a delete there takes every assessment and migration in the project.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    if (Test-VmfStoreItem -RunPath $RunPath -RelPath 'project.json') {
        $id = Get-VmfStoreLeaf -RunPath $RunPath
        throw "400: '$id' is a project, not an assessment or a migration. Select an assessment or a migration in the project."
    }
}

function Assert-VmfParentNotRun {
    <#
    .SYNOPSIS
        Throws when the folder a new run goes in is itself a run.
    .DESCRIPTION
        The project of a run travels beside the run id, and the service checks
        its shape only. A project id that is the id of a run would put the new
        run INSIDE that run, and a delete of the outer run would take it too.
        A loose run's parent is the container, so it is not asked. On blob
        storage the address says whether there is a project (two segments
        after the container). On the file store the root is not known from
        the path - tests keep a run at the root of a store folder - so the
        parent is asked only when the caller says the run is in a project
        (-HasProject; the service does).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter()][switch]$HasProject)
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'azblob' -and @($ctx.Prefix -split '/' | Where-Object { $_ }).Count -lt 2) { return }
    if ($ctx.Backend -eq 'file' -and -not $HasProject) { return }
    $parent = Split-VmfStorePath -Path $RunPath
    if (-not $parent -or $parent -eq $RunPath) { return }
    if (Test-VmfStoreItem -RunPath $parent -RelPath 'run.json') {
        $id = Get-VmfStoreLeaf -RunPath $parent
        throw "400: '$id' is an assessment or a migration, not a project. Use the id of a project, or start the run with no project."
    }
}

function Assert-VmfRunAddress {
    <#
    .SYNOPSIS
        Throws when a NEW run may not be made at this address: a name the
        product keeps, the root of a project, or a folder inside another run.
    .DESCRIPTION
        Asked by Initialize-VmfRun before it writes run.json, and by the
        service before it starts the engine.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter()][switch]$HasProject)
    Assert-VmfRunNames -RunPath $RunPath
    Assert-VmfNotProject -RunPath $RunPath
    Assert-VmfParentNotRun -RunPath $RunPath -HasProject:$HasProject
}

function Assert-VmfRunPrefixDeletable {
    <#
    .SYNOPSIS
        Throws when a delete of this run's prefix would take more than the one
        run: a name the product keeps, a project, or other runs inside it.
    .DESCRIPTION
        Asked by Remove-VmfRun before it writes the migration record, releases
        a machine or deletes a safety copy, and by the service before it writes
        "discarded by" into the run's log. Remove-VmfStorePrefix asks the same
        of every document again, immediately before it deletes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    Assert-VmfRunNames -RunPath $RunPath
    Assert-VmfNotProject -RunPath $RunPath
    $children = @(Get-VmfStorePrefixes -StorePath $RunPath)
    if (-not $children.Count) { return }
    $inside = @(@(@(Get-VmfStoreFoldersHolding -StorePath $RunPath -Folder $children -Name 'run.json') +
                  @(Get-VmfStoreFoldersHolding -StorePath $RunPath -Folder $children -Name 'project.json')) |
        Select-Object -Unique)
    if ($inside.Count) {
        $id = Get-VmfStoreLeaf -RunPath $RunPath
        throw ("400: The folder '$id' holds other assessments or migrations: $(($inside | Select-Object -First 5) -join ', '). " +
               'The product deletes one assessment or migration at a time, so it did not delete this folder.')
    }
}

function Test-VmfProjectLogName {
    <#
    .SYNOPSIS
        PROJECT-LOGS-DELETE-1: is this path, relative to a project, a part of
        the project's own event log? Pure.
    .DESCRIPTION
        `logs/events.jsonl` and the parts it rolls into (`logs/events-2.jsonl`
        and on, EVENTLOG-1): one file straight inside `logs`, matched with
        letter case, and named `*.jsonl`. Nothing else the product writes goes
        in a project's `logs`.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Name)
    [string]$Name -cmatch '^logs/[^/]+\.jsonl$'
}

function Get-VmfPrefixDeleteRefusal {
    <#
    .SYNOPSIS
        Pure: why a bulk delete of these documents would take more than it
        should, or $null. -Names are paths relative to the prefix.
    .DESCRIPTION
        A run (`-Kind run`) holds no project.json and no run.json but its own:
        another one means the prefix is a project or holds other runs. A
        project (`-Kind project`) holds project.json and its own event log,
        and nothing else - the rule Remove-VmfProject states, held for every
        document, not only for the sub-folders.

        PROJECT-LOGS-DELETE-1: the event log is part of the project. An event
        recorded against the project's path, where no run is, leaves
        logs/events.jsonl there (PROJECT-3), and nothing reads it back: every
        reader of an event log asks for a run's log. So a project delete takes
        it - but only an event log part: one file straight inside `logs`
        (that exact case), named `*.jsonl`. A run.json or a project.json in
        `logs`, a sub-folder of it, or any other folder still refuses.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('run', 'project')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names
    )
    if ($Kind -eq 'project') {
        $other = @($Names | Where-Object { $_ -cne 'project.json' -and -not (Test-VmfProjectLogName -Name $_) })
        if (-not $other.Count) { return $null }
        $more = if ($other.Count -gt 5) { " and $($other.Count - 5) more" } else { '' }
        return ("400: Project '$Id' holds documents other than its project document and its event log: " +
                "$(($other | Select-Object -First 5) -join ', ')$more. " +
                'The product deletes only an empty project, so it did not delete this project.')
    }
    $wider = @($Names | Where-Object {
            $leaf = ($_ -split '/')[-1]
            $leaf -ceq 'project.json' -or ($leaf -ceq 'run.json' -and $_ -cne 'run.json')
        })
    if (-not $wider.Count) { return $null }
    "400: The folder '$Id' holds a project or other assessments or migrations: $(($wider | Select-Object -First 5) -join ', '). " +
        'The product deletes one assessment or migration at a time, so it did not delete this folder.'
}
