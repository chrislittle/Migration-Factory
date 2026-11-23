#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
RECORDS-VIEWER-READ-1 (findings F12 and F14 of the first Claude Security scan).

WHAT WAS WRONG. The store keeps three folders beside the runs that are not
runs (Get-VmfNotARunFolders, the one list): `vmf-records` (the kept migration
records, which only Vmf.Admin may list or read through /api/records, and which
stay 90 days after a delete), `vmf-claims` (the machine claims and
deletions.jsonl, the log of who deleted which migration) and `logs`. The three
store endpoints a page reads through - GET /api/store/blob, /api/store/list and
/api/store/docs - took any key Resolve-VmfFacadeStoreKey allowed and checked
only the lowest role. So a Vmf.Viewer could list and read every kept record.

THE RULE NOW.
  - A key or a prefix whose FIRST folder is on the one list is refused (403)
    to a caller who does not hold Vmf.Admin, on all three endpoints. The match
    ignores letter case (the file store does too), a '.' folder and a trailing
    dot or space.
  - A listing gives such a caller no name and no folder under them: the top
    of the store, a prefix that is part of a name ('vmf-rec'), and the depth
    walk of store/docs that every page makes.
  - The folder name counts only as the FIRST folder: a run's own logs
    (<run>/logs/events.jsonl) is read as before.
  - An Admin reads and lists them as before.
  - No page reads them through these endpoints: the machines other migrations
    hold come from the run summary (Get-VmfHeldMachines), and the records from
    /api/records.
#>
BeforeDiscovery {
    # The cases of one test are the names on the one list, so it is read before Pester finds them.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    $script:keptNames = @(& (Get-Module VmMigrationFactory) { Get-VmfNotARunFolders })
}
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repo 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:kept = @(& (Get-Module VmMigrationFactory) { Get-VmfNotARunFolders })

    # A store with every kept folder, a run, and a run's own logs folder.
    $script:root = Join-Path $TestDrive 'store'
    $files = [ordered]@{
        'vmf-records/rec1.json'           = '{"record":1}'
        'vmf-claims/claims/vm1.json'      = '{"holder":"proj/m1"}'
        'vmf-claims/deletions.jsonl'      = '{"by":"admin@example.com"}'
        'logs/events.jsonl'               = '{"event":1}'
        'proj/project.json'               = '{"projectId":"proj"}'
        'proj/m1/run.json'                = '{"runId":"m1"}'
        'proj/m1/logs/events.jsonl'       = '{"event":2}'
        'vmf-recordsx/run.json'           = '{"runId":"vmf-recordsx"}'
    }
    foreach ($k in $files.Keys) {
        $file = Join-Path $script:root ($k -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($file, $files[$k], [System.Text.UTF8Encoding]::new($false))
    }
    $env:VMF_STORE_PATH = $script:root

    if (-not ('HttpResponseContext' -as [type])) {
        Add-Type -TypeDefinition 'public class HttpResponseContext { public object StatusCode; public object Body; public string ContentType; public System.Collections.IDictionary Headers; }'
    }
    function Global:Push-OutputBinding { param($Name, $Value) $global:VmfKeptFoldersResponse = $Value }
    # Call one endpoint as a caller who holds these roles.
    $script:Call = { param([string]$endpoint, [hashtable]$query, [string[]]$roles)
        $claims = @(@{ typ = 'preferred_username'; val = 'user@example.com' }) + @($roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
        $header = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ claims = $claims } | ConvertTo-Json -Depth 4)))
        $request = [pscustomobject]@{ Headers = @{ 'x-ms-client-principal' = $header }; Query = $query }
        $global:VmfKeptFoldersResponse = $null
        & (Join-Path $script:repo 'src' 'facade' 'app' $endpoint 'run.ps1') -Request $request -TriggerMetadata $null
        $global:VmfKeptFoldersResponse
    }
    $script:Principal = { param([string[]]$roles) [pscustomobject]@{ Identity = 'user@example.com'; Roles = @($roles) } }
    # Is the first folder of a store key on the one list?
    $script:IsKept = { param([string]$key) (($key -split '/')[0]) -in $script:kept }
}

AfterAll {
    Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
    Remove-Item Function:\Push-OutputBinding, Variable:\global:VmfKeptFoldersResponse -ErrorAction SilentlyContinue
    Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'RECORDS-VIEWER-READ-1: the folders the product keeps beside the runs' {
    It 'reads the one list, and it names vmf-records and vmf-claims' {
        $script:kept | Should -Contain 'vmf-records'
        $script:kept | Should -Contain 'vmf-claims'
    }
    It 'the service holds no list of its own: it asks Get-VmfNotARunFolders' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $code | Should -Not -Match "'vmf-records'"
        $code | Should -Not -Match "'vmf-claims'"
        $code | Should -Match 'Get-VmfNotARunFolders'
    }
}

