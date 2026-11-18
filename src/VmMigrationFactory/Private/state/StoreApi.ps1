# STORE-1: generic run-store API. The RunPath STRING selects the backend:
#   - any filesystem path            -> 'file'  (v1 semantics, unchanged)
#   - azblob://<account>/<container>/<prefix> -> 'azblob' (Azure Blob backend)
# File semantics are the contract; the blob backend maps them 1:1:
#   atomic write            -> block-blob PUT (last writer wins)
#   FileMode.CreateNew      -> PUT with If-None-Match:* (exactly one creator)
#   shared-append JSONL     -> append blob AppendBlock
# CreateNew leases + atomic moves are correct on LOCAL disk only (never SMB);
# azblob is the multi-operator / cockpit / hosted-engine backend.

function Get-VmfStoreContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RunPath)

    if ($RunPath -match '^azblob://([^/]+)/([^/]+)/(.+?)/*$') {
        [pscustomobject]@{
            Backend = 'azblob'
            Account = $Matches[1]
            Container = $Matches[2]
            Prefix = $Matches[3]
            ContainerUri = "https://$($Matches[1]).blob.core.windows.net/$($Matches[2])"
        }
    }
    elseif ($RunPath -match '^azblob://') {
        throw "Invalid azblob store path '$RunPath' - expected azblob://<account>/<container>/<prefix>."
    }
    else {
        [pscustomobject]@{ Backend = 'file'; Root = $RunPath }
    }
}

function Get-VmfStoreFilePath {
    # file backend only: RelPath uses forward slashes; map to the local layout.
    param($Ctx, [string]$RelPath)
    Join-Path $Ctx.Root ($RelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
}

function Get-VmfStoreBlobPath {
    <#
    .SYNOPSIS
        RUNID-1: a store path, safe to put in a storage REST URI.
    .DESCRIPTION
        Each SEGMENT is escaped and the separators are kept. Escaping the whole
        path at once would escape the slashes too, and produce one blob whose
        name contains them.

        Why at all: the run id and the document name reach this from outside -
        the run id from the browser, a wave or machine name from Azure or from
        somebody typing - and they were concatenated into a URI raw. A '?' or a
        '#' in a name is URI SYNTAX, so it does not name a blob, it rewrites
        the request; '..' is normalised away by .NET before the request is even
        sent. The listing paths in this file have always escaped their prefix.
        This is the same rule for the paths that name one document.

        For every path this product actually writes - letters, digits, hyphens,
        dots, slashes - the result is byte for byte what it was before.

        A SEGMENT THAT IS '..' IS REFUSED, not escaped. FOUND BY THE TEST FOR
        THIS FUNCTION: a dot is an unreserved character, so escaping leaves
        '..' exactly as it was, and .NET then normalises it away while building
        the request - a read of `<run>/../plan.json` left the run entirely.
        Escaping alone looked like it covered this and did not.

        Refusing rather than repairing is the rule the facade's own key guard
        states: a path that had to be corrected before it was safe is not a
        path this should answer. Nothing in this product names a document '..'.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $segments = $Path -split '/'
    foreach ($segment in $segments) {
        if ($segment -eq '..') { throw "Store path '$Path' goes up a level, so it does not name a document in this run." }
    }
    ($segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

function Get-VmfStoreBlobUri {
    param($Ctx, [string]$RelPath)
    "$($Ctx.ContainerUri)/$(Get-VmfStoreBlobPath "$($Ctx.Prefix)/$RelPath")"
}

function Get-VmfStoreHandleUri {
    <#
    .SYNOPSIS
        SCHEDULE-PASS-DUE-1: the blob address of a document HANDLE
        (azblob://<account>/<container>/<path>) - a document of a run, or one
        at the top of the container.
    .DESCRIPTION
        The same address Get-VmfStoreBlobUri gives for a document of a run:
        each segment of the path is escaped, and a '..' segment is refused
        (Get-VmfStoreBlobPath). It also takes a document with no run above it,
        which Get-VmfStoreContext refuses as a run path on purpose - so the
        version-checked writer can write schedule-due.json at the top of the
        store, with the same If-Match as every other version-checked write.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Handle)
    if ($Handle -notmatch '^azblob://([^/]+)/([^/]+)/(.+)$') { throw "Invalid azblob document '$Handle' - expected azblob://<account>/<container>/<path>." }
    "https://$($Matches[1]).blob.core.windows.net/$($Matches[2])/$(Get-VmfStoreBlobPath $Matches[3])"
}

# EVENTLOG-1: how many parts a line document may roll into before this refuses
# to keep looking. 200 parts is ten million events. The number is a guard, not
# a budget: a loop with no end has no place in the one function every other
# component writes through.
$script:VmfStoreLinePartsMax = 200

# Which part of each line document this process is writing now, by run and
# document name. Synchronized because the engine runs several workers in one
# process (SCALE-2).
$script:VmfStoreLinePart = [hashtable]::Synchronized(@{})

function Get-VmfStoreLinePartKey {
    # The cache is keyed on the blob's own address, not on the run path as it
    # was typed - the same run written as .../run1 and .../run1/ is one run.
    param($Ctx, [string]$RelPath)
    "$($Ctx.ContainerUri)/$($Ctx.Prefix)|$RelPath"
}

function Clear-VmfStoreLinePart {
    <#
    .SYNOPSIS
        EVENTLOG-1: forget which part of this run's logs was being written.
    .DESCRIPTION
        A cache of a fact that moves forward is safe until the thing it
        describes goes backwards, and there are two moments where it does: a
        run that is deleted, and a run that is set up. After either, part two
        may not exist any more, and a writer still aiming at it would put the
        run's first line in a document that no reader reaches - readers stop at
        the first part that is not there, so the whole log would be invisible.
    #>
    param($Ctx)
    if ($Ctx.Backend -ne 'azblob') { return }
    $keyPrefix = "$($Ctx.ContainerUri)/$($Ctx.Prefix)|"
    foreach ($k in @($script:VmfStoreLinePart.Keys)) {
        if ($k.StartsWith($keyPrefix)) { $script:VmfStoreLinePart.Remove($k) }
    }
}

# FILE-BACKEND-RACE-1: on the file backend a document can be read by one
# process while another creates it (FileShare.None, the lease primitive),
# replaces it (File.Move over it) or removes it. Windows refuses each of those
# against a plain open ("being used by another process", "Access to the path
# is denied"), and a file removed between Test-Path and the read made the read
# throw. A watch loop and its workers do exactly this, all the time. So every
# file-backend read opens the file SHARED (others may write, replace or delete
# it) and tries again while it is mid-change, and every replace and delete
# tries again while a reader still has the file open. A file gone by the time
# it is read reads as not there. Blob storage has none of this.
# A held file is tried again for up to this long. The pause is the thread's own
# sleep: a test's guard turns Start-Sleep into no wait, which made every retry
# run in the same instant.
$script:VmfFileWaitMilliseconds = 1000
$script:VmfFileRetryMilliseconds = 25

function Get-VmfFileErrorKind {
    <#
    .SYNOPSIS
        FILE-BACKEND-RACE-1: what a file call's error means. A .NET call made
        from PowerShell throws a MethodInvocationException that WRAPS the real
        one, so a typed catch never sees an IOException: unwrap it first.
        'gone' (no file or folder), 'held' (in use, mid-replace, delete
        pending), or 'other'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Exception]$Exception)
    $e = $Exception
    while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    if ($e -is [System.IO.FileNotFoundException] -or $e -is [System.IO.DirectoryNotFoundException]) { return 'gone' }
    if ($e -is [System.IO.IOException] -or $e -is [System.UnauthorizedAccessException]) { return 'held' }
    'other'
}

function Read-VmfFileTextShared {
    <#
    .SYNOPSIS
        FILE-BACKEND-RACE-1: the text of a file, read with sharing that a
        writer, a replace or a delete allows. $null when the file is not
        there (or is empty, as Get-Content -Raw gives). Tries again while the
        file is held exclusively or mid-replace; throws after about a second.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $deadline = [DateTime]::UtcNow.AddMilliseconds($script:VmfFileWaitMilliseconds)
    while ($true) {
        try {
            $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            try {
                $reader = [System.IO.StreamReader]::new($fs, [System.Text.UTF8Encoding]::new($false), $true)
                $text = $reader.ReadToEnd()
            }
            finally { $fs.Dispose() }
            if ($text.Length -eq 0) { return $null }
            return $text
        }
        catch {
            $kind = Get-VmfFileErrorKind -Exception $_.Exception
            if ($kind -eq 'gone') { return $null }
            if ($kind -ne 'held') { throw }
            # A file whose delete is pending answers "access denied" until it
            # is gone; a file that stays held is a real refusal.
            if (-not [System.IO.File]::Exists($Path)) { return $null }
            if ([DateTime]::UtcNow -ge $deadline) { throw }
        }
        [System.Threading.Thread]::Sleep($script:VmfFileRetryMilliseconds)
    }
}

function Move-VmfFileReplace {
    <#
    .SYNOPSIS
        FILE-BACKEND-RACE-1: move a written temporary file over its target,
        trying again while a reader still has the target open (Windows refuses
        the replace then, even when the reader allows delete - measured). The
        temporary file is removed if the move never succeeds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($script:VmfFileWaitMilliseconds)
    while ($true) {
        try { [System.IO.File]::Move($Source, $Destination, $true); return }
        catch {
            if ((Get-VmfFileErrorKind -Exception $_.Exception) -ne 'held' -or [DateTime]::UtcNow -ge $deadline) {
                Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
                throw
            }
        }
        [System.Threading.Thread]::Sleep($script:VmfFileRetryMilliseconds)
    }
}

function Remove-VmfFileShared {
    <#
    .SYNOPSIS
        FILE-BACKEND-RACE-1: delete a file, trying again while a reader still
        has it open. Gone already is fine.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($script:VmfFileWaitMilliseconds)
    while ($true) {
        try { [System.IO.File]::Delete($Path); return }
        catch {
            $kind = Get-VmfFileErrorKind -Exception $_.Exception
            if ($kind -eq 'gone') { return }
            if ($kind -ne 'held' -or [DateTime]::UtcNow -ge $deadline) { throw }
        }
        [System.Threading.Thread]::Sleep($script:VmfFileRetryMilliseconds)
    }
}
function Read-VmfStoreText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') {
        return Read-VmfFileTextShared -Path (Get-VmfStoreFilePath $ctx $RelPath)
    }
    $resp = Invoke-VmfStorageRequest -Method GET -Uri (Get-VmfStoreBlobUri $ctx $RelPath)
    if ($resp.StatusCode -eq 404) { return $null }
    if ($resp.StatusCode -ne 200) { throw "Store read '$RelPath' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
    $resp.Content
}

