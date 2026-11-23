#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STORE-RESERVED-NAMES-1: a project or a run named after a store folder the
# product keeps - or a run addressed at a project's root - must never delete
# the kept migration records, the machine claims, or a whole project.
#
# Found by the first Claude Security scan (F1 to F5). The store holds
# vmf-records/ (the kept migration records), vmf-claims/ (the machine claims
# and deletions.jsonl) and logs/ beside the runs. Every walk of the store knew
# those names; nothing that CREATED or DELETED a prefix asked them:
#
#   1. New-VmfProject -ProjectId vmf-records wrote vmf-records/project.json,
#      and Remove-VmfProject then found no sub-folder (the folder is flat) and
#      deleted every kept record.
#   2. A run started as vmf-records wrote vmf-records/run.json, and its
#      discard deleted the folder.
#   3. A run started under a project's id, with no project, wrote run.json at
#      the project's root, and its discard deleted the whole project - the
#      state of machines in the middle of a move included.
#
# Each path is tested on the file store AND on the blob address shape, through
# the engine function that must refuse it and through the service.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    # Az is not installed in CI, so the service tests mock a stand-in, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:temp = New-VmfTestTemp -Prefix 'srn'
    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'not-a-run-folders.json') -Raw | ConvertFrom-Json
    $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator'); TenantId = 't1' }

    $script:Reserved = { param($n) "400: The product keeps its own records in the folder '$n'. Use a different name." }

    # A file store with the kept records and claims beside the runs.
    function Global:SrnStore {
        $root = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        SrnPut $root 'vmf-records/mig-1.json' '{"migration":"mig-1"}'
        SrnPut $root 'vmf-records/estate--mig-2.json' '{"migration":"mig-2"}'
        SrnPut $root 'vmf-claims/claim-1.json' '{"runId":"r1"}'
        SrnPut $root 'vmf-claims/deletions.jsonl' '{"runId":"old"}'
        $root
    }
    function Global:SrnPut([string]$Root, [string]$Rel, [string]$Text) {
        $full = Join-Path $Root ($Rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        [System.IO.File]::WriteAllText($full, $Text)
    }
    function Global:SrnFiles([string]$Root) {
        @(Get-ChildItem $Root -Recurse -File | ForEach-Object { $_.FullName.Substring($Root.Length + 1) -replace '\\', '/' } | Sort-Object)
    }

    # The blob shape: an in-memory container behind the one storage seam, so
    # the refusals are proved on azblob:// addresses as the service and the
    # engine use them. Every request is recorded.
    $global:SrnBlobs = [ordered]@{}
    $global:SrnCalls = [System.Collections.Generic.List[string]]::new()
    function Global:SrnAnswer([string]$Method, [string]$Uri) {
        $global:SrnCalls.Add("$Method $Uri")
        $u = [uri]$Uri
        $q = [System.Web.HttpUtility]::ParseQueryString($u.Query)
        $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart('/'))
        $name = ($path -split '/', 2)[1]
        if ($q['comp'] -eq 'list') {
            $prefix = [string]$q['prefix']
            $names = @($global:SrnBlobs.Keys | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) })
            $sb = [System.Text.StringBuilder]::new('<?xml version="1.0"?><EnumerationResults><Blobs>')
            if ($q['delimiter']) {
                $seen = @{}
                foreach ($n in $names) {
                    $rest = $n.Substring($prefix.Length)
                    if ($rest.Contains('/')) {
                        $folder = $prefix + $rest.Substring(0, $rest.IndexOf('/') + 1)
                        if (-not $seen[$folder]) { $seen[$folder] = 1; [void]$sb.Append("<BlobPrefix><Name>$folder</Name></BlobPrefix>") }
                    }
                    else { [void]$sb.Append("<Blob><Name>$n</Name></Blob>") }
                }
            }
            else { foreach ($n in $names) { [void]$sb.Append("<Blob><Name>$n</Name></Blob>") } }
            [void]$sb.Append('</Blobs><NextMarker></NextMarker></EnumerationResults>')
            return [pscustomobject]@{ StatusCode = 200; Content = $sb.ToString(); Headers = @{} }
        }
        if ($q['restype'] -eq 'container') { return [pscustomobject]@{ StatusCode = 409; Content = ''; Headers = @{} } }
        switch ($Method) {
            'HEAD' { if ($global:SrnBlobs.Contains($name)) { return [pscustomobject]@{ StatusCode = 200; Content = ''; Headers = @{} } } }
            'GET' { if ($global:SrnBlobs.Contains($name)) { return [pscustomobject]@{ StatusCode = 200; Content = $global:SrnBlobs[$name]; Headers = @{} } } }
            'DELETE' { if ($global:SrnBlobs.Contains($name)) { $global:SrnBlobs.Remove($name) }; return [pscustomobject]@{ StatusCode = 202; Content = ''; Headers = @{} } }
            'PUT' { $global:SrnBlobs[$name] = ''; return [pscustomobject]@{ StatusCode = 201; Content = ''; Headers = @{} } }
        }
        [pscustomobject]@{ StatusCode = 404; Content = ''; Headers = @{} }
    }
    $script:MockBlob = {
        $global:SrnCalls.Clear()
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { SrnAnswer $Method $Uri }
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany { , @($Uri | ForEach-Object { SrnAnswer 'GET' $_ }) }
    }
    $script:Changed = { @($global:SrnCalls | Where-Object { $_ -match '^(DELETE|PUT) ' -and $_ -notmatch 'restype=container$' }) }
    $script:SeedBlobs = {
        $global:SrnBlobs.Clear()
        $global:SrnBlobs['vmf-records/mig-1.json'] = '{"migration":"mig-1"}'
        $global:SrnBlobs['vmf-claims/claim-1.json'] = '{"runId":"r1"}'
        $global:SrnBlobs['vmf-claims/deletions.jsonl'] = '{"runId":"old"}'
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\SrnStore', 'function:\SrnPut', 'function:\SrnFiles', 'function:\SrnAnswer', 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
    Remove-Variable -Name SrnBlobs, SrnCalls -Scope Global -ErrorAction SilentlyContinue
}