Describe 'RECORDS-VIEWER-READ-1: store/blob' {
    It '<role> gets 403 for <path>' -ForEach @(
        foreach ($role in 'Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator') {
            foreach ($path in 'vmf-records/rec1.json', 'vmf-claims/deletions.jsonl', 'vmf-claims/claims/vm1.json', 'logs/events.jsonl',
                'VMF-Records/rec1.json', './vmf-records/rec1.json', 'vmf-records./rec1.json', 'vmf-records /rec1.json', '././vmf-claims/deletions.jsonl') {
                @{ role = $role; path = $path }
            }
        }) {
        $r = & $script:Call 'GetStoreBlob' @{ path = $path } @($role)
        [int]$r.StatusCode | Should -Be 403
        [string]$r.Body | Should -Not -Match 'record":1|admin@example'
    }
    It 'each name on the one list is refused to a Viewer: <_>' -ForEach $script:keptNames {
        [int](& $script:Call 'GetStoreBlob' @{ path = "$_/x.json" } @('Vmf.Viewer')).StatusCode | Should -Be 403
    }
    It 'an Admin reads <_>' -ForEach @('vmf-records/rec1.json', 'vmf-claims/deletions.jsonl', 'logs/events.jsonl') {
        $r = & $script:Call 'GetStoreBlob' @{ path = $_ } @('Vmf.Admin')
        [int]$r.StatusCode | Should -Be 200
    }
    It 'a user who holds Viewer and Admin reads a record' {
        [int](& $script:Call 'GetStoreBlob' @{ path = 'vmf-records/rec1.json' } @('Vmf.Viewer', 'Vmf.Admin')).StatusCode | Should -Be 200
    }
    It 'a Viewer still reads a run, its own logs, and a run whose name only starts with a kept name' -ForEach @('proj/m1/run.json', 'proj/m1/logs/events.jsonl', 'vmf-recordsx/run.json') {
        [int](& $script:Call 'GetStoreBlob' @{ path = $_ } @('Vmf.Viewer')).StatusCode | Should -Be 200
    }
}

Describe 'RECORDS-VIEWER-READ-1: store/list' {
    It '<role> gets 403 for the prefix <prefix>' -ForEach @(
        foreach ($role in 'Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator') {
            foreach ($prefix in 'vmf-records/', 'vmf-records', 'vmf-claims/', 'Vmf-Claims/claims', 'logs/', './vmf-records/') {
                @{ role = $role; prefix = $prefix }
            }
        }) {
        [int](& $script:Call 'GetStoreList' @{ prefix = $prefix } @($role)).StatusCode | Should -Be 403
    }
    It 'an Admin lists vmf-records/' {
        $r = & $script:Call 'GetStoreList' @{ prefix = 'vmf-records/' } @('Vmf.Admin')
        [int]$r.StatusCode | Should -Be 200
        @(($r.Body | ConvertFrom-Json).names) | Should -Contain 'vmf-records/rec1.json'
    }
    It '<role>: the top of the store, by folder, leaves the kept folders out and keeps the rest' -ForEach @(
        @{ role = 'Vmf.Viewer' }, @{ role = 'Vmf.Approver' }, @{ role = 'Vmf.Operator' }) {
        $r = & $script:Call 'GetStoreList' @{ prefix = ''; delimiter = '/' } @($role)
        [int]$r.StatusCode | Should -Be 200
        $body = $r.Body | ConvertFrom-Json
        @($body.prefixes | Where-Object { & $script:IsKept $_ }) | Should -BeNullOrEmpty
        @($body.prefixes) | Should -Contain 'proj'
        @($body.prefixes) | Should -Contain 'vmf-recordsx'
    }
    It 'a Viewer: every blob in the store leaves out each one under a kept folder' {
        $body = (& $script:Call 'GetStoreList' @{ prefix = '' } @('Vmf.Viewer')).Body | ConvertFrom-Json
        @($body.names | Where-Object { & $script:IsKept $_ }) | Should -BeNullOrEmpty
        @($body.names) | Should -Contain 'proj/m1/logs/events.jsonl'
    }
    It 'a Viewer: a prefix that is part of a kept name gives nothing under it' {
        $body = (& $script:Call 'GetStoreList' @{ prefix = 'vmf-rec' } @('Vmf.Viewer')).Body | ConvertFrom-Json
        @($body.names) | Should -Not -Contain 'vmf-records/rec1.json'
        @($body.names) | Should -Contain 'vmf-recordsx/run.json'
    }
    It 'an Admin: the top of the store still shows the kept folders' {
        $body = (& $script:Call 'GetStoreList' @{ prefix = ''; delimiter = '/' } @('Vmf.Admin')).Body | ConvertFrom-Json
        foreach ($k in 'vmf-records', 'vmf-claims', 'logs') { @($body.prefixes) | Should -Contain $k }
        $all = (& $script:Call 'GetStoreList' @{ prefix = 'vmf-rec' } @('Vmf.Admin')).Body | ConvertFrom-Json
        @($all.names) | Should -Contain 'vmf-records/rec1.json'
    }
}

