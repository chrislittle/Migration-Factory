#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
PERF-RUN-IDS-1: the run finder (Get-VmfFacadeRunIds) sends its listings of the
top-level folders together, at most 8 at a time.

WHAT WAS WRONG. The schedule timer and the daily cleanup both start with this
function. It listed the top of the store, then listed each top-level folder to
see whether it holds project.json, one listing after another. A store with P
projects and loose runs waited for 1 + P listings in a row before either pass
read a run.

THE RULE NOW.
  - The top of the store is listed first, every page of it.
  - The listings of the folders go out together through
    Invoke-VmfStorageGetMany (at most 8 in flight, one token), the same
    function the store reads of PERF-RUNS-LIST-1 use.
  - A folder listing that has a next marker is followed page by page from
    that marker, as Get-VmfStorePrefixes does: a project with more runs than
    one page holds is neither cut short nor taken for a run.
  - A listing the store refuses stops the walk with the status. Reading a
    refused listing as "no project.json here" would name a project as a run.
  - The run ids are the same as before, on blob and on the file store,
    including the folders that are not runs (PROJECT-3).

The blob service on this computer (_FakeBlobService.ps1) serves the same folder
the file store reads, so the two backends are compared on one store. It does
not page, so the paging rules use a mock of the two store calls.
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repo 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_FakeBlobService.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: a stand-in to mock, defined BEFORE the guard,
    # which blocks Get-AzAccessToken too.
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:savedStorePath = $env:VMF_STORE_PATH
    Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue

    # Twelve projects, each with two runs and the event log the old retention
    # pass left beside them; three loose runs; a run whose name only starts
    # like a folder that is not a run; and the two folders at the top that are
    # not runs. Sixteen folders to list: more than 8, so the limit is reached.
    $script:root = Join-Path (New-VmfTestTemp -Prefix 'runids') 'store'
    $write = { param($rel, $text)
        $full = Join-Path $script:root ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $text -NoNewline -Encoding utf8NoBOM
    }
    $script:want = [System.Collections.Generic.List[string]]::new()
    foreach ($i in 1..12) {
        $project = 'p{0:d2}' -f $i
        & $write "$project/project.json" "{`"projectId`":`"$project`"}"
        foreach ($run in 'mig', 'asmt') {
            & $write "$project/$run/run.json" "{`"runId`":`"$run`"}"
            $script:want.Add("$project/$run")
        }
        & $write "$project/logs/events.jsonl" '{"step":"retention"}'
    }
    foreach ($run in 'loose1', 'loose2', 'loose3', 'logs-of-war') {
        & $write "$run/run.json" "{`"runId`":`"$run`"}"
        $script:want.Add($run)
    }
    & $write 'vmf-claims/claim.json' '{}'
    & $write 'logs/events.jsonl' '{}'
    $script:want = @($script:want | Sort-Object)
    $script:folders = 16

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
    if ($null -ne $script:savedStorePath) { $env:VMF_STORE_PATH = $script:savedStorePath }
    Remove-VmfTestTemp
    Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'PERF-RUN-IDS-1: the run finder on the file store' {
    It 'finds every run, inside a project and loose, and no folder that is not a run' {
        @(Get-VmfFacadeRunIds -StorePath $script:root) | Should -Be $script:want
    }
}