Describe 'STORE-RESERVED-NAMES-1: one list of the folders that are not runs' {
    It 'the engine list is the fixture list' {
        $engine = @(InModuleScope VmMigrationFactory { Get-VmfNotARunFolders })
        @($engine | Sort-Object) -join ',' | Should -BeExactly (@($script:fixture.notRuns | Sort-Object) -join ',')
    }

    It 'the folders the product writes its records and claims to are on it' {
        InModuleScope VmMigrationFactory {
            $script:VmfRecordFolder | Should -BeIn @(Get-VmfNotARunFolders)
            (Get-VmfClaimScopePath -RunPath 'azblob://acct/cont/run-1').Split('/')[-1] | Should -BeIn @(Get-VmfNotARunFolders)
        }
    }

    It 'the browser copy in help.js names exactly the fixture list' {
        $js = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $fn = [regex]::Match($js, '(?s)function runFolderIsRun\b.*?\n  \}').Value
        $fn | Should -Not -BeNullOrEmpty
        $names = @([regex]::Matches($fn, "leaf !== '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        @($names | Sort-Object) -join ',' | Should -BeExactly (@($script:fixture.notRuns | Sort-Object) -join ',')
    }

    It 'no other engine or service file holds its own copy of the list' {
        $files = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory'), (Join-Path $script:repoRoot 'src' 'facade') -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.Name -ne 'StoreNames.ps1' })
        $copies = @(foreach ($f in $files) {
                $code = Get-VmfCodeOnly -Path $f.FullName
                if ($code -match "'vmf-(claims|records)'\s*,|,\s*'vmf-(claims|records)'") { $f.Name }
            })
        $copies | Should -BeNullOrEmpty -Because 'a second list is a list that can disagree with the first'
    }

    It 'the service answers from the engine list: every fixture case' {
        foreach ($case in $script:fixture.cases) {
            Test-VmfFacadeRunFolder -Path $case.path | Should -Be ([bool]$case.isRun) -Because $case.why
        }
    }

    It 'the service asks the engine list rather than naming the folders itself' {
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $fn = [regex]::Match($core, '(?s)function Test-VmfFacadeRunFolder \{.*?\n\}').Value
        # RECORDS-VIEWER-READ-1: the service reads the list in one place,
        # Get-VmfFacadeNotRunFolders, which the store endpoints ask too.
        $fn | Should -Match 'Get-VmfFacadeNotRunFolders'
        $fn | Should -Not -Match "'vmf-records'"
        $read = [regex]::Match($core, '(?s)function Get-VmfFacadeNotRunFolders \{.*?\n\}').Value
        $read | Should -Match 'Get-VmfNotARunFolders'
        $read | Should -Not -Match "'vmf-records'"
    }

    It 'the engine walks of the store skip every folder on the list, logs included' {
        $store = SrnStore
        SrnPut $store 'logs/events.jsonl' '{}'
        SrnPut $store 'loose-1/run.json' '{"runId":"loose-1","kind":"assessment"}'
        $ids = @(InModuleScope VmMigrationFactory -Parameters @{ sp = $store } { param($sp) Get-VmfStoreRunPaths -StorePath $sp | ForEach-Object { $_.Id } })
        $ids | Should -Be @('loose-1')
    }
}

Describe 'STORE-RESERVED-NAMES-1: a project may not be named after a kept folder (F1, F2)' {
    It 'New-VmfProject refuses <Name>, and writes nothing' -ForEach @(
        @{ Name = 'vmf-records' }, @{ Name = 'vmf-claims' }, @{ Name = 'logs' }) {
        $store = SrnStore
        $before = SrnFiles $store
        { New-VmfProject -StorePath $store -ProjectId $Name -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false } |
            Should -Throw (& $script:Reserved $Name)
        SrnFiles $store | Should -Be $before
    }

    It 'New-VmfProject refuses an id an assessment or a migration already uses' {
        $store = SrnStore
        SrnPut $store 'scan-1/run.json' '{"runId":"scan-1","kind":"assessment"}'
        { New-VmfProject -StorePath $store -ProjectId 'scan-1' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false } |
            Should -Throw "400: An assessment or a migration already uses the name 'scan-1'. Use a different name for the project."
        Test-Path (Join-Path $store 'scan-1' 'project.json') | Should -BeFalse
    }

    It 'New-VmfProject still creates a project on a free id' {
        $store = SrnStore
        (New-VmfProject -StorePath $store -ProjectId 'contoso-exit' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false).ProjectId |
            Should -Be 'contoso-exit'
    }

    It 'Remove-VmfProject refuses vmf-records, even with a project.json planted there, and every record stays' {
        $store = SrnStore
        SrnPut $store 'vmf-records/project.json' '{"projectId":"vmf-records","name":"x"}'
        $before = SrnFiles $store
        { Remove-VmfProject -StorePath $store -ProjectId 'vmf-records' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false } |
            Should -Throw (& $script:Reserved 'vmf-records')
        SrnFiles $store | Should -Be $before
    }

    It 'Remove-VmfProject refuses a project that holds a document other than project.json, and deletes nothing' {
        # A mis-addressed start writes run.json at the project's root: no
        # sub-folder, so the old "must be empty" test passed it.
        $store = SrnStore
        New-VmfProject -StorePath $store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        SrnPut $store 'contoso/run.json' '{"runId":"contoso","kind":"assessment"}'
        $before = SrnFiles $store
        { Remove-VmfProject -StorePath $store -ProjectId 'contoso' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false } |
            Should -Throw "400: Project 'contoso' holds documents other than its project document and its event log: run.json. The product deletes only an empty project, so it did not delete this project."
        SrnFiles $store | Should -Be $before
    }

    It 'Remove-VmfProject still deletes an empty project' {
        $store = SrnStore
        New-VmfProject -StorePath $store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        (Remove-VmfProject -StorePath $store -ProjectId 'contoso' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false).Documents | Should -Be 1
        Test-Path (Join-Path $store 'contoso') | Should -BeFalse
        @(SrnFiles $store | Where-Object { $_ -like 'vmf-*' }).Count | Should -Be 4
    }

    Context 'on blob storage' {
        BeforeEach { & $script:SeedBlobs; & $script:MockBlob }

        It 'New-VmfProject refuses vmf-records before any store call' {
            { New-VmfProject -StorePath 'azblob://acct/cont' -ProjectId 'vmf-records' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false } |
                Should -Throw (& $script:Reserved 'vmf-records')
            $global:SrnCalls.Count | Should -Be 0
        }

        It 'New-VmfProject refuses an id a run already uses, and writes nothing' {
            $global:SrnBlobs['scan-1/run.json'] = '{"runId":"scan-1"}'
            { New-VmfProject -StorePath 'azblob://acct/cont' -ProjectId 'scan-1' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false } |
                Should -Throw "400: An assessment or a migration already uses the name 'scan-1'*"
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'Remove-VmfProject refuses vmf-records before any store call, so no record is deleted' {
            $global:SrnBlobs['vmf-records/project.json'] = '{"projectId":"vmf-records","name":"x"}'
            { Remove-VmfProject -StorePath 'azblob://acct/cont' -ProjectId 'vmf-records' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false } |
                Should -Throw (& $script:Reserved 'vmf-records')
            $global:SrnCalls.Count | Should -Be 0
        }

        It 'Remove-VmfProject refuses a project whose root holds run.json, and sends no delete' {
            $global:SrnBlobs['contoso/project.json'] = '{"projectId":"contoso","name":"x"}'
            $global:SrnBlobs['contoso/run.json'] = '{"runId":"contoso"}'
            { Remove-VmfProject -StorePath 'azblob://acct/cont' -ProjectId 'contoso' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false } |
                Should -Throw "400: Project 'contoso' holds documents other than its project document and its event log: run.json*"
            & $script:Changed | Should -BeNullOrEmpty
            $global:SrnBlobs.Count | Should -Be 5
        }
    }
}

Describe 'STORE-RESERVED-NAMES-1: the one bulk delete takes one run or one empty project (Remove-VmfStorePrefix)' {
    It 'refuses a kept folder as a <Kind>, on the file store, and deletes nothing' -ForEach @(
        @{ Kind = 'run'; Name = 'vmf-records' }, @{ Kind = 'project'; Name = 'vmf-claims' }, @{ Kind = 'run'; Name = 'logs' }) {
        $store = SrnStore
        SrnPut $store 'logs/events.jsonl' '{}'
        $before = SrnFiles $store
        { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store $Name); k = $Kind } { param($rp, $k) Remove-VmfStorePrefix -RunPath $rp -Kind $k -Confirm:$false } } |
            Should -Throw (& $script:Reserved $Name)
        SrnFiles $store | Should -Be $before
    }

    It 'refuses a run prefix that holds project.json' {
        $store = SrnStore
        SrnPut $store 'contoso/project.json' '{}'
        SrnPut $store 'contoso/run.json' '{}'
        { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store 'contoso') } { param($rp) Remove-VmfStorePrefix -RunPath $rp -Kind run -Confirm:$false } } |
            Should -Throw "400: The folder 'contoso' holds a project or other assessments or migrations: project.json. The product deletes one assessment or migration at a time, so it did not delete this folder."
        Test-Path (Join-Path $store 'contoso' 'project.json') | Should -BeTrue
    }

    It 'refuses a run prefix that holds another run' {
        $store = SrnStore
        SrnPut $store 'outer/run.json' '{}'
        SrnPut $store 'outer/inner/run.json' '{}'
        { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store 'outer') } { param($rp) Remove-VmfStorePrefix -RunPath $rp -Kind run -Confirm:$false } } |
            Should -Throw "400: The folder 'outer' holds a project or other assessments or migrations: inner/run.json*"
        Test-Path (Join-Path $store 'outer' 'inner' 'run.json') | Should -BeTrue
    }

    It 'still deletes a run with its own documents' {
        $store = SrnStore
        SrnPut $store 'p1/run-1/run.json' '{}'
        SrnPut $store 'p1/run-1/state/a.json' '{}'
        InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store 'p1' 'run-1') } { param($rp) Remove-VmfStorePrefix -RunPath $rp -Kind run -Confirm:$false } |
            Should -Be 2
        Test-Path (Join-Path $store 'p1' 'run-1') | Should -BeFalse
    }

    Context 'on blob storage' {
        BeforeEach { & $script:SeedBlobs; & $script:MockBlob }

        It 'refuses vmf-records before any store call' {
            { InModuleScope VmMigrationFactory { Remove-VmfStorePrefix -RunPath 'azblob://acct/cont/vmf-records' -Kind run -Confirm:$false } } |
                Should -Throw (& $script:Reserved 'vmf-records')
            $global:SrnCalls.Count | Should -Be 0
        }

        It 'refuses a run inside a kept folder (vmf-claims/x)' {
            $global:SrnBlobs['vmf-claims/x/run.json'] = '{}'
            { InModuleScope VmMigrationFactory { Remove-VmfStorePrefix -RunPath 'azblob://acct/cont/vmf-claims/x' -Kind run -Confirm:$false } } |
                Should -Throw (& $script:Reserved 'vmf-claims')
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'refuses a run prefix that is a project, and sends no delete' {
            $global:SrnBlobs['contoso/project.json'] = '{}'
            $global:SrnBlobs['contoso/run.json'] = '{}'
            $global:SrnBlobs['contoso/mig-1/state/a.json'] = '{}'
            { InModuleScope VmMigrationFactory { Remove-VmfStorePrefix -RunPath 'azblob://acct/cont/contoso' -Kind run -Confirm:$false } } |
                Should -Throw "400: The folder 'contoso' holds a project or other assessments or migrations: project.json*"
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'refuses a project prefix that holds anything but project.json, and sends no delete' {
            $global:SrnBlobs['contoso/project.json'] = '{}'
            $global:SrnBlobs['contoso/stray.json'] = '{}'
            { InModuleScope VmMigrationFactory { Remove-VmfStorePrefix -RunPath 'azblob://acct/cont/contoso' -Kind project -Confirm:$false } } |
                Should -Throw "400: Project 'contoso' holds documents other than its project document and its event log: stray.json*"
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'the second sweep deletes no project document that appeared after the first listing' {
            $global:SrnBlobs['scan-7/run.json'] = '{}'
            $global:SrnBlobs['scan-7/plan.json'] = '{}'
            # A DELETE of the first pass makes a project document appear under
            # the prefix, before the sweep lists it again.
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
                $r = SrnAnswer $Method $Uri
                if ($Method -eq 'DELETE' -and $Uri -like '*scan-7/run.json') { $global:SrnBlobs['scan-7/project.json'] = '{}' }
                $r
            }
            { InModuleScope VmMigrationFactory { Remove-VmfStorePrefix -RunPath 'azblob://acct/cont/scan-7' -Kind run -Confirm:$false } } |
                Should -Throw "400: The folder 'scan-7' holds a project or other assessments or migrations: project.json*"
            @($global:SrnBlobs.Keys) | Should -Contain 'scan-7/project.json'
        }

        It 'still deletes a run inside a project' {
            $global:SrnBlobs['p1/project.json'] = '{}'
            $global:SrnBlobs['p1/run-1/run.json'] = '{}'
            $global:SrnBlobs['p1/run-1/state/a.json'] = '{}'
            InModuleScope VmMigrationFactory { Remove-VmfStorePrefix -RunPath 'azblob://acct/cont/p1/run-1' -Kind run -Confirm:$false } | Should -Be 2
            @($global:SrnBlobs.Keys) | Should -Contain 'p1/project.json'
            @($global:SrnBlobs.Keys | Where-Object { $_ -like 'p1/run-1/*' }).Count | Should -Be 0
        }
    }
}

Describe 'STORE-RESERVED-NAMES-1: a run may not be made at a kept folder or a project root (Initialize-VmfRun)' {
    It 'refuses a run called <Name>, and writes no run.json' -ForEach @(
        @{ Name = 'vmf-records' }, @{ Name = 'vmf-claims' }, @{ Name = 'logs' }) {
        $store = SrnStore
        $before = SrnFiles $store
        { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store $Name); id = $Name } { param($rp, $id) Initialize-VmfRun -RunPath $rp -RunId $id -Kind assessment } } |
            Should -Throw (& $script:Reserved $Name)
        SrnFiles $store | Should -Be $before
    }

    It 'refuses the root of a project, and writes nothing there' {
        $store = SrnStore
        New-VmfProject -StorePath $store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store 'contoso') } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'contoso' -Kind assessment } } |
            Should -Throw "400: 'contoso' is a project, not an assessment or a migration. Select an assessment or a migration in the project."
        @(Get-ChildItem (Join-Path $store 'contoso') -Recurse).Name | Should -Be @('project.json')
    }

    It 'refuses a run inside another run' {
        $store = SrnStore
        InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store 'scan-1') } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'scan-1' -Kind assessment | Out-Null }
        { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store 'scan-1' 'inner') } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'inner' -Kind assessment -Project 'scan-1' } } |
            Should -Throw "400: 'scan-1' is an assessment or a migration, not a project. Use the id of a project, or start the run with no project."
        Test-Path (Join-Path $store 'scan-1' 'inner') | Should -BeFalse
    }

    It 'on the file store, asks the parent only when a project is named (the root of a store folder is not known)' {
        $store = SrnStore
        SrnPut $store 'run.json' '{"runId":"outer"}'
        InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store 'next') } { param($rp)
            (Initialize-VmfRun -RunPath $rp -RunId 'next').runId | Should -Be 'next'
        }
    }

    It 'still makes a run inside a project, and a loose run' {
        $store = SrnStore
        New-VmfProject -StorePath $store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ s = $store } { param($s)
            (Initialize-VmfRun -RunPath (Join-Path $s 'contoso' 'scan-1') -RunId 'scan-1' -Kind assessment -Project 'contoso').runId | Should -Be 'scan-1'
            (Initialize-VmfRun -RunPath (Join-Path $s 'logs-of-war') -RunId 'logs-of-war').runId | Should -Be 'logs-of-war'
        }
    }

    Context 'on blob storage' {
        BeforeEach { & $script:SeedBlobs; & $script:MockBlob }

        It 'refuses vmf-records before any store call' {
            { InModuleScope VmMigrationFactory { Initialize-VmfRun -RunPath 'azblob://acct/cont/vmf-records' -RunId 'vmf-records' -Kind assessment } } |
                Should -Throw (& $script:Reserved 'vmf-records')
            $global:SrnCalls.Count | Should -Be 0
        }

        It 'refuses a run in a project called vmf-claims' {
            { InModuleScope VmMigrationFactory { Initialize-VmfRun -RunPath 'azblob://acct/cont/vmf-claims/scan-1' -RunId 'scan-1' -Kind assessment } } |
                Should -Throw (& $script:Reserved 'vmf-claims')
            $global:SrnCalls.Count | Should -Be 0
        }

        It 'refuses the root of a project, and writes nothing' {
            $global:SrnBlobs['contoso/project.json'] = '{"projectId":"contoso"}'
            { InModuleScope VmMigrationFactory { Initialize-VmfRun -RunPath 'azblob://acct/cont/contoso' -RunId 'contoso' -Kind assessment } } |
                Should -Throw "400: 'contoso' is a project*"
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'refuses a run inside another run' {
            $global:SrnBlobs['scan-1/run.json'] = '{"runId":"scan-1"}'
            { InModuleScope VmMigrationFactory { Initialize-VmfRun -RunPath 'azblob://acct/cont/scan-1/inner' -RunId 'inner' -Kind assessment } } |
                Should -Throw "400: 'scan-1' is an assessment or a migration, not a project*"
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'still makes a loose run and a run inside a project, and asks nothing of the container root' {
            $global:SrnBlobs['contoso/project.json'] = '{"projectId":"contoso"}'
            InModuleScope VmMigrationFactory {
                Initialize-VmfRun -RunPath 'azblob://acct/cont/scan-1' -RunId 'scan-1' -Kind assessment | Out-Null
                Initialize-VmfRun -RunPath 'azblob://acct/cont/contoso/scan-2' -RunId 'scan-2' -Kind assessment -Project 'contoso' | Out-Null
            }
            @($global:SrnBlobs.Keys) | Should -Contain 'scan-1/run.json'
            @($global:SrnBlobs.Keys) | Should -Contain 'contoso/scan-2/run.json'
        }
    }
}

Describe 'STORE-RESERVED-NAMES-1: Remove-VmfRun deletes one run and never more (F3, F4, F5)' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
    }

    It 'refuses a "run" at vmf-records, and every kept record stays (F4)' {
        $store = SrnStore
        SrnPut $store 'vmf-records/run.json' '{"schemaVersion":9,"kind":"assessment","runId":"vmf-records"}'
        $before = SrnFiles $store
        { Remove-VmfRun -RunPath (Join-Path $store 'vmf-records') -Reason 'x' -Confirm:$false } | Should -Throw (& $script:Reserved 'vmf-records')
        SrnFiles $store | Should -Be $before
    }

    It 'refuses a "run" at a project root, and the project, its runs and the claims stay (F3, F5)' {
        $store = SrnStore
        New-VmfProject -StorePath $store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        SrnPut $store 'contoso/run.json' '{"schemaVersion":9,"kind":"assessment","runId":"contoso"}'
        SrnPut $store 'contoso/mig-1/run.json' '{"schemaVersion":9,"kind":"migration","runId":"mig-1"}'
        SrnPut $store 'contoso/mig-1/state/vm1.json' '{"state":"DEALLOCATED"}'
        $before = SrnFiles $store
        { Remove-VmfRun -RunPath (Join-Path $store 'contoso') -Reason 'x' -Confirm:$false } |
            Should -Throw "400: 'contoso' is a project, not an assessment or a migration. Select an assessment or a migration in the project."
        SrnFiles $store | Should -Be $before -Because 'nothing is written either: no migration record, no deletions line'
    }

    It 'refuses a run that holds another run, before it writes anything' {
        $store = SrnStore
        SrnPut $store 'outer/run.json' '{"schemaVersion":9,"kind":"assessment","runId":"outer"}'
        SrnPut $store 'outer/inner/run.json' '{"schemaVersion":9,"kind":"assessment","runId":"inner"}'
        $before = SrnFiles $store
        { Remove-VmfRun -RunPath (Join-Path $store 'outer') -Reason 'x' -Confirm:$false } |
            Should -Throw "400: The folder 'outer' holds other assessments or migrations: inner. The product deletes one assessment or migration at a time, so it did not delete this folder."
        SrnFiles $store | Should -Be $before
    }

    It 'refuses when a project document appears while the delete runs: the last check is at the bulk delete' {
        $store = SrnStore
        SrnPut $store 'scan-9/run.json' '{"schemaVersion":9,"kind":"assessment","runId":"scan-9"}'
        Mock -ModuleName VmMigrationFactory Assert-VmfNoBillingReservation {
            SrnPut (Split-Path $RunPath) 'scan-9/project.json' '{}'
        }
        { Remove-VmfRun -RunPath (Join-Path $store 'scan-9') -Reason 'x' -Confirm:$false } |
            Should -Throw "400: The folder 'scan-9' holds a project or other assessments or migrations: project.json*"
        Test-Path (Join-Path $store 'scan-9' 'project.json') | Should -BeTrue
    }

    It 'still deletes an assessment inside a project, and the project stays' {
        $store = SrnStore
        New-VmfProject -StorePath $store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $store 'contoso' 'scan-1') } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'scan-1' -Kind assessment -Project 'contoso' | Out-Null }
        (Remove-VmfRun -RunPath (Join-Path $store 'contoso' 'scan-1') -Reason 'x' -Confirm:$false).Removed | Should -BeTrue
        Test-Path (Join-Path $store 'contoso' 'scan-1') | Should -BeFalse
        Test-Path (Join-Path $store 'contoso' 'project.json') | Should -BeTrue
        Test-Path (Join-Path $store 'vmf-records' 'mig-1.json') | Should -BeTrue
    }

    Context 'on blob storage' {
        BeforeEach { & $script:SeedBlobs; & $script:MockBlob }

        It 'refuses vmf-records before any store call' {
            $global:SrnBlobs['vmf-records/run.json'] = '{"runId":"vmf-records"}'
            { Remove-VmfRun -RunPath 'azblob://acct/cont/vmf-records' -Reason 'x' -Confirm:$false } | Should -Throw (& $script:Reserved 'vmf-records')
            $global:SrnCalls.Count | Should -Be 0
        }

        It 'refuses a project root, and sends no delete and no write' {
            $global:SrnBlobs['contoso/project.json'] = '{"projectId":"contoso"}'
            $global:SrnBlobs['contoso/run.json'] = '{"schemaVersion":9,"kind":"assessment","runId":"contoso"}'
            $global:SrnBlobs['contoso/mig-1/run.json'] = '{"runId":"mig-1"}'
            { Remove-VmfRun -RunPath 'azblob://acct/cont/contoso' -Reason 'x' -Confirm:$false } | Should -Throw "400: 'contoso' is a project*"
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'refuses a run that holds another run, and sends no delete and no write' {
            $global:SrnBlobs['outer/run.json'] = '{"schemaVersion":9,"kind":"assessment","runId":"outer"}'
            $global:SrnBlobs['outer/inner/run.json'] = '{"runId":"inner"}'
            { Remove-VmfRun -RunPath 'azblob://acct/cont/outer' -Reason 'x' -Confirm:$false } | Should -Throw "400: The folder 'outer' holds other assessments or migrations: inner*"
            & $script:Changed | Should -BeNullOrEmpty
        }
    }
}

