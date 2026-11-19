#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
PERF-PROJECTS-LIST-1: the list of projects (Get-VmfProject -StorePath, behind
GET api/projects, which the first step of Assess and migrate asks for) reads
only the project folders, together.

WHAT WAS WRONG. For each top-level folder of the store, one after another, it
read project.json. A loose run, and every other folder that is not a project,
was a read that found nothing. Measured on the lab install (PERF-ANALYSIS-1):
p50 2.4 to 5.9 s, and the time grows with the number of top-level folders.

THE RULE NOW.
  - The top of the store is listed, every page of it (Get-VmfStorePrefixes).
  - Each folder is listed for project.json, the listings sent together through
    Invoke-VmfStorageGetMany (at most 8 in flight, one token), every page
    followed - the way the run finder lists the folders (PERF-RUN-IDS-1).
  - Only the folders whose listing names project.json are read, and those
    reads go together too (Read-VmfStoreTextMany, PERF-RUNS-LIST-1).
  - A listing or a read the store refuses stops the list with the status. A
    refusal read as "no project.json here" would make a project disappear.
  - The answer is the same, field for field, on blob and on the file store,
    as the function gave it before (the oracle below is that function).

The blob service on this computer (_FakeBlobService.ps1) serves the same folder
the file store reads. It does not page, so the paging rules use mocks.
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_FakeBlobService.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: a stand-in to mock, defined BEFORE the guard,
    # which blocks Get-AzAccessToken too.
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # Ten projects (each with a run), three loose runs, the claim registry, a
    # folder with a document whose name only starts like project.json, and a
    # folder with project.json one level down. Sixteen folders: more than 8.
    $script:base = New-VmfTestTemp -Prefix 'projlist'
    $script:root = Join-Path $script:base 'store'
    New-Item -ItemType Directory -Path $script:root | Out-Null
    $write = { param($rel, $text)
        $full = Join-Path $script:root ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $text -NoNewline -Encoding utf8NoBOM
    }
    $script:projectIds = @(1..10 | ForEach-Object { 'p{0:d2}' -f $_ })
    foreach ($id in $script:projectIds) {
        $a = @{ StorePath = $script:root; ProjectId = $id; Name = "Project $id"
                OnBehalfOf = @{ Identity = 'sam@example.com'; TenantId = 't1' } }
        if ($id -eq 'p02') { $a.Scope = @{ subscriptions = @('00000000-0000-0000-0000-000000000000') } }
        if ($id -eq 'p03') { $a.Note = 'Contoso datacentre exit' }
        New-VmfProject @a -Confirm:$false | Out-Null
        & $write "$id/mig/run.json" "{`"runId`":`"mig`",`"project`":`"$id`"}"
    }
    foreach ($run in 'loose1', 'loose2', 'loose3') { & $write "$run/run.json" "{`"runId`":`"$run`"}" }
    & $write 'vmf-claims/claim.json' '{}'
    & $write 'almost/project.json.bak' '{"projectId":"almost"}'
    & $write 'deeper/inner/project.json' '{"projectId":"deeper"}'
    $script:folders = 16

    # The function as it was before this item: every folder, one read each.
    $script:Oracle = { param([string]$StorePath)
        InModuleScope VmMigrationFactory -Parameters @{ sp = $StorePath } {
            @(foreach ($name in Get-VmfStorePrefixes -StorePath $sp) {
                $path = "$($sp.TrimEnd('/', '\'))/$name"
                $doc = Read-VmfStoreJson -RunPath $path -RelPath 'project.json' -Depth 6
                if ($doc) {
                    [pscustomobject]@{
                        ProjectId = [string]$doc.projectId; Name = [string]$doc.name
                        CreatedUtc = [string]$doc.createdUtc; CreatedBy = [string]$doc.createdBy
                        Scope = $doc.scope; Note = [string]$doc.note; ProjectPath = $path
                    }
                }
            })
        }
    }
    $script:Json = { param($rows) @($rows) | ConvertTo-Json -Depth 8 -AsArray }
    # The same rows without the path, which names the backend.
    $script:NoPath = { param($rows) @($rows | Select-Object -Property * -ExcludeProperty ProjectPath) }

    $script:Xml = { param([string[]]$Blobs = @(), [string[]]$Prefixes = @(), [string]$Next = '')
        $sb = [System.Text.StringBuilder]::new('<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Blobs>')
        foreach ($b in $Blobs) { $null = $sb.Append("<Blob><Name>$b</Name></Blob>") }
        foreach ($f in $Prefixes) { $null = $sb.Append("<BlobPrefix><Name>$f</Name></BlobPrefix>") }
        $null = $sb.Append('</Blobs>')
        $null = $sb.Append($(if ($Next) { "<NextMarker>$Next</NextMarker>" } else { '<NextMarker />' }))
        $null = $sb.Append('</EnumerationResults>')
        $sb.ToString()
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'PERF-PROJECTS-LIST-1: the list of projects on the file store' {
    It 'gives the answer the function gave before, field for field' {
        $want = & $script:Json (& $script:Oracle $script:root)
        @(& $script:Oracle $script:root).Count | Should -Be 10 -Because 'the oracle must see the projects, or the test agrees with nothing'
        & $script:Json (Get-VmfProject -StorePath $script:root) | Should -BeExactly $want
    }

    It 'gives the same answer when the store path ends in a separator' {
        $want = & $script:Json (& $script:Oracle "$script:root/")
        & $script:Json (Get-VmfProject -StorePath "$script:root/") | Should -BeExactly $want
    }

    It 'reads project.json only in the project folders' {
        $script:reads = [System.Collections.Generic.List[string]]::new()
        $script:realRead = InModuleScope VmMigrationFactory { Get-Command Read-VmfFileTextShared -CommandType Function }
        Mock -ModuleName VmMigrationFactory Read-VmfFileTextShared { $script:reads.Add([string]$Path); & $script:realRead -Path $Path }
        $null = Get-VmfProject -StorePath $script:root
        $script:reads.Count | Should -Be 10
        foreach ($r in $script:reads) { $r | Should -Match 'p\d\d[/\\]project\.json$' }
    }

    It 'gives nothing for a store with no folders' {
        $empty = Join-Path $script:base 'empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        @(Get-VmfProject -StorePath $empty).Count | Should -Be 0
    }
}

Describe 'PERF-PROJECTS-LIST-1: the list of projects over HTTP, on blob storage' {
    BeforeAll {
        $script:svc = [VmfFakeBlobService]::new($script:base, 40)
        $script:svc.RequireToken = 'Bearer projects-token'
        $env:VMF_TEST_CONTAINER_URI = "$($script:svc.BaseUri)cont"
        $script:tokens = 0
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { $script:tokens++; [pscustomobject]@{ Token = 'projects-token' } }
        # The store's own context, with the container at the local service.
        # The service serves the folder above the store, so the store is the
        # prefix 'store' in the container 'cont'.
        Mock -ModuleName VmMigrationFactory Get-VmfStoreContext {
            if ($RunPath -match '^azblob://([^/]+)/([^/]+)/(.+?)/*$') {
                return [pscustomobject]@{ Backend = 'azblob'; Account = $Matches[1]; Container = $Matches[2]; Prefix = $Matches[3]; ContainerUri = $env:VMF_TEST_CONTAINER_URI }
            }
            [pscustomobject]@{ Backend = 'file'; Root = $RunPath }
        }
        $script:blobStore = 'azblob://acct/cont/store'
    }
    AfterAll { $script:svc.Dispose(); Remove-Item Env:\VMF_TEST_CONTAINER_URI -ErrorAction SilentlyContinue }

    It 'gives the answer the function gave before on blob, field for field' {
        $want = & $script:Json (& $script:Oracle $script:blobStore)
        @(& $script:Oracle $script:blobStore).Count | Should -Be 10
        & $script:Json (Get-VmfProject -StorePath $script:blobStore) | Should -BeExactly $want
    }

    It 'gives the answer of the file store, and each path on blob' {
        $want = & $script:Json (& $script:NoPath (Get-VmfProject -StorePath $script:root))
        $got = @(Get-VmfProject -StorePath $script:blobStore)
        & $script:Json (& $script:NoPath $got) | Should -BeExactly $want
        $got.ProjectPath | Should -Be @($script:projectIds | ForEach-Object { "$script:blobStore/$_" })
    }

    It 'THE DEFECT: lists the top once, each folder once, and reads only the project folders' {
        $script:svc.ResetCounts()
        $null = Get-VmfProject -StorePath $script:blobStore
        $script:svc.Requests | Should -Be (1 + $script:folders + 10)
        $docReads = @($script:svc.Log | Where-Object { $_ -notmatch 'comp=list' })
        $docReads.Count | Should -Be 10
        foreach ($r in $docReads) { $r | Should -Match '^GET /cont/store/p\d\d/project\.json$' }
    }

    It 'THE DEFECT: sends the requests together, at most 8 in flight' {
        $script:svc.ResetCounts()
        $null = Get-VmfProject -StorePath $script:blobStore
        $script:svc.MaxInFlight | Should -Be 8 -Because 'one read after another is what made the first step wait; 8 is the limit the store reads keep'
    }

    It 'sends the folder listings in one batch and the project reads in another' {
        $script:batches = [System.Collections.Generic.List[object]]::new()
        $script:realMany = InModuleScope VmMigrationFactory { Get-Command Invoke-VmfStorageGetMany -CommandType Function }
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany { $script:batches.Add(@($Uri)); & $script:realMany -Uri $Uri }
        $null = Get-VmfProject -StorePath $script:blobStore
        $script:batches.Count | Should -Be 2
        @($script:batches[0]).Count | Should -Be $script:folders
        foreach ($u in $script:batches[0]) { $u | Should -Match 'comp=list' }
        @($script:batches[1]).Count | Should -Be 10
        foreach ($u in $script:batches[1]) { $u | Should -Match '/cont/store/p\d\d/project\.json$' }
    }

    It 'asks for one token for each batch, not one for each read' {
        $script:tokens = 0
        $null = Get-VmfProject -StorePath $script:blobStore
        # The top listing, the folder listings, the project reads.
        $script:tokens | Should -BeLessOrEqual 3
    }

    It 'a read the service answers "try later" is tried again, and the answer is the same' {
        $want = & $script:Json (Get-VmfProject -StorePath $script:root | Select-Object -Property * -ExcludeProperty ProjectPath)
        $script:svc.FailFirst['store/p04/project.json'] = 2
        & $script:Json (& $script:NoPath (Get-VmfProject -StorePath $script:blobStore)) | Should -BeExactly $want
        $script:svc.FailFirst['store/p04/project.json'] | Should -Be 0
    }

    It 'a store refused as a whole stops the list and names the status' {
        $script:svc.RequireToken = 'Bearer another-token'
        try { { Get-VmfProject -StorePath $script:blobStore } | Should -Throw '*HTTP 403*' }
        finally { $script:svc.RequireToken = 'Bearer projects-token' }
    }

    It 'a store at the root of its container gives the same projects' {
        $svcRoot = [VmfFakeBlobService]::new($script:root, 0)
        $svcRoot.RequireToken = 'Bearer projects-token'
        $saved = $env:VMF_TEST_CONTAINER_URI
        $env:VMF_TEST_CONTAINER_URI = "$($svcRoot.BaseUri)cont"
        try {
            $want = & $script:Json (& $script:NoPath (Get-VmfProject -StorePath $script:root))
            $got = @(Get-VmfProject -StorePath 'azblob://acct/cont')
            & $script:Json (& $script:NoPath $got) | Should -BeExactly $want
            $got[0].ProjectPath | Should -Be 'azblob://acct/cont/p01'
        }
        finally { $env:VMF_TEST_CONTAINER_URI = $saved; $svcRoot.Dispose() }
    }
}

Describe 'PERF-PROJECTS-LIST-1: paging, refusals and a document that went' {
    BeforeAll {
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'paging-token' } }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreContext {
            if ($RunPath -match '^azblob://([^/]+)/([^/]+)/(.+?)/*$') {
                return [pscustomobject]@{ Backend = 'azblob'; Account = $Matches[1]; Container = $Matches[2]; Prefix = $Matches[3]; ContainerUri = 'https://store.example.com/cont' }
            }
            [pscustomobject]@{ Backend = 'file'; Root = $RunPath }
        }
        $script:doc = { param($id) "{`"projectId`":`"$id`",`"name`":`"Project $id`",`"createdUtc`":`"2026-11-08T10:00:00Z`",`"createdBy`":`"sam@example.com`"}" }
    }
    BeforeEach {
        $script:requests = [System.Collections.Generic.List[string]]::new()
        $script:together = [System.Collections.Generic.List[object]]::new()
        # One at a time: the top of the store in two pages, and the second page
        # of the listing of 'big'.
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $script:requests.Add($Uri)
            $text = if ($Uri -match 'prefix=big%2F' -and $Uri -match 'marker=big-2') { & $script:Xml -Blobs @('big/project.json') }
                    elseif ($Uri -match 'prefix=big%2F') { throw 'the first page of big was sent again' }
                    elseif ($Uri -match 'marker=top-2') { & $script:Xml -Prefixes @('late/') }
                    elseif ($Uri -notmatch 'prefix=') { & $script:Xml -Prefixes @('big/', 'loose/') -Next 'top-2' }
                    else { throw "an unexpected request: $Uri" }
            [pscustomobject]@{ StatusCode = 200; Content = $text }
        }
        # Sent together: the first page of each folder listing, and the reads.
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            $script:together.Add(@($Uri))
            , @($Uri | ForEach-Object {
                if ($_ -match '/(big|late)/project\.json$') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:doc $Matches[1]) } }
                elseif ($_ -match 'prefix=big%2F') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Next 'big-2') } }
                elseif ($_ -match 'prefix=loose%2F') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml) } }
                elseif ($_ -match 'prefix=late%2F') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Blobs @('late/project.json')) } }
                else { throw "an unexpected request: $_" }
            })
        }
    }

    It 'follows every page of the top, and a project.json named on a later page of a folder listing' {
        @(Get-VmfProject -StorePath 'azblob://acct/cont').ProjectId | Should -Be @('big', 'late')
        $script:together.Count | Should -Be 2
        @($script:together[0]).Count | Should -Be 3 -Because 'big, loose and late, in one batch'
    }

    It 'goes on from the next marker, and does not send the first page again' {
        $null = Get-VmfProject -StorePath 'azblob://acct/cont'
        @($script:requests | Where-Object { $_ -match 'prefix=big%2F' }).Count | Should -Be 1
    }

    It 'lists a folder only for project.json, so a folder of many runs is a short listing' {
        $null = Get-VmfProject -StorePath 'azblob://acct/cont'
        foreach ($u in $script:together[0]) { $u | Should -Match 'prefix=[a-z]+%2Fproject\.json(&|$)' }
    }

    It 'a folder listing the store refuses stops the list and names the folder and the status' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            , @($Uri | ForEach-Object {
                if ($_ -match 'prefix=loose%2F') { [pscustomobject]@{ StatusCode = 403; Content = 'refused' } }
                else { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml) } }
            })
        }
        { Get-VmfProject -StorePath 'azblob://acct/cont' } | Should -Throw "*'loose/'*HTTP 403*"
    }

    It 'a project read the store refuses stops the list and names the document and the status' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            , @($Uri | ForEach-Object {
                if ($_ -match '/late/project\.json$') { [pscustomobject]@{ StatusCode = 500; Content = 'broken' } }
                elseif ($_ -match '/big/project\.json$') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:doc 'big') } }
                elseif ($_ -match 'prefix=big%2F') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Next 'big-2') } }
                elseif ($_ -match 'prefix=late%2F') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Blobs @('late/project.json')) } }
                else { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml) } }
            })
        }
        { Get-VmfProject -StorePath 'azblob://acct/cont' } | Should -Throw "*'project.json'*HTTP 500*"
    }

    It 'a project.json that went between the listing and the read is not a project, as before' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            , @($Uri | ForEach-Object {
                if ($_ -match '/late/project\.json$') { [pscustomobject]@{ StatusCode = 404; Content = '<Error/>' } }
                elseif ($_ -match '/big/project\.json$') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:doc 'big') } }
                elseif ($_ -match 'prefix=big%2F') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Next 'big-2') } }
                elseif ($_ -match 'prefix=late%2F') { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Blobs @('late/project.json')) } }
                else { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml) } }
            })
        }
        @(Get-VmfProject -StorePath 'azblob://acct/cont').ProjectId | Should -Be @('big')
    }

    It 'a folder listing that never ends stops the list rather than guess' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $text = if ($Uri -notmatch 'prefix=') { & $script:Xml -Prefixes @('big/') } else { & $script:Xml -Next 'again' }
            [pscustomobject]@{ StatusCode = 200; Content = $text }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            , @($Uri | ForEach-Object { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Next 'again') } })
        }
        { Get-VmfProject -StorePath 'azblob://acct/cont' } | Should -Throw '*stopped early*'
    }

    It 'a store with no folders sends no folder listing' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Blobs @('retention-status.json')) } }
        @(Get-VmfProject -StorePath 'azblob://acct/cont').Count | Should -Be 0
        $script:together.Count | Should -Be 0
    }
}