function Write-VmfStoreText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') {
        $path = Get-VmfStoreFilePath $ctx $RelPath
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = "$path.tmp.$PID.$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
        [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
        Move-VmfFileReplace -Source $tmp -Destination $path
        return
    }
    $resp = Invoke-VmfStorageRequest -Method PUT -Uri (Get-VmfStoreBlobUri $ctx $RelPath) `
        -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body $Content
    if ($resp.StatusCode -ne 201) { throw "Store write '$RelPath' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
}

function Split-VmfStorePath {
    <#
    .SYNOPSIS
        The parent of a store path, for BOTH backends.
    .DESCRIPTION
        FOUND BY THE VOLUME DRILL, 2026-09-01, and it had broken the product.

        `Split-Path -Parent` MUST NOT be used on a store path. It does not
        throw - it silently rewrites

            azblob://account/container/run/assessment.json
        into
            azblob: followed by BACKSLASH-separated segments

        turning the forward slashes into backslashes. The store no longer
        recognises that as a blob path, and the caller eventually gets
        "Cannot find drive. A drive with the name 'azblob' does not exist."
        raised from somewhere else entirely, which points at nothing.

        The consequence was not cosmetic: `New-VmfPlan` derives the assessment's
        directory this way to find `approval.json`, so once ASSESS-PAGE-1 made
        that a gate, PLANNING FROM ANY ASSESSMENT ON BLOB STORAGE FAILED -
        approved or not. Blob storage is what the hosted engine uses. Every unit
        test passed throughout, because they all use local temp directories.

        `-Leaf` is safe (pure string work); it is `-Parent` that goes through the
        PowerShell provider. `Get-VmfClaimRoot` already had the right shape -
        branch on the azblob prefix FIRST - so this is that rule, in one place,
        where everything can reach it.
    .OUTPUTS
        The parent path, or '' when there is no parent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $trimmed = $Path.TrimEnd([char]0x2F, [char]0x5C)
    if ($trimmed -match '^azblob://') {
        # Never fewer than account/container: azblob://a/c has no parent that is
        # still a store path, and returning 'azblob://a' would invent one.
        if ($trimmed -match '^(azblob://[^/]+/[^/]+)/(.+)$') {
            $rest = $Matches[2]
            if ($rest -notmatch '/') { return $Matches[1] }
            return $trimmed -replace '/[^/]+$', ''
        }
        return $trimmed
    }
    $parent = Split-Path -Path $trimmed -Parent
    if ($null -eq $parent) { return '' }
    [string]$parent
}

function Read-VmfStoreJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter()][int]$Depth = 24
    )
    $raw = Read-VmfStoreText -RunPath $RunPath -RelPath $RelPath
    if ($null -eq $raw) { return $null }
    $raw | ConvertFrom-Json -Depth $Depth
}

function Read-VmfStoreTextMany {
    <#
    .SYNOPSIS
        PERF-RUNS-LIST-1: Read-VmfStoreText for many documents, read together.
        One text per item, in the same order; $null for a document that is not
        there, exactly as Read-VmfStoreText gives it.
    .DESCRIPTION
        On blob storage the reads go out together, at most 8 at a time
        (Invoke-VmfStorageGetMany). On the file backend they are read one by
        one, with the same shared read as every other file read: a local disk
        is not where the time went.
        Any answer other than 200 and 404 throws, naming the document, as
        Read-VmfStoreText does.
        PAGE-LOAD-1 removed it with the list of runs, its only caller then;
        PERF-PROJECTS-LIST-1 brought it back for the list of projects.
    .PARAMETER Items
        Objects with RunPath and RelPath.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)
    $list = @($Items)
    $out = [object[]]::new($list.Count)
    $blob = [System.Collections.Generic.List[int]]::new()
    $uris = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $list.Count; $i++) {
        $ctx = Get-VmfStoreContext -RunPath ([string]$list[$i].RunPath)
        if ($ctx.Backend -eq 'file') {
            $out[$i] = Read-VmfFileTextShared -Path (Get-VmfStoreFilePath $ctx ([string]$list[$i].RelPath))
            continue
        }
        $blob.Add($i)
        $uris.Add((Get-VmfStoreBlobUri $ctx ([string]$list[$i].RelPath)))
    }
    if ($blob.Count) {
        $answers = Invoke-VmfStorageGetMany -Uri $uris.ToArray()
        for ($k = 0; $k -lt $blob.Count; $k++) {
            $i = $blob[$k]
            $resp = $answers[$k]
            if ($resp.StatusCode -eq 404) { $out[$i] = $null; continue }
            if ($resp.StatusCode -ne 200) { throw "Store read '$([string]$list[$i].RelPath)' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
            $out[$i] = $resp.Content
        }
    }
    , $out
}

function Write-VmfStoreJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)]$Document,
        [Parameter()][int]$Depth = 24
    )
    Write-VmfStoreText -RunPath $RunPath -RelPath $RelPath -Content ($Document | ConvertTo-Json -Depth $Depth)
}

function Write-VmfStoreRootJson {
    <#
    .SYNOPSIS
        Write ONE document at the top of the store, beside the runs - such as
        the daily cleanup's retention-status.json.
    .DESCRIPTION
        Found on the first Azure install, 2026-09-24. The cleanup wrote its
        record with the store ROOT as the run path. In Azure the root is a bare
        container, which the store refuses as a run path on purpose - a run
        path naming the whole container would let a run delete reach every
        run. So the record was never written in Azure, and the safety-copies
        card could not say when the last pass ran. Local tests passed.

        This takes a NAME, not a path, and writes that one document. It deletes
        nothing and lists nothing, so the container root never becomes a run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Document,
        [Parameter()][int]$Depth = 24
    )
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "'$Name' is not a document name - a document at the top of the store has no folder." }
    $trimmed = $StorePath.TrimEnd([char]0x2F, [char]0x5C)
    $json = $Document | ConvertTo-Json -Depth $Depth
    if ($trimmed -match '^azblob://([^/]+)/([^/]+)$') {
        $uri = "https://$($Matches[1]).blob.core.windows.net/$($Matches[2])/$([uri]::EscapeDataString($Name))"
        $resp = Invoke-VmfStorageRequest -Method PUT -Uri $uri -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body $json
        if ($resp.StatusCode -ne 201) { throw "Store write '$Name' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
        return
    }
    # A local folder, or a store below the container: the ordinary writer.
    Write-VmfStoreText -RunPath $trimmed -RelPath $Name -Content $json
}

function Read-VmfStoreRootJson {
    <#
    .SYNOPSIS
        Read ONE document at the top of the store - the twin of
        Write-VmfStoreRootJson. $null when it is not there.
    .DESCRIPTION
        PERF-RETENTION-TIMEOUT-1: the daily cleanup now reads its own record
        back, to start where its last pass stopped. The same rule as the
        writer: a NAME, not a path, so the container root never becomes a run.

        Dates stay text (-DateKind String). ConvertFrom-Json would turn an ISO
        date into a date value, and the pass compares and writes them back
        (CLAUDE.md, PLANVER-2). A store that refuses the read throws: a refusal
        is not a document that is not there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][int]$Depth = 24
    )
    $raw = Read-VmfStoreRootText -StorePath $StorePath -Name $Name
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $raw | ConvertFrom-Json -Depth $Depth -DateKind String
}

function Get-VmfStoreRootHandle {
    <#
    .SYNOPSIS
        SCHEDULE-PASS-DUE-1: where ONE document at the top of the store is -
        @{ Blob = <azblob:// handle, or $null>; RunPath = <the folder on the
        file backend, or a store below the container> }. A NAME, not a path,
        as Write-VmfStoreRootJson takes, so the container root never becomes
        a run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "'$Name' is not a document name - a document at the top of the store has no folder." }
    $trimmed = $StorePath.TrimEnd([char]0x2F, [char]0x5C)
    if ($trimmed -match '^azblob://([^/]+)/([^/]+)$') { return [pscustomobject]@{ Blob = "$trimmed/$Name"; RunPath = $null } }
    [pscustomobject]@{ Blob = $null; RunPath = $trimmed }
}

function Read-VmfStoreRootText {
    <#
    .SYNOPSIS
        The TEXT of one document at the top of the store, as stored - $null
        when it is not there. SCHEDULE-PASS-DUE-1 reads schedule-due.json
        with it, so the version it judges (Get-VmfDocumentVersion) is the
        version of the text it read (PLANVER-2).
    .DESCRIPTION
        A store that refuses the read throws: a refusal is not a document that
        is not there.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Name
    )
    $at = Get-VmfStoreRootHandle -StorePath $StorePath -Name $Name
    if ($at.Blob) {
        $resp = Invoke-VmfStorageRequest -Method GET -Uri (Get-VmfStoreHandleUri -Handle $at.Blob)
        if ($resp.StatusCode -eq 404) { return $null }
        if ($resp.StatusCode -ne 200) { throw "Store read '$Name' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
        return [string]$resp.Content
    }
    # A local folder, or a store below the container: the ordinary reader.
    Read-VmfStoreText -RunPath $at.RunPath -RelPath $Name
}

function Write-VmfStoreRootTextIfVersion {
    <#
    .SYNOPSIS
        SCHEDULE-PASS-DUE-1: write one document at the top of the store only
        if it still holds the version the caller read (PLANVER-2). $true when
        this call wrote it; $false when it changed, is gone, or another
        version-checked writer holds it.
    .DESCRIPTION
        The same mechanism as every other version-checked write
        (Write-VmfTextDocumentIfVersion: If-Match on blob storage, the lock
        file on the file backend), for a document with no run above it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $at = Get-VmfStoreRootHandle -StorePath $StorePath -Name $Name
    if (-not $at.Blob) { return (Write-VmfStoreTextIfVersion -RunPath $at.RunPath -RelPath $Name -Content $Content -ExpectedVersion $ExpectedVersion) }
    try {
        Write-VmfTextDocumentIfVersion -Path $at.Blob -Content $Content -ExpectedVersion $ExpectedVersion
        $true
    }
    catch {
        if (([string]$_.Exception.Message).StartsWith('409:', [System.StringComparison]::Ordinal)) { return $false }
        throw
    }
}

function Write-VmfStoreRootTextExclusive {
    <#
    .SYNOPSIS
        SCHEDULE-PASS-DUE-1: create one document at the top of the store only
        if it is not there. $true when this call created it; $false when it
        was there already.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $at = Get-VmfStoreRootHandle -StorePath $StorePath -Name $Name
    if (-not $at.Blob) { return (Write-VmfStoreTextExclusive -RunPath $at.RunPath -RelPath $Name -Content $Content) }
    $resp = Invoke-VmfStorageRequest -Method PUT -Uri (Get-VmfStoreHandleUri -Handle $at.Blob) `
        -Headers @{ 'x-ms-blob-type' = 'BlockBlob'; 'If-None-Match' = '*' } -Body $Content
    if ($resp.StatusCode -eq 201) { return $true }
    if ($resp.StatusCode -in @(409, 412)) { return $false }
    throw "Store exclusive-create '$Name' failed: HTTP $($resp.StatusCode) $($resp.Content)"
}

