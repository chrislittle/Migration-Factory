#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
PAGE-LOAD-1: many store documents in one call (GET /api/store/docs).

WHAT WAS WRONG. MEASURED on the lab install, 2026-11-06 (Application
Insights, 15:16-15:21 UTC): one load of the Overview or the Assessments page
sent about 200 calls to the service - about 140 GetStoreBlob and 30
GetStoreList in 30 seconds, one for each store document: every run.json,
assessment.json, approval.json and run-status.json. Each call took 30 ms to
2 s, and the page waited for all of them. A page load sometimes took 2
minutes.

THE RULE NOW.
  - One call lists the store once and reads every document whose name the
    page asks for, at most 8 in flight (Invoke-VmfStorageGetMany), and gives
    back the listing down to a depth and the text of each document.
  - The same app roles as the per-file reads it replaces (store/blob and
    store/list: Viewer, Approver, Operator, Administrator), and nothing those
    roles could not already read: every blob of the container is readable
    through store/blob by the same roles.
  - The text of each document is as the store holds it. A document that is
    not JSON is given back as it is, and the rest are still there: the page
    parses each one by itself.
  - No document version. A page that saves a document reads it through
    store/blob, whose header carries the version the service issued
    (PLANVER-2); a version in a bulk answer would be a second mechanism.
  - Paging: a call stops after a budget of documents and characters and says
    where to go on (`next`), so a store that grows does not make one answer
    without a limit.

