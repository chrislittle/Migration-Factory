# S3-1: Stage 3 facade core. Runs inside the Azure Functions app (and in
# Pester, locally, with the file store - the store API makes both identical).
# AuthN is the platform's (Easy Auth); this module enforces AUTHZ (app roles)
# and shapes contract documents into API responses. It never mutates in S3-1.

$ErrorActionPreference = 'Stop'

# PERF-TELEMETRY-1: each function of the service starts a record of its calls
# to the run store and to ARM before its body, and writes it as one trace line
# in a finally (the record lives in the VmMigrationFactory module, which holds
# the store seam - see Private/azureops/CallTimings.ps1). Neither ever fails
# the function.
function Start-VmfFacadeCallTimings {
    [CmdletBinding()]
    param()
    try { & (Get-Module VmMigrationFactory) { Start-VmfCallTimings } }
    catch { $null = $_ }
}

function Complete-VmfFacadeCallTimings {
    [CmdletBinding()]
    param()
    try { & (Get-Module VmMigrationFactory) { Complete-VmfCallTimings } }
    catch { $null = $_ }
}

function Test-VmfFacadeTokenFromIdentityEndpoint {
    <#
    .SYNOPSIS
        FACADE-SIGNIN-COLD-1: $true in the web service, whose tokens come from
        the managed identity endpoint - the engine module's answer
        (Test-VmfTokenFromIdentityEndpoint), asked from this module.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [bool](& (Get-Module VmMigrationFactory) { Test-VmfTokenFromIdentityEndpoint })
}

function Send-VmfFacadeArmRequest {
    <#
    .SYNOPSIS
        PERF-TELEMETRY-1: the facade's own ARM call, timed. Invoke-AzRestMethod
        is still called from THIS module, so a test's mock of it here still
        applies. PERF-TELEMETRY-HUNG-1: it ends at the module's time limit for
        an ARM request (Receive-VmfArmAnswer) if Azure does not answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][string]$Payload
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 0
    try {
        $send = @{ Method = $Method; Path = $Path }
        if ($PSBoundParameters.ContainsKey('Payload')) { $send.Payload = $Payload }
        $vmf = Get-Module VmMigrationFactory
        # FACADE-SIGNIN-COLD-1: in the web service, a token from the managed
        # identity endpoint and no Az module (AzureOpsToken.ps1).
        if (Test-VmfFacadeTokenFromIdentityEndpoint) {
            $resp = & $vmf { param($a) Invoke-VmfArmHttpRequest @a } $send
        }
        else {
            $asJob = & $vmf { param([string[]]$n) Test-VmfCommandCanRunAsJob -ParameterName $n } @((Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue).Parameters.Keys)
            if ($asJob) { $send.AsJob = $true }
            $answer = Invoke-AzRestMethod @send
            $resp = & $vmf { param($a, $m, $p) Receive-VmfArmAnswer -Answer $a -Method $m -Target $p } $answer $Method $Path
        }
        $status = [int]$resp.StatusCode
        $resp
    }
    finally {
        $ms = $clock.Elapsed.TotalMilliseconds
        try {
            & (Get-Module VmMigrationFactory) { param($m, $p, $s, $d) Add-VmfCallTiming -Kind arm -Method $m -Target $p -Status $s -DurationMs $d } $Method $Path $status $ms
        }
        catch { $null = $_ }
    }
}

function ConvertTo-VmfHashtable {
    <#
    .SYNOPSIS
        BODY-HASH-1: a piece of a request body, as a hashtable, from EITHER
        shape it can arrive in.
    .DESCRIPTION
        AZURE FUNCTIONS HANDS A JSON BODY TO POWERSHELL AS A HASHTABLE. Four
        routes converted it by walking `$obj.PSObject.Properties`, which on a
        Hashtable yields the CONTAINER's own .NET members - Count, SyncRoot,
        IsReadOnly, Keys, Values - and not one of its entries.

        A lab migration stalled on its last machine because of it. A user
        pressed "Accept this and continue" on a machine parked below the MANA
        kernel floor and the service answered:

          '' is not a setting for 'onDriverBelowFloor' - it must be one of:
          stop, proceed.

        The page had sent `proceed`. THE MESSAGE MADE NO SENSE FOR A REASON:
        the converted hashtable holds a literal entry named `Keys`, whose
        value is the original key collection, so the validator's
        `$Override.Keys` returned the REAL key - and looking that key up found
        nothing, which reads as ''. The key survives and the value vanishes.

        It also walked past a guard. Invoke-VmfFacadeResolve refuses to let
        anybody but an approver remove a wave's sign-off, and asks
        `ContainsKey('requireApproval')`. On the mangled hashtable that is
        false, so the check never ran. The request then failed anyway on the
        empty value - closed by ACCIDENT, not by design.

        A dictionary is read as a dictionary. Anything else keeps the property
        walk, which is right for the PSCustomObject that ConvertFrom-Json
        produces - the shape a test or any other caller parses for itself.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }
    $h = @{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { $h[[string]$key] = $InputObject[$key] }
        return $h
    }
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h
}

function ConvertFrom-VmfClientPrincipal {
    <#
    .SYNOPSIS
        Parse Easy Auth's x-ms-client-principal header (base64 JSON) into
        @{ Identity; Roles[] }. $null for missing/garbage = unauthenticated.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$Header)

    if ([string]::IsNullOrWhiteSpace($Header)) { return $null }
    try {
        $doc = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Header)) | ConvertFrom-Json
    }
    catch { return $null }

    $claims = @($doc.claims)
    $identity = ($claims | Where-Object { $_.typ -in @('preferred_username', 'upn', 'email') } |
        Select-Object -First 1).val
    $roles = @($claims | Where-Object { $_.typ -in @('roles', 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role') } |
        ForEach-Object { $_.val })
    if (-not $identity) { return $null }
    [pscustomobject]@{ Identity = [string]$identity; Roles = $roles }
}

function Assert-VmfFacadeRole {
    <#
    .SYNOPSIS
        Enforce that the caller holds ANY of the required app roles.
        Throws 401-shaped (no principal) or 403-shaped (missing role) errors
        the HTTP wrappers translate into status codes.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string[]]$AnyOf
    )
    if (-not $Principal) { throw '401: sign in required' }
    $held = @($Principal.Roles)
    if (-not ($AnyOf | Where-Object { $_ -in $held })) {
        throw "403: requires one of [$($AnyOf -join ', ')] - '$($Principal.Identity)' holds [$($held -join ', ')]"
    }
}

function Test-VmfFacadeRole {
    <#
    .SYNOPSIS
        The question Assert-VmfFacadeRole answers, as a BOOLEAN - for a caller
        that has to DECIDE something on the answer rather than stop on it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string[]]$AnyOf
    )
    if (-not $Principal) { return $false }
    @(@($Principal.Roles) | Where-Object { $_ -in $AnyOf }).Count -gt 0
}

function Test-VmfFacadeRunFolder {
    <#
    .SYNOPSIS
        PROJECT-3: is this store folder a run, or something that merely sits
        beside the runs?
    .DESCRIPTION
        Two folders are not runs and never will be. `vmf-claims` is the claim
        registry. `logs` is an event log, and the product writes it itself: an
        event recorded against a path that holds no run leaves one beside the
        runs rather than inside one.

        MEASURED on a lab install 2026-09-16. Before PROJECT-2 the
        retention pass could only see the top level, so it took the PROJECT for
        a run, looked for a plan that was never going to be there, and recorded
        the failure - creating `test2/logs`. PROJECT-2 fixed the walk and left
        the debris, which then counted as a fourth run in a project that holds
        three, and which the overview asked for a run record on every load.

        The browser has the twin of this in `runFolderIsRun` (help.js), because
        the service walks the store for the timers and the browser walks it for
        the pages. `tests/fixtures/not-a-run-folders.json` is the one list of
        cases they are both held to.

        The folder NAME is matched whole. `logs-of-war` is a run.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $leaf = ($Path -split '/')[-1]
    $leaf -notin @('vmf-claims', 'logs', 'vmf-records')
}
function Get-VmfFacadeRunIds {
    <#
    .SYNOPSIS
        PROJECT-2: every run in the store, including the ones inside a project.
    .DESCRIPTION
        A listing with a delimiter returns the TOP level only. A run outside a
        project is a top-level prefix and comes back. A run INSIDE one is a
        level down, and what comes back instead is the project folder - which
        then looks like a run with no run.json in it.

        Three places enumerated that way and saw no run inside a project:

          /api/runs            reported project folders as runs
          RetentionRunner      never reaped a safety copy inside a project
          ScheduleRunner       A SCHEDULED WAVE INSIDE A PROJECT NEVER STARTED

        The last one is the reason this is a defect and not untidiness: a
        person schedules a wave for the small hours and nothing happens, with
        no error anywhere, because the pass never looked in the folder it is
        in.

        The dashboard has answered this correctly since ASSESS-LIST-1, in
        listRunsAcrossProjects, and its rule is the one used here: a top-level
        prefix is a PROJECT if project.json sits inside it, and a RUN if not.
        Derived from the store, never from an index - an index of projects is a
        second source of truth that can disagree with the projects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StorePath)
    if ($StorePath -notmatch '^azblob://') {
        $out = foreach ($dir in Get-ChildItem $StorePath -Directory -ErrorAction SilentlyContinue) {
            if (-not (Test-VmfFacadeRunFolder -Path $dir.Name)) { continue }
            if (Test-Path (Join-Path $dir.FullName 'project.json')) {
                foreach ($child in Get-ChildItem $dir.FullName -Directory -ErrorAction SilentlyContinue) {
                    if (Test-VmfFacadeRunFolder -Path $child.Name) { "$($dir.Name)/$($child.Name)" }
                }
            }
            else { $dir.Name }
        }
        return @($out | Sort-Object)
    }
    # The top of the store, every page of it.
    $top = Get-VmfFacadeStoreListing -Prefix '' -Delimiter '/'
    if ($top.truncated) { throw 'the run store listing stopped early: the top of the store has more pages than the service follows' }
    # PROJECT-3: the claim registry and an event log are not runs, at the top
    # or beside a project's runs.
    $folders = @(@($top.prefixes) | Where-Object { Test-VmfFacadeRunFolder -Path $_ })
    if ($folders.Count -eq 0) { return }
    # PERF-RUN-IDS-1: the first page of each folder, all sent together, at
    # most 8 in flight - one listing after another made each timer pass wait
    # for 1 + P listings in a row before it read a run.
    $uris = @($folders | ForEach-Object { Get-VmfFacadeListUri -Prefix "$_/" -Delimiter '/' })
    $answers = & (Get-Module VmMigrationFactory) { param($u) Invoke-VmfStorageGetMany -Uri $u } $uris
    $answers = @($answers)
    $out = for ($k = 0; $k -lt $folders.Count; $k++) {
        $name = $folders[$k]
        $code = [int]$answers[$k].StatusCode
        # A refused listing is not "no project.json here": that would name a
        # project as a run.
        if ($code -ne 200) { throw "the run store refused the listing of '$name/': HTTP $code" }
        $page = ConvertFrom-VmfFacadeBlobListing -Xml ([string]$answers[$k].Content)
        $blobs = @($page.names)
        $children = @($page.prefixes)
        if ($page.nextMarker) {
            # The paging rule of Get-VmfStorePrefixes: go on from the marker.
            # A project's project.json can be on any page, so every page is
            # read before the folder is called a project or a run.
            $rest = Get-VmfFacadeStoreListing -Prefix "$name/" -Delimiter '/' -Marker $page.nextMarker
            if ($rest.truncated) { throw "the run store listing stopped early: '$name/' has more pages than the service follows" }
            $blobs += @($rest.names)
            $children += @($rest.prefixes)
        }
        if ($blobs -contains "$name/project.json") {
            foreach ($child in $children) { if (Test-VmfFacadeRunFolder -Path $child) { $child } }
        }
        else { $name }
    }
    @($out | Sort-Object)
}

function Get-VmfFacadeRunStorePath {
    <#
    .SYNOPSIS
        PROJECT-2: the store path for the run this request is about, project
        included.
    .DESCRIPTION
        A run inside a project lives at `project/run`. The route can only carry
        `runs/{runId}` - one segment - so the project travels beside it, in the
        body of a POST or the query of a GET.

        SEVENTEEN endpoints take a run id. FOUR of them composed the project
        back on, by hand, each in its own expression. THIRTEEN did not, and for
        a run inside a project they looked where it is not:

            No plan found at 'azblob://.../vmf-runs/<run>/plan.json'

        MEASURED on a lab install 2026-09-15, where every run is inside a
        project: saving a plan failed, capacity said nothing had been worked
        out, and accepting the settings answered "the plan version being
        accepted is required" - because the step that reads the plan to find
        its version had found no plan.

        So this is the one place that knows. A right answer written out four
        times is a wrong answer thirteen times, and
        tests/unit/RunStorePath.Tests.ps1 refuses an endpoint that composes its
        own.

        The project is checked exactly as the run id is: Get-VmfFacadeStorePath
        guards the whole key (RUNID-1), and a project that tries to climb out
        of the container is refused there rather than here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    $runId = [string]$Request.Params.runId
    # A POST carries it in the body, a GET in the query. Neither is required:
    # a run outside a project has no project, which is legal and common.
    $project = ''
    if ($Request.Body -and $Request.Body.project) { $project = [string]$Request.Body.project }
    elseif ($Request.Query -and $Request.Query.project) { $project = [string]$Request.Query.project }
    Get-VmfFacadeStorePath -RunId $(if ($project) { "$project/$runId" } else { $runId })
}

function Get-VmfFacadeStorePath {
    <#
    .SYNOPSIS
        The run-store path the facade serves, from app settings:
        azblob://VMF_STORE_ACCOUNT/VMF_STORE_CONTAINER (or a local path in
        VMF_STORE_PATH for tests/dev).
    .DESCRIPTION
        RUNID-1: $RunId COMES FROM THE BROWSER. It is the {runId} segment of
        every runs/... route, and sixteen endpoints hand it straight here,
        where it becomes part of a blob key.

        It was the only browser-supplied value on this boundary with no check
        at all - and in the very same expression, in PostDiscardRun and
        PostApproveAssessment, the PROJECT half is refused unless it matches a
        strict pattern. Two halves of one path, one checked and one not.

        Resolve-VmfFacadeStoreKey is the guard the store endpoints already use
        for exactly this, and its own description says why: a path supplied by
        the browser must be refused before it is used as a blob key. It allows
        a slash, which this needs - a run inside a project is `project/run`.

        NOT because an attack was found. A slash does not survive the route at
        all (IIS refuses an encoded one; see PostDiscardRun), so the container
        cannot be escaped and another run cannot be reached. It is because a
        trust boundary whose two halves disagree about the same input is a
        question somebody has to answer again every time they read it, and the
        answer costs one line. Get-VmfStoreBlobUri escapes the result as well,
        so the sink is safe whatever arrives.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$RunId = '')
    # AllowEmpty: no run id is a real request - it names the whole store.
    $RunId = Resolve-VmfFacadeStoreKey -Path $RunId -AllowEmpty
    if ($env:VMF_STORE_PATH) {
        return $(if ($RunId) { Join-Path $env:VMF_STORE_PATH $RunId } else { $env:VMF_STORE_PATH })
    }
    if (-not $env:VMF_STORE_ACCOUNT -or -not $env:VMF_STORE_CONTAINER) {
        throw 'Facade misconfigured: set VMF_STORE_ACCOUNT + VMF_STORE_CONTAINER (or VMF_STORE_PATH).'
    }
    ("azblob://$($env:VMF_STORE_ACCOUNT)/$($env:VMF_STORE_CONTAINER)/$RunId").TrimEnd('/')
}

function Get-VmfFacadePlanPath {
    # The plan document handle inside a run store (file path or azblob URI).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StorePath)
    if ($StorePath -match '^azblob://') { return "$StorePath/plan.json" }
    Join-Path $StorePath 'plan.json'
}

function Resolve-VmfFacadeStoreKey {
    <#
    .SYNOPSIS
        STORE-READ-1: a path supplied BY THE BROWSER, made safe to use as a blob
        key inside the run-store container - or refused.
    .DESCRIPTION
        The store endpoints exist so the dashboard stops reading blob storage
        directly. That moves the choice of WHICH blob from the caller's own
        Azure rights to ours: the facade reads with its managed identity, which
        can see the whole container. Without this guard, anybody holding the
        lowest role could ask for any blob the facade can reach.

        It REFUSES rather than sanitises. A path that had to be corrected before
        it was safe is not a path this API should answer - quietly repairing it
        hides the attempt and invites the next one.

        No regular expressions here on purpose: every check is a plain string
        test, so nothing depends on how a backslash survives an editor, a shell
        or a here-string. This repository has lost a regex to that three times.
    .OUTPUTS
        The key, unchanged, when it is safe. Otherwise it throws a message
        beginning 400, which the endpoints map to Bad Request.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Path,
        [Parameter()][switch]$AllowEmpty
    )
    $value = [string]$Path
    if ([string]::IsNullOrEmpty($value)) {
        # An empty PREFIX lists the top of the container, which is a real
        # request. An empty BLOB path is not.
        if ($AllowEmpty) { return '' }
        throw '400 a path is required'
    }
    if ($value.Length -gt 1024) { throw '400 the path is too long' }
    if ($value.StartsWith('/')) { throw '400 the path must be relative' }
    if ($value.Contains('\')) { throw '400 the path must use forward slashes' }
    if ($value.Contains('://')) { throw '400 the path must not contain a scheme' }
    if ($value.Length -ge 2 -and $value[1] -eq ':') { throw '400 the path must not name a drive' }
    foreach ($ch in $value.ToCharArray()) {
        if ([int]$ch -lt 32 -or [int]$ch -eq 127) { throw '400 the path contains a control character' }
    }
    # Traversal is checked on SEGMENTS, so a blob honestly named "..notes" or
    # "run..1" is still allowed. Only a segment that IS ".." goes up a level.
    foreach ($segment in ($value -split '/')) {
        if ($segment -eq '..') { throw '400 the path must not go up a level' }
    }
    return $value
}

function ConvertFrom-VmfFacadeBlobListing {
    <#
    .SYNOPSIS
        STORE-READ-1: an Azure Blob list response, as the shape the dashboard
        already expects - names, prefixes, and the marker to continue from.
    .DESCRIPTION
        The browser used to parse this XML itself. The shape returned here is
        deliberately the same one its helper produced, so the pages above it do
        not change: names from Blob, prefixes from BlobPrefix with the trailing
        slash removed.

        NextMarker is carried out because the browser NEVER PAGED. A listing
        stops at 5,000 blobs, so a large enough run was silently short by
        however much it held - no error, just missing rows. The endpoint pages;
        this reports where to continue.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowEmptyString()][string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) {
        return [pscustomobject]@{ names = @(); prefixes = @(); nextMarker = '' }
    }
    # STORE-READ-4: START AT THE FIRST '<'. AZURE SENDS A BYTE ORDER MARK, AND
    # `[xml]$string` CANNOT PARSE A STRING THAT BEGINS WITH ONE.
    #
    # Measured on a work subscription, 2026-09-14, on the FIRST page load of a
    # fresh install - the whole dashboard showed this instead of the Overview:
    #
    #   Cannot convert value "<?xml version="1.0" ...?><EnumerationResults ...>"
    #   to type "System.Xml.XmlDocument". Error: "The specified node cannot be
    #   inserted as the valid child of this node, because the specified node is
    #   the wrong type."
    #
    # The message looks like the XML starts correctly because the mark is
    # invisible. It is U+FEFF, sitting before the declaration, and .NET reads a
    # declaration that is not at position 0 as a node in the wrong place.
    #
    # THE ENGINE ALREADY KNEW. `Get-VmfStoreNames` in StoreApi.ps1 carries the
    # comment "Response is XML; the BOM-safe way is regex over <Name> nodes",
    # and RetentionRunner and ScheduleRunner (and GetRuns, until PAGE-LOAD-1) use regex for the same
    # reason. STORE-READ-1 moved this parse out of the browser, where a
    # DOMParser had tolerated the mark, and into PowerShell, which does not -
    # and the tests fed it hand-written XML with no mark, so every one passed.
    #
    # Trimming the character would do it. Starting at the first '<' also
    # survives leading whitespace and a mark that arrived mis-decoded, and says
    # what it means: XML begins at a tag.
    $start = $Xml.IndexOf('<')
    if ($start -lt 0) { throw "The storage listing is not XML: '$Xml'" }
    $doc = [xml]$Xml.Substring($start)
    $names = @($doc.SelectNodes('//Blobs/Blob/Name') | ForEach-Object { [string]$_.InnerText })
    $prefixes = @($doc.SelectNodes('//Blobs/BlobPrefix/Name') | ForEach-Object { ([string]$_.InnerText).TrimEnd('/') })
    $marker = [string]($doc.SelectSingleNode('//EnumerationResults/NextMarker').InnerText)
    [pscustomobject]@{ names = $names; prefixes = $prefixes; nextMarker = $marker }
}

function Get-VmfFacadeContainerUri {
    <#
    .SYNOPSIS
        PAGE-LOAD-1: the run store's container on blob storage, from the app
        settings. One place, so a test can point the store reads at a blob
        service on the computer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:VMF_STORE_ACCOUNT -or -not $env:VMF_STORE_CONTAINER) { throw 'Facade misconfigured: set VMF_STORE_ACCOUNT + VMF_STORE_CONTAINER.' }
    "https://$($env:VMF_STORE_ACCOUNT).blob.core.windows.net/$($env:VMF_STORE_CONTAINER)"
}

function Get-VmfFacadeListUri {
    <#
    .SYNOPSIS
        PERF-RUN-IDS-1: the address of one page of a run store listing. One
        place, so a page sent alone (Get-VmfFacadeStoreListing) and the first
        pages sent together (Get-VmfFacadeRunIds) ask the store the same way.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][string]$Prefix = '',
        [Parameter()][AllowEmptyString()][string]$Delimiter = '',
        [Parameter()][AllowEmptyString()][string]$Marker = ''
    )
    $uri = (Get-VmfFacadeContainerUri) + '?restype=container&comp=list'
    $uri += '&prefix=' + [uri]::EscapeDataString($Prefix)
    if ($Delimiter) { $uri += '&delimiter=' + [uri]::EscapeDataString($Delimiter) }
    if ($Marker) { $uri += '&marker=' + [uri]::EscapeDataString($Marker) }
    $uri
}

function Get-VmfFacadeStoreListing {
    <#
    .SYNOPSIS
        STORE-READ-1: a listing of the run store under a prefix, in the shape
        the pages take - names, prefixes with the trailing slash removed, and
        whether the listing stopped early.
    .DESCRIPTION
        GetStoreList (store/list) and GetStoreDocs (store/docs, PAGE-LOAD-1)
        both list through this. It was the body of GetStoreList, moved here
        without a change so the two cannot list two ways.

        With no delimiter the listing is every blob under the prefix. Blob
        storage gives 5,000 names a page; this follows the pages up to 50, and
        a listing that stopped early SAYS so - the browser once never paged at
        all, so a run past 5,000 blobs was quietly short by whatever it held.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowEmptyString()][string]$Prefix = '',
        [Parameter()][AllowEmptyString()][string]$Delimiter = '',
        # PERF-RUN-IDS-1: go on from this marker (a page already read gave it).
        # Blob storage only; the local store has no pages.
        [Parameter()][AllowEmptyString()][string]$Marker = ''
    )
    $names = [System.Collections.Generic.List[string]]::new()
    $prefixes = [System.Collections.Generic.List[string]]::new()
    $truncated = $false

    if ($env:VMF_STORE_PATH) {
        # Local store, for tests and development. Same shape, no network.
        $root = $env:VMF_STORE_PATH
        $start = if ($Prefix) { Join-Path $root ($Prefix -replace '/', [System.IO.Path]::DirectorySeparatorChar) } else { $root }
        $searchRoot = if (Test-Path -LiteralPath $start -PathType Container) { $start } else { Split-Path $start -Parent }
        if ($searchRoot -and (Test-Path -LiteralPath $searchRoot -PathType Container)) {
            $recurse = -not $Delimiter
            foreach ($item in (Get-ChildItem -LiteralPath $searchRoot -Recurse:$recurse -ErrorAction SilentlyContinue)) {
                $rel = $item.FullName.Substring($root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, '/') -replace '\\', '/'
                if ($Prefix -and -not $rel.StartsWith($Prefix)) { continue }
                if ($item.PSIsContainer) { if ($Delimiter) { $prefixes.Add($rel.TrimEnd('/')) } }
                else { $names.Add($rel) }
            }
        }
    }
    else {
        $marker = $Marker
        $pages = 0
        do {
            $uri = Get-VmfFacadeListUri -Prefix $Prefix -Delimiter $Delimiter -Marker $marker
            $response = & (Get-Module VmMigrationFactory) { param($u) Invoke-VmfStorageRequest -Method GET -Uri $u } $uri
            if ([int]$response.StatusCode -ge 400) { throw "the run store refused the listing: HTTP $($response.StatusCode)" }
            $page = ConvertFrom-VmfFacadeBlobListing -Xml $response.Content
            foreach ($n in $page.names) { $names.Add($n) }
            foreach ($folder in $page.prefixes) { $prefixes.Add($folder) }
            $marker = $page.nextMarker
            $pages++
        } while ($marker -and $pages -lt 50)
        $truncated = [bool]$marker
    }
    [pscustomobject]@{ names = @($names); prefixes = @($prefixes); truncated = $truncated }
}