function Write-VmfStoreJsonExclusive {
    <#
    .SYNOPSIS
        Create-if-absent: exactly one caller wins. Returns $true when this call
        created the document, $false when it already existed. This is THE
        mutual-exclusion primitive (leases).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)]$Document,
        # STORE-CREATE-LOST-ANSWER-1: see Write-VmfStoreTextExclusive.
        [Parameter()][switch]$UniqueText
    )
    Write-VmfStoreTextExclusive -RunPath $RunPath -RelPath $RelPath -Content ($Document | ConvertTo-Json -Depth 24) -UniqueText:$UniqueText
}

function Write-VmfStoreTextExclusive {
    <#
    .SYNOPSIS
        Write-VmfStoreJsonExclusive for a text the caller holds as it is
        stored - create-if-absent, so its version (PLANVER-2) is unchanged.
        STALE-APPROVAL-RACE-1 puts an approval back with it.
    .PARAMETER UniqueText
        STORE-CREATE-LOST-ANSWER-1: the text holds its writer's id and the
        time, so no other writer writes the same text - or the caller needs
        only that the document holds this text, whoever wrote it, and takes
        nothing for itself by the create (run-status.json).
        Invoke-VmfStorageRequest sends a PUT again when the answer to the
        first is lost; when the first one landed, the second meets the
        document and the store answers 409 or 412. With this switch the document is then read, and a document that
        holds this text (Get-VmfDocumentVersion, PLANVER-2) is this call's own
        create: $true. Without it a 409 or 412 is always $false, because two
        writers of one text would both win. The file backend gets no lost
        answer (CreateNew), so it is as it was.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter()][switch]$UniqueText
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    $json = $Content
    if ($ctx.Backend -eq 'file') {
        $path = Get-VmfStoreFilePath $ctx $RelPath
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        try {
            # CreateNew: atomic - the OS guarantees exactly one creator wins.
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush($true)
            }
            finally { $fs.Dispose() }
            return $true
        }
        catch {
            $e = $_.Exception
            while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
            if ($e -is [System.IO.IOException]) { return $false }
            # FILE-BACKEND-RACE-1: readers now allow delete, so a lease can be
            # mid-delete while one still has it open; CreateNew then answers
            # "access denied". The lease is still there, so somebody holds it.
            if ($e -is [System.UnauthorizedAccessException] -and [System.IO.File]::Exists($path)) { return $false }
            throw
        }
    }
    $uri = Get-VmfStoreBlobUri $ctx $RelPath
    $resp = Invoke-VmfStorageRequest -Method PUT -Uri $uri `
        -Headers @{ 'x-ms-blob-type' = 'BlockBlob'; 'If-None-Match' = '*' } -Body $json
    if ($resp.StatusCode -eq 201) { return $true }
    if ($resp.StatusCode -in @(409, 412)) {
        if (-not $UniqueText) { return $false }
        # The document as stored says whose create it was. A read the store
        # does not answer with 200, or does not answer at all, shows nothing,
        # so it stays $false, as before.
        try { $now = Invoke-VmfStorageRequest -Method GET -Uri $uri }
        catch { return $false }
        return ($now.StatusCode -eq 200 -and
            [string]::Equals((Get-VmfDocumentVersion -Text ([string]$now.Content)), (Get-VmfDocumentVersion -Text $json), [System.StringComparison]::Ordinal))
    }
    throw "Store exclusive-create '$RelPath' failed: HTTP $($resp.StatusCode) $($resp.Content)"
}

function Test-VmfStoreItem {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') { return [bool](Test-Path (Get-VmfStoreFilePath $ctx $RelPath)) }
    $resp = Invoke-VmfStorageRequest -Method HEAD -Uri (Get-VmfStoreBlobUri $ctx $RelPath)
    # STORE-RUNPATHS-REFUSED-1: only 404 says "not here". A 403, or a 500
    # after the retries, says nothing about the document, and read as "no" it
    # took a project for a loose run, a halt flag for no halt, and a plan for
    # no plan. It throws, as Read-VmfStoreText does for the same answers.
    if ($resp.StatusCode -eq 200) { return $true }
    if ($resp.StatusCode -eq 404) { return $false }
    throw "Store check '$RelPath' failed: HTTP $($resp.StatusCode) $($resp.Content)"
}

function Remove-VmfStoreItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') {
        Remove-VmfFileShared -Path (Get-VmfStoreFilePath $ctx $RelPath)
        return
    }
    $resp = Invoke-VmfStorageRequest -Method DELETE -Uri (Get-VmfStoreBlobUri $ctx $RelPath)
    if ($resp.StatusCode -notin @(202, 404)) { throw "Store delete '$RelPath' failed: HTTP $($resp.StatusCode)" }
}

function Get-VmfResponseETag {
    <#
    .SYNOPSIS
        The ETag of a storage response, whatever the case of the header name.
        Empty when there is none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Response)
    $etag = ''
    if ($Response -and $Response.Headers) {
        foreach ($k in @($Response.Headers.Keys)) { if ([string]$k -ieq 'ETag') { $etag = [string](@($Response.Headers[$k])[0]) } }
    }
    $etag
}

function Remove-VmfStoreAsideLeftover {
    <#
    .SYNOPSIS
        STALE-APPROVAL-RACE-1: remove the texts Remove-VmfStoreItemIfVersion
        moved aside more than a minute ago (<file>.removing-<ticks>-<id>). A
        remover that stopped between its two moves leaves one; it was being
        removed, and nothing reads it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($dir)) { return }
    $prefix = [System.IO.Path]::GetFileName($Path) + '.removing-'
    $limit = [DateTime]::UtcNow.AddMinutes(-1).Ticks
    foreach ($left in [System.IO.Directory]::GetFiles($dir, "$prefix*")) {
        $ticks = 0L
        $stamp = ([System.IO.Path]::GetFileName($left).Substring($prefix.Length) -split '-')[0]
        if ([long]::TryParse($stamp, [ref]$ticks) -and $ticks -lt $limit) { Remove-VmfFileShared -Path $left }
    }
}

function Remove-VmfStoreItemIfVersion {
    <#
    .SYNOPSIS
        STALE-APPROVAL-RACE-1: remove a document only if it still holds the
        version the caller judged (PLANVER-2). $true when this call removed it;
        $false when it is gone or holds another text, which is left as it is.
    .DESCRIPTION
        A judgement followed by an ordinary delete leaves a gap: a writer that
        lands between them loses its document, and the caller names the one it
        judged. Here the check and the delete are one step, the way
        Write-VmfTextDocumentIfVersion makes them one step for a write.

        On blob storage the delete carries If-Match with the ETag of the text
        whose version was checked. On the file backend, holding the lock a
        version-checked writer takes (Enter-VmfDocumentFileLock), the document
        is moved aside by a rename (one step; only one mover wins) and the text
        moved aside is checked. A lock another caller holds for the whole wait
        leaves the document as it is ($false). Text that is not the text judged goes back, unless a
        newer document is already in its place.
    .PARAMETER ExpectedVersion
        Get-VmfDocumentVersion of the text the caller judged.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') {
        $path = Get-VmfStoreFilePath $ctx $RelPath
        # A text left aside by a remover that stopped between its two moves
        # is older than a minute: it was being removed, so it goes. The time
        # is in the name - a rename keeps the file's own time.
        Remove-VmfStoreAsideLeftover -Path $path
        # LEASE-HEARTBEAT-RACE-1: the lock a version-checked writer holds
        # between its check and its write. Without it a removal could land in
        # that gap, and the writer then put back a document that was removed -
        # a renewal wrote its old holder over the lease a new holder created.
        # A lock held for the whole wait leaves the document as it is.
        $lock = Enter-VmfDocumentFileLock -Path $path
        if ($lock.Outcome -ne 'held') { return $false }
        try {
            # The name ends in no store extension, so no listing of the folder
            # finds it while it is aside.
            $aside = "$path.removing-$([DateTime]::UtcNow.Ticks)-$([System.Guid]::NewGuid().ToString('N'))"
            $deadline = [DateTime]::UtcNow.AddMilliseconds($script:VmfFileWaitMilliseconds)
            while ($true) {
                try { [System.IO.File]::Move($path, $aside); break }
                catch {
                    $kind = Get-VmfFileErrorKind -Exception $_.Exception
                    if ($kind -eq 'gone') { return $false }
                    if ($kind -ne 'held' -or [DateTime]::UtcNow -ge $deadline) { throw }
                }
                [System.Threading.Thread]::Sleep($script:VmfFileRetryMilliseconds)
            }
            $text = Read-VmfFileTextShared -Path $aside
            if ([string]::Equals((Get-VmfDocumentVersion -Text ([string]$text)), $ExpectedVersion, [System.StringComparison]::Ordinal)) {
                Remove-VmfFileShared -Path $aside
                return $true
            }
            # Another text: written after the judgement. Back in its place - and
            # if a newer one is there already, that one stays.
            try { [System.IO.File]::Move($aside, $path) }
            catch {
                if (-not [System.IO.File]::Exists($path)) { throw }
                Remove-VmfFileShared -Path $aside
            }
            return $false
        }
        finally { Exit-VmfDocumentFileLock -Lock $lock }
    }
    $uri = Get-VmfStoreBlobUri $ctx $RelPath
    $now = Invoke-VmfStorageRequest -Method GET -Uri $uri
    if ($now.StatusCode -eq 404) { return $false }
    if ($now.StatusCode -ne 200) { throw "Store read '$RelPath' failed: HTTP $($now.StatusCode) $($now.Content)" }
    if (-not [string]::Equals((Get-VmfDocumentVersion -Text ([string]$now.Content)), $ExpectedVersion, [System.StringComparison]::Ordinal)) { return $false }
    $etag = Get-VmfResponseETag -Response $now
    if (-not $etag) { throw "Store read '$RelPath' returned no ETag, so it cannot be removed safely." }
    $resp = Invoke-VmfStorageRequest -Method DELETE -Uri $uri -Headers @{ 'If-Match' = $etag }
    if ($resp.StatusCode -eq 202) { return $true }
    if ($resp.StatusCode -eq 412) { return $false }
    # Invoke-VmfStorageRequest sends a DELETE again when the answer to the
    # first is lost; if the first one landed, the second finds nothing.
    if ($resp.StatusCode -eq 404) { return $true }
    throw "Store delete '$RelPath' failed: HTTP $($resp.StatusCode)"
}

function Get-VmfStoreNames {
    <#
    .SYNOPSIS
        Leaf names (no folder, extension kept) of the documents in one store
        folder, e.g. Get-VmfStoreNames ... -Folder 'capacity' -> 'c1.json',...
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        # Empty = the documents directly under RunPath (a scope such as the
        # migration records, whose documents are not in a sub-folder).
        [Parameter(Mandatory)][AllowEmptyString()][string]$Folder,
        [Parameter()][string]$Extension   # e.g. '.json'; empty = all
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') {
        $dir = Get-VmfStoreFilePath $ctx $Folder
        $filter = if ($Extension) { "*$Extension" } else { '*' }
        # Select-Object, NOT ForEach-Object: ForEach-Object supports
        # ShouldProcess, so under -WhatIf it does not run and this returns
        # NOTHING. A -WhatIf caller then saw an empty store and reported
        # "nothing to do", which is the most dangerous wrong answer a preview
        # can give - it looks like a clean result. Found by the reaper's own
        # -WhatIf test.
        return @(Get-ChildItem $dir -Filter $filter -File -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)
    }
    $listPrefix = if ($Folder) { "$($ctx.Prefix)/$Folder/" } else { "$($ctx.Prefix)/" }
    $uri = "$($ctx.ContainerUri)?restype=container&comp=list&prefix=$([uri]::EscapeDataString($listPrefix))"
    $resp = Invoke-VmfStorageRequest -Method GET -Uri $uri
    if ($resp.StatusCode -ne 200) { throw "Store list '$Folder' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
    # Response is XML; the BOM-safe way is regex over <Name> nodes.
    $names = [regex]::Matches($resp.Content, '<Name>([^<]+)</Name>') | ForEach-Object {
        ($_.Groups[1].Value -split '/')[-1]
    }
    @($names | Where-Object { -not $Extension -or $_.EndsWith($Extension) })
}

function Get-VmfStorePrefixes {
    <#
    .SYNOPSIS
        PROJECT-1: the immediate child prefixes of a store root - the projects,
        or the runs inside one.
    .DESCRIPTION
        Derived from what is actually in the store rather than from an index. An
        index of projects would be a second source of truth that can disagree
        with the projects, and this codebase has already paid for that shape
        twice (the blocker wording, the storage check names).

        On blob this uses `delimiter=/`, which is how the API returns folders
        rather than every blob beneath them - so listing a store with a thousand
        runs is one small response, not a thousand names to post-process.
    .OUTPUTS
        [string[]] child names, no trailing slash.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$StorePath)

    $ctx = Get-VmfStoreContext -RunPath "$($StorePath.TrimEnd([char]0x2F, [char]0x5C))/_"
    if ($ctx.Backend -eq 'file') {
        $root = Split-VmfStorePath -Path "$($StorePath.TrimEnd([char]0x2F, [char]0x5C))/_"
        if (-not (Test-Path $root)) { return @() }
        # Select-Object for the same reason as Get-VmfStoreNames above: under
        # -WhatIf, ForEach-Object yields nothing.
        return @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)
    }

    # The context was built from a dummy child so the account/container split is
    # the same code path; the prefix to list is the ROOT, which for a container
    # root is empty.
    $prefix = Split-VmfStorePath -Path $ctx.Prefix
    if ($prefix -eq $ctx.Prefix) { $prefix = '' }
    $listPrefix = if ($prefix) { "$prefix/" } else { '' }

    $names = [System.Collections.Generic.List[string]]::new()
    $marker = ''
    $pages = 0
    do {
        $uri = "$($ctx.ContainerUri)?restype=container&comp=list&delimiter=%2F"
        if ($listPrefix) { $uri += "&prefix=$([uri]::EscapeDataString($listPrefix))" }
        if ($marker) { $uri += "&marker=$([uri]::EscapeDataString($marker))" }
        $resp = Invoke-VmfStorageRequest -Method GET -Uri $uri
        if ($resp.StatusCode -ne 200) { throw "Store prefix list failed: HTTP $($resp.StatusCode) $($resp.Content)" }
        foreach ($m in [regex]::Matches($resp.Content, '<BlobPrefix><Name>([^<]+)</Name></BlobPrefix>')) {
            $names.Add(($m.Groups[1].Value.TrimEnd('/') -split '/')[-1])
        }
        $marker = ([regex]::Match($resp.Content, '<NextMarker>([^<]*)</NextMarker>')).Groups[1].Value
        $pages++
    } while ($marker -and $pages -lt 100)

    @($names | Sort-Object -Unique)
}

function Get-VmfStoreFoldersHolding {
    <#
    .SYNOPSIS
        PERF-PROJECTS-LIST-1: which of these folders of a store root hold the
        document -Name, directly - for example the folders that hold
        project.json, which are the projects.
    .DESCRIPTION
        The list of projects read project.json in every top-level folder, one
        after another, and every loose run was a read that found nothing.
        MEASURED on the lab install (PERF-ANALYSIS-1): p50 2.4 to 5.9 s.

        On blob storage each folder is LISTED for the one name, the listings
        sent together through Invoke-VmfStorageGetMany (at most 8 in flight,
        one token) - the way the run finder lists the folders (PERF-RUN-IDS-1).
        The listing prefix is the document's own name, so a project that holds
        a thousand runs is still a short answer. A listing that has a next
        marker is followed from it, page by page, as Get-VmfStorePrefixes does.

        A LISTING THE STORE REFUSES THROWS, naming the folder and the status.
        Read as "the document is not here", a refusal would make a project
        disappear from the list with nothing said. A listing that still has a
        next page after 100 pages throws too, rather than guess.

        On the file backend: the document exists, or it does not.
    .OUTPUTS
        [string[]] the folders that hold the document, in the order given.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Folder,
        [Parameter(Mandatory)][string]$Name
    )
    $folders = @($Folder | Where-Object { $_ })
    if ($folders.Count -eq 0) { return @() }
    $root = $StorePath.TrimEnd([char]0x2F, [char]0x5C)
    $ctx = Get-VmfStoreContext -RunPath "$root/_"
    if ($ctx.Backend -eq 'file') {
        $dir = Split-VmfStorePath -Path "$root/_"
        return @($folders | Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $dir $_) $Name) -PathType Leaf })
    }

    # The root's own prefix, as Get-VmfStorePrefixes works it out.
    $prefix = Split-VmfStorePath -Path $ctx.Prefix
    if ($prefix -eq $ctx.Prefix) { $prefix = '' }
    $listPrefix = if ($prefix) { "$prefix/" } else { '' }
    $base = "$($ctx.ContainerUri)?restype=container&comp=list&delimiter=%2F"
    $uriOf = { param([string]$f, [string]$marker)
        $uri = "$base&prefix=$([uri]::EscapeDataString("$listPrefix$f/$Name"))"
        if ($marker) { $uri += "&marker=$([uri]::EscapeDataString($marker))" }
        $uri
    }
    $answers = Invoke-VmfStorageGetMany -Uri @($folders | ForEach-Object { & $uriOf $_ '' })
    @(for ($k = 0; $k -lt $folders.Count; $k++) {
        $f = $folders[$k]
        $want = "$listPrefix$f/$Name"
        $resp = $answers[$k]
        $pages = 1
        $found = $false
        while ($true) {
            if ([int]$resp.StatusCode -ne 200) { throw "Store list '$f/' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
            foreach ($m in [regex]::Matches([string]$resp.Content, '<Blob>\s*<Name>([^<]+)</Name>')) {
                if ([System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) -ceq $want) { $found = $true }
            }
            $marker = ([regex]::Match([string]$resp.Content, '<NextMarker>([^<]*)</NextMarker>')).Groups[1].Value
            if ($found -or -not $marker) { break }
            if ($pages -ge 100) { throw "Store list '$f/' stopped early: it has more pages than the store reads follow" }
            $resp = Invoke-VmfStorageRequest -Method GET -Uri (& $uriOf $f $marker)
            $pages++
        }
        if ($found) { $f }
    })
}

function Remove-VmfStorePrefix {
    <#
    .SYNOPSIS
        RUN-LIFECYCLE-1: delete an entire run - every document under its
        prefix. The only bulk delete in the store API, and the only caller is
        Remove-VmfRun, which decides whether that is allowed.
    .OUTPUTS
        [int] how many documents were deleted.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$RunPath)

    $ctx = Get-VmfStoreContext -RunPath $RunPath
    # EVENTLOG-1: the parts are going with the run.
    Clear-VmfStoreLinePart -Ctx $ctx
    if ($ctx.Backend -eq 'file') {
        if (-not (Test-Path $ctx.Root)) { return 0 }
        $count = @(Get-ChildItem $ctx.Root -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($PSCmdlet.ShouldProcess($ctx.Root, 'Delete every document in this run')) {
            Remove-Item $ctx.Root -Recurse -Force
        }
        return $count
    }

    # Blob: enumerate the whole prefix (paged) and delete each one. Listing
    # returns full blob names, so they are used as-is rather than re-derived.
    $deleted = 0
    $marker = ''
    $pages = 0
    do {
        $uri = "$($ctx.ContainerUri)?restype=container&comp=list&prefix=$([uri]::EscapeDataString("$($ctx.Prefix)/"))"
        if ($marker) { $uri += "&marker=$([uri]::EscapeDataString($marker))" }
        $resp = Invoke-VmfStorageRequest -Method GET -Uri $uri
        if ($resp.StatusCode -ne 200) { throw "Store list for delete failed: HTTP $($resp.StatusCode) $($resp.Content)" }
        $names = [regex]::Matches($resp.Content, '<Name>([^<]+)</Name>') | ForEach-Object { $_.Groups[1].Value }
        foreach ($n in $names) {
            if ($PSCmdlet.ShouldProcess($n, 'Delete document')) {
                # RUNID-1: escaped like every other document address. A name that
                # came back from a listing is still a name, and a delete that misses
                # is what leaves a run half-removed.
                $del = Invoke-VmfStorageRequest -Method DELETE -Uri "$($ctx.ContainerUri)/$(Get-VmfStoreBlobPath $n)"
                if ($del.StatusCode -in @(202, 404)) { $deleted++ }
                else { throw "Delete '$n' failed: HTTP $($del.StatusCode) $($del.Content)" }
            }
        }
        $marker = ([regex]::Match($resp.Content, '<NextMarker>([^<]*)</NextMarker>')).Groups[1].Value
        $pages++
        if ($pages -gt 100) { throw 'Refusing to page for ever while deleting a run - something is wrong with the listing.' }
    } while ($marker)

    # Check that it is actually gone. Observed on a real store: a run was
    # deleted and its events log was still there afterwards - something wrote
    # to it between the listing and the end. A delete that half-worked and said
    # nothing leaves a run that shows up in listings and cannot be opened, so
    # sweep once more and refuse quietly to call that success.
    if ($PSCmdlet.ShouldProcess($ctx.Prefix, 'Verify the run is gone')) {
        $check = Invoke-VmfStorageRequest -Method GET -Uri "$($ctx.ContainerUri)?restype=container&comp=list&prefix=$([uri]::EscapeDataString("$($ctx.Prefix)/"))"
        $left = if ($check.StatusCode -eq 200) {
            @([regex]::Matches($check.Content, '<Name>([^<]+)</Name>') | ForEach-Object { $_.Groups[1].Value })
        } else { @() }
        foreach ($n in $left) {
            $again = Invoke-VmfStorageRequest -Method DELETE -Uri "$($ctx.ContainerUri)/$(Get-VmfStoreBlobPath $n)"
            if ($again.StatusCode -in @(202, 404)) { $deleted++ }
            else { throw "The run was not fully deleted: '$n' remains (HTTP $($again.StatusCode)). Nothing else remains." }
        }
    }
    $deleted
}

function Add-VmfStoreLine {
    <#
    .SYNOPSIS
        Append one line to a shared line-oriented document (events.jsonl).
        Concurrent appenders never corrupt each other: file backend uses
        FileShare.ReadWrite whole-line writes, azblob uses an append blob.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$Line
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') {
        $path = Get-VmfStoreFilePath $ctx $RelPath
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Line + "`n")
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
                return
            }
            catch [System.IO.IOException] {
                if ($attempt -eq 5) { throw }
                Start-Sleep -Milliseconds (10 * $attempt)
            }
        }
        return
    }
    # EVENTLOG-1: WHICH PART OF THIS LOG IS BEING WRITTEN NOW.
    #
    # An append blob holds 50,000 blocks and this writes one per event, so a
    # long run fills a document and has to carry on in the next one. The part
    # in hand is remembered PER PROCESS, because otherwise every event for the
    # rest of the run would ask Azure about the full part first and be told no.
    # It is a cache of something that only ever moves forward, so one that is
    # behind costs a request and nothing else - and one that is ahead cannot
    # happen, since only this process put it there.
    $key = Get-VmfStoreLinePartKey -Ctx $ctx -RelPath $RelPath
    $part = if ($script:VmfStoreLinePart.ContainsKey($key)) { $script:VmfStoreLinePart[$key] } else { $RelPath }

    for ($roll = 0; $roll -lt $script:VmfStoreLinePartsMax; $roll++) {
        $uri = Get-VmfStoreBlobUri $ctx $part
        # Ensure the append blob exists (exactly-one-creator; 409/412 = already there).
        $create = Invoke-VmfStorageRequest -Method PUT -Uri $uri `
            -Headers @{ 'x-ms-blob-type' = 'AppendBlob'; 'If-None-Match' = '*' } -Body ''
        if ($create.StatusCode -notin @(201, 409, 412)) {
            throw "Store append-create '$part' failed: HTTP $($create.StatusCode) $($create.Content)"
        }
        $resp = Invoke-VmfStorageRequest -Method PUT -Uri "$uri`?comp=appendblock" -Body ($Line + "`n")

        # A log written by an older version can be a BLOCK blob, and appending to
        # one returns 409 InvalidBlobType for ever. Found clearing a real store:
        # the run could not be stopped or removed at all, because closing it out
        # writes a line about closing it out. A log that cannot be appended to must
        # not strand the run it belongs to, so the blob is converted in place,
        # keeping everything already in it.
        #
        # This rewrites the blob, so a writer appending at the same instant could
        # lose a line. That is accepted deliberately: it happens once, on a legacy
        # log, and the alternative is a run nobody can ever tidy away.
        if ($resp.StatusCode -eq 409 -and $resp.Content -match 'InvalidBlobType') {
            $existing = Read-VmfStoreText -RunPath $RunPath -RelPath $part
            # Azure will not change a blob's TYPE in place - a PUT of an append
            # blob over a block blob is refused with the same 409. The old one has
            # to go first, which is why its content is read above and put back
            # below.
            $drop = Invoke-VmfStorageRequest -Method DELETE -Uri $uri
            if ($drop.StatusCode -notin @(202, 404)) {
                throw "Store append '$part' could not remove the old log to convert it: HTTP $($drop.StatusCode) $($drop.Content)"
            }
            $recreate = Invoke-VmfStorageRequest -Method PUT -Uri $uri -Headers @{ 'x-ms-blob-type' = 'AppendBlob' } -Body ''
            if ($recreate.StatusCode -ne 201) {
                throw "Store append '$part' could not convert the old log: HTTP $($recreate.StatusCode) $($recreate.Content)"
            }
            if ($existing) {
                $keep = Invoke-VmfStorageRequest -Method PUT -Uri "$uri`?comp=appendblock" -Body $existing
                if ($keep.StatusCode -ne 201) {
                    throw "Store append '$part' lost the old log while converting it: HTTP $($keep.StatusCode)"
                }
            }
            $resp = Invoke-VmfStorageRequest -Method PUT -Uri "$uri`?comp=appendblock" -Body ($Line + "`n")
        }

        # THE PART IS FULL. Past 50,000 blocks Azure refuses with 409
        # BlockCountExceedsLimit, and this function used to THROW - so the
        # engine, which writes an event around every Azure call, would start
        # failing the migration itself. Worse, the run could not then be closed
        # out, for the reason written just above: closing it out writes a line
        # about closing it out.
        #
        # A thousand-machine run reaches it, and the product documents itself as
        # handling an estate that size. So the log rolls into the next part and
        # the line goes there instead. Nothing is dropped and nothing is
        # renamed.
        if ($resp.StatusCode -eq 409 -and $resp.Content -match 'BlockCountExceedsLimit') {
            $part = Get-VmfStoreLinePartName -RelPath $part
            $script:VmfStoreLinePart[$key] = $part
            continue
        }

        if ($resp.StatusCode -ne 201) { throw "Store append '$part' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
        return
    }
    throw ("Store append '$RelPath' found no part with room in $($script:VmfStoreLinePartsMax) tries. " +
        'Something is refusing every append, not filling every part.')
}

