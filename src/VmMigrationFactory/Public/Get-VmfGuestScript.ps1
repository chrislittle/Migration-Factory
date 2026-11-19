function Get-VmfGuestScript {
    <#
    .SYNOPSIS
        Load a guest script asset by name, verifying it against the manifest.
    .DESCRIPTION
        Returns the script content plus its manifest metadata (version, sha256).
        The sha256 of the file on disk MUST match the manifest - a mismatch means
        the manifest wasn't regenerated after an edit (tools/Update-GuestManifest.ps1)
        and is treated as a hard error: what runs in customer VMs must be exactly
        what was reviewed and recorded.
    .PARAMETER Name
        Script file name, e.g. 'Test-NvmeReady.ps1' or 'nvme-check.sh'.
    .PARAMETER GuestRoot
        Root of the guest assets (default: the module's bundled src/guest).
    .OUTPUTS
        [pscustomobject] @{ Name; Os; Version; Sha256; Content; Path; Packages }
        Packages (MANA-WIN-1): the manifest's pin for each package this
        script downloads and installs - name, version, url, sha256 - or empty.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][string]$GuestRoot
    )

    if (-not $GuestRoot) {
        # Module layout: src/VmMigrationFactory/../guest
        $GuestRoot = Join-Path $script:VmfModuleRoot '..' 'guest'
        $GuestRoot = [System.IO.Path]::GetFullPath($GuestRoot)
    }

    $manifestPath = Join-Path $GuestRoot 'manifest.json'
    if (-not (Test-Path $manifestPath)) { throw "Guest manifest not found: $manifestPath" }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -Depth 6

    $entry = @($manifest.scripts) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $entry) { throw "Guest script '$Name' is not listed in the manifest." }

    $path = Join-Path $GuestRoot $entry.os $Name
    if (-not (Test-Path $path)) { throw "Guest script file missing: $path" }

    $actualHash = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $entry.sha256) {
        throw "Guest script '$Name' sha256 mismatch: manifest=$($entry.sha256) actual=$actualHash. " +
              'Run tools/Update-GuestManifest.ps1 and review the change.'
    }

    $packages = @(@($manifest.PSObject.Properties['packages'] | ForEach-Object { $_.Value }) |
        ForEach-Object { $_ } | Where-Object { $_ -and $_.script -eq $Name })

    [pscustomobject]@{
        Name     = $entry.name
        Os       = $entry.os
        Version  = $entry.version
        Sha256   = $entry.sha256
        Content  = Get-Content $path -Raw
        Path     = $path
        Packages = $packages
    }
}