function Get-VmfFacadeStoreDocs {
    <#
    .SYNOPSIS
        PAGE-LOAD-1: the store listed once, down to a depth, with the text of
        every document whose name a page asks for - in ONE call.
    .DESCRIPTION
        MEASURED on the lab install, 2026-11-06: one load of the Overview or
        the Assessments page sent about 200 calls to the service, one for each
        store document (about 140 GetStoreBlob and 30 GetStoreList in 30
        seconds), and the page waited for all of them.

        This gives a page what those calls gave, from one call:
          names    every blob under the prefix with at most -Depth segments
                   after it, in ordinal order;
          folders  every folder under the prefix with at most -Depth segments,
                   from EVERY blob - a folder whose blobs are all deeper than
                   the depth is still named, so a page can list a level from
                   this exactly as store/list would with a delimiter;
          docs     { path, text } for each listed name that a -Read pattern
                   matches. text is the document as the store holds it; it is
                   empty when the document was gone by the time it was read;
                   `error` names a read the store refused, for that document
                   only;
          next     where the next call goes on (-After), when a budget of
                   documents or characters stopped this one; '' at the end.
                   The listing comes with the first page only.

        A listing the store cut short (truncated) reads no document: the page
        cannot tell what the listing is missing, so it asks for each document
        itself (unknown means ask).

        ROLES: exactly the set store/blob and store/list check. Every blob in
        the container is readable through store/blob by the same roles, so
        this returns nothing a caller could not already read - only in one
        call instead of two hundred.

        NO DOCUMENT VERSION. A page that saves a document reads it through
        store/blob, which issues its version in a header beside the text
        (PLANVER-2). This is for pages that only draw.

        A text is never parsed here. A document that is not JSON goes back as
        it is, and the page parses each one by itself, so one bad document
        cannot cost the rest of the answer.
    .PARAMETER Read
        Name patterns, matched against the LAST segments of a path, case
        sensitive: 'run.json' matches every run.json; 'state/*.json' matches a
        document in a folder named state. Letters, digits, '.', '_', '-', '*'
        and '/' only. At most 12.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter()][AllowEmptyString()][string]$Prefix = '',
        [Parameter()][int]$Depth = 3,
        [Parameter()][AllowEmptyCollection()][string[]]$Read = @(),
        [Parameter()][AllowEmptyString()][string]$After = '',
        [Parameter()][int]$MaxDocs = 400,
        [Parameter()][int]$MaxChars = 4000000
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')

    # Everything the caller names is checked before it is used.
    $Prefix = Resolve-VmfFacadeStoreKey -Path $Prefix -AllowEmpty
    if ($Prefix -and -not $Prefix.EndsWith('/')) { throw '400 the prefix must be a folder, ending in /' }
    if ($Depth -lt 1 -or $Depth -gt 6) { throw '400 the depth is 1 to 6' }
    $patterns = @($Read)
    if ($patterns.Count -eq 0) { throw '400 name at least one document to read' }
    if ($patterns.Count -gt 12) { throw '400 name at most 12 documents to read' }
    $allowed = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-*/'
    $split = foreach ($pattern in $patterns) {
        $text = [string]$pattern
        if (-not $text) { throw '400 a document name is empty' }
        foreach ($ch in $text.ToCharArray()) { if ($allowed.IndexOf($ch) -lt 0) { throw "400 a document name may not contain '$ch'" } }
        $segments = $text -split '/'
        foreach ($segment in $segments) {
            if (-not $segment) { throw '400 a document name has an empty folder' }
            if ($segment -eq '..' -or $segment -eq '.') { throw '400 a document name must not go up a level' }
        }
        , @($segments)
    }
    if ($After) { $After = Resolve-VmfFacadeStoreKey -Path $After }

    $listing = Get-VmfFacadeStoreListing -Prefix $Prefix
    $first = -not $After
    $names = [System.Collections.Generic.List[string]]::new()
    $folders = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $wanted = [System.Collections.Generic.List[string]]::new()
    $sorted = [string[]]@($listing.names)
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    foreach ($name in $sorted) {
        if (-not $name.StartsWith($Prefix, [System.StringComparison]::Ordinal)) { continue }
        $parts = $name.Substring($Prefix.Length) -split '/'
        # Every folder of every blob, down to the depth.
        for ($i = 1; $i -lt $parts.Count -and $i -le $Depth; $i++) { $null = $folders.Add($Prefix + ($parts[0..($i - 1)] -join '/')) }
        if ($parts.Count -gt $Depth) { continue }
        $names.Add($name)
        if ($After -and [string]::CompareOrdinal($name, $After) -le 0) { continue }
        foreach ($segments in $split) {
            if ($segments.Count -gt $parts.Count) { continue }
            $tail = $parts[($parts.Count - $segments.Count)..($parts.Count - 1)] -join '/'
            if ($tail -clike ($segments -join '/')) { $wanted.Add($name); break }
        }
    }

    $docs = [System.Collections.Generic.List[object]]::new()
    $next = ''
    if (-not $listing.truncated -and $wanted.Count) {
        $chars = 0
        $at = 0
        $m = Get-Module VmMigrationFactory
        # In batches, so the budget is counted on what was read; a batch is
        # the store's own limit of reads in flight several times over.
        while ($at -lt $wanted.Count) {
            $batch = @($wanted[$at..([Math]::Min($at + 31, $wanted.Count - 1))])
            if ($env:VMF_STORE_PATH) {
                $answers = foreach ($path in $batch) {
                    $file = Join-Path $env:VMF_STORE_PATH ($path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                    # The same text store/blob gives on this backend.
                    $text = if (Test-Path -LiteralPath $file -PathType Leaf) { Get-Content -LiteralPath $file -Raw } else { $null }
                    [pscustomobject]@{ StatusCode = $(if ($null -eq $text) { 404 } else { 200 }); Content = $text }
                }
            }
            else {
                $container = Get-VmfFacadeContainerUri
                # Each SEGMENT is escaped, as store/blob does.
                $uris = @($batch | ForEach-Object { "$container/" + ((($_ -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/') })
                $answers = & $m { param($u) Invoke-VmfStorageGetMany -Uri $u } $uris
            }
            $answers = @($answers)
            $stop = $false
            for ($k = 0; $k -lt $batch.Count; $k++) {
                $code = [int]$answers[$k].StatusCode
                $doc = if ($code -eq 200) { [pscustomobject]@{ path = $batch[$k]; text = [string]$answers[$k].Content } }
                       elseif ($code -eq 404) { [pscustomobject]@{ path = $batch[$k]; text = $null } }
                       else { [pscustomobject]@{ path = $batch[$k]; text = $null; error = "HTTP $code" } }
                $docs.Add($doc)
                $chars += ([string]$doc.text).Length
                $at++
                if ($at -lt $wanted.Count -and ($docs.Count -ge $MaxDocs -or $chars -ge $MaxChars)) { $stop = $true; break }
            }
            if ($stop) { $next = $docs[$docs.Count - 1].path; break }
        }
    }

    [pscustomobject]@{
        names     = $(if ($first) { @($names) } else { @() })
        folders   = $(if ($first) { @($folders) } else { @() })
        truncated = [bool]$listing.truncated
        docs      = @($docs)
        next      = $next
    }
}

function Get-VmfFacadeApprovalRemovals {
    <#
    .SYNOPSIS
        APPR-LEVER-1: which machines would STOP needing an approver's sign-off
        if this change were saved.
    .DESCRIPTION
        The sign-off is the only separation of duties over a wave, and an
        Operator is deliberately refused the approve endpoint. The engine's
        gate reads ONE field to decide whether a wave needs one at all
        (policy.requireApproval, in Test-VmfWaveApproval), so the lever that
        switches that field off IS the approval. It belongs to the same role.

        Every writer of the field asks this question first and refuses a
        caller who does not hold Vmf.Approver or Vmf.Admin. Putting the
        requirement ON is nobody's risk and stays an operator action.

        A machine whose policy says NOTHING about the requirement is read as
        REQUIRING it, exactly as the engine's gate reads it. Reading absence as
        "not required" here would let a plan that lost the key lose the gate
        with it.
    .PARAMETER Requested
        vmId -> the requireApproval value the caller wants written.
    .OUTPUTS
        The vmIds that require sign-off now and would not after the change.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][hashtable]$Requested
    )
    # Only an explicit NO takes a requirement off. Anything else - yes, or a
    # value the engine will refuse as not a yes or no - cannot.
    $off = @($Requested.Keys | Where-Object { $Requested[$_] -is [bool] -and -not $Requested[$_] })
    if ($off.Count -eq 0) { return @() }

    $plan = & (Get-Module VmMigrationFactory) { param($rp) Read-VmfPlanDocument -RunPath $rp -Depth 24 } $StorePath
    $byId = @{}
    foreach ($e in @($plan.entries)) { $byId[[string]$e.vmId] = $e }

    $lowered = foreach ($id in $off) {
        $entry = $byId[[string]$id]
        # A machine this plan does not have is refused BY NAME further in; it
        # is not this function's answer to give.
        if (-not $entry) { continue }
        # SIGNOFF-NULL-1: the engine's one rule, so a stored null or 0 - which
        # the gate holds as required - is not a requirement nobody needs an
        # approver to take off.
        $now = & (Get-Module VmMigrationFactory) { param($e) Test-VmfApprovalRequired -PlanEntry $e } $entry
        if ($now) { [string]$id }
    }
    @($lowered)
}

function Get-VmfFacadeDecisionsTaken {
    <#
    .SYNOPSIS
        DECIDE-2: which machines would have a CHOICE accepted for them if this
        wave change were saved.
    .DESCRIPTION
        The wave editor sets the three "stop and ask" gates for a whole wave at
        once. Moving one to its accepting value accepts a known loss - files on
        the temporary disk given up, accelerated networking given up, a
        system-assigned identity destroyed - for every machine the wave names.
        That is the same act the machine's own panel offers one at a time, and
        since 2026-09-11 it belongs to the approver in both places: every
        accepted loss is the approver's.

        Only a CHANGE counts. A machine already set to the accepting value is
        not being decided for again, so an Operator can still rename a wave or
        move machines around without a signature. The same shape as
        Get-VmfFacadeApprovalRemovals, and for the same reason.

        A machine whose policy says NOTHING about a lever is read as the
        ENGINE's default - `stop` for all three - so a plan that lost the key
        cannot lose the gate with it.
    .PARAMETER Requested
        vmId -> @{ lever = value } the caller wants written.
    .OUTPUTS
        @{ VmId = <id>; Lever = <name>; Accept = <value> } for each change.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][hashtable]$Requested
    )
    if ($Requested.Count -eq 0) { return @() }
    $gated = Get-VmfDecisionLevers
    if ($gated.Count -eq 0) { return @() }

    $plan = & (Get-Module VmMigrationFactory) { param($rp) Read-VmfPlanDocument -RunPath $rp -Depth 24 } $StorePath
    $byId = @{}
    foreach ($e in @($plan.entries)) { $byId[[string]$e.vmId] = $e }

    $taken = foreach ($id in @($Requested.Keys)) {
        $entry = $byId[[string]$id]
        # A machine this plan does not have is refused BY NAME further in.
        if (-not $entry) { continue }
        foreach ($lever in @($Requested[$id].Keys)) {
            if (-not $gated.ContainsKey($lever)) { continue }
            $rule = $gated[$lever]
            if (-not $rule.approver) { continue }
            # DECIDE-ROLE-1: ORDINAL, as Set-VmfWavePlan checks the value. A
            # value this does not count as accepting skips the approver, so the
            # wave save must refuse it - and it does, by the same comparison.
            if (-not [string]::Equals([string]$Requested[$id][$lever], [string]$rule.accept, [System.StringComparison]::Ordinal)) { continue }
            # Already accepted for this machine? Then nothing is being decided.
            $now = 'stop'
            if ($entry.policy -and $entry.policy.PSObject.Properties[$lever]) { $now = [string]$entry.policy.$lever }
            # Ordinal too, so every comparison on the approver path is one kind.
            if ([string]::Equals($now, [string]$rule.accept, [System.StringComparison]::Ordinal)) { continue }
            @{ VmId = [string]$id; Lever = [string]$lever; Accept = [string]$rule.accept }
        }
    }
    @($taken)
}

function Invoke-VmfFacadeApprove {
    <#
    .SYNOPSIS
        S3-2: record a wave approval AS THE VALIDATED USER (Vmf.Approver).
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$Note,
        # APPR-2: what the approver's browser had on screen. Mandatory here,
        # unlike on the cmdlet: this IS the racing path. The page renders the
        # wave table from a plan it read up to refreshSeconds ago, and a
        # Vmf.Operator may rewrite that wave - with no approver involved - in
        # the seconds the dialog is open. Without this the approver's click
        # signs whatever plan.json holds when the request lands.
        [Parameter(Mandatory)][string]$PlanHash
        # REBUILD-REMOVE-ACCEPT-1: no list of machines whose identity the
        # approver accepts to lose - no move rebuilds a machine.
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Approver', 'Vmf.Admin')
    Approve-VmfWave -RunPath $StorePath -PlanPath (Get-VmfFacadePlanPath -StorePath $StorePath) `
        -Wave $Wave -Note $Note -ExpectedPlanHash $PlanHash `
        -OnBehalfOf @{ Identity = $Principal.Identity; TenantId = $null }
}

function Invoke-VmfFacadeApprovePlan {
    <#
    .SYNOPSIS
        PLANRUN-1: sign off the WHOLE plan AS THE VALIDATED USER (Vmf.Approver).
    .DESCRIPTION
        One signature for every wave, bound to the plan version the approver's
        browser showed - the same APPR-2 race as a wave approval, so the hash
        is mandatory here too. It is also the consent for the run to carry on:
        the timer starts the next wave when one finishes.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Note,
        [Parameter(Mandatory)][string]$PlanHash,
        # REBUILD-REMOVE-ACCEPT-1: no list of machines whose identity the
        # approver accepts to lose - no move rebuilds a machine.
        # SQL-TEMPDB-SIGNOFF-1: the machines the approver ticked the box for -
        # SQL Server found, and a move to an NVMe temporary disk or none.
        # Approve-VmfPlan judges the list against the plan.
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$SqlTempdbChecked = @()
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Approver', 'Vmf.Admin')
    # SCHEDULE-PASS-DUE-1: Approve-VmfPlan marks the run for the five-minute
    # pass after it saves the sign-off (Add-VmfRunScheduleDue).
    Approve-VmfPlan -RunPath $StorePath -PlanPath (Get-VmfFacadePlanPath -StorePath $StorePath) `
        -Note $Note -ExpectedPlanHash $PlanHash -SqlTempdbChecked @($SqlTempdbChecked) `
        -OnBehalfOf @{ Identity = $Principal.Identity; TenantId = $null }
}


function Test-VmfFacadeRunJobRunning {
    <#
    .SYNOPSIS
        SCHEDULE-PASS-DUE-1: does an execution of the engine run a wave, a
        restore or a finish of this run now (Running or Processing)? The
        five-minute pass asks it before it takes a run out of the record of
        the runs to check, when no fact in the store names one.
    .DESCRIPTION
        Asked through Test-VmfFacadeEngineRunning, so inside the pass it reads
        the list of executions the pass keeps (TIMER-EXEC-LIST-1). The run is
        named by its place in the store ('project/run'), as the pass names it.
        A list Azure does not give throws, and the pass keeps the run.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RunId)
    # SCAN-FAIL-SHOWN-1: and a scan - the pass ends the wait of a scan whose
    # job stops with no answer (Invoke-VmfFacadeEndSilentScan), so the run
    # stays in the record while the scan runs, also after its 15 minutes.
    # VOLUMES-CHECK-JOB-STOP-1: and Check the volumes, which can start a
    # machine that the pass returns when its job stops.
    Test-VmfFacadeEngineRunning -Operation @('wave', 'restore', 'finish', 'assess', 'checkvolumes') -RunId $RunId
}

function Invoke-VmfFacadeEndSilentScan {
    <#
    .SYNOPSIS
        SCAN-FAIL-SHOWN-1: end the wizard's wait for a scan whose engine job
        ended with no answer. Called by the five-minute pass, for every run it
        checks.
    .DESCRIPTION
        Measured on the lab installation, 2026-11-09: a scan's execution ended
        Failed, wrote no console line and no line in the run's activity, and
        the wizard said "Looking for machines" with no end. Azure keeps the
        status, in the list of executions the pass already reads
        (Get-VmfFacadeEngineExecutions - inside the pass, the list it keeps,
        TIMER-EXEC-LIST-1). An assess execution of this run with a status that
        means it ended without success (Test-VmfScanExecutionEnded) has the
        run's activity read, and the engine's rule (Get-VmfScanSilentEnd)
        decides whether the scan answered after the start line that names the
        execution. When it did not, the engine:assess fail line goes into the
        activity - the line the entrypoint writes for an error the scan does
        not catch, and the line the wizard ends its wait on. Written once:
        the next pass finds it.
        The run is named by its place in the store ('project/run'), as the pass
        names it; an execution the page started carries the two apart
        (VMF_PROJECT, VMF_RUN_ID). No execution of this run that ended reads
        nothing from the store. A list Azure does not give throws, and a line
        that cannot be written throws: the pass says so, and asks again.
    .OUTPUTS
        Execution, Status and Detail of the line written, or nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId
    )
    $m = Get-Module VmMigrationFactory
    $field = { param($envs, $name) [string](@($envs | Where-Object { $_.name -eq $name }) | Select-Object -First 1).value }
    $ended = @(foreach ($x in @(Get-VmfFacadeEngineExecutions)) {
            if (-not $x) { continue }
            $envs = @($x.properties.template.containers[0].env)
            if ((& $field $envs 'VMF_OPERATION') -cne 'assess') { continue }
            $proj = & $field $envs 'VMF_PROJECT'
            $run = & $field $envs 'VMF_RUN_ID'
            if ($(if ($proj) { "$proj/$run" } else { $run }) -cne $RunId) { continue }
            $status = [string]$x.properties.status
            if (-not (& $m { param($s) Test-VmfScanExecutionEnded -Status $s } $status)) { continue }
            [pscustomobject]@{ Name = [string]$x.name; Status = $status }
        })
    if (-not $ended.Count) { return }
    $end = & $m { param($rp, $x) Get-VmfScanSilentEnd -Events @(Read-VmfEvents -RunPath $rp) -Executions $x } $StorePath $ended
    if (-not $end) { return }
    # A throwing write on purpose: it is what ends the wait on the page, and a
    # line that is not written is written by the next pass.
    & $m { param($rp, $d, $ex, $st)
        Write-VmfEvent -RunPath $rp -Step 'engine:assess' -Outcome fail -Detail $d -Data @{ execution = $ex; executionStatus = $st }
    } $StorePath $end.Detail $end.Execution $end.Status
    $end
}