function Get-VmfStoreLinePartName {
    <#
    .SYNOPSIS
        EVENTLOG-1: the next part of a rolled line document.
    .DESCRIPTION
        logs/events.jsonl -> logs/events-2.jsonl -> logs/events-3.jsonl ...

        The FIRST part keeps the original name on purpose. Every run ever
        written has a logs/events.jsonl, every reader already asks for it, and
        renaming it would strand the history this product exists to keep.

        The dashboard has the twin of this in JavaScript (nextLogPart in
        help.js), because the engine does the naming and the browser does the
        reading. tests/fixtures/log-part-names.json is the one list of cases
        they are both held to - if they ever disagree, a log stops at part one
        and nobody is told.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RelPath)

    $dir = [System.IO.Path]::GetDirectoryName($RelPath) -replace '\\', '/'
    $ext = [System.IO.Path]::GetExtension($RelPath)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($RelPath)

    $n = 1
    if ($base -match '^(?<stem>.+)-(?<n>\d+)$') {
        $base = $Matches['stem']
        $n = [int]$Matches['n']
    }
    $name = "$base-$($n + 1)$ext"
    if ($dir) { "$dir/$name" } else { $name }
}

function Read-VmfStoreLines {
    <#
    .SYNOPSIS
        Every line of a line document, the parts it rolled into included.
    .DESCRIPTION
        EVENTLOG-1. A log that filled carries on in a next part, so asking for
        logs/events.jsonl has to answer with logs/events-2.jsonl as well, in
        order, or the console shows the first 50,000 events of a run and calls
        that the run.

        READING STOPS AT THE FIRST PART THAT IS NOT THERE. Parts are made in
        order and whatever makes one appends to it in the same breath, so a gap
        means the end. A log that never filled pays one read that finds
        nothing.

        POSITION IS NOT TIME. Several workers append at once, so a line in part
        2 can be older than a line in part 3 - as two lines inside one part can
        already be. Anything that cares WHEN something happened reads the
        timestamp.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $part = $RelPath
    for ($i = 0; $i -lt $script:VmfStoreLinePartsMax; $i++) {
        $raw = Read-VmfStoreText -RunPath $RunPath -RelPath $part
        if ([string]::IsNullOrWhiteSpace($raw)) { break }
        foreach ($line in ($raw -split "`r?`n")) {
            if ($line.Trim()) { $lines.Add($line) }
        }
        $part = Get-VmfStoreLinePartName -RelPath $part
    }
    @($lines)
}

