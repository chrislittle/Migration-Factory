#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:guestRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' 'src' 'guest'))
    $script:manifest = Get-Content (Join-Path $guestRoot 'manifest.json') -Raw | ConvertFrom-Json -Depth 6
}

Describe 'Guest manifest integrity' {

    It 'every file on disk is listed in the manifest' {
        $onDisk = foreach ($os in @('windows', 'linux')) {
            Get-ChildItem (Join-Path $guestRoot $os) -File | ForEach-Object { $_.Name }
        }
        $listed = @($manifest.scripts) | ForEach-Object { $_.name }
        foreach ($f in $onDisk) { $listed | Should -Contain $f }
    }

    It 'every manifest entry exists on disk' {
        foreach ($entry in @($manifest.scripts)) {
            Join-Path $guestRoot $entry.os $entry.name | Should -Exist
        }
    }

    It 'sha256 in manifest matches every file on disk (no drift)' {
        foreach ($entry in @($manifest.scripts)) {
            $path = Join-Path $guestRoot $entry.os $entry.name
            $actual = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $actual | Should -Be $entry.sha256 -Because "$($entry.name) changed without running tools/Update-GuestManifest.ps1"
        }
    }

    It 'versions are semver' {
        foreach ($entry in @($manifest.scripts)) {
            $entry.version | Should -Match '^\d+\.\d+\.\d+$'
        }
    }
}

Describe 'Get-VmfGuestScript' {

    It 'loads a known script with matching hash' {
        $s = Get-VmfGuestScript -Name 'Test-NvmeReady.ps1' -GuestRoot $guestRoot
        $s.Os | Should -Be 'windows'
        $s.Content | Should -Match 'vmf\.guest/2'
    }

    It 'throws for a script not in the manifest' {
        { Get-VmfGuestScript -Name 'not-a-script.ps1' -GuestRoot $guestRoot } | Should -Throw '*not listed*'
    }

    It 'throws on hash drift' {
        # Copy the guest tree, tamper with one file, keep the stale manifest
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-drift-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Copy-Item $guestRoot $tmp -Recurse
        Add-Content (Join-Path $tmp 'windows' 'Test-NvmeReady.ps1') "`n# tampered"
        try {
            { Get-VmfGuestScript -Name 'Test-NvmeReady.ps1' -GuestRoot $tmp } | Should -Throw '*sha256 mismatch*'
        }
        finally { Remove-Item $tmp -Recurse -Force }
    }
}
