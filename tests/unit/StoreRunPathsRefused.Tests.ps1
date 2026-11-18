#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
STORE-RUNPATHS-REFUSED-1: a store check that is refused or fails must stop the
work that asked it, never read as "the document is not here".

WHAT WAS WRONG. The run finder (Get-VmfStoreRunPaths) asked, for each top-level
folder, whether project.json was there, with Test-VmfStoreItem. On blob storage
that was a HEAD request, and Test-VmfStoreItem gave $true only for 200: a 403,
or a 500 after the retries, gave $false. So a refused check took a PROJECT for
a loose run; its run.json is not there, so it was skipped, and the migrations
inside it were never read. Get-VmfMigrationsPlannedFrom then said that no
migration was planned from the assessment, and Assert-VmfAssessmentUnused let
the delete go on - the defect ASSESS-LINK-1 was written to stop.

THE RULE NOW.
  - The run finder asks Get-VmfStoreFoldersHolding (PERF-PROJECTS-LIST-1),
    which lists the folders together and throws on a refused listing.
  - A delete of an assessment whose check fails stops with a clear error that
    says nothing was deleted.
  - The tidy-up of abandoned runs finds the projects the same way.
  - Test-VmfStoreItem answers $true for 200, $false for 404, and throws for
    any other answer, as Read-VmfStoreText already does. Its other callers (a
    halt flag, a plan that makes a run a decision) read a refusal as "no" too.
  - On a healthy store the run paths are the same as before, on the file store
    and on blob.
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

    # Two projects, an assessment in one and the migration planned from it in
    # the other (New-VmfPlan allows that), a loose assessment and its loose
    # migration, the claim registry and the records folder.
    $script:base = New-VmfTestTemp -Prefix 'runpaths'
    $script:root = Join-Path $script:base 'store'
    New-Item -ItemType Directory -Path $script:root | Out-Null
    foreach ($proj in 'estate', 'other') {
        New-VmfProject -StorePath $script:root -ProjectId $proj -Name $proj `
            -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' } -Confirm:$false | Out-Null
    }
    $mk = { param([string]$Id, [string]$Kind, [string]$From)
        $parts = $Id -split '/'
        $project = if ($parts.Count -gt 1) { $parts[0] } else { $null }
        InModuleScope VmMigrationFactory -Parameters @{ rp = "$script:root/$Id"; id = $parts[-1]; k = $Kind; f = $From; pr = $project } {
            Initialize-VmfRun -RunPath $rp -RunId $id -Kind $k -FromAssessment $f -Project $pr | Out-Null
        }
    }
    & $mk 'estate/scan-1' 'assessment' ''
    & $mk 'other/scan-1-migration-1' 'migration' 'scan-1'
    & $mk 'scan-2' 'assessment' ''
    & $mk 'scan-2-migration-1' 'migration' 'scan-2'
    foreach ($f in 'vmf-claims', 'vmf-records') {
        New-Item -ItemType Directory -Path (Join-Path $script:root $f) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path $script:root $f) 'x.json') -Value '{}' -NoNewline
    }

    # The function as it was before this item: one Test-VmfStoreItem a folder.
    $script:Oracle = { param([string]$StorePath)
        InModuleScope VmMigrationFactory -Parameters @{ sp = $StorePath } {
            $r0 = $sp.TrimEnd('/', '\')
            @(foreach ($prefix in @(Get-VmfStorePrefixes -StorePath $r0)) {
                if ($prefix -in @('vmf-claims', 'vmf-records')) { continue }
                $path = "$r0/$prefix"
                if (Test-VmfStoreItem -RunPath $path -RelPath 'project.json') {
                    foreach ($child in @(Get-VmfStorePrefixes -StorePath $path)) {
                        [pscustomobject]@{ Id = "$prefix/$child"; Path = "$path/$child" }
                    }
                    continue
                }
                [pscustomobject]@{ Id = $prefix; Path = $path }
            })
        }
    }
    $script:Find = { param([string]$StorePath)
        @(InModuleScope VmMigrationFactory -Parameters @{ sp = $StorePath } { Get-VmfStoreRunPaths -StorePath $sp })
    }
    $script:Json = { param($rows) @($rows | Select-Object Id, Path) | ConvertTo-Json -Depth 4 -AsArray }
    $script:wantIds = @('estate/scan-1', 'other/scan-1-migration-1', 'scan-2', 'scan-2-migration-1')
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'STORE-RUNPATHS-REFUSED-1: the run finder on the file store' {
    It 'gives the run paths the function gave before' {
        $want = & $script:Json (& $script:Oracle $script:root)
        @(& $script:Oracle $script:root).Id | Should -Be $script:wantIds -Because 'the oracle must see the runs, or the test agrees with nothing'
        & $script:Json (& $script:Find $script:root) | Should -BeExactly $want
    }

    It 'gives the same run paths when the store path ends in a separator' {
        $want = & $script:Json (& $script:Oracle "$script:root/")
        & $script:Json (& $script:Find "$script:root/") | Should -BeExactly $want
    }

    It 'finds the migration in another project, so the delete of the assessment is refused' {
        { Remove-VmfRun -RunPath "$script:root/estate/scan-1" -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*other/scan-1-migration-1*'
    }
}

Describe 'STORE-RUNPATHS-REFUSED-1: the run finder over HTTP, on blob storage' {
    BeforeAll {
        $script:svc = [VmfFakeBlobService]::new($script:root, 0)
        $script:svc.RequireToken = 'Bearer runpaths-token'
        $env:VMF_TEST_CONTAINER_URI = "$($script:svc.BaseUri)cont"
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'runpaths-token' } }
        # The service serves the store folder as the container 'cont': the store
        # is the root of its container, as on an install.
        Mock -ModuleName VmMigrationFactory Get-VmfStoreContext {
            if ($RunPath -match '^azblob://([^/]+)/([^/]+)/(.+?)/*$') {
                return [pscustomobject]@{ Backend = 'azblob'; Account = $Matches[1]; Container = $Matches[2]; Prefix = $Matches[3]; ContainerUri = $env:VMF_TEST_CONTAINER_URI }
            }
            [pscustomobject]@{ Backend = 'file'; Root = $RunPath }
        }
        $script:blobStore = 'azblob://acct/cont'
        $script:realMany = InModuleScope VmMigrationFactory { Get-Command Invoke-VmfStorageGetMany -CommandType Function }
        $script:realRequest = InModuleScope VmMigrationFactory { Get-Command Invoke-VmfStorageRequest -CommandType Function }
        # The store refuses every check of one folder: its listing, sent with
        # the others, and a check of its project.json alone (the request the
        # run finder sent before this item). The real answers otherwise.
        $script:RefuseListing = { param([string]$Folder, [int]$Status)
            $script:refuseFolder = $Folder
            $script:refuseStatus = $Status
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
                if ($Method -eq 'HEAD' -and $Uri -like "*/$script:refuseFolder/project.json") { return [pscustomobject]@{ StatusCode = $script:refuseStatus; Content = '' } }
                if ($Uri -like "*prefix=$([uri]::EscapeDataString("$script:refuseFolder/"))*") { return [pscustomobject]@{ StatusCode = $script:refuseStatus; Content = 'refused by the test' } }
                $pass = @{ Method = $Method; Uri = $Uri }
                if ($Headers) { $pass.Headers = $Headers }
                if ($null -ne $Body -and $Body -ne '') { $pass.Body = $Body }
                & $script:realRequest @pass
            }
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageGetMany {
                $answers = & $script:realMany -Uri $Uri
                $needle = "prefix=$([uri]::EscapeDataString("$script:refuseFolder/"))"
                , @(for ($k = 0; $k -lt @($Uri).Count; $k++) {
                    if (@($Uri)[$k] -like "*$needle*") { [pscustomobject]@{ StatusCode = $script:refuseStatus; Content = 'refused by the test' } }
                    else { @($answers)[$k] }
                })
            }
        }
    }
    AfterAll { $script:svc.Dispose(); Remove-Item Env:\VMF_TEST_CONTAINER_URI -ErrorAction SilentlyContinue }

    It 'gives the run paths the function gave before on blob' {
        $want = & $script:Json (& $script:Oracle $script:blobStore)
        @(& $script:Oracle $script:blobStore).Id | Should -Be $script:wantIds
        & $script:Json (& $script:Find $script:blobStore) | Should -BeExactly $want
    }

    It 'gives the run ids of the file store, and each path on blob' {
        $got = & $script:Find $script:blobStore
        $got.Id | Should -Be @((& $script:Find $script:root).Id)
        $got.Path | Should -Be @($script:wantIds | ForEach-Object { "$script:blobStore/$_" })
    }

    It 'THE DEFECT: sends no check of one document, and lists the folders together' {
        $script:svc.ResetCounts()
        $null = & $script:Find $script:blobStore
        @($script:svc.Log | Where-Object { $_ -like 'HEAD *' }).Count | Should -Be 0 -Because 'a HEAD a folder was the check that read a refusal as "no project here"'
        @($script:svc.Log | Where-Object { $_ -match 'prefix=[a-z0-9-]+%2Fproject\.json' }).Count | Should -Be 4 -Because 'estate, other, scan-2 and scan-2-migration-1; the claims and records folders are not asked'
    }

    It 'THE DEFECT: a folder listing the store refuses (403) stops the run finder and names the folder' {
        & $script:RefuseListing 'other' 403
        { & $script:Find $script:blobStore } | Should -Throw "*'other/'*HTTP 403*"
    }

    It 'THE DEFECT: a folder listing that fails (500 after the retries) stops the run finder' {
        & $script:RefuseListing 'other' 500
        { & $script:Find $script:blobStore } | Should -Throw "*'other/'*HTTP 500*"
    }

    It 'THE DEFECT: a refused check (403) refuses the delete of the assessment, and nothing is deleted' {
        & $script:RefuseListing 'other' 403
        { Remove-VmfRun -RunPath "$script:blobStore/estate/scan-1" -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw "*cannot say whether a migration was planned from assessment 'scan-1'*Nothing was deleted*HTTP 403*"
        Test-Path (Join-Path $script:root 'estate/scan-1/run.json') | Should -BeTrue
    }

    It 'THE DEFECT: a failed check (500) refuses the delete of the assessment too' {
        & $script:RefuseListing 'other' 500
        { Remove-VmfRun -RunPath "$script:blobStore/estate/scan-1" -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw "*Nothing was deleted*HTTP 500*"
        Test-Path (Join-Path $script:root 'estate/scan-1/run.json') | Should -BeTrue
    }

    It 'on a healthy store the delete of the assessment is still refused for the migration it names' {
        { Remove-VmfRun -RunPath "$script:blobStore/estate/scan-1" -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*still holds 1 migration(s) planned from it: other/scan-1-migration-1*'
    }

    It 'the tidy-up of abandoned runs stops on a refused folder listing, and removes nothing' {
        & $script:RefuseListing 'other' 403
        { Remove-VmfAbandonedRuns -StorePath $script:blobStore -OlderThanDays 1 -Confirm:$false } | Should -Throw "*'other/'*HTTP 403*"
        Test-Path (Join-Path $script:root 'other/scan-1-migration-1/run.json') | Should -BeTrue
    }

    It 'the tidy-up of abandoned runs asks no check of one document to find the projects' {
        $script:svc.ResetCounts()
        $null = Remove-VmfAbandonedRuns -StorePath $script:blobStore -OlderThanDays 1 -WhatIf
        @($script:svc.Log | Where-Object { $_ -like 'HEAD */project.json' }).Count | Should -Be 0
    }

    It 'the tidy-up stops when the store refuses the check for a plan, rather than take the run as one with no plan' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            if ($Method -eq 'HEAD' -and $Uri -like '*/plan.json') { return [pscustomobject]@{ StatusCode = 403; Content = '' } }
            # A mock's $PSBoundParameters is empty: rebuild the call by name.
            $pass = @{ Method = $Method; Uri = $Uri }
            if ($Headers) { $pass.Headers = $Headers }
            if ($null -ne $Body -and $Body -ne '') { $pass.Body = $Body }
            & $script:realRequest @pass
        }
        { Remove-VmfAbandonedRuns -StorePath $script:blobStore -OlderThanDays 1 -WhatIf } | Should -Throw "*'plan.json'*HTTP 403*"
    }
}

Describe 'STORE-RUNPATHS-REFUSED-1: a check of one document on blob storage' {
    BeforeAll {
        Mock -ModuleName VmMigrationFactory Get-VmfStoreContext {
            [pscustomobject]@{ Backend = 'azblob'; Account = 'acct'; Container = 'cont'; Prefix = 'store/run-1'; ContainerUri = 'https://store.example.com/cont' }
        }
    }

    It 'answers yes for 200' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 200; Content = '' } }
        InModuleScope VmMigrationFactory { Test-VmfStoreItem -RunPath 'azblob://acct/cont/store/run-1' -RelPath 'halt.flag' } | Should -BeTrue
    }

    It 'answers no for 404' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 404; Content = '' } }
        InModuleScope VmMigrationFactory { Test-VmfStoreItem -RunPath 'azblob://acct/cont/store/run-1' -RelPath 'halt.flag' } | Should -BeFalse
    }

    It 'throws for <status>, naming the document and the status, rather than answer no' -ForEach @(
        @{ status = 403 }, @{ status = 500 }, @{ status = 503 }, @{ status = 409 }
    ) {
        $script:st = $status
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = $script:st; Content = 'no' } }
        { InModuleScope VmMigrationFactory { Test-VmfStoreItem -RunPath 'azblob://acct/cont/store/run-1' -RelPath 'halt.flag' } } |
            Should -Throw "*'halt.flag'*HTTP $status*"
    }

    It 'a halt flag the store refuses to show stops the check, rather than say the wave is not halted' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 403; Content = '' } }
        { InModuleScope VmMigrationFactory { Test-VmfWaveHalted -RunPath 'azblob://acct/cont/store/run-1' } } | Should -Throw '*HTTP 403*'
    }
}