function Read-VmfJsonDocument {
    <#
    .SYNOPSIS
        Read a JSON document by HANDLE: a local file path, or an azblob://
        document URI (as returned by Invoke-VmfAssessment / New-VmfPlan on the
        azblob backend). Lets -AssessmentPath / -PlanPath style parameters work
        unchanged on both backends.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][int]$Depth = 24
    )
    if ($Path -match '^azblob://(.+)/([^/]+)$') {
        return Read-VmfStoreJson -RunPath "azblob://$($Matches[1])" -RelPath $Matches[2] -Depth $Depth
    }
    # A missing file keeps Get-Content's own error, as before.
    if (-not [System.IO.File]::Exists($Path)) { return (Get-Content $Path -Raw | ConvertFrom-Json -Depth $Depth) }
    Read-VmfFileTextShared -Path $Path | ConvertFrom-Json -Depth $Depth
}

function Read-VmfTextDocument {
    <#
    .SYNOPSIS
        Raw text of a document by HANDLE (local file path or azblob:// URI) -
        for byte-faithful uses like hashing (APPR-1 plan binding).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '^azblob://(.+)/([^/]+)$') {
        return Read-VmfStoreText -RunPath "azblob://$($Matches[1])" -RelPath $Matches[2]
    }
    # A missing file keeps Get-Content's own error, as before.
    if (-not [System.IO.File]::Exists($Path)) { return (Get-Content $Path -Raw) }
    Read-VmfFileTextShared -Path $Path
}