Describe 'PERF-RUN-IDS-1: the run finder over HTTP, on blob storage' {
    BeforeAll {
        $script:svc = [VmfFakeBlobService]::new($script:root, 40)
        $script:svc.RequireToken = 'Bearer ids-token'
        $script:tokens = 0
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { $script:tokens++; [pscustomobject]@{ Token = 'ids-token' } }
        Mock -ModuleName FacadeCore Get-VmfFacadeContainerUri { "$($script:svc.BaseUri)cont" }
    }
    AfterAll { $script:svc.Dispose() }

    It 'gives the same run ids as the file store' {
        @(Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont') | Should -Be $script:want
    }

    It 'lists the top once and each folder that can hold a run once' {
        $script:svc.ResetCounts()
        $null = Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont'
        $script:svc.Requests | Should -Be (1 + $script:folders)
        $log = @($script:svc.Log)
        @($log | Where-Object { $_ -match 'prefix=(vmf-claims|logs)%2F' }) | Should -BeNullOrEmpty -Because 'a folder that is not a run is not listed (PROJECT-3)'
    }

    It 'THE DEFECT: sends the folder listings together, at most 8 in flight' {
        $script:svc.ResetCounts()
        $null = Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont'
        $script:svc.MaxInFlight | Should -Be 8 -Because 'one listing after another is what made each pass wait; 8 is the limit the store reads keep'
    }

    It 'asks for one token for the folder listings, not one for each' {
        $script:tokens = 0
        $null = Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont'
        # One for the top listing, one for all the folder listings together.
        $script:tokens | Should -BeLessOrEqual 2
    }
}

Describe 'PERF-RUN-IDS-1: paging and refusals' {
    BeforeAll {
        Mock -ModuleName FacadeCore Get-VmfFacadeContainerUri { 'https://store.example.com/cont' }
    }
    BeforeEach {
        $script:requests = [System.Collections.Generic.List[string]]::new()
        $script:together = [System.Collections.Generic.List[object]]::new()
        # The one-at-a-time request: the top of the store in two pages, and the
        # second page of the project 'big'.
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $script:requests.Add($Uri)
            $text = if ($Uri -match 'prefix=big%2F' -and $Uri -match 'marker=big-2') {
                        & $script:Xml -Blobs @('big/project.json') -Prefixes @('big/r3/', 'big/logs/')
                    }
                    elseif ($Uri -match 'prefix=big%2F') { throw 'the first page of big was sent again' }
                    elseif ($Uri -match 'marker=top-2') { & $script:Xml -Prefixes @('late/') }
                    elseif ($Uri -match 'prefix=(&|$)') { & $script:Xml -Prefixes @('big/', 'loose/', 'vmf-claims/') -Next 'top-2' }
                    else { throw "an unexpected request: $Uri" }
            [pscustomobject]@{ StatusCode = 200; Content = $text }
        }
        # The listings sent together: the first page of each folder. 'big' has
        # more runs than one page holds, and its project.json is on page 2.
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            $script:together.Add(@($Uri))
            , @($Uri | ForEach-Object {
                $text = if ($_ -match 'prefix=big%2F') { & $script:Xml -Prefixes @('big/r1/', 'big/r2/') -Next 'big-2' }
                        elseif ($_ -match 'prefix=loose%2F') { & $script:Xml -Blobs @('loose/run.json') -Prefixes @('loose/machines/') }
                        elseif ($_ -match 'prefix=late%2F') { & $script:Xml -Blobs @('late/project.json') -Prefixes @('late/r9/') }
                        else { throw "an unexpected listing: $_" }
                [pscustomobject]@{ StatusCode = 200; Content = $text }
            })
        }
    }

    It 'follows every page of the top, then sends every folder listing in one call' {
        $ids = @(Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont')
        $ids | Should -Contain 'late/r9' -Because 'late/ is on the second page of the top'
        $script:together.Count | Should -Be 1
        @($script:together[0]).Count | Should -Be 3 -Because 'big, loose and late; vmf-claims is not a run'
    }

    It 'a project whose project.json is on a later page is a project, with the runs of every page' {
        $ids = @(Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont')
        $ids | Should -Be @('big/r1', 'big/r2', 'big/r3', 'late/r9', 'loose')
    }

    It 'goes on from the next marker, and does not send the first page again' {
        $null = Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont'
        @($script:requests | Where-Object { $_ -match 'prefix=big%2F' }).Count | Should -Be 1
    }

    It 'a folder listing the store refuses stops the walk and names the status' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            , @($Uri | ForEach-Object {
                if ($_ -match 'prefix=loose%2F') { [pscustomobject]@{ StatusCode = 403; Content = 'refused' } }
                else { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Blobs @('x/run.json')) } }
            })
        }
        { Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont' } | Should -Throw '*HTTP 403*'
    }

    It 'a top listing the store refuses stops the walk and names the status' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 403; Content = 'refused' } }
        { Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont' } | Should -Throw '*HTTP 403*'
    }

    It 'a folder listing that never ends stops the walk rather than give part of a project' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $text = if ($Uri -match 'prefix=(&|$)') { & $script:Xml -Prefixes @('big/') }
                    else { & $script:Xml -Prefixes @('big/rx/') -Next 'again' }
            [pscustomobject]@{ StatusCode = 200; Content = $text }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            , @($Uri | ForEach-Object { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Prefixes @('big/r1/') -Next 'again') } })
        }
        { Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont' } | Should -Throw '*stopped early*'
    }

    It 'a top listing that never ends stops the walk rather than give part of the store' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Prefixes @('loose/') -Next 'again') }
        }
        { Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont' } | Should -Throw '*stopped early*'
        $script:together.Count | Should -Be 0 -Because 'nothing is listed below a top that was not read to its end'
    }

    It 'a store with no folders sends no folder listing' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 200; Content = (& $script:Xml -Blobs @('retention-status.json')) } }
        @(Get-VmfFacadeRunIds -StorePath 'azblob://acct/cont').Count | Should -Be 0
        $script:together.Count | Should -Be 0
    }
}

Describe 'PERF-RUN-IDS-1: the listing address' {
    BeforeAll {
        Mock -ModuleName FacadeCore Get-VmfFacadeContainerUri { 'https://store.example.com/cont' }
    }

    It 'escapes a marker, so a character the store puts in it cannot end the query or add a field' {
        $uri = InModuleScope FacadeCore { Get-VmfFacadeListUri -Prefix 'p 1/' -Delimiter '/' -Marker 'a b&c=d/+' }
        $uri | Should -BeExactly 'https://store.example.com/cont?restype=container&comp=list&prefix=p%201%2F&delimiter=%2F&marker=a%20b%26c%3Dd%2F%2B'
    }

    It 'sends no marker field for the first page' {
        $uri = InModuleScope FacadeCore { Get-VmfFacadeListUri -Prefix '' }
        $uri | Should -Not -Match 'marker='
    }
}