function Invoke-VmfFacadeExportMigrationRecord {
    <#
    .SYNOPSIS
        ATTEST-1: the full record of one migration, built now, kept for another
        90 days, and returned (Vmf.Admin).
    .DESCRIPTION
        For the Administrator role only, because engineering and
        change management keep this as the record of the change. A POST because
        it WRITES: building the record keeps it in vmf-records/.

        RECORD-DELETE-1: refused while the engine deletes the migration with
        its safety copies - the check that refuses a restore or a wave start
        then. A delete that keeps the copies runs inside one request of this
        service and has no open line; Export-VmfMigrationRecord refuses, at
        the moment it keeps the record, a migration whose delete has begun.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Principal, [Parameter(Mandatory)][string]$StorePath)
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Admin')
    Assert-VmfFacadeNotBeingDeleted -StorePath $StorePath `
        -Refusal '409: This migration is being deleted with its safety copies, so the product does not make its record now. When the delete is complete, Records of each migration shows its record.'
    Export-VmfMigrationRecord -RunPath $StorePath -GeneratedBy ([string]$Principal.Identity)
}

function Invoke-VmfFacadeListMigrationRecords {
    <#
    .SYNOPSIS
        ATTEST-1: the migration records kept in the store, deleted migrations
        included (Vmf.Admin).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Principal)
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Admin')
    @(Get-VmfMigrationRecord -StorePath (Get-VmfFacadeStorePath))
}

function Invoke-VmfFacadeGetKeptMigrationRecord {
    <#
    .SYNOPSIS
        ATTEST-1: one kept migration record by name - the way to reach the
        record of a migration that has been deleted (Vmf.Admin).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Principal, [Parameter(Mandatory)][string]$Name)
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Admin')
    Get-VmfMigrationRecord -StorePath (Get-VmfFacadeStorePath) -Name $Name
}

function Invoke-VmfFacadeContinuePlan {
    <#
    .SYNOPSIS
        PLANRUN-1: when a wave of a signed-off plan has finished, start the
        next one. Called by the timer, every pass, for every run.
    .DESCRIPTION
        The engine runs ONE wave and exits, and nothing ever started the next:
        an eight-wave plan was eight returns to the console. The decision is the
        engine module's (Get-VmfPlanRunDecision - pure rules plus the engine's
        own start gates); this does the starting, with the same guard the
        stalled-wave resume has against starting twice: an execution of a wave
        of this run that Azure reports Running means one is already on its way,
        so nothing else starts.

        Returns what it started, or nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId
    )
    $m = Get-Module VmMigrationFactory
    $planPath = Get-VmfFacadePlanPath -StorePath $StorePath
    $d = & $m { param($rp, $pp) Get-VmfPlanRunDecision -RunPath $rp -PlanPath $pp } $StorePath $planPath
    # GATE-WORDS-1: the next wave waits because its settings changed after
    # they were accepted. The status line tells the person to select Review &
    # accept options again, and the page offers that button only after this
    # refusal is logged - as the restart timer below and the wave start do.
    # Said once (Write-VmfOptionsChangedRefusal), not every five minutes.
    if ($d.PSObject.Properties['GateCode'] -and [string]$d.GateCode -eq 'changed' -and [string]$d.GateWave) {
        & $m { param($rp, $w, $dd) Write-VmfOptionsChangedRefusal -RunPath $rp -Wave $w -Detail $dd | Out-Null } $StorePath ([string]$d.GateWave) ([string]$d.Detail)
    }
    if (-not $d.Wave) {
        # WAVE-ORDER-START-1: a person started the first wave, and the engine
        # has not taken a machine yet - its container is starting. The store
        # alone then says that nothing has begun, and this pass wrote "the
        # first wave starts when somebody starts it" right after somebody did
        # (lab Session A, 2026-11-04). Azure's list of executions is the only
        # place that knows, so it is asked - only for this answer, which only
        # a signed-off plan that has not begun gives.
        if ([string]$d.Reason -eq 'notStarted' -and (Test-VmfFacadeEngineRunning -Operation 'wave' -RunId $RunId)) { return }
        & $m { param($rp, $dd) Set-VmfPlanRunStatus -RunPath $rp -Decision $dd | Out-Null } $StorePath $d
        return
    }

    # ENGINE-START-PART-1 review: any run of a wave of this migration, Running
    # or Processing, asked the way the start's own guard asks. A Running-only
    # check let a fresh container (Processing) through to a start the guard
    # refused, and the pass wrote a false 'fail' line.
    # TIMER-EXEC-LIST-1: asked of Azure, not of the list the pass keeps. The
    # start's own guard asks about the wave it starts only, and this question
    # is any wave of the run. It is asked only when a wave is about to start.
    if (Test-VmfFacadeEngineRunning -Operation 'wave' -RunId $RunId -Fresh) { return }

    # WAVE-APPROVE-1: the start rests on the wave's OWN approval when it has
    # one - which may be a later approval by another approver than the one who
    # signed the plan off - so that is the name the start carries.
    $signed = & $m { param($rp) Read-VmfStoreJson -RunPath $rp -RelPath 'plan-approval.json' -Depth 6 } $StorePath
    $waveApproval = & $m { param($rp, $w) try { Read-VmfStoreJson -RunPath $rp -RelPath "approvals/$w.json" -Depth 8 } catch { $null } } $StorePath ([string]$d.Wave)
    $by = if ($waveApproval -and $waveApproval.approvedBy -and [string]$waveApproval.approvedBy.identity) { [string]$waveApproval.approvedBy.identity }
          elseif ($signed -and $signed.approvedBy) { [string]$signed.approvedBy.identity } else { 'unknown' }
    $r = Invoke-VmfFacadeStartEngine -Principal ([pscustomobject]@{ Identity = "signed-off plan ($by)"; Roles = @('Vmf.Operator') }) `
        -Operation 'wave' -RunId $RunId -Wave $d.Wave `
        -Note "the signed-off plan continues: $($d.Detail)" -WaveVersion ([string]$d.WaveVersion)
    & $m { param($rp, $dd, $ex) Set-VmfPlanRunStatus -RunPath $rp -Decision $dd -Execution $ex | Out-Null } $StorePath $d ([string]$r.execution)
    [pscustomobject]@{ Wave = $d.Wave; Execution = $r.execution; After = $d.After }
}

function Invoke-VmfFacadeDiscardRun {
    <#
    .SYNOPSIS
        RUN-LIFECYCLE-1: throw away a run that never got past setup.
    .DESCRIPTION
        Deliberately NARROWER than the Remove-VmfRun cmdlet. From a web page,
        the only run that may be discarded is one that was scanned and never
        planned - nothing was ever touched, there are no safety copies to
        orphan, and there is nothing to lose but a scan that takes minutes to
        redo. Anything with a plan is a decision that belongs at the command
        line, where the operator has to say what happens to the safety copies.

        Gated on the operator role, like every other action that changes
        something. The person's identity and reason go into the run log - which
        is written BEFORE the records are deleted, because afterwards there is
        nowhere to write it.

        DISCARD-ENGINE-1 (GitHub issue 427): deleting the safety copies as well
        is NOT done here. It needs Az.Resources and the right to delete a
        customer's snapshots, and this service has neither - by design, the
        same split as the daily cleanup. So with copies to delete, this checks
        everything it can, writes a 'discard' start line the page shows, and
        starts the engine's 'discard' operation, which deletes every copy and
        then the records. Keeping the copies changes nothing in Azure and is
        still done here, at once.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][AllowEmptyString()][string]$Note,
        [Parameter()][switch]$DeleteSafetyCopies,
        # DISCARD-ENGINE-1: the run and its project, for the engine - which
        # builds its own store path from them, as for every operation.
        [Parameter()][string]$RunId,
        [Parameter()][string]$Project
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    $identity = if ($Principal -and $Principal.Identity) { [string]$Principal.Identity } else { 'unknown' }

    $stage = & (Get-Module VmMigrationFactory) { param($rp)
        $plan = Read-VmfPlanDocument -RunPath $rp -Depth 24
        $docs = @(Get-VmfStoreNames -RunPath $rp -Folder 'state' -Extension '.json' |
            ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "state/$_" -Depth 24 })
        $r = Get-VmfRunStage -Plan $plan -StateDocs $docs
        # DELETE-UNSTARTED-WAVE-1: does a machine work now - a state that is
        # not PLANNED and not settled, the in-flight rule of
        # Test-VmfRunDiscardable? Between waves none does.
        $states = Get-VmfEngineStates
        $r.Working = @($docs | Where-Object { $s = [string]$_.state; $s -and $s -ne $states.NotStarted -and $s -notin $states.Terminal }).Count
        $r
    } $StorePath

    # A run still working on a machine is never discardable from anywhere -
    # that record is what knows how to put the machine back. Everything else
    # may go: a lab fills up with runs nobody can remove, and a risk is not
    # a reason to leave no way out.
    # DELETE-UNSTARTED-WAVE-1 (option (a), 2026-11-16): between waves no
    # machine works, but the machines of the next wave have not settled, so the
    # stage is running. The page shows Stop this migration then (runIsWorking
    # asks VmfHelp.runStage, this rule's twin), and Stop leaves those machines
    # out. Said as what is true: they did not start.
    if ($stage.Stage -eq 'running') {
        if ($stage.Working -eq 0) {
            throw '400: Some machines of this migration did not start. Select Stop this migration first. It leaves out those machines and does not change them.'
        }
        throw "400: This migration works on machines now: $($stage.Detail). Select Stop this migration first."
    }

    $reason = if ($Note) { $Note } else { 'discarded from the dashboard' }
    try {
        # Every check the delete makes, before anything is written or started:
        # ASSESS-LINK-1 and RUN-DELETE-RESERVE-1 refuse BEFORE "discarded by"
        # goes into a log that is not going to be discarded after all, and
        # DISCARD-ENGINE-1 before an engine is started for a delete the engine
        # would refuse. Returns how many safety copies the run still holds.
        $copies = & (Get-Module VmMigrationFactory) { param($rp)
            $m = Read-VmfStoreJson -RunPath $rp -RelPath 'run.json' -Depth 6
            if ($m) { Assert-VmfAssessmentUnused -RunPath $rp -Manifest $m }
            Assert-VmfNoBillingReservation -RunPath $rp
            $plan = Read-VmfPlanDocument -RunPath $rp -Depth 24
            $docs = @(Get-VmfStoreNames -RunPath $rp -Folder 'state' -Extension '.json' |
                ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "state/$_" -Depth 24 })
            $verdict = Test-VmfRunDiscardable -Plan $plan -StateDocs $docs
            if (-not $verdict.Ok) { throw "400: $($verdict.Detail)" }
            # ROLLBACK-DISKS-FIRST-1 review: and the rollback disks
            # that nothing used. A run can hold them with no copy left (a copy
            # deleted, a disk whose delete failed), and only the engine can
            # delete a disk - so they start the engine too.
            # MADE-DISK-RUN-DELETE-1: and the disks a rollback, a restore or a
            # rebuild made from a copy that nothing uses - the same reason.
            @{ Copies = @($verdict.OrphanSnapshots).Count; Disks = @($verdict.RollbackDisksBeforeMove).Count; Made = @($verdict.MadeDisks).Count }
        } $StorePath
        $rollbackDisksBeforeMove = [int]$copies.Disks
        $madeDisks = [int]$copies.Made
        $copies = [int]$copies.Copies

        # Review 2 item 3: never while the engine works on this migration. A
        # restore marks its machine only late, and a machine waiting for a slot
        # in a wave has no state document at all, so the store cannot say -
        # Azure can. For both kinds of delete: keeping the copies removes the
        # records a running job still writes to.
        $manifestIds = & (Get-Module VmMigrationFactory) { param($rp) Read-VmfStoreJson -RunPath $rp -RelPath 'run.json' -Depth 6 } $StorePath
        $busyRunId = if ($RunId) { $RunId } elseif ($manifestIds) { [string]$manifestIds.runId } else { '' }
        $busyProject = if ($PSBoundParameters.ContainsKey('Project')) { $Project } elseif ($manifestIds) { [string]$manifestIds.project } else { '' }
        # SWAP-REFUSED-AFTER-STOP-1: and Finish the rollback / Finish the restore.
        # RESTORE-EARLIER-DELETE-1: and Delete these disks, which writes each
        # disk it deletes into the record of the machine.
        # MADE-DISK-DELETE-1: and Delete these disks now, which does the same.
        if ($busyRunId -and (Test-VmfFacadeEngineRunning -Operation @('wave', 'restore', 'finish', 'deleteearlier', 'deletemade', 'checkvolumes') -RunId $busyRunId -Project $busyProject)) {
            throw '400: The engine works on this migration now. Delete it when that job ends.'
        }

        if ($DeleteSafetyCopies -and ($copies + $rollbackDisksBeforeMove + $madeDisks) -gt 0) {
            if (-not $RunId) { throw '400: deleting the safety copies needs the migration id, so the engine can find it' }
            # One delete at a time: a second press while the engine works would
            # start a second job over the same copies.
            if (Test-VmfFacadeEngineRunning -Operation 'discard' -RunId $RunId -Project $Project) {
                throw '400: This migration is already being deleted. Wait for that to finish, then look at the page again.'
            }
            # STEP-LOG-6: a throwing write on purpose. It is written before the
            # engine starts, and the page shows the delete from this line, so a
            # line that cannot be written starts no delete.
            & (Get-Module VmMigrationFactory) { param($rp, $who, $note, $n, $d, $m)
                $diskWords = if ($d -gt 0) { " and $d rollback disks" } else { '' }
                $madeWords = if ($m -gt 0) { " and $m disks that a rollback or a restore made from the copies" } else { '' }
                Write-VmfEvent -RunPath $rp -Step 'discard' -Outcome start `
                    -Detail "$who started to delete this migration and its $n safety copies${diskWords}${madeWords}: $note"
            } $StorePath $identity $reason $copies $rollbackDisksBeforeMove $madeDisks
            # S1: the generic engine route refuses 'discard'; only this path,
            # after the checks above, may start it. A module variable, so no
            # caller outside this module can set it.
            $script:VmfDiscardDispatch = $true
            try {
                $started = Invoke-VmfFacadeStartEngine -Principal $Principal -Operation 'discard' -RunId $RunId -Project $Project -Note $reason
            }
            catch {
                # S3: the start line is already written. Without an end, the
                # page would say "deleting" for an hour and refuse a restore
                # or a wave meanwhile - for a job that never started.
                # STEP-LOG-6: through the one helper, so the scan covers it. A
                # line that cannot be written is a warning in the service log,
                # and the person gets the start's own error.
                $why = $_.Exception.Message
                & (Get-Module VmMigrationFactory) { param($rp, $w)
                    Write-VmfStepLine -RunPath $rp -Step 'discard' -Outcome fail `
                        -Detail "The engine did not start, so nothing was deleted. The service said: $w"
                } $StorePath $why
                throw
            }
            finally { $script:VmfDiscardDispatch = $false }
            return [pscustomobject]@{
                queued       = $true
                operation    = 'discard'
                execution    = [string]$started.execution
                safetyCopies = $copies
                rollbackDisksBeforeMove = $rollbackDisksBeforeMove
                madeDisks    = $madeDisks
            }
        }

        # Keeping the copies, or none to delete: nothing changes in Azure, so
        # it is done here. NEVER -DeleteSafetyCopies from this service - the
        # guard in FacadeAzModules.Tests.ps1 fails if it comes back. With no
        # copies switch at all, a copy that appeared since the count above is
        # refused by Remove-VmfRun rather than kept against the person's choice.
        # STEP-LOG-6: a throwing write on purpose. It is written before
        # Remove-VmfRun removes a record, so a line that cannot be written
        # removes nothing.
        & (Get-Module VmMigrationFactory) { param($rp, $who, $note, $keep)
            Write-VmfEvent -RunPath $rp -Step 'run' -Outcome ok -Detail "discarded by ${who}: $note"
            if ($keep) { Remove-VmfRun -RunPath $rp -Reason $note -RemovedBy $who -KeepSafetyCopies -Confirm:$false }
            else       { Remove-VmfRun -RunPath $rp -Reason $note -RemovedBy $who -Confirm:$false }
        } $StorePath $identity $reason (-not $DeleteSafetyCopies)
    }
    catch {
        # "It still holds things" is an ANSWER for the person, not a server
        # fault - the same shape as deleting a project.
        if ("$_" -match 'still holds') { throw "400: $_" }
        throw
    }
}

# DISCARD-ENGINE-1 S1: set only by Invoke-VmfFacadeDiscardRun around its start.
$script:VmfDiscardDispatch = $false
# RESTORE-END-JOB-1: set only by Invoke-VmfFacadeResumeStalledPutBacks around
# its start - the operation id of the restore it starts again. A
# module variable, as the discard's is, so no request body can set it: the
# generic route would otherwise let anybody name another job's id.
$script:VmfResumeDispatch = $null
# SCHEDULE-START-ONCE-1: set only by Invoke-VmfFacadeReleaseDueSchedules around
# its start - the start id the wave's schedule holds on record. The start sends
# it to Azure (VMF_SCHEDULE_START), so a later pass finds this start in the
# executions list. A module variable, as the two above are, so no request body
# can set it.
$script:VmfScheduleStartId = $null
# ENGINE-START-PART-1 review: the states in which an engine execution is a
# run. A new execution is Processing while its container pulls the image,
# before it is Running. Every question "does a run go on?" asks this list,
# through Test-VmfFacadeEngineRunning.
$script:VmfEngineAliveStates = @('Running', 'Processing')

function Test-VmfFacadeEngineRunning {
    <#
    .SYNOPSIS
        DISCARD-ENGINE-1: is an execution of this engine operation, for this
        run, still running? Asked of Azure, which is the only place that knows.
    .DESCRIPTION
        The same question Invoke-VmfFacadeContinuePlan asks before it starts a
        wave: the job's executions, with their status and the operation and
        run each was started with.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Review 2 item 3: one operation or several, asked in one listing.
        [Parameter(Mandatory)][string[]]$Operation,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][string]$Project,
        # RESTORE-ONE-AT-A-TIME-1: only executions started for this machine
        # (VMF_VM_ID, which a restore and a rebuild carry). Without the case:
        # Azure gives one ID in more than one letter case (VMID-CASE-1).
        [Parameter()][string]$VmId,
        # ENGINE-START-PART-1: only executions started for this wave
        # (VMF_WAVE, which a wave start carries).
        [Parameter()][string]$Wave,
        # TIMER-EXEC-LIST-1: read Azure now, also inside a timer pass that
        # keeps a list. For a question whose "no" starts something that the
        # start's own guard does not ask about.
        [Parameter()][switch]$Fresh
    )
    # S4: every page (the module's ARM list follows nextLink), and a new
    # execution is 'Processing' before it is 'Running' - the one most likely
    # to be there when a second press arrives.
    # TIMER-EXEC-LIST-1: inside the five-minute pass, one list answers every
    # question (Get-VmfFacadeEngineExecutions); a list Azure does not give
    # throws, as it did.
    $items = Get-VmfFacadeEngineExecutions -Fresh:$Fresh
    # ENGINE-START-PART-1 review: one run, two spellings. The page names the
    # run and its project apart (VMF_RUN_ID run, VMF_PROJECT project); the
    # timer passes name it by its place in the store (VMF_RUN_ID project/run,
    # no VMF_PROJECT). Both sides are compared as that place.
    $want = if ($Project) { "$Project/$RunId" } else { $RunId }
    $alive = @(@($items) | Where-Object {
        $envs = @($_.properties.template.containers[0].env)
        $proj = [string](@($envs | Where-Object { $_.name -eq 'VMF_PROJECT' }) | Select-Object -First 1).value
        $run = [string](@($envs | Where-Object { $_.name -eq 'VMF_RUN_ID' }) | Select-Object -First 1).value
        $_.properties.status -in $script:VmfEngineAliveStates -and
        (@($envs | Where-Object { $_.name -eq 'VMF_OPERATION' -and $_.value -in $Operation })) -and
        $(if ($proj) { "$proj/$run" } else { $run }) -eq $want -and
        (-not $VmId -or [string](@($envs | Where-Object { $_.name -eq 'VMF_VM_ID' }) | Select-Object -First 1).value -ieq $VmId) -and
        (-not $Wave -or [string](@($envs | Where-Object { $_.name -eq 'VMF_WAVE' }) | Select-Object -First 1).value -eq $Wave)
    })
    $alive.Count -gt 0
}

# TIMER-EXEC-LIST-1: the engine job's executions, kept for one five-minute
# timer pass. $null outside a pass: every question reads Azure. Inside a pass:
# @{ Items = <the list, or $null when none is kept>; ReadUtc = <when read> }.
# A module variable, set only by the timer (Start-VmfFacadeEngineListPass), so
# no request can make the service keep a list.
$script:VmfEngineListPass = $null
# A kept list older than this is read again. The pass reads the machine
# records again at the same age (Select-VmfScheduleStateDocs). It also limits
# what a list can cost if a pass the host stopped left it in the worker.
$script:VmfEngineListMaxAgeSeconds = 30

function Start-VmfFacadeEngineListPass {
    <#
    .SYNOPSIS
        TIMER-EXEC-LIST-1: from now until Stop-VmfFacadeEngineListPass, one
        list of the engine's executions answers every question of the
        five-minute pass.
    .DESCRIPTION
        The put-back pass asked Azure once for each machine with an open
        restore or finish, and the stalled-wave pass, the hold pass and the
        next-wave decision asked again - each question read every page of the
        executions. The answer was the same list each time, apart from an
        execution the same pass started. So the pass keeps the list it read,
        and empties it when anything starts an execution
        (Invoke-VmfFacadeStartEngine), when the list is older than
        $script:VmfEngineListMaxAgeSeconds, and when a read fails.
    #>
    [CmdletBinding()]
    param()
    $script:VmfEngineListPass = @{ Items = $null; ReadUtc = $null }
}

function Stop-VmfFacadeEngineListPass {
    <# .SYNOPSIS TIMER-EXEC-LIST-1: the pass ends; every question reads Azure again. #>
    [CmdletBinding()]
    param()
    $script:VmfEngineListPass = $null
}

function Clear-VmfFacadeEngineList {
    <#
    .SYNOPSIS
        TIMER-EXEC-LIST-1: forget the kept list, so the next question of the
        pass reads Azure. Invoke-VmfFacadeStartEngine asks it before its own
        guards and after it asked Azure to start: a start changes the list.
    #>
    [CmdletBinding()]
    param()
    if ($script:VmfEngineListPass) {
        $script:VmfEngineListPass.Items = $null
        $script:VmfEngineListPass.ReadUtc = $null
    }
}

function Get-VmfFacadeEngineExecutions {
    <#
    .SYNOPSIS
        TIMER-EXEC-LIST-1: the engine job's executions, every page - from the
        list the pass keeps when it is younger than the limit, else from Azure.
    .DESCRIPTION
        A list Azure does not give throws, and is never kept: a failed read is
        never an answer of "not running", and the kept list is emptied, so the
        next question reads again. -Fresh reads Azure and leaves the kept list
        as it is.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][switch]$Fresh)
    $jobId = $env:VMF_ENGINE_JOB_ID
    if (-not $jobId) { throw 'Facade misconfigured: VMF_ENGINE_JOB_ID is not set (deploy the engine job first).' }
    $pass = $script:VmfEngineListPass
    if (-not $Fresh -and $pass -and $null -ne $pass.Items -and $pass.ReadUtc -and
        ([datetime]::UtcNow - $pass.ReadUtc).TotalSeconds -lt $script:VmfEngineListMaxAgeSeconds) {
        return , $pass.Items
    }
    $list = & (Get-Module VmMigrationFactory) { param($path) Get-VmfArmList -Path $path } "$jobId/executions?api-version=2025-01-01"
    if (-not $list.Ok) {
        if (-not $Fresh) { Clear-VmfFacadeEngineList }
        throw "Could not list engine executions: HTTP $($list.StatusCode)"
    }
    $items = @($list.Items)
    if (-not $Fresh -and $pass) {
        $pass.Items = $items
        $pass.ReadUtc = [datetime]::UtcNow
    }
    , $items
}

function Get-VmfFacadeScheduleStartExecutions {
    <#
    .SYNOPSIS
        SCHEDULE-START-ONCE-1: the names of the engine executions that a
        scheduled start with this start id made, in ANY status - asked of
        Azure, the same listing as Test-VmfFacadeEngineRunning.
    .DESCRIPTION
        A run that ended is still a start that was made, so the status is not
        asked. A start id is new for each start, so nothing else is matched.
        A list Azure does not give throws: a start that cannot be checked is
        not made again.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$StartId,
        # SCHEDULE-WAVE-VERSION-1: only the runs that go on (Running or
        # Processing, $script:VmfEngineAliveStates) - the ones that may still
        # remove the schedule or put it back.
        [Parameter()][switch]$Alive
    )
    $jobId = $env:VMF_ENGINE_JOB_ID
    if (-not $jobId) { throw 'Facade misconfigured: VMF_ENGINE_JOB_ID is not set (deploy the engine job first).' }
    $list = & (Get-Module VmMigrationFactory) { param($path) Get-VmfArmList -Path $path } "$jobId/executions?api-version=2025-01-01"
    if (-not $list.Ok) { throw "Could not list engine executions: HTTP $($list.StatusCode)" }
    @(@($list.Items) | Where-Object {
        $envs = @($_.properties.template.containers[0].env)
        [string]::Equals([string](@($envs | Where-Object { $_.name -eq 'VMF_SCHEDULE_START' }) | Select-Object -First 1).value, $StartId, [System.StringComparison]::Ordinal) -and
        (-not $Alive -or [string]$_.properties.status -in $script:VmfEngineAliveStates)
    } | ForEach-Object { [string]$_.name })
}

function Get-VmfFacadeOpenDiscard {
    <#
    .SYNOPSIS
        DISCARD-ENGINE-1 S2: the 'discard' start line that nothing has ended
        yet, or nothing. The same rule as the page's discardIndex: a start is
        ended by a 'discard' or 'engine:discard' failure or refusal.
    .DESCRIPTION
        RECORD-DELETE-1: the rule lives in the engine (Get-VmfOpenDiscard),
        which needs it too; this asks it there, so there is one copy.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Events)
    & (Get-Module VmMigrationFactory) { param($list) Get-VmfOpenDiscard -Events $list } $Events
}

function Assert-VmfFacadeNotBeingDeleted {
    <#
    .SYNOPSIS
        DISCARD-ENGINE-1 S2: refuse an action that would change a machine of a
        migration the engine is deleting.
    .DESCRIPTION
        The engine deletes the safety copies for minutes before it removes the
        records. A retry in that gap takes NEW copies the delete never saw, and
        a wave or a restore starts work on a machine whose record is about to
        go. So restore, rebuild, retry and a wave start are refused while a
        delete is open in the log AND Azure says its job is still there. An
        open line with no job (one the platform stopped without a word) does
        not hold the migration hostage.

        RECORD-DELETE-1: the record download asks the same question, with its
        own sentence, because a download starts nothing on a machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][string]$Refusal = '400: This migration is being deleted with its safety copies. Nothing else can start on it until the delete ends.'
    )
    $state = & (Get-Module VmMigrationFactory) { param($rp)
        $events = @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -in @('discard', 'engine:discard') })
        @{ Events = $events; Manifest = (Read-VmfStoreJson -RunPath $rp -RelPath 'run.json' -Depth 6) }
    } $StorePath
    $open = Get-VmfFacadeOpenDiscard -Events $state.Events
    if (-not $open -or -not $state.Manifest) { return }
    if (Test-VmfFacadeEngineRunning -Operation 'discard' -RunId ([string]$state.Manifest.runId) -Project ([string]$state.Manifest.project)) {
        throw $Refusal
    }
}

function Invoke-VmfFacadeDeleteProject {
    <#
    .SYNOPSIS
        PROJ-DEL-1: delete an EMPTY project (Vmf.Operator).
    .DESCRIPTION
        The dashboard had no delete button for assessments or projects, so
        there was no way to clear them out from the app.

        The cmdlet refuses a project that still holds assessments or
        migrations, and names them. That refusal is the whole safety story, so
        it stays in the engine where the API path cannot route around it - this
        wrapper adds the role check and the identity, nothing else.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter()][AllowEmptyString()][string]$Note
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    $identity = if ($Principal -and $Principal.Identity) { [string]$Principal.Identity } else { 'unknown' }
    $reason = if ($Note) { $Note } else { 'deleted from the dashboard' }

    try {
        & (Get-Module VmMigrationFactory) { param($root, $id, $why, $who)
            Remove-VmfProject -StorePath $root -ProjectId $id -Reason $why -RemovedBy $who -Confirm:$false
        } $StorePath $ProjectId $reason $identity
    }
    catch {
        # "It still holds things" is an ANSWER for the person, not a server
        # fault - it tells them exactly what to do next.
        if ("$_" -match 'still holds|no project called') { throw "400: $_" }
        throw
    }
}

function Invoke-VmfFacadeStopRun {
    <#
    .SYNOPSIS
        RUN-LIFECYCLE-1: close out a run that cannot finish - the machines were
        deleted, or the workers are gone (Vmf.Operator).
    .DESCRIPTION
        Touches nothing in Azure. It marks unfinished machines skipped, frees
        them for another migration, and pauses the run. -Force is deliberately
        NOT offered here: if a live worker still holds a machine, the honest
        answer from a web page is "not from here", because the person cannot
        see whether that worker is really gone.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][AllowEmptyString()][string]$Note,
        # POWER-ONLY-CHANGED-1: the run and its project, to start the engine
        # operation that returns each machine to its power state.
        [Parameter()][string]$RunId,
        [Parameter()][string]$Project
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    $identity = if ($Principal -and $Principal.Identity) { [string]$Principal.Identity } else { 'unknown' }
    $reason = if ($Note) { $Note } else { 'stopped from the dashboard' }
    $result = try {
        & (Get-Module VmMigrationFactory) { param($rp, $who, $note)
            Stop-VmfRun -RunPath $rp -Reason $note -StoppedBy $who -Confirm:$false
        } $StorePath $identity $reason
    }
    catch {
        if ("$_" -match 'still holds') { throw "400: $_" }
        throw
    }
    # POWER-ONLY-CHANGED-1 (2026-11-06): a machine turned on at any phase and
    # then left out or stopped must be turned off again. The
    # service has no right to change a machine, so the engine returns each one.
    Add-VmfFacadePowerReturn -Principal $Principal -Result $result -RunId $RunId -Project $Project -Note $reason
}

function Add-VmfFacadePowerReturn {
    <#
    .SYNOPSIS
        POWER-ONLY-CHANGED-1: after Leave this machine out or Stop this
        migration, start the engine operation 'powerback' when a machine's
        power state is owed (PowerOwed on the result), and say on the result
        whether it started (PowerReturn). Never throws: the record keeps the
        power state owed, and the machine panel offers the return again.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter()][AllowNull()]$Result,
        [Parameter()][string]$RunId,
        [Parameter()][string]$Project,
        [Parameter()][string]$VmId,
        [Parameter()][string]$Note
    )
    if (-not $Result) { return $Result }
    $owed = @(@($Result.PowerOwed) | Where-Object { $_ })
    $said = ''
    if ($owed.Count) {
        if (-not $RunId) { $said = 'not started: the call did not name the migration' }
        else {
            try {
                $start = @{ Principal = $Principal; Operation = 'powerback'; RunId = $RunId; Note = $Note }
                if ($Project) { $start.Project = $Project }
                if ($VmId) { $start.VmId = $VmId }
                Invoke-VmfFacadeStartEngine @start | Out-Null
                $said = 'started'
            }
            catch { $said = "not started: $($_ -replace '^\d{3}: ', '')" }
        }
    }
    $Result | Add-Member -NotePropertyName PowerReturn -NotePropertyValue $said -Force
    $Result
}

function Invoke-VmfFacadeHalt {
    <#
    .SYNOPSIS
        S3-2: pause a run's wave execution (Vmf.Operator) - no new machines
        start; in-flight ones finish safely.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Note
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    & (Get-Module VmMigrationFactory) { param($rp, $reason)
        Set-VmfWaveHalt -RunPath $rp -Reason $reason
    } $StorePath "operator halt by $($Principal.Identity): $Note"
    [pscustomobject]@{ Halted = $true; By = $Principal.Identity; Note = $Note }
}

function Invoke-VmfFacadeClearHalt {
    <#
    .SYNOPSIS
        S3-2: resume a paused run (Vmf.Operator) - audited.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Note
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    # SCHEDULE-PASS-DUE-1: Clear-VmfWaveHalt marks the run for the five-minute
    # pass after it removes the brake (Add-VmfRunScheduleDue).
    Clear-VmfWaveHalt -RunPath $StorePath -Note $Note -ClearedBy $Principal.Identity
}

function Invoke-VmfFacadeSkipVm {
    <#
    .SYNOPSIS
        SKIP-ONE-1: leave ONE machine out, so the rest of the wave finishes.
    .DESCRIPTION
        A wave could not get past a parked machine, and the page had no way
        to skip that one machine in the wave.

        Gated on the operator, like every other action that changes something.
        The machine is not touched in Azure - this records that it will not
        migrate in this run, and frees it for another one.

        EVERY REFUSAL IS THE ENGINE'S. A machine a worker is driving right
        now, one that already migrated, one this run does not hold: Skip-VmfVm
        decides all of them, so the API path cannot route around any of it.
        This adds the role check and the identity, nothing else.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Note,
        # POWER-ONLY-CHANGED-1: the run and its project, to start the engine
        # operation that returns the machine to its power state.
        [Parameter()][string]$RunId,
        [Parameter()][string]$Project
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    $identity = if ($Principal -and $Principal.Identity) { [string]$Principal.Identity } else { 'unknown' }

    $result = try {
        & (Get-Module VmMigrationFactory) { param($rp, $id, $why, $who)
            Skip-VmfVm -RunPath $rp -VmId $id -Reason $why -SkippedBy $who -Confirm:$false
        } $StorePath $VmId $Note $identity
    }
    catch {
        # "It is still working", "it already migrated", "it is not in this
        # plan" are ANSWERS for the person, not server faults - each one tells
        # them what to do next.
        if ("$_" -match 'still working|already migrated|not in this') { throw "400: $_" }
        throw
    }
    # POWER-ONLY-CHANGED-1: a machine whose power state the product changed
    # and did not return is returned by the engine, which then gives back the
    # claim.
    Add-VmfFacadePowerReturn -Principal $Principal -Result $result -RunId $RunId -Project $Project -VmId ([string]$result.VmId) -Note $Note
}

function Invoke-VmfFacadeResolve {
    <#
    .SYNOPSIS
        S3-2: resolve a parked/held machine AS THE VALIDATED USER - per-VM
        policy override + audited re-arm.
    .DESCRIPTION
        Two role rules (DECIDE-ROLE-1). Accept this and continue - ONE
        decision's accepting value and nothing else - needs Vmf.Approver or
        Vmf.Admin, and without Vmf.Operator or Vmf.Admin the engine accepts it
        only as the decision the machine waits for (-DecisionOnly). Every other
        request - a retry, any other setting - needs Vmf.Operator or Vmf.Admin,
        and an accepting value or a removed sign-off requirement needs the
        approver as well.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Note,
        [Parameter()][hashtable]$PolicyOverride,
        # RETRY-1: omitted by the dashboard now - the engine derives where a
        # retry re-enters. Still accepted so an engineer can force it.
        [Parameter()][ValidateSet('PRECHECK', 'VALIDATING')][string]$ReturnTo
        # REBUILD-REMOVE-ACCEPT-1: no account and no list of extensions - no
        # decision accepts an identity loss or a rebuild any more.
    )
    # DECIDE-ROLE-1: which ACTION this request is decides which role it needs.
    # Accept this and continue - a decision's accepting value, and nothing
    # else - is the approver's alone (OWNER-QUESTIONS-1 row 26). The page
    # offered it to an approver, and this asked for the operator role first,
    # so an approver who was not an operator saw the button and got a 403.
    # Every other request keeps the operator gate it had: a plain retry, any
    # other setting, a gate put back, a decision sent WITH another setting
    # (or the decision would carry it past this gate), more than one decision
    # at once, and a forced -ReturnTo. The approver's own checks below still
    # run for every request.
    #
    # A value counts as accepting only when it is exactly the accepting text:
    # one string, compared ORDINALLY - character for character, as the engine
    # and the plan contract compare it. Anything else is not a decision here,
    # and the engine refuses it as a value no setting takes. The three must
    # change together: a value this side does not count as accepting skips
    # the approver check, so the engine must refuse it too.
    $decisions = Get-VmfDecisionLevers
    $accepting = @(if ($PolicyOverride) {
        foreach ($key in @($PolicyOverride.Keys)) {
            if (-not $decisions.ContainsKey($key)) { continue }
            $rule = $decisions[$key]
            $sentValue = $PolicyOverride[$key]
            if ($rule.approver -and $sentValue -is [string] -and
                [string]::Equals($sentValue, [string]$rule.accept, [System.StringComparison]::Ordinal)) { $key }
        }
    })
    $acceptOnly = @($PolicyOverride.Keys).Count -eq 1 -and $accepting.Count -eq 1 -and -not $ReturnTo
    $operates = Test-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    if (-not $acceptOnly) {
        Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    }
    elseif (-not $Principal) { throw '401: sign in required' }
    # DISCARD-ENGINE-1 S2: a retry takes new safety copies the delete never saw.
    Assert-VmfFacadeNotBeingDeleted -StorePath $StorePath
    # APPR-LEVER-1: the same lever, one machine at a time. -PolicyOverride
    # writes any lever onto one machine's plan entry, and the sign-off
    # requirement is one of them (Get-VmfPolicyLevers), so a wave could be
    # emptied of its gate one parked machine at a time.
    if ($PolicyOverride -and $PolicyOverride.ContainsKey('requireApproval')) {
        $lowered = @(Get-VmfFacadeApprovalRemovals -StorePath $StorePath -Requested @{ $VmId = $PolicyOverride['requireApproval'] })
        if ($lowered.Count -gt 0 -and -not (Test-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Approver', 'Vmf.Admin'))) {
            throw ("403: only an approver can remove the sign-off requirement. " +
                   "'$($Principal.Identity)' holds [$(@($Principal.Roles) -join ', ')]. " +
                   "Ask a user with the Approver role to make this change.")
        }
    }
    # DECIDE-1: a stop whose kind is `decision` is not a fault. Accepting it
    # writes a lever onto ONE machine's plan entry, and what it accepts cannot
    # be undone - a rebuilt machine's old identity does not come back. That is
    # a risk acceptance, not an operational retry, so it needs the approver.
    # Since 2026-09-11 the approver is the role that accepts a risk.
    #
    # The levers and the accepting values are read from data/stop-reasons.json,
    # so a decision added there arrives GATED rather than open. Only the
    # accepting value is held back: setting the lever the other way parks the
    # machine, which takes nothing away and needs no approver.
    foreach ($key in $accepting) {
        $rule = $decisions[$key]
        if (-not (Test-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Approver', 'Vmf.Admin'))) {
            throw ("403: only an approver can accept this. Setting '$key' to " +
                   "'$($rule.accept)' accepts a known consequence for this machine, which only an approver may do. " +
                   "'$($Principal.Identity)' holds [$(@($Principal.Roles) -join ', ')]. " +
                   "Ask a user with the Approver role to make this decision.")
        }
    }
    $params = @{
        RunPath = $StorePath; PlanPath = (Get-VmfFacadePlanPath -StorePath $StorePath)
        VmId = $VmId; Note = $Note; ResolvedBy = $Principal.Identity
        ResolvedRoles = @($Principal.Roles | ForEach-Object { [string]$_ })
    }
    # DECIDE-ROLE-1: without the operator role, the decision is all this call
    # may do. Anything else it can do re-arms the machine, and a retry is the
    # operator's. So the engine checks the decision against the stop that
    # parked the machine, on the state it reads before it writes anything:
    # the machine waits for a decision, the change names that decision's
    # setting alone, and the value is its accepting one. The check and the
    # state change are not one step, so it is as current as that read.
    if (-not $operates) { $params.DecisionOnly = $true }
    if ($ReturnTo) { $params.ReturnTo = $ReturnTo }
    if ($PolicyOverride) { $params.PolicyOverride = $PolicyOverride }
    # SCHEDULE-PASS-DUE-1: Resolve-VmfDecision marks the run for the five-minute
    # pass after it saves the decision (Add-VmfRunScheduleDue).
    Resolve-VmfDecision @params
}

function Invoke-VmfFacadeTidyAbandonedRuns {
    <#
    .SYNOPSIS
        REAPER-1: remove scans nobody finished (Vmf.Operator).
    .DESCRIPTION
        Thin. The engine decides which runs qualify - setup stage only, older
        than the cutoff, and an unreadable date means KEEP - and none of that
        is restated here.

        `preview` is the default from the app: a person sees exactly which
        scans would go, and how old each one is, before anything is removed.
        Nothing about this is automatic; there is no timer that calls it.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][int]$OlderThanDays = 30,
        [Parameter()][switch]$Apply
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    if ($OlderThanDays -lt 1 -or $OlderThanDays -gt 3650) { throw '400: the age must be between 1 and 3650 days' }
    $identity = if ($Principal -and $Principal.Identity) { [string]$Principal.Identity } else { 'unknown' }

    & (Get-Module VmMigrationFactory) { param($root, $days, $who, $apply)
        if ($apply) {
            Remove-VmfAbandonedRuns -StorePath $root -OlderThanDays $days `
                -Reason 'abandoned setup, cleared from the dashboard' -RemovedBy $who -Confirm:$false
        } else {
            Remove-VmfAbandonedRuns -StorePath $root -OlderThanDays $days -RemovedBy $who -WhatIf
        }
    } $StorePath $OlderThanDays $identity ([bool]$Apply)
}