function Write-VmfJsonDocument {
    <#
    .SYNOPSIS
        Write a JSON document by HANDLE (local file path or azblob:// document
        URI) - the write counterpart of Read-VmfJsonDocument.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Document,
        [Parameter()][int]$Depth = 24
    )
    if ($Path -match '^azblob://(.+)/([^/]+)$') {
        Write-VmfStoreJson -RunPath "azblob://$($Matches[1])" -RelPath $Matches[2] -Document $Document -Depth $Depth
        return
    }
    $tmp = "$Path.tmp.$PID.$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
    [System.IO.File]::WriteAllText($tmp, ($Document | ConvertTo-Json -Depth $Depth), [System.Text.UTF8Encoding]::new($false))
    Move-VmfFileReplace -Source $tmp -Destination $Path
}

# How long a version-checked writer or remover on the file backend waits for
# another one to finish with a document (Enter-VmfDocumentFileLock).
$script:VmfDocumentLockWaitMilliseconds = 10000

function Enter-VmfDocumentFileLock {
    <#
    .SYNOPSIS
        PLAN-WRITE-RACE-1, LEASE-HEARTBEAT-RACE-1: take the lock file that
        holds a file-backend check and its write (or its removal) together.
    .DESCRIPTION
        The lock is '<document>.lock', created the way a lease is: only one
        creator wins. It holds this caller's own token, so only this caller
        removes it (Exit-VmfDocumentFileLock). A lock older than a minute is
        from a writer that died: it is taken over by a RENAME, which only one
        caller wins, and put back if what was renamed was not the stale lock
        that was judged (another caller took it over first).

        Every version-checked writer (Write-VmfTextDocumentIfVersion) and
        every version-checked remover (Remove-VmfStoreItemIfVersion) takes it.
        A remover that did not take it could remove a lease between a
        renewal's check and its write, and the renewal then wrote the old
        holder over the new holder's lease.
    .OUTPUTS
        @{ Outcome = 'held' | 'busy' | 'gone'; Path; Token }. 'busy': another
        caller held it for the whole wait. 'gone': the folder is not there.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][int]$WaitMilliseconds = $script:VmfDocumentLockWaitMilliseconds
    )
    $lock = "$Path.lock"
    $token = [System.Guid]::NewGuid().ToString('N')
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMilliseconds)
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $bytes = [System.Text.Encoding]::ASCII.GetBytes($token); $fs.Write($bytes, 0, $bytes.Length) }
            finally { $fs.Dispose() }
            return [pscustomobject]@{ Outcome = 'held'; Path = $lock; Token = $token }
        }
        catch [System.IO.DirectoryNotFoundException] { return [pscustomobject]@{ Outcome = 'gone'; Path = $lock; Token = $null } }
        catch [System.IO.IOException] {
            # Asked first, on every pass: a stale lock that cannot be taken
            # over (the mutation run found this spinning for ever) must still
            # end in an answer.
            if ([DateTime]::UtcNow -gt $deadline) { return [pscustomobject]@{ Outcome = 'busy'; Path = $lock; Token = $null } }
            $held = Get-Item -LiteralPath $lock -ErrorAction SilentlyContinue
            if ($held -and $held.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-1)) {
                $was = Get-Content -LiteralPath $lock -Raw -ErrorAction SilentlyContinue
                $grave = "$lock.stale.$token"
                try {
                    [System.IO.File]::Move($lock, $grave)
                    $got = Get-Content -LiteralPath $grave -Raw -ErrorAction SilentlyContinue
                    if ($got -ne $was) { try { [System.IO.File]::Move($grave, $lock) } catch { } }
                    else { Remove-Item -LiteralPath $grave -Force -ErrorAction SilentlyContinue }
                }
                catch { Start-Sleep -Milliseconds 50 }
                continue
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Exit-VmfDocumentFileLock {
    <#
    .SYNOPSIS
        Remove a lock Enter-VmfDocumentFileLock gave, only while it still holds
        this caller's token.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Lock)
    if (-not $Lock -or $Lock.Outcome -ne 'held') { return }
    if ((Get-Content -LiteralPath $Lock.Path -Raw -ErrorAction SilentlyContinue) -eq $Lock.Token) {
        Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue
    }
}

function Write-VmfTextDocumentIfVersion {
    <#
    .SYNOPSIS
        PLAN-WRITE-RACE-1: write a document by HANDLE only if it still holds
        the version the caller read (PLANVER-2). Throws 409 otherwise.
    .DESCRIPTION
        A version check before an ordinary write leaves a gap: two writers
        both pass the check, and the second overwrites the first without a
        word. Here the check and the write are one step.

        On blob storage the write carries If-Match with the ETag of the text
        whose version was checked, so a write by anybody in between fails it.
        On the file backend a lock file, created the way a lease is (only one
        creator wins), holds the check and the write together. A lock older
        than a minute is from a writer that died, and is removed.
    .PARAMETER ExpectedVersion
        Get-VmfDocumentVersion of the text the caller read.
    .PARAMETER WaitMilliseconds
        How long a file-backend writer waits for another one to finish.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter()][int]$WaitMilliseconds = $script:VmfDocumentLockWaitMilliseconds
    )
    $changed = '409: Somebody changed the plan at the same time, so the product did not save this change. Load the page again, then make the change again.'
    if ($Path -match '^azblob://') {
        # SCHEDULE-PASS-DUE-1: the address of the handle, also for a document
        # at the top of the container (schedule-due.json), which has no run.
        $uri = Get-VmfStoreHandleUri -Handle $Path
        $now = Invoke-VmfStorageRequest -Method GET -Uri $uri
        if ($now.StatusCode -eq 404) { throw $changed }
        if ($now.StatusCode -ne 200) { throw "Store read '$Path' failed: HTTP $($now.StatusCode) $($now.Content)" }
        if ((Get-VmfDocumentVersion -Text ([string]$now.Content)) -ne $ExpectedVersion) { throw $changed }
        $etag = Get-VmfResponseETag -Response $now
        if (-not $etag) { throw "Store read '$Path' returned no ETag, so it cannot be written safely." }
        $resp = Invoke-VmfStorageRequest -Method PUT -Uri $uri -Headers @{ 'x-ms-blob-type' = 'BlockBlob'; 'If-Match' = $etag } -Body $Content
        if ($resp.StatusCode -eq 412) {
            # Invoke-VmfStorageRequest sends a PUT again when the answer to the
            # first is lost. If the first one landed, the second meets our own
            # text - a success, not somebody else's change.
            $again = Invoke-VmfStorageRequest -Method GET -Uri $uri
            if ($again.StatusCode -eq 200 -and (Get-VmfDocumentVersion -Text ([string]$again.Content)) -eq (Get-VmfDocumentVersion -Text $Content)) { return }
            throw $changed
        }
        if ($resp.StatusCode -ne 201) { throw "Store write '$Path' failed: HTTP $($resp.StatusCode) $($resp.Content)" }
        return
    }

    $lock = Enter-VmfDocumentFileLock -Path $Path -WaitMilliseconds $WaitMilliseconds
    if ($lock.Outcome -eq 'gone') { throw $changed }
    # Asked first, on every pass: a stale lock that cannot be taken over (the
    # mutation run found this spinning for ever) must still end in an answer.
    if ($lock.Outcome -ne 'held') { throw '409: The product is saving another change to the plan. Try again in a moment.' }
    try {
        $current = Read-VmfFileTextShared -Path $Path
        if ($null -eq $current -or (Get-VmfDocumentVersion -Text $current) -ne $ExpectedVersion) { throw $changed }
        $tmp = "$Path.tmp.$PID.$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
        [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
        Move-VmfFileReplace -Source $tmp -Destination $Path
    }
    finally { Exit-VmfDocumentFileLock -Lock $lock }
}

