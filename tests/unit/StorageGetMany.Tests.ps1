#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
PERF-RUNS-LIST-1: Invoke-VmfStorageGetMany, many store reads sent together, at
most 8 in flight, with one token.

These tests lived in RunList.Tests.ps1 with the list of runs (GET /api/runs).
PAGE-LOAD-1 removed that list - no page asked for it any more - and store/docs
(Get-VmfFacadeStoreDocs, StoreDocs.Tests.ps1) now sends its reads through this
function, so its own tests stay, as they were.
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
}
AfterAll { Remove-VmfTestTemp; Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue }
Describe 'PERF-RUNS-LIST-1: Invoke-VmfStorageGetMany, the reads sent together' {
    BeforeAll {
        $script:dir = Join-Path (New-VmfTestTemp -Prefix 'getmany') 'c'
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        foreach ($i in 1..20) { Set-Content (Join-Path $script:dir "doc$i.json") -Value "{`"n`":$i}" -NoNewline -Encoding utf8NoBOM }
        $script:svc2 = [VmfFakeBlobService]::new($script:dir, 30)
        $script:svc2.RequireToken = 'Bearer many-token'
        $script:tokens = 0
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { $script:tokens++; [pscustomobject]@{ Token = 'many-token' } }
        $script:Uri = { param($name) "$($script:svc2.BaseUri)cont/$name" }
        # The function gives back ONE array; each answer is taken out of it here.
        $script:GetMany = { param([string[]]$u, [int]$limit = 8)
            InModuleScope VmMigrationFactory -Parameters @{ u = $u; l = $limit } { (Invoke-VmfStorageGetMany -Uri $u -Limit $l) | ForEach-Object { $_ } }
        }
    }
    AfterAll { $script:svc2.Dispose() }

    It 'gives each answer back in the place of the request that asked for it' {
        $uris = @(1..20 | ForEach-Object { & $script:Uri "doc$_.json" })
        $out = @(& $script:GetMany $uris)
        $out.Count | Should -Be 20
        foreach ($i in 1..20) {
            $out[$i - 1].StatusCode | Should -Be 200
            ($out[$i - 1].Content | ConvertFrom-Json).n | Should -Be $i
        }
    }

    It 'keeps at most the limit in flight, and uses all of it' {
        $script:svc2.ResetCounts()
        $null = & $script:GetMany @(1..20 | ForEach-Object { & $script:Uri "doc$_.json" }) 3
        $script:svc2.MaxInFlight | Should -Be 3
        $script:svc2.Requests | Should -Be 20
    }

    It 'asks for one token for all of them, and sends it' {
        $script:tokens = 0
        $out = @(& $script:GetMany @((& $script:Uri 'doc1.json'), (& $script:Uri 'doc2.json')))
        $script:tokens | Should -Be 1
        $out[0].StatusCode | Should -Be 200 -Because 'the service refuses a request without the token (403)'
    }

    It 'gives a missing document back as 404, not as an error' {
        $out = @(& $script:GetMany @((& $script:Uri 'nothing.json'), (& $script:Uri 'doc3.json')))
        $out[0].StatusCode | Should -Be 404
        $out[1].StatusCode | Should -Be 200
    }

    It 'tries a "try later" answer again, through the one request with retries' {
        $script:svc2.FailFirst['doc4.json'] = 1
        $out = @(& $script:GetMany @((& $script:Uri 'doc4.json')))
        $out[0].StatusCode | Should -Be 200
        ($out[0].Content | ConvertFrom-Json).n | Should -Be 4
    }

    It 'an empty list sends nothing' {
        $script:svc2.ResetCounts()
        @(& $script:GetMany @()).Count | Should -Be 0
        $script:svc2.Requests | Should -Be 0
    }
}