function Invoke-VmfFacadeSetMachineTarget {
    <#
    .SYNOPSIS
        WAVE-MIX-2: change one machine's size series after planning
        (Vmf.Operator).
    .DESCRIPTION
        Thin, like every wrapper here: the recompute and every refusal live in
        Set-VmfMachineTarget. The identity comes from the validated principal,
        never the body. A preview writes nothing; an apply REQUIRES the plan
        version the page read (PLANVER-2), because the browser is where the
        race with another editor lives.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][AllowEmptyString()][string]$Option = '',
        [Parameter()][AllowEmptyString()][string]$PlanVersion = '',
        [Parameter()][switch]$Preview,
        # RETRY-SERIES-1: a machine that rolled back, given this series so it
        # can be tried again on it.
        [Parameter()][switch]$AfterRollback
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    if (-not $VmId) { throw '400: the machine is required' }
    if (-not $Preview) {
        if ($Option -notin @('v5', 'v6', 'v7')) { throw '400: the size series must be v5, v6 or v7' }
        if (-not $PlanVersion) { throw '400: the version of the plan being changed is required' }
    }
    $identity = [string]$Principal.Identity
    if (-not $identity) { throw '401: a target change must name the signed-in person' }

    & (Get-Module VmMigrationFactory) { param($rp, $id, $opt, $ver, $who, $preview, $afterRollback)
        if ($preview) {
            Set-VmfMachineTarget -RunPath $rp -VmId $id -ChangedBy $who -AfterRollback:$afterRollback -WhatIf
        } else {
            Set-VmfMachineTarget -RunPath $rp -VmId $id -Option $opt -ExpectedPlanVersion $ver -ChangedBy $who -AfterRollback:$afterRollback -Confirm:$false
        }
    } $StorePath $VmId $Option $PlanVersion $identity ([bool]$Preview) ([bool]$AfterRollback)
}

function Invoke-VmfFacadeSetWaves {
    <#
    .SYNOPSIS
        WAVE-1 phase 2: save a hand-composed wave layout (Vmf.Operator).
        Every safety rule lives in the engine cmdlet, not here.

        The ONE exception is the sign-off requirement, and it is here because
        it is a question about the CALLER: only an approver may take it off.
        See Get-VmfFacadeApprovalRemovals.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        # WAVE-REMOVE-NOT-SAVED-1: may be empty - Delete on the last wave sends
        # no wave. A body with no list of waves at all is refused below.
        [Parameter()][AllowNull()][AllowEmptyCollection()]$Waves,
        [Parameter()][AllowEmptyString()][string]$Note = '',
        # PLAN-WRITE-RACE-1: the plan version the page read (PLANVER-2). The
        # wave editor sends it; a save from a page read before somebody else's
        # change is then refused, not written over it.
        [Parameter()][AllowEmptyString()][string]$PlanVersion = ''
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    if ($null -eq $Waves) { throw '400: a wave layout is required' }

    # JSON arrives as PSCustomObjects; the engine takes hashtables.
    $waveOf  = @{}  # vmId -> the wave whose save writes a judged value on it
    $layout = @{ waves = @(foreach ($w in @($Waves)) {
        $h = @{ name = [string]$w.name; vmIds = @($w.vmIds | ForEach-Object { [string]$_ }) }
        if ($w.capacityGate) { $h.capacityGate = [string]$w.capacityGate }
        # SIGNOFF-NULL-1: as sent. A [bool] cast here read 0 as off and the
        # text 'false' as on; the engine refuses anything but true or false.
        if ($null -ne $w.requireApproval) { $h.requireApproval = $w.requireApproval }
        # WAVE-2 phase C: the rest of the ruled levers travel too. Values are
        # validated by Set-VmfWavePlan, not here - one place decides what a
        # lever may be.
        if ($w.onDDataFound) { $h.onDDataFound = [string]$w.onDDataFound }
        # WAVE-KERNEL-LINE-1: the kernel choice is not a setting of a wave. It
        # travels as sent, so the engine refuses it by name rather than this
        # call dropping it in silence.
        if ($null -ne $w.onDriverBelowFloor) { $h.onDriverBelowFloor = $w.onDriverBelowFloor }
        # REBUILD-REMOVE-ACCEPT-1: "If a machine would get a new
        # system-assigned identity" is gone with the rebuild, so it does not
        # travel; the engine takes it from no wave save.
        if ($null -ne $w.keepSnapshotDays -and "$($w.keepSnapshotDays)" -ne '') { $h.keepSnapshotDays = $w.keepSnapshotDays }
        if ($null -ne $w.throttle -and "$($w.throttle)" -ne '') { $h.throttle = $w.throttle }              # SCALE-UX-1
        # WAVE-LEVER-OVERRIDE-1: the settings the person changed on the card,
        # each with the value the card showed. The engine writes a setting on
        # a machine that stays in its wave only when it is listed here.
        if ($null -ne $w.changed) {
            $c = @{}
            if ($w.changed -is [System.Collections.IDictionary]) { foreach ($k in @($w.changed.Keys)) { $c[[string]$k] = $w.changed[$k] } }
            else { foreach ($pr in @($w.changed.PSObject.Properties)) { $c[[string]$pr.Name] = $pr.Value } }
            $h.changed = $c
        }
        # WAVE-LEVER-RESET-1: the machines the person gave back the value of
        # the wave, per setting. The engine checks them by name and judges
        # them with every other write below.
        if ($null -ne $w.reset) {
            $rs = @{}
            if ($w.reset -is [System.Collections.IDictionary]) { foreach ($k in @($w.reset.Keys)) { $rs[[string]$k] = @($w.reset[$k] | ForEach-Object { [string]$_ }) } }
            else { foreach ($pr in @($w.reset.PSObject.Properties)) { $rs[[string]$pr.Name] = @($pr.Value | ForEach-Object { [string]$_ }) } }
            $h.reset = $rs
        }
        $h
    }) }

    # WAVE-LEVER-OVERRIDE-1: judge what the engine WILL WRITE, not what the
    # page sent. The page sends every setting its card shows, and a setting
    # the person did not change - or one a decision gave a machine - is not
    # written; judging the request asked for an approver over values nothing
    # would write, and judging nothing else would miss a value that is. One
    # rule, the engine's (Get-VmfWaveSettingWrites). Both ways to take a gate
    # off a machine are writes: changing it on its wave's card, and moving the
    # machine into a wave whose card has it off (a machine joining a wave takes
    # its settings).
    $judged = & (Get-Module VmMigrationFactory) { param($rp, $l) Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l } $StorePath $layout
    # PLAN-WRITE-RACE-1: the plan judged must be the plan the page read, and
    # the plan written - so a page that read another is told so (409) rather
    # than refused by a check made on a plan it never saw, and the writer
    # refuses a plan written after this judgement.
    if ($PlanVersion -and $judged.Version -and $PlanVersion -ne $judged.Version) {
        throw '409: The plan changed after this page read it. Load the page again, then make the change again.'
    }
    $writes = @($judged.Writes)
    $asked = @{}; $decided = @{}
    foreach ($wr in $writes) {
        if ($wr.Field -eq 'requireApproval') { $asked[$wr.VmId] = [bool]$wr.To; $waveOf[$wr.VmId] = $wr.Wave }
        elseif ($wr.Field -eq 'onDDataFound') {
            if (-not $decided.ContainsKey($wr.VmId)) { $decided[$wr.VmId] = @{} }
            $decided[$wr.VmId][$wr.Field] = [string]$wr.To
            $waveOf[$wr.VmId] = $wr.Wave
        }
    }

    # APPR-LEVER-1: an Operator may put the sign-off requirement ON a wave, and
    # only an approver may take it OFF. Taking it off is the approval - the
    # engine's gate passes a wave whose entries do not ask for one - and the
    # approve endpoint refuses an Operator on purpose.
    $lowered = @(Get-VmfFacadeApprovalRemovals -StorePath $StorePath -Requested $asked)
    if ($lowered.Count -gt 0 -and -not (Test-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Approver', 'Vmf.Admin'))) {
        $named = @($lowered | ForEach-Object { $waveOf[$_] } | Sort-Object -Unique) -join ', '
        throw ("403: only an approver can remove the sign-off requirement. " +
               "'$($Principal.Identity)' holds [$(@($Principal.Roles) -join ', ')]. " +
               "Ask a user with the Approver role to change $named, or leave the requirement on.")
    }

    # DECIDE-2: and the same rule for the three "stop and ask" gates. Moving
    # one to its accepting value accepts a known loss for every machine the
    # wave names - the same act the machine's own panel offers one at a time,
    # which DECIDE-1 gave to the approver. Gating one place and not the other
    # would leave the wider action as the easier one.
    $taken = @(Get-VmfFacadeDecisionsTaken -StorePath $StorePath -Requested $decided)
    if ($taken.Count -gt 0 -and -not (Test-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Approver', 'Vmf.Admin'))) {
        $levers = @($taken | ForEach-Object { $_.Lever } | Sort-Object -Unique) -join ', '
        $waves  = @($taken | ForEach-Object { $waveOf[$_.VmId] } | Sort-Object -Unique) -join ', '
        throw ("403: only an approver can accept this for a wave. Setting $levers on " +
               "$waves accepts a loss $($taken.Count) machine(s) cannot get back. " +
               "'$($Principal.Identity)' holds [$(@($Principal.Roles) -join ', ')]. " +
               "Ask a user with the Approver role to make this decision.")
    }

    Set-VmfWavePlan -RunPath $StorePath -PlanPath (Get-VmfFacadePlanPath -StorePath $StorePath) `
        -Layout $layout -ChangedBy $Principal.Identity -Note $Note -ExpectedPlanVersion $(if ($PlanVersion) { $PlanVersion } else { [string]$judged.Version })
}

function Invoke-VmfFacadeSchedule {
    <#
    .SYNOPSIS
        SCHED-1: schedule a wave for later, or cancel a scheduled one
        (Vmf.Operator). Scheduling is not approving - the engine's sign-off
        gate still stands between a schedule and a running wave.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][string]$RunAtUtc,
        [Parameter()][switch]$Cancel,
        [Parameter()][int]$WindowMinutes,
        [Parameter()][AllowEmptyString()][string]$Note = ''
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    if ($Cancel) {
        return Remove-VmfWaveSchedule -RunPath $StorePath -Wave $Wave -CancelledBy $Principal.Identity -Note $Note
    }
    if (-not $RunAtUtc) { throw '400: a time to start is required' }
    if (-not $Note) { throw '400: scheduling a wave requires a note explaining the action' }
    # SCALE-UX-1: a number the engine cannot run is refused NOW, not when the
    # schedule releases at three in the morning with nobody watching. The
    # environment's own ceiling only matters above 7, so the job is read
    # only then.
    # SCALE-2: the number is split over containers; the ceiling is 60; and
    # the environment must have the cores - asked now, not at three in the
    # morning. One job read serves both.
    # MACHINES-AT-ONCE-RANGE-1: the number is the WAVE's own (one setting per
    # wave, on the wave editor). A schedule takes none: when the time comes,
    # the wave starts at its number as it is then.
    $Throttle = Get-VmfFacadeWaveThrottle -StorePath $StorePath -Wave $Wave
    Get-VmfFacadeWaveContainers -Workers $Throttle | Out-Null
    $schedJob = $null
    try { $schedJob = Get-VmfFacadeEngineJob } catch { Write-Warning "the engine job could not be read while scheduling: $($_.Exception.Message)" }
    if ($schedJob) {
        Get-VmfFacadeWaveContainers -Workers $Throttle -ConsumptionOnly:(Test-VmfFacadeConsumptionOnly -Job $schedJob) | Out-Null
        Assert-VmfFacadeEngineCapacity -Workers $Throttle -Job $schedJob | Out-Null
    }
    $when = [datetime]::MinValue
    if (-not [datetime]::TryParse($RunAtUtc, [ref]$when)) { throw '400: that start time is not a valid date and time' }
    $params = @{ RunPath = $StorePath; Wave = $Wave; RunAtUtc = $when
                 ScheduledBy = $Principal.Identity; Note = $Note }
    if ($WindowMinutes) { $params.WindowMinutes = $WindowMinutes }
    # SCHEDULE-PASS-DUE-1: Set-VmfWaveSchedule marks the run for the five-minute
    # pass after it saves the schedule (Add-VmfRunScheduleDue).
    Set-VmfWaveSchedule @params
}

function Invoke-VmfFacadeReleaseDueSchedules {
    <#
    .SYNOPSIS
        SCHED-1: start any wave whose scheduled time has arrived. Called by
        the timer, and deliberately separable from it so the decisions are
        testable without a clock.

        A due wave that still needs sign-off is LEFT ALONE and reported, not
        started - the approval gate sits ahead of the schedule, so a schedule
        can never be a way around it. It stays pending, so approving later
        lets it go on a subsequent pass.

        SCHEDULE-START-ONCE-1: a wave starts once. The start goes on record
        in the schedule before it is made (Set-VmfScheduleStartRecord), with
        a start id the start carries to Azure; a schedule with a start on
        record is never started as a new one (Private/state/ScheduleStart.ps1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][datetime]$AsOf = (Get-Date).ToUniversalTime()
    )

    $released = @()
    $m = Get-Module VmMigrationFactory
    # SCHEDULE-START-ONCE-1: every schedule of the run from one listing, with
    # the version this pass judges: the due ones, and the ones with a start on
    # record (Get-VmfScheduleStep).
    foreach ($item in @(& $m { param($rp, $t) Get-VmfScheduleStep -RunPath $rp -AsOf $t } $StorePath $AsOf)) {
        $s = $item.Schedule
        $wave = [string]$item.Wave
        $version = [string]$item.Version
        # A start that is made is never made again. 'started': the wave
        # started, and only its start time is left. 'starting': Azure says
        # whether the start was made - an execution with its start id, in any
        # status. A list Azure does not give throws, and nothing starts.
        # SCHEDULE-WAVE-VERSION-1: while an engine run of this start goes on,
        # the schedule is that run's to settle - it removes it, or puts it
        # back to pending when the wave changed. The service never removes or
        # puts back a schedule then (-EngineRuns).
        if ($item.Step -eq 'started') {
            $live = $false
            try { $live = @(Get-VmfFacadeScheduleStartExecutions -StartId ([string]$s.startId) -Alive).Count -gt 0 }
            catch {
                Write-Warning "the runs of the scheduled start of wave $wave could not be listed, so its start time stays: $($_.Exception.Message)"
                continue
            }
            Complete-VmfFacadeScheduledStart -StorePath $StorePath -Wave $wave -Version $version -Executions @($s.executions) -Recorded -EarlierPass -EngineRuns:$live
            continue
        }
        if ($item.Step -eq 'starting') {
            $made = @(Get-VmfFacadeScheduleStartExecutions -StartId ([string]$s.startId))
            if ($made.Count) {
                $live = @(Get-VmfFacadeScheduleStartExecutions -StartId ([string]$s.startId) -Alive).Count -gt 0
                Complete-VmfFacadeScheduledStart -StorePath $StorePath -Wave $wave -Version $version -Executions $made -EarlierPass -EngineRuns:$live
                continue
            }
            # None listed, and the record is younger than the grace period: it
            # may belong to a pass that still starts the engine, or Azure does
            # not list that start yet. Left alone - no gates, no new id.
            # Asked on the service's own clock, the clock that wrote it.
            if (& $m { param($sc, $nw) Test-VmfScheduleStartFresh -Schedule $sc -NowUtc $nw } $s (Get-Date).ToUniversalTime()) { continue }
            # Older, and not made (Azure refused it, or the pass stopped before
            # it): the wave goes through every gate again, as a due wave.
        }
        # PLANRUN-1: the ENGINE's own approval gate, not "does a file exist".
        # It is what the wave will be judged by when it starts, it knows a
        # signed-off plan passes every wave in it, and it knows an approval for
        # an older plan version does not. A release it would then refuse is a
        # container started for nothing.
        # WAVE-APPROVE-1 (review 3): and the timer's own rule for a start
        # nobody presses (Get-VmfUnattendedStartRefusal), on the same text. A
        # wave set not to need approval that changed after the plan sign-off
        # passed the approval gate and started at its time, with no approver
        # looking; now it asks again, as the next wave of the plan does.
        # SCHEDULE-WAVE-VERSION-1: and the version of the wave in that text
        # (Get-VmfWaveVersion), which the start carries to the engine. The
        # engine refuses a start whose own read of the wave differs, as it
        # does for the next wave of a signed-off plan (WAVE-APPROVE-1).
        $gates = & (Get-Module VmMigrationFactory) { param($rp, $pp, $w)
            $text = Read-VmfTextDocument -Path $pp
            $approval = Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave $w -PlanText $text
            @{ Approval = $approval
               Unattended = $(if ($approval.Pass) { Get-VmfUnattendedStartRefusal -RunPath $rp -PlanText $text -Wave $w } else { $null })
               WaveVersion = $(if ($text) { Get-VmfWaveVersion -PlanText $text -Wave $w } else { '' }) }
        } $StorePath (Get-VmfFacadePlanPath -StorePath $StorePath) $wave
        $approvalGate = $gates.Approval
        # STEP-LOG-6: each line for a wave left scheduled goes through
        # Write-VmfStepLine. A line that cannot be written stopped the pass: a
        # wave already started this pass was not returned, and the next due
        # wave did not start. Now it is a warning in the service log.
        # Arch section 9: a wave that cannot finish inside its window must not
        # start - machines mid-migration when the window closes is worse than
        # a wave that never began.
        # SCHEDULE-STARTING-STUCK-1: each check that stops the start gives its
        # line here, and the wave stays scheduled ($held). The checks run in
        # the order they always did.
        $held = $null
        if ($s.windowMinutes) {
            $fit = Test-VmfWaveWindow -RunPath $StorePath -PlanPath (Get-VmfFacadePlanPath -StorePath $StorePath) `
                -Wave $wave -WindowMinutes ([int]$s.windowMinutes)
            if (-not $fit.Fits) { $held = @{ PutBack = $true; Line = "wave $wave was due to start but will not fit its window: $($fit.Reason)" } }
        }
        if (-not $held -and -not $approvalGate.Pass) {
            $held = @{ PutBack = $true; Line = "wave $wave was due to start but has not been approved - it stays scheduled until someone signs it off" }
        }
        if (-not $held -and $gates.Unattended) {
            $held = @{ PutBack = $true; Line = "wave $wave was due to start, but it changed after the plan was signed off. It does not start by itself, so it stays scheduled. To start it, select Cancel the scheduled start, then select Start this wave." }
        }
        # ENGINE-START-PART-1 review: a run of this wave goes on (Running or
        # Processing). The start would be refused, so the wave stays scheduled
        # and is asked again on the next pass, and the next due wave starts.
        # SCHEDULE-STARTING-STUCK-1 review: an old start record is NOT put
        # back here. The run may be THIS start, which Azure listed later than
        # the grace period; a put-back drops the start id, and the pending
        # schedule would start the wave again after that run. It stays
        # 'starting': the next pass finds the execution by the start id, or,
        # once the run ended with none of this start, checks the wave again.
        if (-not $held -and (Test-VmfFacadeEngineRunning -Operation 'wave' -RunId $RunId -Wave $wave)) { $held = @{ PutBack = $false; Line = $null } }
        if ($held) {
            # SCHEDULE-STARTING-STUCK-1: an old start record a check stopped
            # goes back to 'pending' before its line, as a due wave's first try
            # leaves it - so the page offers the cancel, the service accepts
            # it, and the line is true. Version-checked against the record the
            # pass judged (PLANVER-2). A stop after this write leaves a pending
            # schedule, which the next pass checks again as a due wave.
            if ($item.Step -eq 'starting' -and $held.PutBack) {
                $back = $false
                try { $back = [bool](& $m { param($rp, $w, $v) Reset-VmfScheduleStartRecord -RunPath $rp -Wave $w -Version $v } $StorePath $wave $version) }
                catch {
                    & $m { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'schedule' -Outcome warn -Detail $d } $StorePath `
                        "Wave $wave was due to start, but the service could not put its schedule back: $(([string]$_.Exception.Message).TrimEnd('.')). The service did not start the wave, and tries again on the next pass."
                    continue
                }
                if (-not $back) {
                    & $m { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'schedule' -Outcome warn -Detail $d } `
                        $StorePath "Wave $wave was due to start, but its schedule changed at the same time, so the service did not start it. The service reads the schedule again on the next pass."
                    continue
                }
            }
            if ($held.Line) {
                & $m { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'schedule' -Outcome warn -Detail $d } $StorePath $held.Line
            }
            continue
        }
        # SCHEDULE-START-ONCE-1: the start goes on record BEFORE it is made,
        # version-checked against the schedule this pass judged. A schedule
        # that changed since is not started; the next pass reads it again.
        $claim = & $m { param($rp, $w, $v) Set-VmfScheduleStartRecord -RunPath $rp -Wave $w -Version $v -Starting } $StorePath $wave $version
        if (-not $claim) {
            & $m { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'schedule' -Outcome warn -Detail $d } `
                $StorePath "Wave $wave was due to start, but its schedule changed at the same time, so the service did not start it. The service reads the schedule again on the next pass."
            continue
        }
        # A start that throws leaves the record 'starting': the next pass asks
        # Azure for the start id, so a start Azure made whose answer was lost
        # is not made again, and a start Azure refused is made again.
        # MACHINES-AT-ONCE-RANGE-1: no number here - the start reads the
        # wave's own number from the plan as it is now.
        $script:VmfScheduleStartId = $claim.StartId
        try {
            $r = Invoke-VmfFacadeStartEngine -Principal ([pscustomobject]@{ Identity = "schedule ($($s.scheduledBy))"; Roles = @('Vmf.Operator') }) `
                -Operation 'wave' -RunId $RunId -Wave $wave `
                -Note "scheduled start: $($s.note)" -WaveVersion ([string]$gates.WaveVersion)
        }
        finally { $script:VmfScheduleStartId = $null }
        # The engine runs now: nothing after this throws, and the wave is
        # returned as released. SCHEDULE-WAVE-VERSION-1: its start time stays
        # on record, for the engine run to remove or put back (-EngineRuns).
        $execs = @(@($r.executions) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if (-not $execs.Count -and $r.execution) { $execs = @([string]$r.execution) }
        Complete-VmfFacadeScheduledStart -StorePath $StorePath -Wave $wave -Version $claim.Version -Executions $execs -EngineRuns
        $released += [pscustomobject]@{ Wave = $wave; Execution = $r.execution; ScheduledBy = $s.scheduledBy }
    }
    @($released)
}

function Complete-VmfFacadeScheduledStart {
    <#
    .SYNOPSIS
        SCHEDULE-START-ONCE-1: after a scheduled start is made, record its
        executions in the schedule (state 'started') and remove the schedule.
        Never throws: the wave runs, and a start time left on record is
        removed by the next pass, which does not start the wave again.
    .PARAMETER Recorded
        The schedule already holds the executions (state 'started').
    .PARAMETER EarlierPass
        The start was made by an earlier pass, which stopped before it
        removed the start time.
    .PARAMETER EngineRuns
        SCHEDULE-WAVE-VERSION-1: an engine run of this start may still go on.
        The start carried the wave version the pass judged, and that run
        removes the start time when its own read of the wave is the same, or
        puts the schedule back to pending when it is not. So the start is
        recorded and the schedule is NOT removed: a removal here would lose
        the schedule of a wave the engine then refuses to start.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$Version,
        [Parameter()][AllowEmptyCollection()][string[]]$Executions = @(),
        [Parameter()][switch]$Recorded,
        [Parameter()][switch]$EarlierPass,
        [Parameter()][switch]$EngineRuns
    )
    $m = Get-Module VmMigrationFactory
    $names = @($Executions | Where-Object { $_ })
    $started = "Wave $Wave started at its scheduled time" +
        $(if ($names.Count -gt 1) { " (executions $($names -join ', '))" } elseif ($names.Count) { " (execution $($names[0]))" } else { '' })
    $why = $null
    $removeVersion = $Version
    if (-not $Recorded) {
        try {
            $rec = & $m { param($rp, $w, $v, $ex) Set-VmfScheduleStartRecord -RunPath $rp -Wave $w -Version $v -Executions $ex } $StorePath $Wave $Version $names
            if ($rec) { $removeVersion = $rec.Version }
        }
        catch { $why = $_.Exception.Message }
    }
    if ($EngineRuns) {
        # Said once, by the pass that made the start or first found it. A
        # record that failed stays 'starting': the next pass finds the start
        # in Azure by its id, and the engine settles either record.
        if ($Recorded) { return }
        $made = "The service started the engine for wave $Wave at its scheduled time" +
            $(if ($names.Count -gt 1) { " (executions $($names -join ', '))" } elseif ($names.Count) { " (execution $($names[0]))" } else { '' }) +
            $(if ($EarlierPass) { ' on an earlier pass' } else { '' }) + '.'
        $words = if ($why) { "$made The service could not record the start: $(([string]$why).TrimEnd('.')). It does not start the wave again." }
                 else { "$made The engine checks the wave again, and then removes the start time. If the wave changed, it does not start and it stays scheduled." }
        & $m { param($rp, $o, $d) Write-VmfStepLine -RunPath $rp -Step 'schedule' -Outcome $o -Detail $d } $StorePath $(if ($why) { 'warn' } else { 'info' }) $words
        return
    }
    $removed = $false
    try { $removed = [bool](& $m { param($rp, $w, $v) Remove-VmfStartedSchedule -RunPath $rp -Wave $w -Version $v } $StorePath $Wave $removeVersion) }
    catch { $why = $_.Exception.Message }
    if ($removed) {
        $words = if ($EarlierPass) { "$started on an earlier pass. The service removed its start time now, and did not start the wave again." }
                 else { "$started, and the service removed its start time." }
        & $m { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'schedule' -Outcome info -Detail $d } $StorePath $words
        return
    }
    if ($why) {
        & $m { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'schedule' -Outcome warn -Detail $d } $StorePath `
            "$started, but the service could not remove its start time: $(([string]$why).TrimEnd('.')). The service removes it on the next pass, and does not start the wave again."
        return
    }
    # Not removed and no error: the schedule changed or is gone, or another
    # writer held it. The start is said once, on the pass that made it; a
    # later pass reads the schedule again.
    if (-not $EarlierPass) {
        & $m { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'schedule' -Outcome info -Detail $d } $StorePath "$started."
    }
}

function Get-VmfFacadeWaveThrottle {
    <#
    .SYNOPSIS
        MACHINES-AT-ONCE-RANGE-1: how many machines at once a wave runs, read
        from its plan as stored now, by the engine's one rule
        (Get-VmfWaveThrottle). Every start and every schedule asks this; no
        request carries a number of its own.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$StorePath, [Parameter(Mandatory)][string]$Wave)
    & (Get-Module VmMigrationFactory) { param($rp, $w)
        $doc = Read-VmfPlanDocument -RunPath $rp -Depth 24
        Get-VmfWaveThrottle -Entries @(@($doc.entries) | Where-Object { [string]$_.wave -eq $w })
    } $StorePath $Wave
}

