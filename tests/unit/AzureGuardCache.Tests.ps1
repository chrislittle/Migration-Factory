#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CI-SPEED-2: the Azure guard reads the module's source once per run.
#
# MEASURED 2026-09-26 on a Windows PC: every test file called
# Get-VmfAzCommandsInSource, which parses all of src/VmMigrationFactory - about
# half a second a file, over two minutes of every run, re-reading source that
# had not changed. The answer is now kept for the run. What must still hold:
# the kept answer is the same as a fresh read, and an edit to a source file is
# seen by the next call, so a new Az call is still blocked the moment it is
# written.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')

    function Global:NewFakeRepo {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-agc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $mod = Join-Path $root 'src' 'VmMigrationFactory'
        New-Item -ItemType Directory -Path $mod -Force | Out-Null
        Set-Content (Join-Path $mod 'One.ps1') "function Get-One { Get-AzVM -Name x }"
        $root
    }
}
AfterAll { Remove-Item 'function:\NewFakeRepo' -ErrorAction SilentlyContinue }

Describe 'CI-SPEED-2: the source is read once, and read again when it changes' {

    BeforeEach { $global:VmfAzCommandsCache = $null }
    AfterEach { $global:VmfAzCommandsCache = $null }

    It 'the kept answer is the same as a fresh read, on the real module' {
        $first = @(Get-VmfAzCommandsInSource -RepoRoot $script:repoRoot)
        $first.Count | Should -BeGreaterThan 10 -Because 'the module calls many Az cmdlets, so an empty list means nothing was read'
        $global:VmfAzCommandsCache | Should -Not -BeNullOrEmpty
        $second = @(Get-VmfAzCommandsInSource -RepoRoot $script:repoRoot)
        ($second -join ',') | Should -Be ($first -join ',')
    }

    It 'a second call does not read the source again' {
        $root = NewFakeRepo
        try {
            @(Get-VmfAzCommandsInSource -RepoRoot $root) | Should -Be @('Get-AzVM')
            # Poison the kept answer: if the second call used it, it says so.
            $global:VmfAzCommandsCache.Found = @('Get-AzKeptAnswer')
            @(Get-VmfAzCommandsInSource -RepoRoot $root) | Should -Be @('Get-AzKeptAnswer')
        }
        finally { Remove-Item $root -Recurse -Force }
    }

    It 'an edited source file is read again, so a new Az call is still blocked' {
        $root = NewFakeRepo
        try {
            @(Get-VmfAzCommandsInSource -RepoRoot $root) | Should -Be @('Get-AzVM')
            $file = Join-Path $root 'src' 'VmMigrationFactory' 'One.ps1'
            Set-Content $file "function Get-One { Get-AzVM -Name x; Remove-AzDisk -Name y }"
            (Get-Item $file).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(1)
            @(Get-VmfAzCommandsInSource -RepoRoot $root) | Should -Be @('Get-AzVM', 'Remove-AzDisk')
        }
        finally { Remove-Item $root -Recurse -Force }
    }

    It 'a new source file is read too' {
        $root = NewFakeRepo
        try {
            @(Get-VmfAzCommandsInSource -RepoRoot $root) | Should -Be @('Get-AzVM')
            Set-Content (Join-Path $root 'src' 'VmMigrationFactory' 'Two.ps1') "function Get-Two { New-AzSnapshot -Name z }"
            @(Get-VmfAzCommandsInSource -RepoRoot $root) | Should -Be @('Get-AzVM', 'New-AzSnapshot')
        }
        finally { Remove-Item $root -Recurse -Force }
    }
}