Describe 'STORE-RESERVED-NAMES-1: the service refuses before it writes or starts anything' {
    BeforeEach {
        $script:store = SrnStore
        $env:VMF_STORE_PATH = $script:store
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:starts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST') { $script:starts.Add([string]$Payload); return [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-1","id":"x"}' } }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'a run route refuses a run id <Id>' -ForEach @(
        @{ Id = 'vmf-records'; Name = 'vmf-records' }, @{ Id = 'contoso/vmf-claims'; Name = 'vmf-claims' }, @{ Id = 'logs'; Name = 'logs' }) {
        { Get-VmfFacadeStorePath -RunId $Id } | Should -Throw (& $script:Reserved $Name)
    }

    It 'a run route refuses a kept name in another letter case' {
        { Get-VmfFacadeStorePath -RunId 'VMF-Records' } | Should -Throw (& $script:Reserved 'VMF-Records')
    }

    It 'a run route still answers a run whose name only starts like a kept folder' {
        Get-VmfFacadeStorePath -RunId 'logs-of-war' | Should -Be (Join-Path $script:store 'logs-of-war')
    }

    It 'the start of a scan called vmf-records is refused, and the engine does not start (F4)' {
        $before = SrnFiles $script:store
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'vmf-records' -ScopeSubs @('00000000-0000-0000-0000-000000000000') } |
            Should -Throw (& $script:Reserved 'vmf-records')
        $script:starts.Count | Should -Be 0
        SrnFiles $script:store | Should -Be $before
    }

    It 'the start of a scan under a project id with no project is refused, and the engine does not start (F3)' {
        New-VmfProject -StorePath $script:store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'contoso' -ScopeSubs @('00000000-0000-0000-0000-000000000000') } |
            Should -Throw "400: 'contoso' is a project, not an assessment or a migration*"
        $script:starts.Count | Should -Be 0
        Test-Path (Join-Path $script:store 'contoso' 'run.json') | Should -BeFalse
    }

    It 'the start of a scan in a "project" that is a run is refused, and the engine does not start' {
        SrnPut $script:store 'scan-1/run.json' '{"schemaVersion":9,"kind":"assessment","runId":"scan-1"}'
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'scan-2' -Project 'scan-1' -ScopeSubs @('00000000-0000-0000-0000-000000000000') } |
            Should -Throw "400: 'scan-1' is an assessment or a migration, not a project*"
        $script:starts.Count | Should -Be 0
    }

    It 'the start of a scan inside a project still starts' {
        New-VmfProject -StorePath $script:store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        (Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'scan-1' -Project 'contoso' -ScopeSubs @('00000000-0000-0000-0000-000000000000')).execution |
            Should -Be 'exec-1'
        $script:starts.Count | Should -Be 1
    }

    It 'Delete this assessment at a project root is refused, and nothing is written into the project (F5)' {
        New-VmfProject -StorePath $script:store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        SrnPut $script:store 'contoso/run.json' '{"schemaVersion":9,"kind":"assessment","runId":"contoso"}'
        $before = SrnFiles $script:store
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath (Join-Path $script:store 'contoso') -RunId 'contoso' -Note 'x' } |
            Should -Throw "400: 'contoso' is a project*"
        SrnFiles $script:store | Should -Be $before -Because 'the "discarded by" line is not written into a project'
    }

    It 'creating a project called vmf-records is refused with 400' {
        { Invoke-VmfFacadeCreateProject -Principal $script:operator -ProjectId 'vmf-records' -Name 'x' } | Should -Throw (& $script:Reserved 'vmf-records')
    }

    It 'deleting a project called vmf-records is refused with 400, and every record stays' {
        SrnPut $script:store 'vmf-records/project.json' '{"projectId":"vmf-records"}'
        $before = SrnFiles $script:store
        { Invoke-VmfFacadeDeleteProject -Principal $script:operator -StorePath $script:store -ProjectId 'vmf-records' -Note 'x' } |
            Should -Throw (& $script:Reserved 'vmf-records')
        SrnFiles $script:store | Should -Be $before
    }
}