function Get-VmfFacadeEngineResources {
    <#
    .SYNOPSIS
        SCALE-UX-1: the engine container's size, from the one number the
        operator chooses - how many machines at once.
    .DESCRIPTION
        Since 2026-09-04 the container scales from one factor the user
        chooses: how many machines at once in a wave. A worker is one process that mostly waits on
        Azure: it uses almost no CPU and a few hundred megabytes of memory.

        MEASURED 2026-09-04 IN THE REAL CONTAINER (the SCALE-UX-1 drill,
        five workers, 2 CPU / 4 GiB, docs/evidence/scale-drill.json): a
        worker idles at 188 MB working set and settles at 525-542 MB while
        it migrates, 567 MB at its peak; the CONTAINER as a whole - the
        number the memory limit is enforced on - held 2,410 MB with five
        working, about 480 MB a worker all-in. The earlier budget of 300 MB
        rested on an idle local reading of 187 MB and was wrong: ten workers
        on 4 GiB would have run out of memory. So the budget is 500 MB a
        worker plus 400 MB for the orchestrator, on the size steps Container
        Apps offers (memory is twice the CPU count, in GiB):

            1-3 workers   1 CPU, 2 GiB   (today's shape; today's default of 3)
            4-7 workers   2 CPU, 4 GiB   (the largest on a legacy environment)
            8-15 workers  4 CPU, 8 GiB   (the largest one container can be)

        This is the size of ONE container, so above 15 is refused here. A
        wave of more machines at once runs on more than one container, up to
        60 (Get-VmfFacadeWaveContainers, SCALE-2), and asks this for each
        container's share. A Dedicated workload profile (D4: 16 GiB) would
        lift the per-container ceiling at an always-on cost; not done. The
        operator never sees a CPU or a gigabyte.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Workers,
        # MEASURED 2026-09-04 by the SCALE-UX-1 drill: a Container Apps
        # environment of the Consumption-only kind (no workload profiles -
        # what platform.bicep deploys today) refuses anything above 2 CPU and
        # 4 GiB for one container: "must add up to one of the following ...
        # [cpu: 2.0, memory: 4.0Gi]". The largest tier exists only on an
        # environment with workload profiles. The job says which kind it is
        # in (workloadProfileName is null on the Consumption-only kind).
        [Parameter()][switch]$ConsumptionOnly
    )
    if ($Workers -lt 1) { throw '400: how many machines at once must be at least 1' }
    if ($Workers -gt 15) {
        throw '400: at most 15 machines at once. One engine container runs 15 workers; more needs more than one container, which this version does not do.'
    }
    if ($ConsumptionOnly -and $Workers -gt 7) {
        throw '400: at most 7 machines at once on this installation. Its Container Apps environment is the Consumption-only kind, and one container there gets at most 2 CPU and 4 GiB. An environment with workload profiles allows 15.'
    }
    $tier = if ($Workers -le 3) { @{ cpu = '1'; memory = '2Gi' } }
            elseif ($Workers -le 7) { @{ cpu = '2'; memory = '4Gi' } }
            else { @{ cpu = '4'; memory = '8Gi' } }
    [pscustomobject]@{ workers = $Workers; cpu = $tier.cpu; memory = $tier.memory }
}

function Get-VmfFacadeWaveContainers {
    <#
    .SYNOPSIS
        SCALE-2: how many engine containers a wave needs for "this many
        machines at once", and each container's share of the workers.
    .DESCRIPTION
        Since 2026-09-05 workers scale out to more containers, not up to a
        larger one. One container runs at
        most 15 workers (measured, SCALE-DRILL-1: ~500 MB each in 8 GiB), or
        7 on a legacy Consumption-only environment. Above that the facade
        starts MORE CONTAINERS on the same wave; every container runs the
        same orchestrator against the same store, and the leases (an
        exactly-one-creator blob write per machine) keep them from ever
        touching the same machine. Shares are balanced: 40 at once is three
        containers of 14, 13 and 13.

        The ceiling is 60 (four containers of 15) in this version, set on
        2026-09-05. VMF_CONTAINER_MAX_WORKERS lowers the per-container
        share for a drill, so two containers can be proven on five machines.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Workers,
        [Parameter()][switch]$ConsumptionOnly
    )
    if ($Workers -lt 1) { throw '400: how many machines at once must be at least 1' }
    if ($Workers -gt 60) {
        throw '400: at most 60 machines at once. The engine runs up to four containers of 15 workers on one wave; more needs a larger environment, which this version does not do.'
    }
    $perMax = if ($ConsumptionOnly) { 7 } else { 15 }
    $forced = 0
    if ($env:VMF_CONTAINER_MAX_WORKERS -and [int]::TryParse([string]$env:VMF_CONTAINER_MAX_WORKERS, [ref]$forced) -and $forced -ge 1 -and $forced -lt $perMax) {
        $perMax = $forced
    }
    $containers = [int][math]::Ceiling($Workers / $perMax)
    $base = [int][math]::Floor($Workers / $containers)
    $extra = $Workers % $containers
    $shares = @(for ($i = 0; $i -lt $containers; $i++) { if ($i -lt $extra) { $base + 1 } else { $base } })
    [pscustomobject]@{ workers = $Workers; containers = $containers; perContainer = $shares; perContainerMax = $perMax }
}

function Get-VmfFacadeEngineCapacity {
    <#
    .SYNOPSIS
        SCALE-2: will this many machines at once fit the engine's own
        environment? Containers x cores against the environment's free
        Consumption cores, read live.
    .DESCRIPTION
        Since 2026-09-04 the quota check has two halves: the install checks
        the base worker, and the wave plan page checks again with the real
        machine count and scale. The
        Container Apps environment reports its Consumption cores in use and
        their limit (measured on the lab: ManagedEnvironmentConsumptionCores
        0 of 100). This is the wave-time half; the install checks the base.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Workers,
        [Parameter(Mandatory)]$Job
    )
    $legacy = Test-VmfFacadeConsumptionOnly -Job $Job
    $split = Get-VmfFacadeWaveContainers -Workers $Workers -ConsumptionOnly:$legacy
    $coresNeeded = 0.0
    foreach ($share in $split.perContainer) {
        $coresNeeded += [double](Get-VmfFacadeEngineResources -Workers ([int]$share) -ConsumptionOnly:$legacy).cpu
    }
    # What the environment says, when it can be asked. A read that fails is
    # NOT a refusal: the answer is "could not be read", said as such, and a
    # wave that truly does not fit is refused by Azure at the start with its
    # own error. Only a definite "does not fit" refuses here.
    $known = $false; $limit = $null; $inUse = $null; $free = $null; $reason = ''
    $envId = [string]$Job.properties.environmentId
    if (-not $envId) { $reason = 'the engine job names no environment' }
    else {
        try {
            $resp = Send-VmfFacadeArmRequest -Method GET -Path "$envId/usages?api-version=2024-03-01"
            if ($resp.StatusCode -ne 200) { $reason = "HTTP $($resp.StatusCode) reading the environment's usage" }
            else {
                $usage = @(($resp.Content | ConvertFrom-Json).value | Where-Object { $_.name.value -eq 'ManagedEnvironmentConsumptionCores' } | Select-Object -First 1)
                if (-not $usage) { $reason = 'the environment reported no Consumption cores usage' }
                else {
                    $limit = [double]$usage.limit
                    $inUse = [double]$usage.currentValue
                    $free = [math]::Max(0, $limit - $inUse)
                    $known = $true
                }
            }
        }
        catch { $reason = $_.Exception.Message }
    }
    [pscustomobject]@{
        workers     = $Workers
        containers  = $split.containers
        coresNeeded = $coresNeeded
        coresInUse  = $inUse
        coresLimit  = $limit
        coresFree   = $free
        known       = $known
        reason      = $reason
        fits        = $(if ($known) { $coresNeeded -le $free } else { $null })
    }
}

function Assert-VmfFacadeEngineCapacity {
    <#
    .SYNOPSIS
        SCALE-2: refuse a start or a schedule the environment cannot hold,
        in a sentence with the numbers to act on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Workers, [Parameter(Mandatory)]$Job)
    $cap = Get-VmfFacadeEngineCapacity -Workers $Workers -Job $Job
    if ($cap.known -and -not $cap.fits) {
        # MANUAL-REVIEW-1: sentences, with the count of containers said once.
        $containersSaid = if ([int]$cap.containers -eq 1) { '1 engine container' } else { "$($cap.containers) engine containers" }
        throw ("400: This wave needs $($cap.coresNeeded) cores for $containersSaid. The Container Apps environment has " +
               "$($cap.coresFree) of $($cap.coresLimit) Consumption cores free. Start fewer machines at once, or request a quota increase for the Consumption cores.")
    }
    $cap
}

function Get-VmfFacadeEngineJob {
    <#
    .SYNOPSIS
        The engine job's definition from ARM - its container template and the
        kind of environment it runs in.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $jobId = $env:VMF_ENGINE_JOB_ID
    if (-not $jobId) { throw 'Facade misconfigured: VMF_ENGINE_JOB_ID is not set (deploy the engine job first).' }
    $jobResp = Send-VmfFacadeArmRequest -Method GET -Path "$jobId`?api-version=2025-01-01"
    if ($jobResp.StatusCode -ne 200) { throw "Could not read the engine job: HTTP $($jobResp.StatusCode)" }
    $jobResp.Content | ConvertFrom-Json -Depth 20
}

function Test-VmfFacadeConsumptionOnly {
    <#
    .SYNOPSIS
        True when the engine job runs in a Consumption-only environment, where
        one container gets at most 2 CPU and 4 GiB (so at most 7 workers).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Job)
    $name = $Job.properties.PSObject.Properties['workloadProfileName'] ? [string]$Job.properties.workloadProfileName : ''
    [string]::IsNullOrWhiteSpace($name)
}