tests/fixtures/store-docs.json is the one list of answers the service and the
pages are both held to (tests/js/page-load.test.js).
#>
BeforeDiscovery {
    # The cases name the tests, so they are read before Pester finds them.
    $script:fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'store-docs.json') -Raw | ConvertFrom-Json -Depth 20
}
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repo 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_FakeBlobService.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: a stand-in to mock, defined BEFORE the guard.
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:fixture = Get-Content (Join-Path $script:repo 'tests' 'fixtures' 'store-docs.json') -Raw | ConvertFrom-Json -Depth 20

    # The fixture store, on disk: an object is written as a document, a string
    # as raw text (so a document that is not JSON can be in it).
    $script:NewStore = { param([string]$name)
        $root = Join-Path (New-VmfTestTemp -Prefix 'storedocs') $name
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($f in $script:fixture.files.PSObject.Properties) {
            $file = Join-Path $root ($f.Name -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
            $text = if ($f.Value -is [string]) { $f.Value } else { $f.Value | ConvertTo-Json -Depth 10 }
            [System.IO.File]::WriteAllText($file, $text, [System.Text.UTF8Encoding]::new($false))
        }
        $root
    }
    $script:root = & $script:NewStore 'store'

    $script:Principal = { param([string[]]$roles) [pscustomobject]@{ Identity = 'viewer@example.com'; Roles = @($roles) } }
    $script:viewer = & $script:Principal @('Vmf.Viewer')
    # RECORDS-VIEWER-READ-1: the fixture is the answer an Admin gets - the
    # whole store. Every other role gets it less the folders the product keeps
    # beside the runs (vmf-claims here); see 'the answer to every other role'.
    $script:admin = & $script:Principal @('Vmf.Admin')
    $script:Docs = { param($query, [hashtable]$more = @{})
        $args2 = @{ Principal = $script:admin; Depth = [int]$query.depth; Read = @($query.read) }
        foreach ($k in $more.Keys) { $args2[$k] = $more[$k] }
        Get-VmfFacadeStoreDocs @args2
    }
    # What the per-file read gives for one document: GetStoreBlob reads the
    # file with Get-Content -Raw on this backend.
    $script:PerFile = { param([string]$path)
        Get-Content -LiteralPath (Join-Path $script:root ($path -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -Raw
    }
}

AfterAll {
    Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
    Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'PAGE-LOAD-1: the same app roles as the per-file reads' {
    BeforeAll { $env:VMF_STORE_PATH = $script:root }

    It 'refuses a caller who is not signed in, as store/blob does' {
        { Get-VmfFacadeStoreDocs -Principal $null -Depth 3 -Read 'run.json' } | Should -Throw '401*'
    }
    It 'refuses a signed-in caller with no product role' {
        { Get-VmfFacadeStoreDocs -Principal (& $script:Principal @('Some.Other')) -Depth 3 -Read 'run.json' } | Should -Throw '403*'
    }
    It 'answers each of the four roles that may read the store: <_>' -ForEach @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin') {
        $out = Get-VmfFacadeStoreDocs -Principal (& $script:Principal @($_)) -Depth 3 -Read 'run.json'
        @($out.docs).Count | Should -BeGreaterThan 0
    }
    It 'gates on exactly the role set of store/blob and store/list' {
        $code = { param($file) (Get-Content (Join-Path $script:repo 'src' 'facade' 'app' $file 'run.ps1') -Raw) }
        $setOf = { param($text) ([regex]::Match($text, 'Assert-VmfFacadeRole -Principal \$\w+ -AnyOf @\(([^)]*)\)')).Groups[1].Value -replace '\s', '' }
        $blob = & $setOf (& $code 'GetStoreBlob')
        $list = & $setOf (& $code 'GetStoreList')
        $core = Get-Content (Join-Path $script:repo 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $fn = [regex]::Match($core, '(?ms)^function Get-VmfFacadeStoreDocs \{(.*?)^\}').Groups[1].Value
        $docs = & $setOf $fn
        $blob | Should -Not -BeNullOrEmpty
        $docs | Should -BeExactly $blob
        $docs | Should -BeExactly $list
    }
}

Describe 'PAGE-LOAD-1: the answer, held to the fixture (file store)' {
    BeforeAll { $env:VMF_STORE_PATH = $script:root }

    It '<name>: the listing down to the depth' -ForEach @($script:fixture.cases | ForEach-Object { @{ name = $_.name; case = $_ } }) {
        $out = & $script:Docs $case.query
        @($out.names) | Should -BeExactly @($case.names)
        @($out.folders) | Should -BeExactly @($case.folders)
        $out.truncated | Should -BeFalse
        $out.next | Should -BeExactly ''
    }
    It '<name>: every document asked for, and nothing else' -ForEach @($script:fixture.cases | ForEach-Object { @{ name = $_.name; case = $_ } }) {
        $out = & $script:Docs $case.query
        @($out.docs | ForEach-Object { $_.path }) | Should -BeExactly @($case.docs)
    }
    It '<name>: each text is what the per-file read gives' -ForEach @($script:fixture.cases | ForEach-Object { @{ name = $_.name; case = $_ } }) {
        $out = & $script:Docs $case.query
        foreach ($d in @($out.docs)) { $d.text | Should -BeExactly (& $script:PerFile $d.path) -Because $d.path }
    }
    It 'a document that is not JSON is given back as it is, and the others are still there' {
        $out = & $script:Docs $script:fixture.cases[0].query
        $bad = @($out.docs | Where-Object path -EQ 'proj/a2/assessment.json')
        $bad.Count | Should -Be 1
        $bad[0].text | Should -BeExactly '{ this document was cut short'
        @($out.docs).Count | Should -Be @($script:fixture.cases[0].docs).Count
    }
    It 'the answer goes through JSON with every text whole' {
        $out = & $script:Docs $script:fixture.cases[0].query
        $round = $out | ConvertTo-Json -Depth 6 -Compress | ConvertFrom-Json -Depth 6
        foreach ($d in @($round.docs)) { $d.text | Should -BeExactly (& $script:PerFile $d.path) }
    }
    It 'gives no document version: a page that saves reads that document through store/blob (PLANVER-2)' {
        $out = & $script:Docs $script:fixture.cases[0].query
        @($out.docs | Where-Object { $_.PSObject.Properties.Name -contains 'version' }).Count | Should -Be 0
        $out.PSObject.Properties.Name | Should -Not -Contain 'version'
    }
    It 'an empty store answers with nothing, not an error' {
        $env:VMF_STORE_PATH = Join-Path (New-VmfTestTemp -Prefix 'storedocs') 'empty'
        New-Item -ItemType Directory -Path $env:VMF_STORE_PATH | Out-Null
        try {
            $out = Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read 'run.json'
            @($out.names).Count | Should -Be 0
            @($out.folders).Count | Should -Be 0
            @($out.docs).Count | Should -Be 0
            $out.next | Should -BeExactly ''
            ($out | ConvertTo-Json -Depth 6 -Compress) | Should -Match '"docs":\[\]'
        }
        finally { $env:VMF_STORE_PATH = $script:root }
    }
}

Describe 'RECORDS-VIEWER-READ-1: the answer to every other role' {
    BeforeAll {
        $env:VMF_STORE_PATH = $script:root
        $script:kept = @(& (Get-Module VmMigrationFactory) { Get-VmfNotARunFolders })
        $script:Less = { param($list) @($list | Where-Object { (($_ -split '/')[0]) -notin $script:kept }) }
    }

    It '<name>: a <role> gets the fixture answer less the folders the product keeps' -ForEach @(
        foreach ($role in 'Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator') {
            foreach ($c in $script:fixture.cases) { @{ name = $c.name; case = $c; role = $role } }
        }) {
        $out = & $script:Docs $case.query @{ Principal = (& $script:Principal @($role)) }
        @($out.names) | Should -BeExactly @(& $script:Less $case.names)
        @($out.folders) | Should -BeExactly @(& $script:Less $case.folders)
        @($out.docs | ForEach-Object path) | Should -BeExactly @(& $script:Less $case.docs)
        @($case.folders | Where-Object { (($_ -split '/')[0]) -in $script:kept }).Count | Should -BeGreaterThan 0 -Because 'the fixture holds a kept folder, so the test can fail'
    }
}

Describe 'PAGE-LOAD-1: paging' {
    BeforeAll { $env:VMF_STORE_PATH = $script:root }

    It 'stops after the budget of documents, says where to go on, and the pages together are the whole answer' {
        $query = $script:fixture.cases[0].query
        $first = & $script:Docs $query @{ MaxDocs = 4 }
        @($first.docs).Count | Should -Be 4
        $first.next | Should -BeExactly @($first.docs)[-1].path
        $all = [System.Collections.Generic.List[string]]::new()
        $all.AddRange([string[]]@($first.docs | ForEach-Object path))
        $after = $first.next
        $calls = 1
        while ($after -and $calls -lt 10) {
            $page = & $script:Docs $query @{ MaxDocs = 4; After = $after }
            @($page.names).Count | Should -Be 0 -Because 'the listing comes with the first page only'
            $all.AddRange([string[]]@($page.docs | ForEach-Object path))
            $after = $page.next
            $calls++
        }
        $calls | Should -Be 3
        @($all) | Should -BeExactly @($script:fixture.cases[0].docs)
    }
    It 'stops after the budget of characters, and always gives at least one document' {
        $query = $script:fixture.cases[0].query
        $page = & $script:Docs $query @{ MaxChars = 1 }
        @($page.docs).Count | Should -Be 1
        $page.next | Should -BeExactly @($page.docs)[0].path
    }
    It 'the last page says there is no more' {
        $out = & $script:Docs $script:fixture.cases[0].query @{ After = 'proj/m1/run.json' }
        @($out.docs | ForEach-Object path) | Should -BeExactly @('proj/project.json')
        $out.next | Should -BeExactly ''
    }
}

Describe 'PAGE-LOAD-1: what the caller names is checked before it is used' {
    BeforeAll { $env:VMF_STORE_PATH = $script:root }

    It 'refuses a depth of <_>' -ForEach @(0, 7, -1) {
        { Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth $_ -Read 'run.json' } | Should -Throw '400*'
    }
    It 'refuses the name pattern <_>' -ForEach @('../run.json', 'state/../x', '/run.json', 'a\b', 'x:y', 'run.json?', '[ab].json', '', 'a//b', 'state/') {
        { Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read @($_) } | Should -Throw '400*'
    }
    It 'refuses more than 12 name patterns' {
        { Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read @(1..13 | ForEach-Object { "f$_.json" }) } | Should -Throw '400*'
    }
    It 'refuses a call that names no document' {
        { Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read @() } | Should -Throw '400*'
    }
    It 'refuses a prefix that climbs out, or that is not a folder' -ForEach @('../x/', 'proj') {
        { Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read 'run.json' -Prefix $_ } | Should -Throw '400*'
    }
    It 'refuses an after that climbs out' {
        { Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read 'run.json' -After '../x' } | Should -Throw '400*'
    }
    It 'a prefix lists and reads inside that folder only, and the depth counts from it' {
        $out = Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 2 -Read 'run.json' -Prefix 'proj/'
        @($out.docs | ForEach-Object path) | Should -BeExactly @('proj/a1/run.json', 'proj/a2/run.json', 'proj/m1/run.json')
        @($out.names | Where-Object { -not $_.StartsWith('proj/') }).Count | Should -Be 0
        @($out.names) | Should -Not -Contain 'proj/m1/state/vm1.json'
    }
}

Describe 'PAGE-LOAD-1: a listing the service cut short' {
    BeforeAll { $env:VMF_STORE_PATH = $script:root }

    It 'says so, and reads no document: the page cannot tell what is missing from it, so it asks for each one' {
        Mock -ModuleName FacadeCore Get-VmfFacadeStoreListing { [pscustomobject]@{ names = @('proj/a1/run.json'); prefixes = @(); truncated = $true } }
        $out = Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read 'run.json'
        $out.truncated | Should -BeTrue
        @($out.docs).Count | Should -Be 0
    }
}

Describe 'PAGE-LOAD-1: over HTTP, on blob storage' {
    BeforeAll {
        Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        $env:VMF_STORE_ACCOUNT = 'acct'
        $env:VMF_STORE_CONTAINER = 'cont'
        $script:svc = [VmfFakeBlobService]::new($script:root, 20)
        $script:svc.RequireToken = 'Bearer docs-token'
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'docs-token' } }
        Mock -ModuleName FacadeCore Get-VmfFacadeContainerUri { "$($script:svc.BaseUri)cont" }
        # The file store's answer, to compare with.
        $env:VMF_STORE_PATH = $script:root
        $script:want = @{}
        foreach ($c in $script:fixture.cases) { $script:want[$c.name] = (& $script:Docs $c.query) | ConvertTo-Json -Depth 6 -Compress }
        Remove-Item Env:\VMF_STORE_PATH
    }
    AfterAll {
        $script:svc.Dispose()
        Remove-Item Env:\VMF_STORE_ACCOUNT, Env:\VMF_STORE_CONTAINER -ErrorAction SilentlyContinue
    }

    It '<name>: the same answer as the file store' -ForEach @($script:fixture.cases | ForEach-Object { @{ name = $_.name; case = $_ } }) {
        $raw = (& $script:Docs $case.query) | ConvertTo-Json -Depth 6 -Compress
        # The blob service serves the bytes as written; the texts are equal.
        $raw | Should -BeExactly $script:want[$name]
    }
    It 'one listing and one read for each document, at most 8 in flight' {
        $script:svc.ResetCounts()
        $out = & $script:Docs $script:fixture.cases[0].query
        $script:svc.Requests | Should -Be (1 + @($out.docs).Count)
        $script:svc.MaxInFlight | Should -BeGreaterThan 1 -Because 'one after another is what made the page wait'
        $script:svc.MaxInFlight | Should -BeLessOrEqual 8 -Because 'the same limit the pages keep'
    }
    It 'a document gone between the listing and the read is given back with no text' {
        Mock -ModuleName FacadeCore Get-VmfFacadeStoreListing { [pscustomobject]@{ names = @('proj/a1/run.json', 'proj/gone/run.json'); prefixes = @(); truncated = $false } }
        $out = Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read 'run.json'
        $gone = @($out.docs | Where-Object path -EQ 'proj/gone/run.json')
        $gone.Count | Should -Be 1
        $gone[0].text | Should -BeNullOrEmpty
        $gone[0].PSObject.Properties.Name | Should -Not -Contain 'error'
        (@($out.docs | Where-Object path -EQ 'proj/a1/run.json'))[0].text | Should -BeExactly (& $script:PerFile 'proj/a1/run.json')
    }
    It 'a read the store refuses names the answer for that document only, and the others are still there' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
            , @($Uri | ForEach-Object {
                if ($_ -like '*a1/run.json') { [pscustomobject]@{ StatusCode = 403; Content = 'refused' } }
                else { [pscustomobject]@{ StatusCode = 200; Content = '{"ok":1}' } }
            })
        }
        $out = Get-VmfFacadeStoreDocs -Principal $script:viewer -Depth 3 -Read 'run.json'
        $bad = (@($out.docs | Where-Object path -EQ 'proj/a1/run.json'))[0]
        $bad.error | Should -BeExactly 'HTTP 403'
        $bad.text | Should -BeNullOrEmpty
        @($out.docs | Where-Object { $_.text -eq '{"ok":1}' }).Count | Should -Be (@($out.docs).Count - 1)
    }
}