function Write-VmfStoreTextIfVersion {
    <#
    .SYNOPSIS
        DECIDE-CARRY-RACE-1: write one store document only if it still holds
        the version the caller read (PLANVER-2). $true when this call wrote
        it; $false when it changed, is gone, or another version-checked
        writer holds it - it is then left as it is.
    .DESCRIPTION
        The run-store twin of Write-VmfTextDocumentIfVersion, and the same
        mechanism: If-Match on the ETag of the checked text on blob storage,
        the lock file on the file backend. A decision's carry-forward reads a
        wave's approval, its acceptance and the plan sign-off, writes the
        decision on each, and writes it back. With an ordinary write, a record
        somebody wrote in between was lost.
    .PARAMETER ExpectedVersion
        Get-VmfDocumentVersion of the text the caller read.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    try {
        Write-VmfTextDocumentIfVersion -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath $RelPath) -Content $Content -ExpectedVersion $ExpectedVersion
        $true
    }
    catch {
        # Every refusal of the version-checked write is a 409; anything else
        # (a store that does not answer) is an error, not a record left.
        if (([string]$_.Exception.Message).StartsWith('409:', [System.StringComparison]::Ordinal)) { return $false }
        throw
    }
}

function Get-VmfStoreItemHandle {
    <#
    .SYNOPSIS
        The externally usable handle of a store item: local file path on the
        file backend, azblob:// document URI on azblob (readable by
        Read-VmfJsonDocument).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RelPath
    )
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') { return (Get-VmfStoreFilePath $ctx $RelPath) }
    "azblob://$($ctx.Account)/$($ctx.Container)/$($ctx.Prefix)/$RelPath"
}

function Initialize-VmfStore {
    <#
    .SYNOPSIS
        Backend bootstrap: file = run directory layout; azblob = ensure the
        container exists (idempotent; the storage ACCOUNT must already exist -
        provisioning infrastructure is an operator action, never implicit).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    # EVENTLOG-1: a run being set up has no parts yet, whatever this process
    # last believed about a run of the same name.
    Clear-VmfStoreLinePart -Ctx $ctx
    if ($ctx.Backend -eq 'file') {
        foreach ($dir in @('state', 'leases', 'evidence', 'logs')) {
            $p = Join-Path $ctx.Root $dir
            if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
        }
        return
    }
    $resp = Invoke-VmfStorageRequest -Method PUT -Uri "$($ctx.ContainerUri)?restype=container"
    if ($resp.StatusCode -notin @(201, 409)) {
        throw "Store container ensure failed: HTTP $($resp.StatusCode) $($resp.Content)"
    }
}