function Invoke-VmfFacadeStartEngine {
    <#
    .SYNOPSIS
        S3-4: start a hosted engine execution (Vmf.Operator) - assess, plan
        or wave - by starting the Container Apps Job with parameter overrides.
        Governance is unchanged: the ENGINE enforces the approval and capacity
        gates; this only launches it.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        # REBUILD-REMOVE-RECOVER-1: no 'rebuild'. Rebuild this machine is gone
        # with the rebuild around the same disks.
        [Parameter(Mandatory)][ValidateSet('assess', 'plan', 'wave', 'restore',
        # SWAP-REFUSED-AFTER-STOP-1: Finish the rollback / Finish the restore -
        # swap the data disks a refused swap left, then start the machine.
        'finish',
        # POWER-ONLY-CHANGED-1: return a machine whose power state the product
        # changed, and did not return, to the power state it was found in.
        'powerback',
        # REACH-1: the operations that used to be PowerShell only. REPORT-AUTO-1
        # removed the report operation: the engine writes the report by itself
        # when a wave finishes and when a machine is restored or rebuilt.
        'reserve', 'release', 'quota', 'retention',
        # QUOTA-BUTTON-1: check one wave's quota against Azure. Reads only.
        'quotacheck',
        # ADVISOR-1: the target options for each machine. Reads only.
        'advise',
        # DISCARD-ENGINE-1: delete a migration WITH its safety copies. The
        # service has no right to delete them; Invoke-VmfFacadeDiscardRun
        # checks the request and starts this.
        'discard',
        # RESTORE-EARLIER-DELETE-1: Delete these disks - the earlier managed
        # disks a restore kept, as its own record names them.
        'deleteearlier',
        # MADE-DISK-DELETE-1: Delete these disks now - the managed disks a
        # put-back made that the record says nothing uses.
        'deletemade',
        # VOLUMES-RESTORE-MIGRATED-1: Check the volumes - the check of the
        # volumes a retry runs first, with no move, for one machine whose
        # record owes it.
        'checkvolumes')][string]$Operation,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][string]$Wave,
        # PROJECT-1: which project the run belongs to. A SEPARATE field rather
        # than part of RunId, because the route cannot carry a slash - IIS
        # rejects an encoded one and the caller gets a bare 404. Measured.
        [Parameter()][string]$Project,
        [Parameter()][string[]]$ScopeRg,
        [Parameter()][string[]]$ScopeSubs,
        [Parameter()][string]$ScopeMg,
        # V7-UX-1: v6 or v7. Validated here rather than trusted from the body -
        # it becomes a size suffix, and an unchecked value would produce a target
        # that does not exist and a refusal nobody could explain.
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration,
        [Parameter()][ValidateSet('BestEffort', 'Reserved')][string]$CapacityGate,
        [Parameter()][ValidateSet('tags', 'resourceGroup', 'singleWave', 'none')][string]$WaveStrategy,
        [Parameter()][string]$AppGroupTag,
        # WAVE-SIZE-REMOVE-1: no wave size; each group is one wave.
        [Parameter()][string]$VmId,
        [Parameter()][ValidateSet('new', 'preserve')][string]$DiskNaming,
        # ROLLBACK-ORIGINALS-LEFT-1: deleteearlier only - which disks. restore
        # (the default): the earlier disks of the last restore; rollback: the
        # original disks rollbacks swapped off. The engine reads the disks
        # themselves from the record.
        [Parameter()][ValidateSet('restore', 'rollback')][string]$DiskSet,
        # RESTORE-COPY-1: which of the two safety copies a restore reads.
        # REBUILD-REMOVE-RECOVER-1: no 'disks', no RebuildAs and no
        # AcceptIdentityLoss - each was for a rebuild, and no operation
        # rebuilds a machine.
        [Parameter()][ValidateSet('pristine', 'prepared')][string]$DiskSource,
        [Parameter()][switch]$AcceptPreserveRisk,
        # MACHINES-AT-ONCE-RANGE-1: no number of machines at once. A wave
        # starts at its own number (below), whoever starts it.
        # A reason is required for actions that CHANGE something (starting a
        # wave). Scanning and planning read and compute only, so they are not
        # gated behind a justification.
        [Parameter()][AllowEmptyString()][string]$Note = '',
        # REACH-1 quota
        [Parameter()][int]$HeadroomVcpus,
        [Parameter()][switch]$WhatIfOnly,
        # WAVE-APPROVE-1 (review 4): the version of the wave a caller judged
        # (Get-VmfWaveVersion). The engine refuses the start when its own read
        # of the wave differs. The timer always sends it: the next wave of a
        # signed-off plan, and a scheduled start (SCHEDULE-WAVE-VERSION-1).
        [Parameter()][string]$WaveVersion
    )
    # ADVISOR-1: the target options follow the review, which an approver
    # makes. They read Azure's size list and change nothing, so the person who
    # approved the review may also ask for them again. Everything else changes
    # machines or spends money. Both branches are written out in full rather
    # than computed, because the role tests read these gates from source and a
    # gate they cannot read is a gate nobody is checking.
    if ($Operation -eq 'advise') {
        Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')
    }
    else {
        Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    }
    # RUNID-1: the run id is checked HERE as well, not only in
    # Get-VmfFacadeStorePath. This function reaches the store two ways: the
    # wave branch builds a path through that function, and every branch puts
    # the run id in VMF_RUN_ID, which the ENGINE CONTAINER then builds its own
    # store path from. A guard on one of those two is a guard on neither.
    $RunId = Resolve-VmfFacadeStoreKey -Path $RunId
    # SCOPE-SUBS-GUID-1: a scan scope subscription goes into a request path
    # (/subscriptions/<id>/providers/...), so only a subscription id passes - a
    # GUID, or /subscriptions/<GUID>, which goes on as the GUID alone, the form
    # every engine read takes. An empty value is refused too: dropped, it could
    # leave no subscription, and the engine then scans its own subscription.
    # Checked before anything is read or started. \z,
    # not $: $ also matches before a final new line. A presence test, not
    # if ($ScopeSubs): @('') is false, and an empty list is too, so both would
    # pass with no check.
    if ($null -ne $ScopeSubs) {
        if (@($ScopeSubs).Count -eq 0) { throw '400: The scopeSubs field has no subscription ID.' }
        $ScopeSubs = @(@($ScopeSubs) | ForEach-Object {
            $m = [regex]::Match([string]$_, '^(?:/subscriptions/)?(?<id>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\z', 'IgnoreCase')
            if (-not $m.Success) { throw '400: The scopeSubs field has a value that is not a subscription ID.' }
            $m.Groups['id'].Value
        })
    }
    if ($Operation -eq 'wave' -and -not $Wave) { throw '400: the wave operation requires a wave name' }
    if ($Operation -eq 'wave' -and -not $Note) { throw '400: starting a wave requires a note explaining the action' }
    if ($Operation -eq 'quotacheck' -and -not $Wave) { throw '400: checking the quota requires a wave name' }
    # REACH-1. Reserving spends money from the moment the reservation exists,
    # and releasing gives back a guarantee somebody may still be counting on -
    # so both name a wave and both record why, on the same bar as starting one.
    if ($Operation -in @('reserve', 'release')) {
        if (-not $Wave) { throw "400: the $Operation operation requires a wave name" }
        if (-not $Note) {
            $why = if ($Operation -eq 'reserve') { 'reserving capacity bills from the moment it is reserved' }
                   else { 'a release removes the capacity that the on-demand capacity reservation holds' }
            throw "400: $why, so it requires a note explaining the action"
        }
    }
    # DISCARD-ENGINE-1 S1: the generic route (POST runs/{id}/engine/discard)
    # would skip every check Invoke-VmfFacadeDiscardRun makes, the start line
    # the page shows and the one-at-a-time check. Only that function sets this.
    if ($Operation -eq 'discard' -and -not $script:VmfDiscardDispatch) {
        throw '400: a migration is deleted with Delete this migration, which checks it first - not by starting the engine directly'
    }
    # DISCARD-ENGINE-1: deleting safety copies cannot be undone, so it records
    # why, on the same bar as a restore.
    if ($Operation -eq 'discard' -and -not $Note) { throw '400: deleting a migration and its safety copies requires a note explaining the action' }

    if ($Operation -eq 'powerback') {
        # POWER-ONLY-CHANGED-1. It changes the power state of a machine, so it
        # records why. Leave this machine out and Stop this migration start it
        # with their own note; without a machine it is every machine of the
        # run whose power state is owed.
        if (-not $Note) { throw '400: returning a machine to its power state requires a note explaining the action' }
    }
    if ($Operation -eq 'finish') {
        # SWAP-REFUSED-AFTER-STOP-1. The same bar as a restore: it changes a
        # machine and starts it. The engine reads what is left from the
        # machine's record, so nothing else is taken from the caller.
        if (-not $VmId) { throw '400: finishing a rollback or a restore requires a machine' }
        if (-not $Note) { throw '400: finishing a rollback or a restore requires a note explaining the action' }
    }
    # RESTORE-EARLIER-DELETE-1: the engine reads which disks from the
    # restore's own record, so only the machine is taken from the caller. The
    # approved confirmation has no note field; who asked is recorded.
    if ($Operation -eq 'deleteearlier' -and -not $VmId) { throw '400: deleting the earlier managed disks of a restore requires a machine' }
    if ($DiskSet -and $Operation -ne 'deleteearlier') { throw "400: only the deleteearlier operation takes a set of disks, not $Operation" }
    # MADE-DISK-DELETE-1: the same - the engine reads which disks from the
    # machine's record (Get-VmfDeletableMadeDisks).
    if ($Operation -eq 'deletemade' -and -not $VmId) { throw '400: deleting the managed disks made from the safety copies requires a machine' }
    # VOLUMES-RESTORE-MIGRATED-1: the engine reads what the check owes from the
    # machine's record, so only the machine is taken from the caller.
    if ($Operation -eq 'checkvolumes' -and -not $VmId) { throw '400: checking the volumes requires a machine' }
    if ($Operation -eq 'restore') {
        if (-not $VmId) { throw '400: the restore operation requires a machine' }
        if (-not $Note) { throw '400: restoring a machine requires a note explaining the action' }
        if ($DiskNaming -eq 'preserve' -and -not $AcceptPreserveRisk) {
            throw '400: keeping the original disk name deletes the existing disk - the caller must accept that explicitly'
        }
    }
    # RETIRE-SCOPE-1 (reversing part of V3-RETIRE-1): the first copy restored
    # goes back to the size the machine had. From one
    # day before Microsoft retires that size, a return to it is outside the
    # scope of this tool: refused HERE, on RETRY-GATE-1's path (a 400 the
    # dialog shows as the sentence), before a job starts. Read from the
    # machine's record alone. The engine asks again before it stops anything;
    # a record this cannot read is left to it.
    # RESTORE-END-JOB-1: a resume of a restore that stopped part
    # way is not asked again - it passed when it started, and a stop part way
    # is never a reason to leave a machine part way.
    # FINISH-END-JOB-1: and a finish.
    $resumeId = if ($Operation -in @('restore', 'finish') -and $script:VmfResumeDispatch) { [string]$script:VmfResumeDispatch } else { '' }
    if (-not $resumeId -and $Operation -eq 'restore' -and $DiskSource -eq 'pristine') {
        $retireRefusal = try {
            & (Get-Module VmMigrationFactory) { param($rp, $id) Get-VmfPutBackRetirementRefusal -RunPath $rp -VmId $id } `
                (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId })) $VmId
        } catch { $null }
        if ($retireRefusal) { throw "400: $retireRefusal" }
        # PREVIEW-RESTORE-UPFRONT-1: the first copy of a move by the in-place
        # upgrade (Preview) goes back across the temporary disk kinds again,
        # which Azure allows only with the preview feature
        # VMTempDiskResizePreview registered. Refused HERE with the engine's
        # own decision and words (Get-VmfPreviewPutBackVerdict), when the
        # record says Preview, the feature reads not registered, and the
        # machine is not on its original size. Anything not read is left to
        # the engine, which asks again before it makes a disk or stops the
        # machine.
        $previewRefusal = try {
            & (Get-Module VmMigrationFactory) { param($rp, $id) Get-VmfPreviewPutBackRefusal -RunPath $rp -VmId $id } `
                (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId })) $VmId
        } catch { $null }
        if ($previewRefusal) { throw "400: $previewRefusal" }
    }
    # ASSESS-PAGE-1: planning creates a MIGRATION from an assessment, so it
    # needs a name for the thing it is about to create. Generated here rather
    # than in the engine because the CALLER has to be told what it is - the
    # wizard follows the operator to the new object, and without the id in the
    # response it would sit watching the assessment for a plan that is being
    # written somewhere else.
    $migrationId = $null
    if ($Operation -eq 'plan') {
        $migrationId = '{0}-migration-{1}' -f $RunId, (Get-Date -Format 'yyyyMMdd-HHmmss')
    }


    # The start API requires the full container spec when overriding env -
    # read the job definition and merge our parameters over its env.
    $job = Get-VmfFacadeEngineJob
    $jobId = $env:VMF_ENGINE_JOB_ID
    # TIMER-EXEC-LIST-1: every guard below reads Azure itself. Inside the
    # five-minute pass a list of the executions is kept for the pass; it is
    # emptied here, so this start never acts on it.
    Clear-VmfFacadeEngineList
    # DISCARD-ENGINE-1 S2: nothing that changes a machine starts on a
    # migration the engine is deleting.
    # Review 2 item 2: reserving bills from the moment it exists, and the delete
    # would remove the only record of it.
    if ($Operation -in @('wave', 'restore', 'finish', 'reserve', 'powerback', 'deleteearlier', 'deletemade', 'checkvolumes')) {
        Assert-VmfFacadeNotBeingDeleted -StorePath (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId }))
    }
    # ENGINE-START-PART-1: one engine run of a wave at a time. The page hides
    # Start while a machine of the wave has a state document (WAVE-GATE-1), but
    # a container that pulls its image has written none - after a part start,
    # or a second press - and the route does not ask the page. A second run
    # takes the machines the first has not leased and runs more at once than
    # the wave was set to. Asked of Azure, as a restore asks (a new execution
    # is Processing before it is Running); a list Azure does not give refuses
    # the start, as it does for a restore.
    if ($Operation -eq 'wave' -and (Test-VmfFacadeEngineRunning -Operation 'wave' -RunId $RunId -Project $Project -Wave $Wave)) {
        throw "400: Wave $Wave runs now. Wait until it ends."
    }
    # TARGET-OPTIONS-WAIT-1: one advise of an assessment at a time. A second
    # one writes target-advice.json again under a page that reads the first,
    # so its version changes and a save from that page is refused. Asked of
    # Azure, as a wave asks; a list Azure does not give refuses the start.
    if ($Operation -eq 'advise' -and (Test-VmfFacadeEngineRunning -Operation 'advise' -RunId $RunId -Project $Project)) {
        throw '400: The product makes the target options for this assessment now. Wait until the list of machines shows.'
    }

    # POWER-ONLY-CHANGED-1: a machine a wave or a restore holds now
    # is that job's; refused here with its sentence, as a restore is. The
    # engine takes the hold itself as well.
    if ($Operation -eq 'powerback' -and $VmId) {
        $powerHold = try {
            & (Get-Module VmMigrationFactory) { param($rp, $id) Get-VmfMachineLeaseRefusal -RunPath $rp -VmId $id } `
                (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId })) $VmId
        } catch { $null }
        if ($powerHold) { throw "400: $powerHold" }
    }
    # RESTORE-ONE-AT-A-TIME-1: one restore of a machine at a time.
    # Two starts each stopped the machine and swapped its disks, and one could
    # start it while the other swapped. Refused here, before a job starts, on
    # RETRY-GATE-1's path (a 400 the dialog shows as the sentence): while Azure
    # lists a restore of this machine - a new one is listed before
    # it takes its hold - and while a live hold stands on it (a wave worker, or
    # a restore whose job is past its start). The engine takes the hold itself
    # as well, so two starts that pass here together cannot both change it.
    # SWAP-REFUSED-AFTER-STOP-1: a finish of a rollback or a restore is one of
    # them - it swaps disks on the stopped machine and starts it.
    # RESTORE-EARLIER-DELETE-1: and Delete these disks, which deletes disks of
    # the machine under the same hold - refused where a restore is, and a
    # restore and a finish are refused while it runs.
    # MADE-DISK-DELETE-1: and Delete these disks now - the same hold, the same
    # refusals, both ways.
    # VOLUMES-RESTORE-MIGRATED-1: and Check the volumes, which can start the
    # machine and writes its record - the same hold, the same refusals.
    if ($Operation -in @('restore', 'finish', 'deleteearlier', 'deletemade', 'checkvolumes')) {
        if (Test-VmfFacadeEngineRunning -Operation @('restore', 'finish', 'deleteearlier', 'deletemade', 'checkvolumes') -RunId $RunId -Project $Project -VmId $VmId) {
            # MANUAL-REVIEW-1: the job Azure lists can be a restore, a finish or
            # a delete of disks, so the sentence names no one job.
            # PUTBACK-BUSY-WORDS-1 names the job.
            throw '400: The engine works on this machine now. Wait until that job ends, then try again.'
        }
        # A store this cannot read is left to the engine, which asks again.
        $holdRefusal = try {
            & (Get-Module VmMigrationFactory) { param($rp, $id) Get-VmfMachineLeaseRefusal -RunPath $rp -VmId $id } `
                (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId })) $VmId
        } catch { $null }
        if ($holdRefusal) { throw "400: $holdRefusal" }
        # RESTORE-END-JOB-1: a restore of this machine that did not
        # finish resumes by itself; a second job would start from a machine
        # that is part way. Only the timer's resume of that SAME job passes.
        $jobRefusal = try {
            & (Get-Module VmMigrationFactory) { param($rp, $id, $op)
                $recorded = Resolve-VmfRecordedVmId -RunPath $rp -VmId $id
                Get-VmfPutBackJobRefusal -Doc (Read-VmfStateDoc -RunPath $rp -VmId $recorded) -VmName (($recorded -split '/')[-1]) -OperationId $op
            } (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId })) $VmId $resumeId
        } catch { $null }
        if ($jobRefusal) { throw "400: $jobRefusal" }
        # MADE-DISK-DELETE-1: the engine's own refusal (a move that has not
        # ended, a restore that holds the disks, a refused swap), in its words,
        # before a job starts. The engine asks it again under the hold.
        # ROLLBACK-ORIGINALS-LEFT-1: and the same refusal for the original disks
        # of a rollback (Remove-VmfRestoreEarlierDisks -Set rollback asks it).
        if ($Operation -eq 'deletemade' -or ($Operation -eq 'deleteearlier' -and $DiskSet -eq 'rollback')) {
            $madeRefusal = try {
                & (Get-Module VmMigrationFactory) { param($rp, $id)
                    $recorded = Resolve-VmfRecordedVmId -RunPath $rp -VmId $id
                    Get-VmfMadeDiskDeleteRefusal -Doc (Read-VmfStateDoc -RunPath $rp -VmId $recorded) -VmName (($recorded -split '/')[-1])
                } (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId })) $VmId
            } catch { $null }
            if ($madeRefusal) { throw "400: $madeRefusal" }
        }
        # VOLUMES-RESTORE-MIGRATED-1: the engine's own refusal (a job works on
        # the machine, a data disk swap is left), in its words.
        if ($Operation -eq 'checkvolumes') {
            $volumesRefusal = try {
                & (Get-Module VmMigrationFactory) { param($rp, $id)
                    $recorded = Resolve-VmfRecordedVmId -RunPath $rp -VmId $id
                    Get-VmfVolumesCheckRefusal -Doc (Read-VmfStateDoc -RunPath $rp -VmId $recorded) -VmName (($recorded -split '/')[-1])
                } (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId })) $VmId
            } catch { $null }
            if ($volumesRefusal) { throw "400: $volumesRefusal" }
        }
        # RESTORE-MID-MOVE-1 (2026-10-19): a new restore of a
        # machine whose move has not ended is refused, also when its wave
        # stopped - in the engine's words, before a job starts. The timer's
        # resume of a restore finishes what it started.
        if ($Operation -eq 'restore' -and -not $resumeId) {
            $midMoveRefusal = try {
                & (Get-Module VmMigrationFactory) { param($rp, $id, $kind)
                    $recorded = Resolve-VmfRecordedVmId -RunPath $rp -VmId $id
                    Get-VmfPutBackMidMoveRefusal -Doc (Read-VmfStateDoc -RunPath $rp -VmId $recorded) -VmName (($recorded -split '/')[-1]) -Kind $kind
                } (Get-VmfFacadeStorePath -RunId $(if ($Project) { "$Project/$RunId" } else { $RunId })) $VmId $Operation
            } catch { $null }
            if ($midMoveRefusal) { throw "400: $midMoveRefusal" }
        }
    }

    $container = ($job.properties.template.containers)[0]

    # SCALE-UX-1 (wave editor): a wave starts at its accepted "how many at
    # once". MACHINES-AT-ONCE-RANGE-1: and at nothing else. The Run it step
    # and the start dialog each set a number for one start, so the screen and
    # the engine could disagree; a person now sets it in one place, the wave
    # settings, and every start - from a page, a schedule, the signed-off
    # plan or a resume - reads it here, by the one rule (Get-VmfWaveThrottle).
    # The wave editor refuses a change to a running wave, so a resume reads
    # the number the wave started with.
    $Throttle = 0
    if ($Operation -eq 'wave') {
        $planRunId = if ($Project) { "$Project/$RunId" } else { $RunId }
        $Throttle = Get-VmfFacadeWaveThrottle -StorePath (Get-VmfFacadeStorePath -RunId $planRunId) -Wave $Wave
    }

    $overrides = @(
        @{ name = 'VMF_OPERATION'; value = $Operation }
        @{ name = 'VMF_RUN_ID'; value = $RunId }
    )
    if ($Wave) { $overrides += @{ name = 'VMF_WAVE'; value = $Wave } }
    if ($Operation -eq 'wave' -and $WaveVersion) { $overrides += @{ name = 'VMF_WAVE_VERSION'; value = $WaveVersion } }
    # SCHEDULE-START-ONCE-1: the start id of a scheduled start. Azure keeps it
    # with the execution, where the next schedule pass looks for it
    # (Get-VmfFacadeScheduleStartExecutions). SCHEDULE-WAVE-VERSION-1: and the
    # engine reads it - it removes the schedule of this start when its read of
    # the wave is the version sent, and puts it back to pending when not.
    if ($Operation -eq 'wave' -and $script:VmfScheduleStartId) { $overrides += @{ name = 'VMF_SCHEDULE_START'; value = [string]$script:VmfScheduleStartId } }
    if ($migrationId) { $overrides += @{ name = 'VMF_MIGRATION_ID'; value = $migrationId } }
    if ($Project) {
        if ($Project -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$') {
            throw '400: that is not a project id - lower-case letters, numbers and hyphens'
        }
        $overrides += @{ name = 'VMF_PROJECT'; value = $Project }
    }
    if ($TargetGeneration) { $overrides += @{ name = 'VMF_TARGET_GENERATION'; value = $TargetGeneration } }
    # SCOPE-RG-LIST-1: one or many, joined the way the subscriptions are.
    if ($ScopeRg) { $overrides += @{ name = 'VMF_SCOPE_RG'; value = ((@($ScopeRg) | Where-Object { $_ }) -join ',') } }
    if ($null -ne $ScopeSubs) { $overrides += @{ name = 'VMF_SCOPE_SUBS'; value = (@($ScopeSubs) -join ',') } }   # SCOPE-1
    if ($ScopeMg) { $overrides += @{ name = 'VMF_SCOPE_MG'; value = $ScopeMg } }                        # SCOPE-1
    if ($CapacityGate) { $overrides += @{ name = 'VMF_CAPACITY_GATE'; value = $CapacityGate } }         # CAP-3
    if ($WaveStrategy) { $overrides += @{ name = 'VMF_WAVE_STRATEGY'; value = $WaveStrategy } }         # WAVE-1
    if ($AppGroupTag) { $overrides += @{ name = 'VMF_APP_TAG'; value = $AppGroupTag } }                 # WAVE-1
    # SCALE-2: a wave's "at once" is split over containers (below); each
    # container gets its own share as VMF_THROTTLE, the total, and its place.
    $split = if ($Operation -eq 'wave') { Get-VmfFacadeWaveContainers -Workers $Throttle -ConsumptionOnly:(Test-VmfFacadeConsumptionOnly -Job $job) } else { $null }
    # SCALE-2: and the environment must have the cores for those containers,
    # checked again here because another wave may have started since the
    # editor asked.
    if ($split) { Assert-VmfFacadeEngineCapacity -Workers $Throttle -Job $job | Out-Null }
    # REACH-1. Reserve and release name a wave like a wave start does; the
    # engine reads the capacity resource group from its own configuration
    # rather than from the caller, because a reservation created somewhere a
    # caller chose is one nobody thinks to look for when it is billing.
    if ($Operation -in @('reserve', 'release', 'retention', 'discard')) {
        $overrides += @{ name = 'VMF_RESTORED_BY'; value = [string]$Principal.Identity }
        $overrides += @{ name = 'VMF_NOTE'; value = $Note }
    }
    if ($Operation -eq 'quota') {
        if ($HeadroomVcpus) { $overrides += @{ name = 'VMF_QUOTA_HEADROOM'; value = "$HeadroomVcpus" } }
        if ($WhatIfOnly) { $overrides += @{ name = 'VMF_QUOTA_WHATIF'; value = 'true' } }
    }
    # RESTORE-END-JOB-1: the operation id of the restore or finish this starts
    # again. The engine takes everything else from that job's record.
    if ($resumeId) { $overrides += @{ name = 'VMF_RESUME_ID'; value = $resumeId } }
    if ($Operation -eq 'powerback') {                                                                  # POWER-ONLY-CHANGED-1
        if ($VmId) { $overrides += @{ name = 'VMF_VM_ID'; value = $VmId } }
        $overrides += @{ name = 'VMF_RESTORED_BY'; value = [string]$Principal.Identity }
        $overrides += @{ name = 'VMF_NOTE'; value = $Note }
    }
    if ($Operation -eq 'checkvolumes') {                                                               # VOLUMES-RESTORE-MIGRATED-1
        $overrides += @{ name = 'VMF_VM_ID'; value = $VmId }
        $overrides += @{ name = 'VMF_RESTORED_BY'; value = [string]$Principal.Identity }
    }
    if ($Operation -in @('deleteearlier', 'deletemade')) {                                             # RESTORE-EARLIER-DELETE-1, MADE-DISK-DELETE-1
        $overrides += @{ name = 'VMF_VM_ID'; value = $VmId }
        $overrides += @{ name = 'VMF_RESTORED_BY'; value = [string]$Principal.Identity }
        if ($DiskSet) { $overrides += @{ name = 'VMF_DISK_SET'; value = $DiskSet } }                    # ROLLBACK-ORIGINALS-LEFT-1
    }
    if ($Operation -eq 'finish') {                                                                     # SWAP-REFUSED-AFTER-STOP-1
        $overrides += @{ name = 'VMF_VM_ID'; value = $VmId }
        $overrides += @{ name = 'VMF_RESTORED_BY'; value = [string]$Principal.Identity }
        $overrides += @{ name = 'VMF_NOTE'; value = $Note }
    }
    if ($Operation -eq 'restore') {                                                                    # RESTORE-1
        $overrides += @{ name = 'VMF_VM_ID'; value = $VmId }
        $overrides += @{ name = 'VMF_RESTORED_BY'; value = [string]$Principal.Identity }
        $overrides += @{ name = 'VMF_NOTE'; value = $Note }
        if ($DiskNaming) { $overrides += @{ name = 'VMF_DISK_NAMING'; value = $DiskNaming } }
        if ($AcceptPreserveRisk) { $overrides += @{ name = 'VMF_ACCEPT_PRESERVE_RISK'; value = 'true' } }
        # RESTORE-COPY-1: WHICH safety copy. Declared, sent by the dashboard and
        # DROPPED HERE, so every restore took the engine's default - the
        # prepared copy - and the pristine one could not be asked for from the
        # app at all. That is the second time this exact path has lost a field
        # between the caller and the job: see EVAL-H6 in PostStartEngine.
        if ($DiskSource) { $overrides += @{ name = 'VMF_DISK_SOURCE'; value = $DiskSource } }
    }
    $overrideNames = @($overrides | ForEach-Object { $_.name })
    $baseEnv = @($container.env | Where-Object { $_.name -notin $overrideNames } |
        ForEach-Object { @{ name = $_.name; value = $_.value } })

    # StartJobExecutionTemplate: containers at TOP level, no template wrapper
    # (found live - the ARM API rejects the wrapped shape).
    # SCALE-UX-1: a wave's container is sized from its worker count; every
    # other operation keeps the job's own size.
    # SCALE-2: one execution per container. A wave of 40 is three containers
    # of 14, 13 and 13, each sized for its own share; every other operation
    # is one container at the job's own size.
    $starts = if ($split) {
        for ($i = 0; $i -lt $split.containers; $i++) {
            $share = [int]$split.perContainer[$i]
            $sized = Get-VmfFacadeEngineResources -Workers $share -ConsumptionOnly:(Test-VmfFacadeConsumptionOnly -Job $job)
            @{ resources = @{ cpu = $sized.cpu; memory = $sized.memory }
               env = @(@{ name = 'VMF_THROTTLE'; value = "$share" },
                       @{ name = 'VMF_THROTTLE_TOTAL'; value = "$($split.workers)" },
                       @{ name = 'VMF_CONTAINER'; value = "$($i + 1)/$($split.containers)" }) }
        }
    }
    else { @(@{ resources = @{ cpu = $container.resources.cpu; memory = $container.resources.memory }; env = @() }) }
    $starts = @($starts)
    # ENGINE-START-PART-1: once one container runs, the engine runs. A later
    # container Azure refuses (or does not answer) is not a failed start: the
    # containers that run lease every machine of the wave between them, with
    # fewer workers at once. So the start is returned as a PART start that
    # names what runs and what does not, and no later container is asked for.
    # A refusal of the FIRST container is a failed start, as before: nothing
    # runs.
    $execNames = [System.Collections.Generic.List[string]]::new()
    $notStarted = [System.Collections.Generic.List[object]]::new()
    $workersStarted = 0
    # TIMER-EXEC-LIST-1: and emptied again once Azure was asked to start,
    # whatever its answer (a start whose answer is lost can still run), so the
    # next question of the pass reads Azure and sees this start.
    try {
        for ($i = 0; $i -lt $starts.Count; $i++) {
            $s = $starts[$i]
            $place = if ($split) { "$($i + 1)/$($split.containers)" } else { '1/1' }
            $share = if ($split) { [int]$split.perContainer[$i] } else { 0 }
            if ($notStarted.Count) {
                $notStarted.Add([pscustomobject]@{ container = $place; workers = $share
                    reason = "Not started, because Azure refused container $($notStarted[0].container)." })
                continue
            }
            $startBody = @{
                containers = @(@{
                    name      = $container.name
                    image     = $container.image
                    resources = $s.resources
                    env       = @($baseEnv + $overrides + $s.env)
                })
            } | ConvertTo-Json -Depth 10
            $refusal = $null
            try {
                $startResp = Send-VmfFacadeArmRequest -Method POST -Path "$jobId/start?api-version=2025-01-01" -Payload $startBody
                if ($startResp.StatusCode -notin @(200, 202)) { $refusal = "HTTP $($startResp.StatusCode) $($startResp.Content)" }
            }
            catch {
                if (-not $execNames.Count) { throw }
                $refusal = $_.Exception.Message
            }
            if ($refusal) {
                if (-not $execNames.Count) { throw "Engine start failed: $refusal" }
                $notStarted.Add([pscustomobject]@{ container = $place; workers = $share; reason = $refusal })
                continue
            }
            $execNames.Add([string]($startResp.Content | ConvertFrom-Json).name)
            $workersStarted += $share
        }
    }
    finally { Clear-VmfFacadeEngineList }
    $execNames = @($execNames)
    $exec = [pscustomobject]@{ name = $execNames[0] }
    $partStart = $notStarted.Count -gt 0
    $partWords = if ($partStart) {
        "Wave $Wave started in $($execNames.Count) of $($split.containers) containers, with $workersStarted of $($split.workers) machines at once. " +
        "Azure refused container $($notStarted[0].container): $($notStarted[0].reason)" +
        $(if ($notStarted.Count -gt 1) {
            $later = @($notStarted | Select-Object -Skip 1 | ForEach-Object { $_.container })
            " $(if ($later.Count -gt 1) { 'Containers' } else { 'Container' }) $($later -join ', ') did not start."
        } else { '' }) +
        ' The containers that run do all the machines of the wave. The service refuses a second start of the wave while it runs.'
    } else { $null }

    # Audit into the run store so the dashboard's activity feed shows WHO
    # launched WHAT - same trail as every other action.
    # PROJECT-1 + ASSESS-PAGE-1, and this audit write was getting BOTH wrong.
    #
    # Initialize-VmfRun writes the manifest ONLY IF ABSENT - first writer wins -
    # and this runs before the engine does. So it decided the manifest for every
    # run started from the app, using the DEFAULT kind: 'migration'. Every
    # assessment launched from the wizard was therefore born labelled a
    # MIGRATION and appeared on the wrong page. That is the operator-visible
    # half of "I see no assessments in the portal".
    #
    # And without the project it audited to the container root while the engine
    # worked inside the project, leaving a phantom empty run in the operator's
    # list for every scan.
    #
    # VMF_RUN_ID names the ASSESSMENT for assess and plan (the migration gets
    # its own id); for everything else it names the migration.
    $auditKind = if ($Operation -in @('assess', 'plan', 'advise')) { 'assessment' } else { 'migration' }
    $storeRunId = if ($Project) { "$Project/$RunId" } else { $RunId }
    $storePath = Get-VmfFacadeStorePath -RunId $storeRunId
    # ENGINE-START-PART-1: written AFTER the start, so a start Azure refuses
    # leaves no manifest of a run that never ran - and in its own handler,
    # because the engine runs now: a manifest that cannot be written must not
    # report the start as failed (the page would show an error, and a person
    # could start it again). The engine writes the manifest itself when it is
    # absent (Invoke-VmfAssessment, New-VmfPlan, Start-VmfWave), so a lost
    # write here costs a warning in the service log, which says so.
    try {
        & (Get-Module VmMigrationFactory) { param($rp, $rid, $kind, $proj)
            Initialize-VmfRun -RunPath $rp -RunId $rid -Kind $kind -Project $proj | Out-Null
        } $storePath $RunId $auditKind $Project
    }
    catch {
        Write-Warning ("The run manifest (run.json) of '$storeRunId' could not be written, and the engine runs (execution $($execNames -join ', ')): " +
                       "$($_.Exception.Message) The engine writes the manifest when it starts.")
    }
    # SCHEDULE-PASS-DUE-1: a wave, a restore or a finish can stop part way, and
    # the five-minute pass starts it again, removes the hold it left and starts
    # the next wave of a signed-off plan - so the run goes into the record of
    # the runs the pass checks, after the start, held there 15 minutes. The
    # engine runs now: a mark that cannot be written is a warning, and the
    # hourly check of every run finds the run.
    # SCAN-FAIL-SHOWN-1: and a scan. Its job can stop with no answer, and the
    # pass then ends the wizard's wait (Invoke-VmfFacadeEndSilentScan).
    if ($Operation -in @('wave', 'restore', 'finish', 'assess')) {
        & (Get-Module VmMigrationFactory) { param($r, $i) Add-VmfRunScheduleDue -StorePath $r -RunId $i -Reason 'engine' -EngineStart | Out-Null } (Get-VmfFacadeStorePath) $storeRunId
    }
    # STEP-LOG-6: the engine runs now, so a line that cannot be written must
    # not report the start as failed - the page would show an error for a start
    # that worked, and a person could start it again. The line goes through
    # Write-VmfStepLine: a lost one is a warning in the service log, with its
    # words, and the start is returned as made.
    # ENGINE-START-PART-1: a part start is said in the same line, as a warning,
    # with each execution that runs and each container that does not.
    # WAVE-ORDER-START-1: the line names the operation and, for a wave, the
    # wave. Until the engine takes a machine, nothing else in the store says
    # that a wave is starting, and the Migrations page offered Start again.
    # SCAN-FAIL-SHOWN-1: and every execution it made, so the five-minute pass
    # can tie an execution that ended with no answer to this start.
    $lineData = @{ operation = $Operation; executions = @($execNames) }
    if ($Operation -eq 'wave' -and $Wave) { $lineData.wave = $Wave }
    & (Get-Module VmMigrationFactory) { param($rp, $outcome, $detail, $data)
        Write-VmfStepLine -RunPath $rp -Step 'engine' -Outcome $outcome -Detail $detail -Data $data
    } $storePath $(if ($partStart) { 'warn' } else { 'start' }) ("hosted $Operation started by $($Principal.Identity)" +
                  $(if ($Note) { ": $Note" } else { '' }) +   # no note, no colon (seen live 2026-09-04)
                  $(if ($execNames.Count -gt 1) { " ($($execNames.Count) containers: executions $($execNames -join ', '))" } else { " (execution $($exec.name))" }) +
                  $(if ($partStart) { ". $partWords" } else { '' })) $lineData

    # camelCase, like every READ endpoint here already returns (runId, halted,
    # waves). PowerShell callers do not care - property access is
    # case-insensitive - but the dashboard is JavaScript and it does, and a
    # response that is PascalCase in one place and camelCase in another is a
    # trap nobody sees until a field silently reads as undefined.
    [pscustomobject]@{
        operation   = $Operation
        runId       = $RunId
        # ASSESS-PAGE-1: for a plan, the migration this created. The caller
        # follows it here; for every other operation it is null.
        migrationId = $migrationId
        execution   = [string]$exec.name
        # SCALE-2: every execution this start made, and how many containers.
        executions  = @($execNames)
        containers  = $execNames.Count
        startedBy   = [string]$Principal.Identity
        note        = $Note
        # ENGINE-START-PART-1: a wave Azure started in only some of its
        # containers - each container that does not run (its place, its
        # workers, why), the workers that run, and the sentence the run page
        # shows. A full start has none of them.
        partStart      = [bool]$partStart
        notStarted     = @($notStarted)
        workersStarted = $(if ($split) { $workersStarted } else { $null })
        message        = $partWords
    }
}

function Get-VmfFacadeScopeList {
    <#
    .SYNOPSIS
        SCOPE-1: the places the service can scan - subscriptions and
        management groups - so the scan dialog offers real choices instead of
        asking anyone to type an id. Enumerated AS THE FACADE's identity: in a
        single-package install the engine and facade are granted together
        (ONBOARD-1), so this approximates the engine's reach; the engine run
        itself remains the authority (it queries only its declared scope).
        A management-group listing failure is NOT fatal - many tenants do not
        grant it, and subscriptions alone are a working choice.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Principal)
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')

    $resp = Send-VmfFacadeArmRequest -Method GET -Path '/subscriptions?api-version=2022-12-01'
    if ($resp.StatusCode -ne 200) { throw "Could not list subscriptions: HTTP $($resp.StatusCode)" }
    $subs = @((($resp.Content | ConvertFrom-Json).value) | ForEach-Object {
        [pscustomobject]@{ id = $_.subscriptionId; name = $_.displayName }
    })

    # An empty list must never be how a permission gap is reported: when
    # the listing fails, say WHY so the picker can too.
    $mgs = @()
    $mgError = $null
    try {
        $mgResp = Send-VmfFacadeArmRequest -Method GET -Path '/providers/Microsoft.Management/managementGroups?api-version=2021-04-01'
        if ($mgResp.StatusCode -eq 200) {
            $mgs = @((($mgResp.Content | ConvertFrom-Json).value) | ForEach-Object {
                [pscustomobject]@{ id = $_.name; name = $_.properties.displayName }
            })
        }
        else { $mgError = "HTTP $($mgResp.StatusCode): $($mgResp.Content)" }
    }
    catch { $mgError = $_.Exception.Message }

    [pscustomobject]@{ subscriptions = $subs; managementGroups = $mgs; managementGroupsError = $mgError }
}

function Get-VmfFacadePreviewFeature {
    <#
    .SYNOPSIS
        TEMP-DISK-PREVIEW-1: is the preview feature VMTempDiskResizePreview
        registered on this subscription? For the targets step, which offers
        the in-place upgrade (Preview) only while it reads Registered, and
        reads it again with Check again.
    .DESCRIPTION
        A READ, as the web service's own identity (it holds the VMF Assessment
        role, which has Microsoft.Features/providers/features/read), so any
        role may ask. It never registers the feature (2026-11-02: tell,
        never register). read is false when Azure did not answer: the page
        then says the feature was not checked - never registered or not.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubscriptionId
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')
    if ($SubscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw '400: a subscription id is required' }
    $r = & (Get-Module VmMigrationFactory) { param($s) @{ Feature = (Get-VmfPreviewFeatureName); State = (Get-VmfPreviewFeatureState -SubscriptionId $s) } } $SubscriptionId
    [pscustomobject]@{
        subscriptionId   = $SubscriptionId
        subscriptionName = [string]$r.State.SubscriptionName
        namespace        = [string]$r.Feature.Namespace
        feature          = [string]$r.Feature.Name
        read             = [bool]$r.State.Read
        registered       = [bool]$r.State.Registered
        state            = $(if ($r.State.State) { [string]$r.State.State } else { $null })
        # PREVIEW-RG-SCOPE-1: the answer of Azure to a read that failed - its
        # HTTP status (0: no answer) and its error code ('' for none) - so the
        # targets step can say it. Never a reason to read registered or not.
        httpStatus       = [int]$r.State.Status
        errorCode        = [string]$r.State.ErrorCode
    }
}
function Get-VmfFacadeResourceGroupList {
    <#
    .SYNOPSIS
        SCOPE-1: resource groups in one subscription, for the scan dialog's
        picker (choosing a resource group should never mean typing its name).
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')
    if ($SubscriptionId -notmatch '^[0-9a-fA-F-]{36}$') { throw '400: a subscription id is required' }
    $resp = Send-VmfFacadeArmRequest -Method GET -Path "/subscriptions/$SubscriptionId/resourcegroups?api-version=2021-04-01"
    if ($resp.StatusCode -ne 200) { throw "Could not list resource groups: HTTP $($resp.StatusCode)" }
    @((($resp.Content | ConvertFrom-Json).value) | ForEach-Object {
        [pscustomobject]@{ id = $_.name; name = $_.name; location = $_.location }
    } | Sort-Object name)
}

function Get-VmfFacadeRunStateDocs {
    <#
    .SYNOPSIS
        FACADE-TIMER-QUEUE-1: every machine record of one run, read once.
    .DESCRIPTION
        The schedule timer gives the same records to the stalled-wave pass and
        the put-back pass. Each read every record itself, one store request a
        record, so one pass read each record two times, and the next-wave
        decision a third. MEASURED on the lab installation, 2026-11-02: a pass
        took 60 to 133 seconds.
        A record that cannot be read is left out, as each pass left it out.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StorePath)
    @(& (Get-Module VmMigrationFactory) { param($rp)
            foreach ($name in Get-VmfStoreNames -RunPath $rp -Folder 'state' -Extension '.json') {
                $doc = Read-VmfStoreJson -RunPath $rp -RelPath "state/$name" -Depth 24
                if ($doc) { $doc }
            }
        } $StorePath)
}