Describe 'PAGE-LOAD-1: the endpoint itself' {
    BeforeAll {
        $env:VMF_STORE_PATH = $script:root
        if (-not ('HttpResponseContext' -as [type])) {
            Add-Type -TypeDefinition 'public class HttpResponseContext { public object StatusCode; public object Body; public string ContentType; public System.Collections.IDictionary Headers; }'
        }
        function Global:Push-OutputBinding { param($Name, $Value) $global:VmfStoreDocsResponse = $Value }
        $script:Call = { param([hashtable]$query, [string[]]$roles)
            $claims = @(@{ typ = 'preferred_username'; val = 'viewer@example.com' }) + @($roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
            $header = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ claims = $claims } | ConvertTo-Json -Depth 4)))
            $request = [pscustomobject]@{ Headers = @{ 'x-ms-client-principal' = $header }; Query = $query }
            $global:VmfStoreDocsResponse = $null
            & (Join-Path $script:repo 'src' 'facade' 'app' 'GetStoreDocs' 'run.ps1') -Request $request -TriggerMetadata $null
            $global:VmfStoreDocsResponse
        }
    }
    AfterAll { Remove-Item Function:\Push-OutputBinding, Variable:\global:VmfStoreDocsResponse -ErrorAction SilentlyContinue }

    It 'is routed at GET store/docs' {
        $fn = Get-Content (Join-Path $script:repo 'src' 'facade' 'app' 'GetStoreDocs' 'function.json') -Raw | ConvertFrom-Json
        $trigger = @($fn.bindings | Where-Object type -EQ 'httpTrigger')[0]
        $trigger.route | Should -BeExactly 'store/docs'
        @($trigger.methods) | Should -BeExactly @('get')
    }
    It 'answers 200 with the fixture answer' {
        $case = $script:fixture.cases[0]
        $r = & $script:Call @{ depth = '3'; read = ($case.query.read -join ',') } @('Vmf.Admin')
        [int]$r.StatusCode | Should -Be 200
        $body = $r.Body | ConvertFrom-Json -Depth 6
        @($body.docs | ForEach-Object path) | Should -BeExactly @($case.docs)
        @($body.names) | Should -BeExactly @($case.names)
    }
    It 'answers 403 to a caller with no product role, and 401 with no caller' {
        [int](& $script:Call @{ depth = '3'; read = 'run.json' } @('Some.Other')).StatusCode | Should -Be 403
        $global:VmfStoreDocsResponse = $null
        & (Join-Path $script:repo 'src' 'facade' 'app' 'GetStoreDocs' 'run.ps1') -Request ([pscustomobject]@{ Headers = @{}; Query = @{ depth = '3'; read = 'run.json' } }) -TriggerMetadata $null
        [int]$global:VmfStoreDocsResponse.StatusCode | Should -Be 401
    }
    It 'answers 400 to a depth that is not a number, and to a path that climbs out' {
        [int](& $script:Call @{ depth = 'deep'; read = 'run.json' } @('Vmf.Viewer')).StatusCode | Should -Be 400
        [int](& $script:Call @{ depth = '3'; read = '../run.json' } @('Vmf.Viewer')).StatusCode | Should -Be 400
    }
    It 'sends no document version header' {
        $r = & $script:Call @{ depth = '3'; read = 'run.json' } @('Vmf.Viewer')
        if ($r.Headers) { $r.Headers.Keys | Should -Not -Contain 'x-vmf-document-version' }
    }
}