Describe 'STORE-RESERVED-NAMES-1: the engine start checks its own address' {
    It 'docker/entrypoint.ps1 asks the run address before it writes anything into the run' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $ask = $code.IndexOf('Assert-VmfRunNames')
        $ask | Should -BeGreaterThan 0
        $code.IndexOf('Assert-VmfNotProject') | Should -BeGreaterThan 0
        $ask | Should -BeLessThan $code.IndexOf('Write-VmfEvent') -Because 'the version line is the first write into the run'
        $ask | Should -BeGreaterThan $code.IndexOf('$runPath = ') -Because 'it asks the address the engine works on'
    }
}

# PROJECT-LOGS-DELETE-1: a project's own logs folder is part of the project.
# The product writes it itself - an event recorded against the project's path,
# where no run is, leaves logs/events.jsonl (PROJECT-3) - and nothing reads it
# back: every reader of an event log asks for a RUN's logs. So the project
# delete takes it with project.json, and nothing more: a run beside it still
# refuses, and a run or a project document under logs still refuses.
Describe 'PROJECT-LOGS-DELETE-1: a project with its own event log is an empty project' {
    BeforeAll {
        $script:NewProj = {
            param($store)
            New-VmfProject -StorePath $store -ProjectId 'contoso' -Name 'x' -OnBehalfOf @{ Identity = 'a@example.com' } -Confirm:$false | Out-Null
        }
        $script:Del = { param($store) Remove-VmfProject -StorePath $store -ProjectId 'contoso' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false }
    }

    It 'the pure rule allows project.json and the event log parts in logs, and only those' {
        InModuleScope VmMigrationFactory {
            Get-VmfPrefixDeleteRefusal -Id 'p' -Kind project -Names @('project.json', 'logs/events.jsonl', 'logs/events-2.jsonl') | Should -BeNullOrEmpty
            foreach ($bad in @('logs/run.json', 'logs/project.json', 'logs/sub/x.jsonl', 'Logs/x.jsonl', 'logs/x.json', 'logs/', 'x/logs/events.jsonl', 'logs.jsonl', 'logs/events.jsonl.txt', 'run.json')) {
                Get-VmfPrefixDeleteRefusal -Id 'p' -Kind project -Names @('project.json', $bad) | Should -BeLike "400: Project 'p' holds documents other than its project document and its event log: $bad.*" -Because $bad
            }
        }
    }

    It 'the run rule is unchanged: a run may hold its own logs' {
        InModuleScope VmMigrationFactory {
            Get-VmfPrefixDeleteRefusal -Id 'r' -Kind run -Names @('run.json', 'logs/events.jsonl') | Should -BeNullOrEmpty
        }
    }

    It 'Remove-VmfProject deletes a project that holds project.json and logs, and nothing beside it' {
        $store = SrnStore
        & $script:NewProj $store
        SrnPut $store 'contoso/logs/events.jsonl' '{"step":"retention"}'
        SrnPut $store 'contoso/logs/events-2.jsonl' '{"step":"retention"}'
        (& $script:Del $store).Documents | Should -Be 3
        Test-Path (Join-Path $store 'contoso') | Should -BeFalse
        @(SrnFiles $store | Where-Object { $_ -like 'vmf-*' }).Count | Should -Be 4
    }

    It 'Remove-VmfProject still refuses a project with a run beside its logs, names only the run, and deletes nothing' {
        $store = SrnStore
        & $script:NewProj $store
        SrnPut $store 'contoso/logs/x.jsonl' '{}'
        SrnPut $store 'contoso/scan-1/run.json' '{"runId":"scan-1","kind":"assessment"}'
        $before = SrnFiles $store
        { & $script:Del $store } | Should -Throw "Project 'contoso' still holds 1 assessment(s) or migration(s): scan-1. *"
        SrnFiles $store | Should -Be $before
    }

    It 'Remove-VmfProject still counts a run named logs-of-war' {
        $store = SrnStore
        & $script:NewProj $store
        SrnPut $store 'contoso/logs-of-war/run.json' '{"runId":"logs-of-war"}'
        { & $script:Del $store } | Should -Throw "*still holds 1 assessment(s) or migration(s): logs-of-war.*"
    }

    It 'Remove-VmfProject refuses <Rel> under the project, and deletes nothing' -ForEach @(
        @{ Rel = 'logs/run.json' }, @{ Rel = 'logs/project.json' }, @{ Rel = 'logs/sub/x.jsonl' }, @{ Rel = 'vmf-records/x.json' }, @{ Rel = 'vmf-claims/x.claim' }) {
        $store = SrnStore
        & $script:NewProj $store
        SrnPut $store 'contoso/logs/events.jsonl' '{}'
        SrnPut $store "contoso/$Rel" '{}'
        $before = SrnFiles $store
        { & $script:Del $store } | Should -Throw "400: Project 'contoso' holds documents other than its project document and its event log: $Rel. *"
        SrnFiles $store | Should -Be $before
    }

    Context 'on blob storage' {
        BeforeEach { & $script:SeedBlobs; & $script:MockBlob }

        It 'Remove-VmfProject deletes project.json and logs, and nothing beside them' {
            $global:SrnBlobs['contoso/project.json'] = '{"projectId":"contoso","name":"x"}'
            $global:SrnBlobs['contoso/logs/events.jsonl'] = '{}'
            $global:SrnBlobs['contoso-2/project.json'] = '{}'
            (Remove-VmfProject -StorePath 'azblob://acct/cont' -ProjectId 'contoso' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false).Documents | Should -Be 2
            @($global:SrnBlobs.Keys | Sort-Object) | Should -Be @('contoso-2/project.json', 'vmf-claims/claim-1.json', 'vmf-claims/deletions.jsonl', 'vmf-records/mig-1.json')
        }

        It 'Remove-VmfProject still refuses a project with a run beside its logs, and sends no delete' {
            $global:SrnBlobs['contoso/project.json'] = '{"projectId":"contoso","name":"x"}'
            $global:SrnBlobs['contoso/logs/events.jsonl'] = '{}'
            $global:SrnBlobs['contoso/scan-1/run.json'] = '{}'
            { Remove-VmfProject -StorePath 'azblob://acct/cont' -ProjectId 'contoso' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false } |
                Should -Throw "Project 'contoso' still holds 1 assessment(s) or migration(s): scan-1. *"
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'Remove-VmfProject refuses <Rel>, and sends no delete' -ForEach @(@{ Rel = 'logs/run.json' }, @{ Rel = 'logs/project.json' }, @{ Rel = 'Logs/x.jsonl' }) {
            $global:SrnBlobs['contoso/project.json'] = '{"projectId":"contoso","name":"x"}'
            $global:SrnBlobs["contoso/$Rel"] = '{}'
            { Remove-VmfProject -StorePath 'azblob://acct/cont' -ProjectId 'contoso' -Reason 'x' -RemovedBy 'a@example.com' -Confirm:$false } |
                Should -Throw "400: Project 'contoso' holds documents other than its project document and its event log: $Rel. *"
            & $script:Changed | Should -BeNullOrEmpty
        }

        It 'the second sweep deletes no run document that appeared under logs after the first listing' {
            $global:SrnBlobs['contoso/project.json'] = '{"projectId":"contoso","name":"x"}'
            $global:SrnBlobs['contoso/logs/events.jsonl'] = '{}'
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
                $r = SrnAnswer $Method $Uri
                if ($Method -eq 'DELETE' -and $Uri -like '*contoso/project.json') { $global:SrnBlobs['contoso/logs/run.json'] = '{}' }
                $r
            }
            { InModuleScope VmMigrationFactory { Remove-VmfStorePrefix -RunPath 'azblob://acct/cont/contoso' -Kind project -Confirm:$false } } |
                Should -Throw "400: Project 'contoso' holds documents other than its project document and its event log: logs/run.json*"
            @($global:SrnBlobs.Keys) | Should -Contain 'contoso/logs/run.json'
        }
    }

    It 'the service deletes a project that holds only its event log' {
        $store = SrnStore
        & $script:NewProj $store
        SrnPut $store 'contoso/logs/events.jsonl' '{}'
        Invoke-VmfFacadeDeleteProject -Principal $script:operator -StorePath $store -ProjectId 'contoso' -Note 'x' | Out-Null
        Test-Path (Join-Path $store 'contoso') | Should -BeFalse
    }
}
# PROJECT-LOGS-DELETE-1 review: the same fault one level down. A walk of the
# store skipped the kept folders at the top, then listed every sub-folder of a
# project as a run, so a project with its own logs showed '<project>/logs' as
# a run id - and the tidy-up of abandoned runs handed it to Remove-VmfRun.
Describe 'PROJECT-LOGS-DELETE-1: no walk of the store takes a project''s logs for a run' {
    BeforeAll {
        $script:OldManifest = '{"runId":"logs","kind":"assessment","createdUtc":"2020-01-01T00:00:00Z"}'
        $script:ProjWithLogs = {
            $store = SrnStore
            SrnPut $store 'contoso/project.json' '{"projectId":"contoso","name":"x"}'
            SrnPut $store 'contoso/logs/events.jsonl' '{}'
            SrnPut $store 'contoso/logs/run.json' $script:OldManifest
            SrnPut $store 'contoso/scan-1/run.json' '{"runId":"scan-1","kind":"assessment","project":"contoso"}'
            $store
        }
    }

    It 'Get-VmfStoreRunPaths lists the run in a project and not its logs, on the file store' {
        $store = & $script:ProjWithLogs
        $ids = @(InModuleScope VmMigrationFactory -Parameters @{ sp = $store } { param($sp) Get-VmfStoreRunPaths -StorePath $sp | ForEach-Object { $_.Id } })
        $ids | Should -Be @('contoso/scan-1')
    }

    It 'Remove-VmfAbandonedRuns does not take a project''s logs for a run, over the store and inside the project' {
        $store = & $script:ProjWithLogs
        $before = SrnFiles $store
        $r = Remove-VmfAbandonedRuns -StorePath $store -OlderThanDays 30 -RemovedBy 'a@example.com' -Confirm:$false
        @($r.Candidates.Id) + @($r.Kept.Id) | Should -Not -Contain 'contoso/logs'
        $r = Remove-VmfAbandonedRuns -StorePath $store -Project 'contoso' -OlderThanDays 30 -RemovedBy 'a@example.com' -Confirm:$false
        @($r.Candidates.Id) + @($r.Kept.Id) | Should -Not -Contain 'logs'
        SrnFiles $store | Should -Be $before
    }

    It 'the service lists the run in a project and not its logs (Get-VmfFacadeRunIds)' {
        $store = & $script:ProjWithLogs
        @(Get-VmfFacadeRunIds -StorePath $store) | Should -Be @('contoso/scan-1')
    }

    Context 'on blob storage' {
        BeforeEach { & $script:SeedBlobs; & $script:MockBlob }

        It 'Get-VmfStoreRunPaths lists the run in a project and not its logs' {
            $global:SrnBlobs['contoso/project.json'] = '{}'
            $global:SrnBlobs['contoso/logs/events.jsonl'] = '{}'
            $global:SrnBlobs['contoso/scan-1/run.json'] = '{}'
            $global:SrnBlobs['loose-1/run.json'] = '{}'
            $ids = @(InModuleScope VmMigrationFactory { Get-VmfStoreRunPaths -StorePath 'azblob://acct/cont' | ForEach-Object { $_.Id } })
            @($ids | Sort-Object) | Should -Be @('contoso/scan-1', 'loose-1')
        }
    }
}