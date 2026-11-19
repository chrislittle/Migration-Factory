#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    # TEMP-LITTER-1: the last of the four sites. Sixty-one of its json files
    # were in the temp folder; it was the only one a full suite run still left
    # behind after the other three were fixed.
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'upstream'

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:toolPath = Join-Path $repoRoot 'tools' 'Test-UpstreamDrift.ps1'
    $script:baselinePath = Join-Path $repoRoot 'src' 'guest' 'upstream.json'
    $script:baseline = Get-Content $baselinePath -Raw | ConvertFrom-Json -Depth 8

    function Global:NewTempBaseline {
        param($Files)
        $doc = @{
            schemaVersion = 1
            repo = 'Azure/SAP-on-Azure-Scripts-and-Utilities'
            branch = 'main'
            pinnedCommit = 'a' * 40
            pinnedUtc = '2026-08-25T00:00:00Z'
            files = $Files
        }
        $tmpFile = Join-Path $script:temp "baseline-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $doc | ConvertTo-Json -Depth 8 | Set-Content $tmpFile
        $tmpFile
    }
}
AfterAll { Remove-Item 'function:\NewTempBaseline' -ErrorAction SilentlyContinue }

Describe 'upstream baseline (UPST-1)' {

    It 'is well-formed: repo, pinned commit, and at least one tracked file' {
        $baseline.repo | Should -Be 'Azure/SAP-on-Azure-Scripts-and-Utilities'
        $baseline.pinnedCommit | Should -Match '^[0-9a-f]{40}$'
        @($baseline.files).Count | Should -BeGreaterThan 0
    }

    It 'every tracked file records a sha256 and the local derivatives it feeds' {
        foreach ($f in @($baseline.files)) {
            $f.path | Should -Not -BeNullOrEmpty
            $f.sha256 | Should -Match '^[0-9a-f]{64}$'
            @($f.localDerivatives).Count | Should -BeGreaterThan 0 -Because "$($f.path) must say which local assets to re-evaluate on drift"
        }
    }

    It 'local derivatives point at files that exist (or engine areas by convention)' {
        foreach ($f in @($baseline.files)) {
            foreach ($d in @($f.localDerivatives)) {
                if ($d -match '^(src|lab|tools)[\\/]') {
                    Join-Path $repoRoot $d | Should -Exist
                }
                else {
                    $d | Should -Match '^engine:' -Because 'non-file derivatives use the engine:<area> convention'
                }
            }
        }
    }
}

Describe 'Test-UpstreamDrift.ps1 logic (no network)' {

    It 'reports NO drift when upstream content matches the baseline hashes' {
        $content = 'stable upstream content'
        $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($content))) -Algorithm SHA256).Hash.ToLowerInvariant()
        $bl = NewTempBaseline -Files @(@{ path = 'X/a.ps1'; sha256 = $hash; localDerivatives = @('engine:pathB') })
        try {
            $result = & $toolPath -BaselinePath $bl -ContentProvider { param($Path) 'stable upstream content' }
            $result.Drifted | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
        }
        finally { Remove-Item $bl -Force }
    }

    It 'reports drift with the changed paths when upstream moved' {
        $hash = 'b' * 64
        $bl = NewTempBaseline -Files @(
            @{ path = 'X/a.ps1'; sha256 = $hash; localDerivatives = @('engine:pathB') },
            @{ path = 'X/b.sh'; sha256 = $hash; localDerivatives = @('src/guest/linux/nvme-fix.sh') }
        )
        try {
            $result = & $toolPath -BaselinePath $bl -ContentProvider { param($Path) "new content of $Path" }
            @($result.Drifted).Count | Should -Be 2
            @($result.Drifted.path) | Should -Contain 'X/a.ps1'
            $result.ExitCode | Should -Be 1
        }
        finally { Remove-Item $bl -Force }
    }

    It 'treats an unfetchable upstream file as drift (deleted/moved upstream)' {
        $bl = NewTempBaseline -Files @(@{ path = 'X/gone.ps1'; sha256 = ('c' * 64); localDerivatives = @('engine:pathA') })
        try {
            $result = & $toolPath -BaselinePath $bl -ContentProvider { param($Path) throw '404' }
            @($result.Drifted).Count | Should -Be 1
            $result.Drifted[0].reason | Should -Match 'fetch failed'
        }
        finally { Remove-Item $bl -Force }
    }

    It '-UpdateBaseline re-pins hashes and records the new commit' {
        $bl = NewTempBaseline -Files @(@{ path = 'X/a.ps1'; sha256 = ('d' * 64); localDerivatives = @('engine:pathB') })
        try {
            $result = & $toolPath -BaselinePath $bl -ContentProvider { param($Path) 'fresh content' } `
                -UpdateBaseline -CommitSha ('e' * 40)
            $result.ExitCode | Should -Be 0
            $updated = Get-Content $bl -Raw | ConvertFrom-Json
            $updated.pinnedCommit | Should -Be ('e' * 40)
            $expected = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('fresh content'))) -Algorithm SHA256).Hash.ToLowerInvariant()
            $updated.files[0].sha256 | Should -Be $expected
        }
        finally { Remove-Item $bl -Force }
    }
}

# REPORT-1, 2026-09-19: the report has to be openable. See DocsDrift.Tests.ps1.
Describe 'REPORT-1: every upstream drift entry can be opened' {

    It 'a changed file and an unreadable one both carry their links' {
        $bl = NewTempBaseline @(@{ path = 'X/a.ps1'; sha256 = ('b' * 64); localDerivatives = @('engine:pathB') })
        $changed = & $toolPath -BaselinePath $bl -ContentProvider { param($Path) "new content of $Path" }
        $unreadable = & $toolPath -BaselinePath $bl -ContentProvider { param($Path) throw '404' }

        $all = @($changed.Drifted) + @($unreadable.Drifted)
        @($all | Where-Object { $_.kind -eq 'changed' }).Count | Should -Be 1
        @($all | Where-Object { $_.kind -eq 'unreachable' }).Count | Should -Be 1
        foreach ($d in $all) {
            $d.url        | Should -Be "https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities/blob/main/$($d.path)"
            $d.changesUrl | Should -Be "https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities/commits/main/$($d.path)"
        }
    }
}

AfterAll {
    # TEMP-LITTER-1. A throw here fails the container, which is the point.
    Remove-VmfTestTemp
}