function Invoke-VmfFacadeResumeStalledWaves {
    <#
    .SYNOPSIS
        RESUME-1: start a new engine execution for any wave that is mid-flight
        with nobody working on it.
    .DESCRIPTION
        The engine is resumable: every step checkpoints, and a fresh execution
        picks each machine up from its state document. What was missing was
        anything that STARTED that fresh execution. An execution that died -
        the job's replica timeout, a platform restart, an image defect - left
        the wave exactly where it stopped, for ever, until a person noticed.
        That was too fragile.

        A wave is STALLED when all of these hold:
          - it has at least one machine in a working state PAST PLANNED, or
            one that a stopped execution of the wave took before its check
            started (WAVE-RESUME-PLANNED-1, Get-VmfWaveTakenBeforeCheck: this
            run's claim, no record past PLANNED, and a 'wave start' line no end
            line follows) - a wave nobody started is not stalled, it is waiting;
          - the run is not halted - a halt is a person saying stop, and this
            must never argue with it;
          - the wave passes the engine's start gates (Get-VmfWaveStartGate):
            acknowledged, accepted, and approved or set not to need it -
            resuming is not approving;
          - no worker is alive - no lease in this run has a heartbeat younger
            than the lease timeout, which is the same fact the engine's own
            watchdog uses;
          - no execution of this wave is Running - read from Azure, because a
            freshly started execution has no leases yet while it pulls its
            image, and a second start in that window would double-drive.

        RETRY-WAIT-SAYS-WHY-1: when a wave with a machine at work is held -
        by a live hold of a worker of another wave, by a restore, or by a
        start gate - the pass writes one 'resume' line that says which, once
        for each cause (Write-VmfResumeHoldLine). The page shows it on the
        machine in place of "within about 5 minutes".

        Read-only apart from the start itself and that line. Idempotent: two timer passes
        cannot start two executions, because the second sees the first as
        Running.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId,
        # Same default as Start-VmfWave's lease timeout: a heartbeat older than
        # this means the worker is gone.
        [Parameter()][int]$LeaseTimeoutSeconds = 900,
        # FACADE-TIMER-QUEUE-1: the run's machine records, read once by the
        # timer (Get-VmfFacadeRunStateDocs). None given: read here.
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$StateDocs
    )
    $m = Get-Module VmMigrationFactory

    if (& $m { param($rp) Test-VmfWaveHalted -RunPath $rp } $StorePath) { return @() }
    $plan = & $m { param($rp) Read-VmfPlanDocument -RunPath $rp -Depth 24 } $StorePath
    if (-not $plan -or -not $plan.entries) { return @() }

    # A live worker anywhere in the run means the run is being worked on.
    # RESTORE-ONE-AT-A-TIME-1: a live restore counts too, on
    # purpose: a wave restarted now would wait for its machine anyway, and the
    # restart is asked again on the next pass, after the restore ends.
    $liveLeases = @(& $m { param($rp, $t)
        $cutoff = (Get-Date).ToUniversalTime().AddSeconds(-$t)
        foreach ($name in Get-VmfStoreNames -RunPath $rp -Folder 'leases' -Extension '.lease') {
            $lease = Read-VmfStoreJson -RunPath $rp -RelPath "leases/$name" -Depth 6
            if (-not $lease) { continue }
            $hb = [datetime]::Parse($lease.heartbeatUtc, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            if ($hb -ge $cutoff) { $lease }
        }
    } $StorePath $LeaseTimeoutSeconds)

    # Every record's state, once. Working states past PLANNED: a machine here
    # was started and did not finish.
    # RESUME-GATE-1: NOT wrapped in @(). A hashtable wrapped in an array
    # answers ContainsKey through the array, and returns nothing for an index,
    # so the log read "the previous execution stopped with vmf-e2e-g1 at ".
    if ($null -eq $StateDocs) { $StateDocs = @(Get-VmfFacadeRunStateDocs -StorePath $StorePath) }
    $states = @{}
    foreach ($doc in $StateDocs) {
        if (-not $doc) { continue }
        $states[[string]$doc.vmId] = [string]$doc.state
    }
    # The working states are the engine's list, so they are read in its scope.
    $midFlight = (& $m { param($s)
        $out = @{}
        foreach ($id in @($s.Keys)) {
            if ($s[$id] -in $script:VmfWorkingStates -and $s[$id] -ne 'PLANNED') { $out[$id] = $s[$id] }
        }
        $out
    } $states)
    # RETRY-WAIT-SAYS-WHY-1: the newest step of each machine at work - when a
    # retry sent it back - so a hold is said again for a retry after its line.
    $lastStepUtc = @{}
    foreach ($doc in $StateDocs) {
        if (-not $doc -or -not $midFlight.ContainsKey([string]$doc.vmId)) { continue }
        $last = @($doc.history) | Select-Object -Last 1
        if ($last -and $last.PSObject.Properties['tsUtc']) {
            $lastStepUtc[[string]$doc.vmId] = & $m { param($v) ConvertTo-VmfResumeHoldUtc $v } $last.tsUtc
        }
    }
    $holdSince = {
        param($stuckEntries)
        $times = @($stuckEntries | ForEach-Object { $lastStepUtc[[string]$_.vmId] } | Where-Object { $_ })
        if ($times.Count) { ($times | Measure-Object -Maximum).Maximum } else { $null }
    }
    # RETRY-WAIT-SAYS-WHY-1: the run's 'resume' lines, read once a pass and only
    # when a wave is held. A line that cannot be read or written is a warning:
    # it says why, and must never stop the pass.
    $resumeRead = @{}
    $sayHold = {
        param([string]$heldWave, [hashtable]$hold, $since)
        try {
            if (-not $resumeRead.ContainsKey('lines')) { $resumeRead['lines'] = @(& $m { param($rp) @(Read-VmfEvents -RunPath $rp -Step 'resume') } $StorePath) }
            & $m { param($rp, $w, $h, $s, $e) Write-VmfResumeHoldLine -RunPath $rp -Wave $w -Hold $h -Since $s -Events $e } $StorePath $heldWave $hold $since $resumeRead['lines'] | Out-Null
        }
        catch { Write-Warning "RETRY-WAIT-SAYS-WHY-1: why wave '$heldWave' waits could not be said: $($_.Exception.Message)" }
    }

    # A live worker anywhere in the run means the run is being worked on, and
    # nothing starts again. RETRY-WAIT-SAYS-WHY-1: a wave with a machine at
    # work and no live hold of its own waits for that worker, and says so.
    if ($liveLeases.Count) {
        foreach ($group in (@($plan.entries) | Group-Object wave)) {
            $stuck = @($group.Group | Where-Object { $_ -and $midFlight.ContainsKey([string]$_.vmId) })
            if (-not $stuck.Count) { continue }
            $hold = & $m { param($p, $w, $l) Get-VmfResumeLeaseHold -Plan $p -Wave $w -Leases $l } $plan $group.Name $liveLeases
            if ($hold) { & $sayHold $group.Name $hold (& $holdSince $stuck) }
        }
        return @()
    }

    # WAVE-RESUME-PLANNED-1: and the machines a worker took - claim and lease -
    # whose execution stopped before the state machine wrote their record. The
    # lease ran out (no live lease, above), and nothing else starts the wave.
    $taken = (& $m { param($rp, $p, $s) Get-VmfWaveTakenBeforeCheck -RunPath $rp -Plan $p -States $s } $StorePath $plan $states)
    if (-not $midFlight.Count -and -not $taken.Count) { return @() }

    $resumed = @()
    foreach ($group in (@($plan.entries) | Group-Object wave)) {
        $wave = $group.Name
        $stuck = @($group.Group | Where-Object { $midFlight.ContainsKey($_.vmId) })
        $takenHere = if ($taken.ContainsKey($wave)) { @($taken[$wave]) } else { @() }
        if (-not $stuck.Count -and -not $takenHere.Count) { continue }
        # RETRY-GATE-1: approval is asked below, by the engine's own start gate
        # - the list a retry is now held to. This asked its own narrower
        # question first (an approval file, or the plan sign-off), so a wave
        # set not to need approval was never restarted: a retry the engine
        # accepted waited at PRECHECK for ever, with nothing on the screen.
        # ENGINE-START-PART-1 review: a run of this wave, Running or
        # Processing, asked the way the start's own guard asks - so a fresh
        # container is a run, and the pass goes on to the next wave.
        if (Test-VmfFacadeEngineRunning -Operation 'wave' -RunId $RunId -Wave $wave) { continue }

        # RESUME-GATE-1: the engine would refuse a wave that fails its start
        # gates - so do not start one to be refused. A wave refused for changed
        # settings is said once, so the run page offers the acceptance again.
        $gate = & $m { param($rp, $pp, $p, $w) Get-VmfWaveStartGate -RunPath $rp -PlanPath $pp -Plan $p -Wave $w } `
            $StorePath (Get-VmfFacadePlanPath -StorePath $StorePath) $plan $wave
        if ($gate) {
            if ($gate.Code -eq 'changed') {
                & $m { param($rp, $w, $d) Write-VmfOptionsChangedRefusal -RunPath $rp -Wave $w -Detail $d | Out-Null } $StorePath $wave $gate.Detail
            }
            # RETRY-WAIT-SAYS-WHY-1: and say, once, which gate holds the wave,
            # in the gate's own words - for every gate, so the page says why.
            & $sayHold $wave @{ HoldBy = 'gate'; Gate = [string]$gate.Code; Reason = [string]$gate.Detail } (& $holdSince $stuck)
            continue
        }

        $said = @($stuck | ForEach-Object { "$(($_.vmId -split '/')[-1]) at $($midFlight[$_.vmId])" }) +
            @($takenHere | ForEach-Object { "$(($_ -split '/')[-1]) at PLANNED" })
        $stoppedWith = $said -join ', '
        # SCALE-UX-1: resume with the worker count the wave was started with,
        # never a default. MACHINES-AT-ONCE-RANGE-1: that is the wave's own
        # number, which the start reads - the wave editor refuses a change to
        # a running wave, and no start carries a number of its own any more.
        $r = Invoke-VmfFacadeStartEngine -Principal ([pscustomobject]@{ Identity = 'resume (watchdog)'; Roles = @('Vmf.Operator') }) `
            -Operation 'wave' -RunId $RunId -Wave $wave -Note "resumed: the previous execution stopped with $stoppedWith"
        # STEP-LOG-6: the engine runs again for this wave, so a line that cannot
        # be written must not stop the pass before the next stopped wave, or
        # lose the list of what it started.
        # RETRY-WAIT-SAYS-WHY-1: the wave as data, and 'resumed', which ends a
        # hold the line above said (Write-VmfResumeHoldLine).
        & $m { param($rp, $d, $w) Write-VmfStepLine -RunPath $rp -Step 'resume' -Outcome warn -Detail $d -Data @{ wave = $w; code = 'resumed' } } $StorePath `
            "The run stopped before wave $wave finished ($stoppedWith). The engine was started again (execution $($r.execution))." $wave
        $resumed += [pscustomobject]@{ Wave = $wave; Execution = $r.execution; Machines = @(@($stuck | ForEach-Object { [string]$_.vmId }) + @($takenHere)) }
    }
    @($resumed)
}

function Invoke-VmfFacadeRemoveEndedWaveHolds {
    <#
    .SYNOPSIS
        STALE-WAVE-HOLD-1: remove the hold a stopped wave worker left on a
        machine whose move ended, so Restore this machine is not refused for
        it until somebody stops the migration.
    .DESCRIPTION
        A worker removes its hold after the state machine wrote the final
        state. A container stopped between the two writes leaves the hold, and
        a restore never takes over a wave worker's hold (RESTORE-MID-MOVE-1).
        The wave watchdog runs only while the wave runs, and the stalled-wave
        resume never starts a wave whose machines have all ended. So this
        pass, on the same timer (2026-10-30), removes a hold
        when ALL of these hold:
          - a wave worker holds it, and its heartbeat is older than the limit
            the wave watchdog uses (Get-VmfEndedWaveHolds);
          - the machine's record says a final state - a hold on a machine at a
            working state is never removed, because its wave resumes it;
          - no execution of the machine's wave is Running or Processing
            (Test-VmfFacadeEngineRunning, the question the resume asks). A
            machine no longer in the plan: no wave execution of the run at all;
          - it is removed only as judged (Remove-VmfEndedWaveHold).
        The claim of a MIGRATED or SKIPPED machine is given back in the same
        step (CLAIM-KEPT-AFTER-WAVE-1); every other machine keeps its claim.
        A halt does not stop this: a halt stops waves, and this starts nothing.
        Azure is asked only when a hold is found, once for each wave.
    .OUTPUTS
        One object per hold removed: VmId, State, WorkerId, ClaimReleased.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId
    )
    $m = Get-Module VmMigrationFactory
    $holds = @(& $m { param($rp) Get-VmfEndedWaveHolds -RunPath $rp } $StorePath)
    if (-not $holds.Count) { return @() }
    $plan = & $m { param($rp) Read-VmfPlanDocument -RunPath $rp -Depth 24 } $StorePath
    $entries = if ($plan -and $plan.entries) { @($plan.entries) } else { @() }
    # Wave -> is an execution of it running. '' is "any wave of this run".
    $running = @{}
    $out = @()
    foreach ($h in $holds) {
        # VMID-CASE-1: Azure gives one ID in more than one letter case.
        $entry = @($entries | Where-Object { $_ -and [string]$_.vmId -ieq $h.VmId }) | Select-Object -First 1
        $wave = if ($entry) { [string]$entry.wave } else { '' }
        if (-not $running.ContainsKey($wave)) {
            $running[$wave] = if ($wave) { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId $RunId -Wave $wave }
                              else { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId $RunId }
        }
        if ($running[$wave]) { continue }
        $r = & $m { param($rp, $id, $w) Remove-VmfEndedWaveHold -RunPath $rp -VmId $id -Wave $w } $StorePath $h.VmId $wave
        if ($r) { $out += $r }
    }
    @($out)
}

function Invoke-VmfFacadeReadReservingClaims {
    <#
    .SYNOPSIS
        ODCR-STATUS-1: read each quota record of a run that is stuck at
        RESERVING from Azure, by the resource ID the engine recorded before it
        asked, and record the answer. Called by the five-minute pass, for every
        run it checks.
    .DESCRIPTION
        MEASURED on the lab install, 2026-11-09: an engine stopped 4 seconds
        after it asked Azure for a capacity reservation, Azure made it, and the
        page said "Reserving..." for 60 minutes from the clock alone.
        No record at RESERVING asks Azure nothing. Otherwise the list of the
        engine's executions is read NOW (-Fresh), after the records: a reserve
        or release job of this run that runs leaves every record as it is -
        the engine that asked is the only other writer of a RESERVING record,
        and it releases what Azure made when its own save is refused. A job
        started after this list cannot have written these records: a reserve
        writes RESERVING only over a QUOTA_VERIFIED record, and every save
        here quotes the version read before the list.
        Each record is read as the web service's own identity (the VMF
        Assessment role holds the read, one GET by ID), and the module's rule
        decides (Update-VmfReservingClaimFromAzure). A read that fails is a
        warning in the service log, and the record stays for the next pass.
        A list Azure does not give throws, and nothing is read.
    .OUTPUTS
        Outcomes (one per record read), Remaining (the records still at
        RESERVING, for Get-VmfRunScheduleNeed), EngineRuns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId
    )
    $m = Get-Module VmMigrationFactory
    $reads = @(& $m { param($rp) Get-VmfReservingClaims -RunPath $rp } $StorePath)
    if (-not $reads.Count) { return [pscustomobject]@{ Outcomes = @(); Remaining = @(); EngineRuns = $false } }
    if (Test-VmfFacadeEngineRunning -Operation @('reserve', 'release') -RunId $RunId -Fresh) {
        return [pscustomobject]@{ Outcomes = @(); Remaining = $reads; EngineRuns = $true }
    }
    $outcomes = [System.Collections.Generic.List[object]]::new()
    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($read in $reads) {
        try {
            $o = & $m { param($rp, $r) Update-VmfReservingClaimFromAzure -RunPath $rp -Read $r } $StorePath $read
            $outcomes.Add($o)
            if ($o.Outcome -notin @('held', 'failed', 'gone')) { $remaining.Add($read) }
        }
        catch {
            Write-Warning "capacity reservation: the quota record '$($read.Name)' of run '$RunId' was not read from Azure: $($_.Exception.Message). The next pass reads it again."
            $remaining.Add($read)
        }
    }
    [pscustomobject]@{ Outcomes = @($outcomes); Remaining = @($remaining); EngineRuns = $false }
}

function Invoke-VmfFacadeResumeStalledPutBacks {
    <#
    .SYNOPSIS
        RESTORE-END-JOB-1: start again a Restore this machine whose job
        stopped part way - as Invoke-VmfFacadeResumeStalledWaves starts a wave
        again, on the same timer and with the same two questions.
    .DESCRIPTION
        A restore or a rebuild keeps its checkpoint on the machine's record
        (putBackJob, PutBackJob.ps1). Its job STOPPED when that record has not
        ended and:
          - no live hold stands on the machine (Test-VmfMachineHeldNow: a hold
            older than the lease limit is a job that died - the same fact the
            wave watchdog uses), and
          - Azure lists no restore, rebuild or finish of this machine as
            running (a job just started has no hold yet while it pulls its
            image, and a second start then would run two jobs).
        Then the count goes on the record first (one version-checked write,
        so two passes cannot both start it), and the engine is started for the
        SAME operation id (VMF_RESUME_ID): it takes over its own hold and goes
        on from the last step, with the disks it made.
        At $script:VmfPutBackResumeLimit starts, or for a job that ended with an
        answer but whose last lines may be lost, the row is ended with the
        engine's own fail line - the machine and the operation id, so the page
        ends THAT restore (RESTORE-END-LOST-1) and offers it again - and the
        record is removed, so a person can start a new one.
        A halt does not stop this. A halt stops waves; a restore is a person's
        own action on one machine, which a halt never governed, and leaving it
        part way can leave the machine stopped.
    .OUTPUTS
        One object per job acted on: VmId, Kind, OperationId, Action
        (resumed, ended, gaveUp), Execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId,
        # FACADE-TIMER-QUEUE-1: the run's machine records, read once by the
        # timer (Get-VmfFacadeRunStateDocs). None given: read here.
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$StateDocs
    )
    $m = Get-Module VmMigrationFactory
    if ($null -eq $StateDocs) { $StateDocs = @(Get-VmfFacadeRunStateDocs -StorePath $StorePath) }
    $jobs = @(& $m { param($docs)
            foreach ($doc in $docs) {
                $job = Get-VmfPutBackJob -Doc $doc
                # FINISH-END-JOB-1: a finish keeps the same checkpoint.
                if ($job -and [string]$job.operationId -and [string]$job.kind -in @('restore', 'finish')) {
                    [pscustomobject]@{ VmId = [string]$doc.vmId; Job = $job }
                }
            }
        } $StateDocs)
    if (-not $jobs.Count) { return @() }
    # Get-VmfFacadeRunIds names a run inside a project 'project/run'. An
    # execution the page started carries them apart (VMF_PROJECT, VMF_RUN_ID).
    $project = ''
    $run = $RunId
    if ($RunId -match '^([^/]+)/([^/]+)$') { $project = $Matches[1]; $run = $Matches[2] }
    $limit = & $m { $script:VmfPutBackResumeLimit }
    $out = @()
    foreach ($j in $jobs) {
        $vmId = $j.VmId
        $job = $j.Job
        $kind = [string]$job.kind
        $opId = [string]$job.operationId
        $vmName = ($vmId -split '/')[-1]
        $action = & $m { param($j) Get-VmfPutBackJobWords -Job $j } $job
        # RESUME-GIVEUP-KEEP-1: a record the service gave up on stands, and
        # keeps the copies, until a restore finishes: nothing to
        # do, and nothing to say again. FACADE-TIMER-QUEUE-1: so it is skipped
        # FIRST. It was skipped after the hold, the engine's executions and the
        # whole run log were read - every pass, for an answer nothing used.
        if ($job.PSObject.Properties['ended'] -and $job.ended -and
            $job.ended.PSObject.Properties['reason'] -and [string]$job.ended.reason -eq 'gaveUp') { continue }
        $isFinish = $kind -eq 'finish'
        # FINISH-END-JOB-1: a finish over the record of a restore the service
        # gave up on puts that record back when it ends, and with it its hold.
        $priorHolds = $isFinish -and (& $m { param($j) $p = Get-VmfRecordField -Object $j -Name 'prior'; [bool]($p -and (Test-VmfPutBackJobHolds -Doc ([pscustomobject]@{ putBackJob = $p }))) } $job)
        if (& $m { param($rp, $id) Test-VmfMachineHeldNow -RunPath $rp -VmId $id } $StorePath $vmId) { continue }
        if (Test-VmfFacadeEngineRunning -Operation @('restore', 'finish') -RunId $run -Project $project -VmId $vmId) { continue }

        # STEP-LOG-6: a throwing write on purpose. It is written before the
        # record is removed or marked gaveUp, and it is what ends the row on
        # the page (RESTORE-END-LOST-1). A line that cannot be written keeps
        # the record, so the next pass writes it again.
        $endRow = { param($why)
            & $m { param($rp, $k, $w, $id, $op)
                Write-VmfEvent -RunPath $rp -Step "engine:$k" -Outcome fail -Detail $w -VmId $id -CorrelationId $op
            } $StorePath $kind $why $vmId $opId
        }
        if ($job.PSObject.Properties['ended'] -and $job.ended) {
            # It ended with an answer. Its own last line and the engine's fail
            # line are normally there; if both were lost, this ends the row.
            $seen = & $m { param($rp, $id, $k, $op) Test-VmfPutBackEndWritten -Events @(Read-VmfEvents -RunPath $rp) -VmId $id -Kind $k -OperationId $op } $StorePath $vmId $kind $opId
            if (-not $seen) {
                & $endRow "$action of '$vmName' ended, and its last line was not written. $(if ([string]$job.ended.why) { "It said: $(([string]$job.ended.why).TrimEnd('.')). " })Look at the machine and its record. You can start $action again."
            }
            # A job that carried that mark (it ran over a record the service
            # gave up on, and did not finish) keeps it.
            $endAction = if ($job.PSObject.Properties['held'] -and $job.held) { 'gaveUp' } else { 'remove' }
            if (& $m { param($rp, $id, $op, $a, $w) Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId $op -Action $a -Why $w } $StorePath $vmId $opId $endAction ([string]$job.ended.why)) {
                $out += [pscustomobject]@{ VmId = $vmId; Kind = $kind; OperationId = $opId; Action = 'ended'; Execution = $null }
            }
            continue
        }
        if ([int]$job.resumes -ge $limit) {
            $giveUpWhy = "$action of '$vmName' stopped part way when its job stopped, at the step '$([string]$job.phase)'. The service started it again $([int]$job.resumes) times, and it did not finish. The machine can be stopped, or part way. The product keeps the safety copies of the machine and the disks made for it until a restore of the machine finishes. Look at the machine and its disks, then start Restore this machine."
            # FINISH-END-JOB-1: a finish makes no disk and needs no safety
            # copy - the swap record keeps every disk it needs, and the page
            # offers the finish again. Its record goes, and the record it
            # stood over (prior) is back as it was (Update-VmfPutBackJobRecord).
            $giveUpAction = 'gaveUp'
            if ($isFinish) {
                $giveUpWhy = "$action of '$vmName' stopped part way when its job stopped. The service started it again $([int]$job.resumes) times, and it did not finish. The machine stays stopped, and its record names each data disk that is left. $(if ($priorHolds) { 'The product keeps the safety copies of the machine and the disks made for it until a restore of the machine finishes. ' })Look at the machine and its disks, then use $action again."
                $giveUpAction = 'remove'
            }
            & $endRow $giveUpWhy
            # RESUME-GIVEUP-KEEP-1: the record stays, marked gaveUp. It refuses
            # nothing - a person can start a new restore - and it keeps the
            # copies until a restore finishes.
            if (& $m { param($rp, $id, $op, $w, $a) Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId $op -Action $a -Why $w } $StorePath $vmId $opId $giveUpWhy $giveUpAction) {
                $out += [pscustomobject]@{ VmId = $vmId; Kind = $kind; OperationId = $opId; Action = 'gaveUp'; Execution = $null }
            }
            continue
        }
        # Counted before the start: a second pass, or a start that fails, can
        # never start more than the limit.
        if (-not (& $m { param($rp, $id, $op) Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId $op -Action resume } $StorePath $vmId $opId)) { continue }
        $o = $job.options
        $startArgs = @{
            Principal = [pscustomobject]@{ Identity = 'resume (watchdog)'; Roles = @('Vmf.Operator') }
            Operation = $kind; RunId = $run; VmId = $vmId
            Note      = "resumed: the job of $(if ($isFinish) { $action } else { "the $kind" }) started by $([string]$job.startedBy) stopped at the step '$([string]$job.phase)'"
        }
        if ($project) { $startArgs.Project = $project }
        if ($kind -eq 'restore') {
            if ([string]$o.from) { $startArgs.DiskSource = [string]$o.from }
            if ([string]$o.diskNaming) { $startArgs.DiskNaming = [string]$o.diskNaming }
            if ([bool]$o.acceptPreserveRisk) { $startArgs.AcceptPreserveRisk = $true }
        }
        $script:VmfResumeDispatch = $opId
        try { $r = Invoke-VmfFacadeStartEngine @startArgs }
        catch {
            # One machine's refusal never stops the others. It is counted, so
            # the next passes end it at the limit.
            # STEP-LOG-6: the start is already counted on the record, so a line
            # that cannot be written must not stop the pass for the others.
            $why = ([string]$_.Exception.Message) -replace '^\d{3}: ', ''
            & $m { param($rp, $id, $d) Write-VmfStepLine -RunPath $rp -Step 'resume' -Outcome fail -VmId $id -Detail $d } $StorePath $vmId `
                "$action of '$vmName' stopped part way when its job stopped, and the service could not start it again: $($why.TrimEnd('.')). It tries again on the next pass, $limit times in all."
            continue
        }
        finally { $script:VmfResumeDispatch = $null }
        # STEP-LOG-6: the job runs again, so a line that cannot be written must
        # not stop the pass, or lose the record of what it started.
        $resumedWords = if ($isFinish) {
            "$action of '$vmName' stopped part way when its job stopped. The engine started it again (execution $($r.execution)). It swaps only the data disks that are left, then starts the machine."
        }
        else {
            "$action of '$vmName' stopped part way when its job stopped, at the step '$([string]$job.phase)'. The engine started it again (execution $($r.execution)), and it goes on from that step with the disks it made."
        }
        & $m { param($rp, $id, $d) Write-VmfStepLine -RunPath $rp -Step 'resume' -Outcome warn -VmId $id -Detail $d } $StorePath $vmId $resumedWords
        $out += [pscustomobject]@{ VmId = $vmId; Kind = $kind; OperationId = $opId; Action = 'resumed'; Execution = [string]$r.execution }
    }
    @($out)
}