Describe 'RECORDS-VIEWER-READ-1: store/docs' {
    It '<role> gets 403 for the prefix <prefix>' -ForEach @(
        foreach ($role in 'Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator') {
            foreach ($prefix in 'vmf-records/', 'vmf-claims/', 'VMF-RECORDS/', 'logs/', './vmf-claims/') {
                @{ role = $role; prefix = $prefix }
            }
        }) {
        [int](& $script:Call 'GetStoreDocs' @{ prefix = $prefix; depth = '3'; read = '*.json,*.jsonl' } @($role)).StatusCode | Should -Be 403
    }
    It 'an Admin reads vmf-records/' {
        $r = & $script:Call 'GetStoreDocs' @{ prefix = 'vmf-records/'; depth = '3'; read = '*.json' } @('Vmf.Admin')
        [int]$r.StatusCode | Should -Be 200
        @(($r.Body | ConvertFrom-Json).docs.path) | Should -Contain 'vmf-records/rec1.json'
    }
    It '<role>: the depth walk at the top of the store gives no name, folder or document under a kept folder' -ForEach @(
        @{ role = 'Vmf.Viewer' }, @{ role = 'Vmf.Approver' }, @{ role = 'Vmf.Operator' }) {
        $r = & $script:Call 'GetStoreDocs' @{ depth = '4'; read = '*.json,*.jsonl' } @($role)
        [int]$r.StatusCode | Should -Be 200
        $body = $r.Body | ConvertFrom-Json
        @($body.names | Where-Object { & $script:IsKept $_ }) | Should -BeNullOrEmpty
        @($body.folders | Where-Object { & $script:IsKept $_ }) | Should -BeNullOrEmpty
        @($body.docs | Where-Object { & $script:IsKept $_.path }) | Should -BeNullOrEmpty
        @($body.docs.path) | Should -Contain 'proj/m1/run.json'
        @($body.docs.path) | Should -Contain 'proj/m1/logs/events.jsonl'
    }
    It 'an Admin: the depth walk still names the kept folders and reads their documents' {
        $body = (& $script:Call 'GetStoreDocs' @{ depth = '3'; read = '*.json,*.jsonl' } @('Vmf.Admin')).Body | ConvertFrom-Json
        @($body.folders) | Should -Contain 'vmf-records'
        @($body.docs.path) | Should -Contain 'vmf-claims/deletions.jsonl'
    }
    It 'a Viewer who pages with after gets no kept document on a later page either' {
        $out = Get-VmfFacadeStoreDocs -Principal (& $script:Principal @('Vmf.Viewer')) -Depth 3 -Read @('*.json', '*.jsonl') -After 'logs'
        @($out.docs | Where-Object { & $script:IsKept $_.path }) | Should -BeNullOrEmpty
    }
}

Describe 'RECORDS-VIEWER-READ-1: the filter of a listing, key by key' {
    BeforeAll {
        $script:viewerP = & $script:Principal @('Vmf.Viewer')
        $script:adminP = & $script:Principal @('Vmf.Admin')
    }
    It 'leaves out a key under a kept folder for a Viewer: <_>' -ForEach @(
        'vmf-records/rec1.json', 'vmf-records', 'VMF-RECORDS/x', 'Vmf-Claims/deletions.jsonl', 'logs', 'LOGS/events.jsonl',
        'vmf-records./x', 'vmf-records /x', 'vmf-records. /x', './vmf-records/x', '././vmf-claims/x', '/vmf-records/x', '//vmf-claims/x') {
        @(Select-VmfFacadeReadableStoreKeys -Principal $script:viewerP -Key @($_, 'proj/run.json')) | Should -BeExactly @('proj/run.json')
    }
    It 'keeps a key whose kept name is not the first folder, or only part of it: <_>' -ForEach @(
        'proj/logs/events.jsonl', 'proj/vmf-records/x', 'vmf-recordsx/run.json', 'my-logs', 'logs-of-war/run.json') {
        @(Select-VmfFacadeReadableStoreKeys -Principal $script:viewerP -Key @($_)) | Should -BeExactly @($_)
    }
    It 'keeps every key for an Admin' {
        $all = @('vmf-records/rec1.json', 'vmf-claims/deletions.jsonl', 'logs', 'proj/run.json')
        @(Select-VmfFacadeReadableStoreKeys -Principal $script:adminP -Key $all) | Should -BeExactly $all
    }
    It 'keeps no key for a caller who is not signed in' {
        @(Select-VmfFacadeReadableStoreKeys -Principal $null -Key @('vmf-records/x')) | Should -BeNullOrEmpty
    }
}