function Invoke-VmfFacadeResumeStalledVolumeChecks {
    <#
    .SYNOPSIS
        VOLUMES-CHECK-JOB-STOP-1: start Check the volumes again for a machine
        whose check started it and whose job stopped before the return. Called
        by the five-minute pass, for every run it checks.
    .DESCRIPTION
        Check the volumes (the engine operation checkvolumes) starts a machine
        that is Stopped or Stopped (deallocated) for the check, and writes the
        power state it found first (captured.volumesCheckPower, status
        'started'). A job that stops before the return leaves the machine
        running. For each machine with that record, in a state that no job
        works on (Get-VmfVolumesCheckRefusal), that no hold covers and that no
        job of the machine runs on:
          - the record is marked (stoppedUtc, resumes - Set-VmfVolumesCheckStopped);
          - checkvolumes starts again through Invoke-VmfFacadeStartEngine,
            with the same refusals as a person's start. It reads the record,
            does not start the machine again, checks the volumes, and returns
            the machine to the recorded power state;
          - at the limit of a restore's resumes the record is marked gaveUp,
            one line says so, and the pass starts it no more. The panel says
            that the machine runs because a check did not finish.
        A record from the check before a retry belongs to its wave: the
        machine is at Checking, a working state, and the wave's own resume
        finishes it.
    .OUTPUTS
        One object per machine acted on: VmId, Action (resumed, gaveUp),
        Execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$StateDocs
    )
    $m = Get-Module VmMigrationFactory
    if ($null -eq $StateDocs) { $StateDocs = @(Get-VmfFacadeRunStateDocs -StorePath $StorePath) }
    $found = @(& $m { param($docs)
            foreach ($doc in $docs) {
                $rec = Get-VmfVolumesCheckStarted -Doc $doc
                if (-not $rec -or (Get-VmfRecordField -Object $rec -Name 'gaveUp')) { continue }
                if (Get-VmfVolumesCheckRefusal -Doc $doc -VmName (([string]$doc.vmId -split '/')[-1])) { continue }
                [pscustomobject]@{ VmId = [string]$doc.vmId; Power = [string]$rec.power }
            }
        } $StateDocs)
    if (-not $found.Count) { return @() }
    $project = ''
    $run = $RunId
    if ($RunId -match '^([^/]+)/([^/]+)$') { $project = $Matches[1]; $run = $Matches[2] }
    $out = @()
    foreach ($f in $found) {
        $vmId = $f.VmId
        $vmName = ($vmId -split '/')[-1]
        if (& $m { param($rp, $id) Test-VmfMachineHeldNow -RunPath $rp -VmId $id } $StorePath $vmId) { continue }
        if (Test-VmfFacadeEngineRunning -Operation @('checkvolumes', 'restore', 'finish', 'deleteearlier', 'deletemade') -RunId $run -Project $project -VmId $vmId) { continue }
        $powerName = & $m { param($pw) Get-VmfPowerStateName -Power $pw } $f.Power
        $answer = & $m { param($rp, $id) Set-VmfVolumesCheckStopped -RunPath $rp -VmId $id } $StorePath $vmId
        if ($answer -eq 'gaveUp') {
            & $m { param($rp, $id, $d) Write-VmfStepLine -RunPath $rp -Step 'resume' -Outcome fail -VmId $id -Detail $d } $StorePath $vmId `
                "The check of the volumes of '$vmName' started the machine. The check did not finish. The service started the check again $(& $m { $script:VmfPutBackResumeLimit }) times. The check did not finish. The machine is in the power state Running. Before the check, it was $powerName. Select Check the volumes to start the check again."
            $out += [pscustomobject]@{ VmId = $vmId; Action = 'gaveUp'; Execution = $null }
            continue
        }
        if ($answer -ne 'resume') { continue }
        $startArgs = @{
            Principal = [pscustomobject]@{ Identity = 'resume (watchdog)'; Roles = @('Vmf.Operator') }
            Operation = 'checkvolumes'; RunId = $run; VmId = $vmId
        }
        if ($project) { $startArgs.Project = $project }
        try { $r = Invoke-VmfFacadeStartEngine @startArgs }
        catch {
            # One machine's refusal never stops the others; the next pass asks
            # again, and the count on the record ends it at the limit.
            $why = ([string]$_.Exception.Message) -replace '^\d{3}: ', ''
            & $m { param($rp, $id, $d) Write-VmfStepLine -RunPath $rp -Step 'resume' -Outcome fail -VmId $id -Detail $d } $StorePath $vmId `
                "The check of the volumes of '$vmName' started the machine. The check did not finish. The service could not start the check again: $($why.TrimEnd('.')). It tries again on the next pass."
            continue
        }
        & $m { param($rp, $id, $d) Write-VmfStepLine -RunPath $rp -Step 'resume' -Outcome warn -VmId $id -Detail $d } $StorePath $vmId `
            "The check of the volumes of '$vmName' started the machine. The check did not finish. The engine started the check again (execution $($r.execution)). The check returns the machine to the power state $powerName."
        $out += [pscustomobject]@{ VmId = $vmId; Action = 'resumed'; Execution = [string]$r.execution }
    }
    @($out)
}

function Get-VmfFacadeRunSummary {
    <#
    .SYNOPSIS
        One run shaped for the dashboard/API: per-wave rollups (counts,
        approval state) derived from state docs + plan + approvals - the
        contract documents, nothing else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        # CLAIM-AT-PLAN-1: add held, the machines another migration holds. Only
        # Choose the machines asks (held=1): the Reports page reads a summary
        # for every run, and would pay a claims read per run for nothing.
        [Parameter()][switch]$IncludeHeld
    )

    $m = Get-Module VmMigrationFactory
    $manifest = & $m { param($rp) Read-VmfStoreJson -RunPath $rp -RelPath 'run.json' -Depth 4 } $StorePath
    $plan = & $m { param($rp) Read-VmfPlanDocument -RunPath $rp } $StorePath
    $halted = & $m { param($rp) Test-VmfStoreItem -RunPath $rp -RelPath 'halt.flag' } $StorePath
    $stateDocs = & $m { param($rp)
        @(Get-VmfStoreNames -RunPath $rp -Folder 'state' -Extension '.json' |
            ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "state/$_" })
    } $StorePath

    $docById = @{}
    foreach ($d in @($stateDocs)) { if ($d -and $d.vmId) { $docById[[string]$d.vmId] = $d } }

    # COUNT-TRUTH-1: `outcomes` is what the machines say happened, by the ONE
    # definition the pages also use. `stateCounts` stays for the readers that
    # already take it, but a state is not an outcome: a machine put back is
    # still in the state MIGRATED.
    $planDocs = [System.Collections.Generic.List[object]]::new()
    # NOT-IN-WAVE-QUEUED-1: a machine in no wave that never ran is not part of
    # the migration - no wave takes it - so it is in no count and no total,
    # the rule the pages show it by (Test-VmfEntryOutsideRun). It counted as
    # not started, and a finished migration read as still going.
    $shown = @(& $m { param($es, $byId)
        @($es | Where-Object { $_ -and -not (Test-VmfEntryOutsideRun -Entry $_ -StateDoc $byId[[string]$_.vmId]) })
    } @($plan.entries) $docById)
    $waves = foreach ($group in ($shown | Group-Object wave)) {
        $counts = @{}
        $waveDocs = foreach ($e in $group.Group) {
            $doc = $docById[[string]$e.vmId]
            $s = if ($doc) { $doc.state } else { 'PLANNED' }
            $counts[$s] = 1 + ($counts[$s] ?? 0)
            # LAB-UX-1: an outcome is counted only for a machine the plan MOVES
            # (path A), the same machines Get-VmfRunStage counts. A machine
            # given no target is in the plan as MANUAL, never gets a state, and
            # was counted "not started" - so a finished run of one machine read
            # "In progress: 1 rolled back, 3 not started" on the Reports page.
            if ([string]$e.path -ne 'A') { continue }
            $planDocs.Add($doc)
            , $doc
        }
        $outcomes = & $m { param($docs) Get-VmfOutcomeCounts -StateDocs $docs } @($waveDocs)
        # SIGNOFF-NULL-1: the gate's own rule - this read a machine that says
        # nothing about the sign-off as needing none, while the gate refused it.
        $requires = [bool](@($group.Group) | Where-Object { & $m { param($e) Test-VmfApprovalRequired -PlanEntry $e } $_ })
        $approval = & $m { param($rp, $w) Read-VmfStoreJson -RunPath $rp -RelPath "approvals/$w.json" -Depth 6 } $StorePath $group.Name
        [pscustomobject]@{
            wave             = $group.Name
            total            = $group.Count
            stateCounts      = [pscustomobject]$counts
            outcomes         = $outcomes
            requiresApproval = $requires
            approval         = $approval
        }
    }

    # CLAIM-AT-PLAN-1: the machines of the run's assessment that another live
    # migration holds, by the start check's own rule (Get-VmfHeldMachines), so
    # Choose the machines marks them before a person plans one the start
    # refuses. $null when the claims could not be read: unknown is not free,
    # and a failed claims read must not cost the rest of the summary.
    # HELD-READ-DEPTH-1: the reader's own depth. A real assessment nests
    # vms[].workload.evidence[] six deep, and a depth of 4 failed every read.
    $held = if (-not $IncludeHeld) { $null } else { try {
        $assessmentDoc = & $m { param($rp) Read-VmfStoreJson -RunPath $rp -RelPath 'assessment.json' } $StorePath
        $vmIds = @(@($assessmentDoc.vms) | ForEach-Object { [string]$_.vmId } | Where-Object { $_ })
        , @(& $m { param($rp, $ids, $rid) Get-VmfHeldMachines -RunPath $rp -VmIds $ids -RunId $rid } $StorePath $vmIds ([string]$manifest.runId))
    }
    catch {
        Write-Warning "The machines that other migrations hold could not be read: $($_.Exception.Message)"
        $null
    } }

    $summary = [pscustomobject]@{
        runId    = [string]$manifest.runId
        halted   = [bool]$halted
        total    = $shown.Count
        outcomes = & $m { param($docs) Get-VmfOutcomeCounts -StateDocs $docs } $planDocs.ToArray()
        waves    = @($waves)
    }
    if ($IncludeHeld) { $summary | Add-Member -NotePropertyName held -NotePropertyValue $held }
    $summary
}

function Invoke-VmfFacadeAcknowledge {
    <#
    .SYNOPSIS
        IAC-2: record that a signed-in person accepted the infrastructure-as-code
        note for this run.

    .DESCRIPTION
        The identity comes from the validated principal, never from the request
        body - an acknowledgement someone can attribute to a name they typed is
        not an audit trail. Same rule as the wave approvals.

        The STATEMENT is the engine's own wording, so the wizard cannot record an
        acceptance of something softer than what the engine refuses on.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][string]$Topic = 'infrastructure-as-code',
        [Parameter()][AllowEmptyString()][string]$Note = ''
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    if ($Topic -and $Topic -ne 'infrastructure-as-code') { throw "400: unknown acknowledgement topic '$Topic'" }

    $identity = [string]$Principal.Identity
    if (-not $identity) { throw '401: the acknowledgement must name the signed-in person' }

    Confirm-VmfRunAcknowledgement -RunPath $StorePath -AcknowledgedBy $identity -Note $Note -Confirm:$false
}

function Invoke-VmfFacadeAcceptWaveOptions {
    <#
    .SYNOPSIS
        WAVE-2: record that the SIGNED-IN person reviewed and accepted a
        wave's policy levers (Vmf.Operator).
    .DESCRIPTION
        The identity comes from the validated principal, never the request
        body - the same rule as approvals and the IaC acknowledgement. The
        cmdlet binds the acceptance by hash to the wave's exact levers and
        membership, so the engine refuses a wave edited after acceptance.
    .PARAMETER PlanHash
        ACCEPT-HASH-1: the plan the browser had on screen. MANDATORY here, for
        the same reason APPR-2 made it mandatory on approve: the browser is
        where the race lives. A dialog listing the levers is drawn from a plan
        that is already as old as the last refresh tick, and a Vmf.Operator may
        rewrite the wave while it sits open. Without this the record names a
        person as having chosen settings they were never shown.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][AllowEmptyString()][string]$Note = '',
        [Parameter(Mandatory)][string]$PlanHash
        # REBUILD-REMOVE-ACCEPT-1: no list of machines whose rebuild or
        # identity loss the person accepts - no move rebuilds a machine.
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    $identity = [string]$Principal.Identity
    if (-not $identity) { throw '401: the acceptance must name the signed-in person' }

    Confirm-VmfWaveOptions -RunPath $StorePath -PlanPath (Get-VmfFacadePlanPath -StorePath $StorePath) `
        -Wave $Wave -AcceptedBy $identity -Note $Note -ExpectedPlanHash $PlanHash -Confirm:$false
}

function Invoke-VmfFacadeSetTargets {
    <#
    .SYNOPSIS
        ADVISOR-1: save the target the SIGNED-IN person chose for each
        machine (Vmf.Operator).
    .DESCRIPTION
        Same shape as the wave-options acceptance: the identity comes from the
        validated principal, never the request body, and the page quotes back
        the document versions the service issued with what it read (PLANVER-2)
        - the target options, and the targets already saved (empty when none).
        Set-VmfTargetChoice refuses a version that moved with 409, and a choice
        that is not a supported option with 400.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][ValidateSet('current', 'extended')][string]$Default,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Choices,
        [Parameter(Mandatory)][string]$AdviceVersion,
        [Parameter()][AllowEmptyString()][string]$ChoicesVersion = '',
        # MACHINE-PICK-1: the version of the chosen machines the page read.
        [Parameter()][AllowEmptyString()][string]$MachinesVersion = '',
        # MANA-LINUX-KERNEL-1: the migration's default when a Linux kernel has
        # no MANA driver. KERNEL-DEFAULT-EARLIER-1: stop only - the page always
        # sends it; absent is stop.
        [Parameter()][AllowEmptyString()][string]$KernelDefault = ''
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    $identity = [string]$Principal.Identity
    if (-not $identity) { throw '401: the targets must name the signed-in person' }
    if ($KernelDefault -and $KernelDefault -cne 'stop') { throw '400: the kernel default must be stop' }

    # OLD-SKU-1B: a v5 size, when the page names one. Set-VmfTargetChoice
    # accepts only a size from the option's own sizeChoices.
    $asked = @($Choices | ForEach-Object {
            $one = @{ vmId = [string]$_.vmId; option = [string]$_.option }
            if ([string]$_.size) { $one.size = [string]$_.size }
            # OLD-SKU-1C: the disk choice, checked by Set-VmfTargetChoice.
            if ([string]$_.disks) { $one.disks = [string]$_.disks }
            # MANA-LINUX-KERNEL-1: this machine's own kernel choice, checked by
            # Set-VmfTargetChoice.
            if ([string]$_.kernel) { $one.kernel = [string]$_.kernel }
            # REBUILD-PICKER-1: the method the page showed, checked by
            # Set-VmfTargetChoice against the method of the chosen size.
            if ([string]$_.method) { $one.method = [string]$_.method }
            $one })
    Set-VmfTargetChoice -RunPath $StorePath -Choices $asked -Default $Default `
        -ExpectedAdviceVersion $AdviceVersion -ExpectedChoicesVersion $ChoicesVersion `
        -ExpectedMachinesVersion $MachinesVersion -KernelDefault $(if ($KernelDefault) { $KernelDefault } else { 'stop' }) `
        -OnBehalfOf @{ Identity = $identity; TenantId = [string]$Principal.TenantId }
}

function Invoke-VmfFacadeSetMachines {
    <#
    .SYNOPSIS
        MACHINE-PICK-1: save the machines the SIGNED-IN person chose for the
        migration (Vmf.Operator).
    .DESCRIPTION
        The same shape as Invoke-VmfFacadeSetTargets: the identity comes from
        the validated principal, never the request body, and the page quotes
        back the document versions the service issued with what it read
        (PLANVER-2) - the target options the list was drawn from, and the list
        already saved (empty when none). Set-VmfMachineChoice refuses a
        version that moved with 409, and a machine that cannot move with 400.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Machines,
        [Parameter(Mandatory)][string]$AdviceVersion,
        [Parameter()][AllowEmptyString()][string]$ChoiceVersion = ''
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    $identity = [string]$Principal.Identity
    if (-not $identity) { throw '401: the machines must name the signed-in person' }

    Set-VmfMachineChoice -RunPath $StorePath -Machines @($Machines | ForEach-Object { [string]$_ }) `
        -ExpectedAdviceVersion $AdviceVersion -ExpectedChoiceVersion $ChoiceVersion `
        -OnBehalfOf @{ Identity = $identity; TenantId = [string]$Principal.TenantId }
}
function Get-VmfFacadeWaveCapacity {
    <#
    .SYNOPSIS
        REACH-1: what the capacity gate would say about a wave, before anyone
        starts it (any role).
    .DESCRIPTION
        The engine already refuses a wave whose capacity is not there. Asking
        the same question BEFORE pressing start is the difference between
        planning around a shortage and discovering one - and the answer was
        only available as a PowerShell command.

        Read-only: it reads the wave's quota records and applies the gate.
        It calls nothing in Azure and writes nothing, so a Viewer may ask.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][ValidateSet('BestEffort', 'Reserved')][string]$Gate = 'BestEffort'
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')
    & (Get-Module VmMigrationFactory) { param($rp, $w, $g)
        Test-VmfQuotaAndReservation -OutPath $rp -Wave $w -Gate $g
    } $StorePath $Wave $Gate
}

function Invoke-VmfFacadeListProjects {
    <#
    .SYNOPSIS
        PROJECT-1: the projects in the store - the containers holding an
        assessment and the migrations planned from it.
    .DESCRIPTION
        A READ, so it is open to anyone who can see the app at all. Viewers can
        already list runs; hiding the grouping from them would make the runs
        list less legible without protecting anything.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Principal)
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Viewer', 'Vmf.Operator', 'Vmf.Approver', 'Vmf.Admin')
    $store = Get-VmfFacadeStorePath
    @(& (Get-Module VmMigrationFactory) { param($sp) Get-VmfProject -StorePath $sp } $store |
        ForEach-Object {
            [ordered]@{
                projectId = $_.ProjectId; name = $_.Name
                createdUtc = $_.CreatedUtc; createdBy = $_.CreatedBy
                scope = $_.Scope; note = $_.Note
            }
        })
}

function Invoke-VmfFacadeCreateProject {
    <#
    .SYNOPSIS
        PROJECT-1: create a project (Vmf.Operator).
    .DESCRIPTION
        Hard rule 10: a person must be able to start a piece of work from the
        app. Naming an engagement is the FIRST thing an operator does, so
        sending them to PowerShell for it would be the worst possible place to
        break that rule.

        Creating a project touches no machine and spends nothing - it writes one
        document - so it sits at Operator rather than Approver. The identity
        comes from the validated principal, never the body.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][AllowNull()]$Scope,
        [Parameter()][string]$Note
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Operator', 'Vmf.Admin')
    # -cnotmatch, not -notmatch: the plain operator ignores case, which would let
    # 'UPPER' through into a case-sensitive blob prefix.
    if ($ProjectId -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$') {
        throw '400: a project id is lower-case letters, numbers and hyphens, 3 to 64 characters - it is a path segment, not a title'
    }
    if (-not $Name) { throw '400: a project needs a name' }
    $identity = [string]$Principal.Identity
    if (-not $identity) { throw '401: the project must record who created it' }

    $store = Get-VmfFacadeStorePath
    & (Get-Module VmMigrationFactory) { param($sp, $id, $nm, $sc, $nt, $who, $tid)
        New-VmfProject -StorePath $sp -ProjectId $id -Name $nm -Scope $sc -Note $nt `
            -OnBehalfOf @{ Identity = $who; TenantId = $tid } -Confirm:$false
    } $store $ProjectId $Name $Scope $Note $identity ([string]$Principal.TenantId)
}

function Invoke-VmfFacadeApproveAssessment {
    <#
    .SYNOPSIS
        ASSESS-PAGE-1: record that an assessment has been reviewed, so a
        migration may be planned from it (Vmf.Approver).
    .DESCRIPTION
        The same gate as wave approval and the same role, because it is the
        same act: a person reading what was found and taking responsibility for
        what happens next. `New-VmfPlan` refuses an assessment without one, so
        this is enforced in the engine rather than by hiding a button.

        The identity comes from the validated principal, never the request
        body - an approval somebody can type a name into is not an approval.

        SEC-F3: Vmf.Operator is NOT on this list. It was, from the day this
        function was written, while the line above and the commit that added it
        both said "the same role as wave approval" - which admits only Approver
        and Admin. That made the gate a formality: an operator could record the
        review and then plan the migration from it, and the approval named
        themselves. The separation the page advertises - "a migration can only
        be planned from an assessment somebody has accepted" - means accepted
        by somebody OTHER than the person who then acts on it.

        An operator who legitimately needs both holds Vmf.Admin, which is on
        the list. The consequence is deliberate: an operator alone now stops at
        the review step in the wizard and on the assessments page, and is told
        to ask for the role.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][AllowEmptyString()][string]$Note = '',
        # ADVISOR-1: with the run id, the target options are started as soon
        # as the review is recorded.
        [Parameter()][string]$RunId,
        [Parameter()][string]$Project
    )
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Approver', 'Vmf.Admin')
    # No note required here. Approving unlocks PLANNING and touches nothing; the
    # wave approval is the gate that authorises a machine being rebuilt, and it
    # still refuses without a reason.
    $identity = [string]$Principal.Identity
    if (-not $identity) { throw '401: the approval must name the signed-in person' }

    $result = & (Get-Module VmMigrationFactory) { param($rp, $why, $who, $tid)
        Approve-VmfAssessment -RunPath $rp -Note $why -OnBehalfOf @{ Identity = $who; TenantId = $tid }
    } $StorePath $Note $identity ([string]$Principal.TenantId)

    # ADVISOR-1: the next step is choosing each machine's target, and its
    # options come from the engine. Started here so nobody has to ask for
    # them. The review is recorded whether or not the start works; a failed
    # start is reported, and the next step can ask again.
    $advice = [ordered]@{ started = $false; execution = $null; error = $null }
    if ($RunId) {
        $startError = $null; $adviseRuns = $false
        try {
            $startParams = @{ Principal = $Principal; Operation = 'advise'; RunId = $RunId }
            if ($Project) { $startParams.Project = $Project }
            $started = Invoke-VmfFacadeStartEngine @startParams
            $advice.started = $true
            $advice.execution = [string]$started.Execution
        }
        catch {
            $startError = $_.Exception.Message
            # TARGET-OPTIONS-WAIT-1: a start refused because an advise of this
            # assessment runs (an approval recorded again, in a second tab) is
            # no failure: the options come from the one that runs. A failed
            # line here would make the page say they could not be made. A
            # list that cannot be read says nothing, so the failure stands.
            $adviseRuns = try { Test-VmfFacadeEngineRunning -Operation 'advise' -RunId $RunId -Project $Project } catch { $false }
        }
        if ($adviseRuns) { $advice.started = $true }
        elseif ($startError) {
            $advice.error = "The target options did not start: $startError"
            # REVIEW-1: into the run, the way the scheduler records a start it
            # could not make, under the step the engine's refusals use - so the
            # pages that read engine failures show it. A reply field alone was
            # read by nobody.
            # STEP-LOG-6: through the one helper, so the scan covers it. A line
            # that cannot be written is a warning in the service log, and the
            # approval is still returned.
            & (Get-Module VmMigrationFactory) { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'engine:advise' -Outcome fail -Detail $d } `
                $StorePath $advice.error
        }
    }
    $result | Add-Member -NotePropertyName TargetOptions -NotePropertyValue $advice -Force -PassThru
}

function Get-VmfDocumentVersionHeaders {
    <#
    .SYNOPSIS
        CORS-1: the version header for a document, AND the permission a browser
        needs to read it.
    .DESCRIPTION
        PLANVER-2 returns a document's version in `x-vmf-document-version`,
        beside the document, so a page can name the plan it was shown.

        A BROWSER COULD NOT READ IT. The dashboard and this service are
        different origins, and a browser hands JavaScript only the small set of
        CORS-safelisted response headers unless the server names the others in
        `Access-Control-Expose-Headers`. Nothing named it. So
        `response.headers.get('x-vmf-document-version')` was NULL in the
        browser, the page approved with an empty version, and the gate refused
        it: "400: the plan version being approved is required". The approval
        could not be given at all.

        MEASURED against a live install, 2026-09-18: the response carried
        `Access-Control-Allow-Origin` and no expose header of any kind.

        THE HEADER WAS ALWAYS SENT. Nothing dropped it and no log recorded a
        problem - the browser simply declined to hand it over, which is the
        specified behaviour. The flow drill saw the header the whole time
        because PowerShell is not a browser and has no CORS, so the one test
        built to prove this path end to end could not see the defect at all.

        Azure Functions' platform CORS setting has no expose list, so the
        answer has to come from the function.
    .PARAMETER Text
        The document, as it was read from the store.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $version = & (Get-Module VmMigrationFactory) { param($c) Get-VmfDocumentVersion -Text $c } $Text
    @{
        'x-vmf-document-version'        = $version
        'Access-Control-Expose-Headers' = 'x-vmf-document-version'
    }
}
function Get-VmfFacadeReportStyle {
    <#
    .SYNOPSIS
        REPORT-THEME-1: the report's stylesheet and mark, for the migration
        record the Reports page saves.
    .DESCRIPTION
        The record is built in the browser and the report on the service, so
        the two looked like two products. The record now uses the report's own
        stylesheet, and there is one copy of it: the module's. This returns
        that copy - never a second one. Any signed-in role may ask, as for the
        version: it is the look of a document, not data.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Principal)
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')
    & (Get-Module VmMigrationFactory) { Get-VmfReportLook }
}

function Get-VmfFacadeVersion {
    <#
    .SYNOPSIS
        VERSION-1: which build of the service is answering, and which image the
        engine job is pinned to.
    .DESCRIPTION
        Three parts deploy separately - the engine image, this facade, the
        dashboard - and a deploy that stops halfway leaves them on different
        builds. So the dashboard does not assume the service matches it; it
        asks, and this is the answer.

        The engine's DEPLOYED image is read from the job definition, which this
        identity can already read because it starts executions on it. The
        digest is what the last publish pinned. Which VERSION that image is, the engine
        itself writes into every run's activity log as it starts. An engine
        that cannot be read is reported as exactly that - never as a version,
        and never as an error that takes the whole answer down with it.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Principal)
    Assert-VmfFacadeRole -Principal $Principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')

    $engine = [ordered]@{ image = $null; digest = $null; tag = $null; note = $null }
    $jobId = $env:VMF_ENGINE_JOB_ID
    if (-not $jobId) {
        $engine.note = 'The engine job is not configured on this service, so its image cannot be read.'
    }
    else {
        try {
            $resp = Send-VmfFacadeArmRequest -Method GET -Path "$jobId`?api-version=2025-01-01"
            if ($resp.StatusCode -ne 200) {
                $engine.note = "The engine job could not be read: HTTP $($resp.StatusCode)."
            }
            else {
                $image = [string]((($resp.Content | ConvertFrom-Json -Depth 20).properties.template.containers)[0].image)
                $engine.image = $image
                if ($image -match '@(sha256:[0-9a-f]+)$') {
                    $engine.digest = $Matches[1]
                }
                elseif ($image -like 'mcr.microsoft.com/k8se/quickstart-jobs*') {
                    # INSTALL-0 piece 4: the job was created on the placeholder and
                    # no code publish has replaced it yet. Said plainly.
                    $engine.tag = 'placeholder'
                    $engine.note = 'No engine image yet. The first code publish builds it and sets it.'
                }
                elseif ($image -match ':([^:/@]+)$') {
                    $engine.tag = $Matches[1]
                    $engine.note = "The engine job runs the tag '$($Matches[1])', not a digest, so which build it is cannot be proven from here."
                }
                else {
                    $engine.note = 'The engine job names an image with no tag and no digest.'
                }
            }
        }
        catch {
            $engine.note = "The engine job could not be read: $($_.Exception.Message)"
        }
    }

    # PIPELINE-LATER-1: no update model. A person runs every update, so the
    # answer carried who updates this deployment only while a pipeline could.
    [pscustomobject]@{
        service = Get-VmfVersion
        engine  = [pscustomobject]$engine
    }
}
