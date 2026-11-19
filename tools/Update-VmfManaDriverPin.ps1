<#
.SYNOPSIS
    MANA-WIN-1: pin the MANA driver for Windows that Install-ManaDriver.ps1
    installs - one version, on purpose.
.DESCRIPTION
    Microsoft's link (https://aka.ms/manawindowsdrivers) redirects to ONE file
    on download.microsoft.com, named for its version. This:

      1. reads where the link points now, without following it, and refuses
         anything that is not an https file on download.microsoft.com;
      2. downloads that file to a temporary folder, takes its sha256 and size,
         refuses it when no INF in it names the MANA device, and shows the
         signer of each catalog file for the person running it to read;
      2a. runs the guest script's OWN signature check (Test-DriverPackageSignatures,
         read from the script it pins, under Windows PowerShell as Run Command
         runs it) on the unpacked package, and refuses to pin a package that
         every Windows machine would refuse (MANA-PIN-SIG-1);
      3. writes the name, version, URL, sha256 and size into the constants at
         the top of src/guest/windows/Install-ManaDriver.ps1, and raises that
         script's own version, because what it installs changed;
      4. runs tools/Update-GuestManifest.ps1, so the manifest lists the new pin.

    It changes files in this repository only. Nothing reaches a machine until
    the change is reviewed, merged and installed.

    WHEN TO RUN IT: when the daily drift check says Microsoft's link moved, or
    that the pinned file changed - and after reading what changed. Then run the
    unit tests and record the new version in the work item.

    This DOWNLOADS a file of about 4 MB from Microsoft.
.PARAMETER Resolver
    For tests: given the link, returns where it points (the redirect target).
.PARAMETER Downloader
    For tests: given a URL and a path, writes the file there.
.PARAMETER SignatureOverride
    For tests: code that runs after the guest script's functions and before
    its check, to replace the READ of a signature (Get-DriverFileSignature,
    Get-SignerRoot). What the check decides on what it reads, and the catalog
    read, stay the guest script's own.
#>
[CmdletBinding()]
param(
    [string]$Link = 'https://aka.ms/manawindowsdrivers',
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..' 'src' 'guest' 'windows' 'Install-ManaDriver.ps1'),
    [string]$GuestRoot = (Join-Path $PSScriptRoot '..' 'src' 'guest'),
    [scriptblock]$Resolver,
    [scriptblock]$Downloader,
    [scriptblock]$SignatureOverride
)

$ErrorActionPreference = 'Stop'
$ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)

function Invoke-GuestSignatureCheck {
    <#
        MANA-PIN-SIG-1: the guest script's own Test-DriverPackageSignatures on
        the unpacked package - one rule, not a copy of it. The script's
        constants and functions are lifted through the parser (as the unit
        tests do, without its main block) and run under Windows PowerShell
        when it is here, the interpreter Run Command uses. Returns
        @{ Problem; Checked } as the guest function gives them.
    #>
    param([string]$GuestScript, [string]$Folder, [string]$WorkFolder, [scriptblock]$Override)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($GuestScript, [ref]$null, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "$GuestScript does not parse, so its signature check cannot run: $($errors[0].Message)" }
    $statements = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
            ($_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -like '$script:*')
        })
    if (-not @($statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Test-DriverPackageSignatures' })) {
        throw "$GuestScript has no Test-DriverPackageSignatures function, so the package cannot be checked."
    }
    $lifted = ($statements | ForEach-Object { $_.Extent.Text }) -join "`r`n"
    $overrideText = ''
    if ($Override) { $overrideText = $Override.ToString() }
    $runner = @(
        'param([string]$Folder)'
        '$ErrorActionPreference = ''Stop'''
        '$ProgressPreference = ''SilentlyContinue'''
        $lifted
        $overrideText
        '$checked = Test-DriverPackageSignatures -Folder $Folder'
        'ConvertTo-Json -InputObject @{ Problem = $checked.Problem; Checked = $checked.Checked } -Compress'
    ) -join "`r`n"
    $runnerPath = Join-Path $WorkFolder 'signature-check.ps1'
    # A byte order mark, so Windows PowerShell reads the file as UTF-8.
    [System.IO.File]::WriteAllText($runnerPath, $runner, [System.Text.UTF8Encoding]::new($true))
    $winPs = Get-Command powershell.exe -ErrorAction SilentlyContinue
    $shell = if ($winPs) { $winPs.Source } else { (Get-Process -Id $PID).Path }
    $raw = @(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runnerPath -Folder $Folder 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "The signature check of the package did not run: $(($raw | ForEach-Object { [string]$_ }) -join ' ')" }
    $result = [string]($raw | Select-Object -Last 1) | ConvertFrom-Json
    return @{ Problem = [string]$result.Problem; Checked = [string]$result.Checked }
}

if (-not $IsWindows) {
    throw 'The signature check of the driver package needs Windows. Run this tool on Windows. Nothing was pinned.'
}

if (-not $Resolver) {
    $Resolver = {
        param($Url)
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        try {
            $client.Timeout = [TimeSpan]::FromSeconds(60)
            $response = $client.SendAsync([System.Net.Http.HttpRequestMessage]::new('HEAD', $Url)).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -lt 300 -or [int]$response.StatusCode -ge 400 -or -not $response.Headers.Location) {
                throw "$Url did not redirect (HTTP $([int]$response.StatusCode))."
            }
            [uri]::new([uri]$Url, [string]$response.Headers.Location).AbsoluteUri
        }
        finally { $client.Dispose() }
    }
}
if (-not $Downloader) {
    $Downloader = { param($Url, $Path) Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing }
}

$target = [string](& $Resolver $Link)
$uri = [uri]$target
if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'download.microsoft.com' -or $uri.AbsolutePath -notmatch '\.zip$') {
    throw "The link points at '$target'. Only an https .zip file on download.microsoft.com is pinned."
}
$name = [System.IO.Path]::GetFileName($uri.AbsolutePath)
if ($name -notmatch '_(\d+(?:_\d+)+)\.zip$') {
    throw "Cannot read a version from the file name '$name'. Pin it by hand, and say why in the work item."
}
$version = $Matches[1] -replace '_', '.'

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-manapin-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $zip = Join-Path $work $name
    & $Downloader $target $zip
    $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $bytes = (Get-Item -LiteralPath $zip).Length

    # A package with no INF that names the MANA device would be refused by
    # every guest at install time - refuse it here instead, where a person is
    # watching. The catalog signatures are shown, for that person to read.
    $unpacked = Join-Path $work 'package'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
    $manaInfs = @(Get-ChildItem -LiteralPath $unpacked -Filter '*.inf' -File -Recurse | Where-Object {
            $text = [System.IO.File]::ReadAllText($_.FullName)
            $text.IndexOf('VEN_1414&DEV_00BA', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $text.IndexOf('Microsoft Azure Network Adapter', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($manaInfs.Count -eq 0) { throw "$name holds no INF file that names the MANA device. It was not pinned." }
    Write-Host "INF files that name the MANA device or adapter:"
    foreach ($inf in $manaInfs) { Write-Host "  $($inf.FullName.Substring($unpacked.Length).TrimStart('\', '/'))" }
    foreach ($cat in @(Get-ChildItem -LiteralPath $unpacked -Filter '*.cat' -File -Recurse)) {
        $sig = Get-AuthenticodeSignature -LiteralPath $cat.FullName
        Write-Host "  catalog $($cat.Name): $($sig.Status), signed by $($sig.SignerCertificate.Subject)"
    }

    # MANA-PIN-SIG-1: the check every Windows machine runs before it installs
    # the driver. A package it refuses is refused here, where a person is
    # watching, and the script stays unchanged.
    $signature = Invoke-GuestSignatureCheck -GuestScript $ScriptPath -Folder $unpacked -WorkFolder $work -Override $SignatureOverride
    if ($signature.Problem) {
        # The guest's text ends with what the guest did; here nothing was pinned.
        $why = $signature.Problem -replace '\s*Nothing was installed\.\s*$', ''
        throw "$name would be refused by every Windows machine: $why It was not pinned."
    }
    $signatureChecked = $signature.Checked
    Write-Host "Signature check passed: $signatureChecked."
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

$text = [System.IO.File]::ReadAllText($ScriptPath)
$before = $text
$set = @{ NAME = $name; VERSION = $version; URL = $target; SHA256 = $sha; BYTES = [string]$bytes }
foreach ($field in $set.Keys) {
    $pattern = "(?m)^(\`$script:PACKAGE_$field\s*=\s*)'[^']*'"
    if ($text -notmatch $pattern) { throw "$ScriptPath has no `$script:PACKAGE_$field constant." }
    $value = $set[$field]
    $text = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + "'" + $value + "'" })
}

if ($text -ceq $before) {
    Write-Host "The pin is already $name ($version), sha256 $sha. Nothing changed."
    return [pscustomobject]@{ Changed = $false; Name = $name; Version = $version; Sha256 = $sha; Bytes = $bytes; SignatureCheck = $signatureChecked }
}

# What a guest installs changed, so the script's own version moves too.
$vm = [regex]::Match($text, "(?m)^\`$script:VERSION\s*=\s*'(\d+)\.(\d+)\.(\d+)'")
if (-not $vm.Success) { throw "$ScriptPath has no `$script:VERSION." }
$newScriptVersion = '{0}.{1}.{2}' -f $vm.Groups[1].Value, $vm.Groups[2].Value, ([int]$vm.Groups[3].Value + 1)
$text = $text.Remove($vm.Index, $vm.Length).Insert($vm.Index, "`$script:VERSION = '$newScriptVersion'")

[System.IO.File]::WriteAllText($ScriptPath, $text, [System.Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot 'Update-GuestManifest.ps1') -GuestRoot $GuestRoot | Out-Null

Write-Host "Pinned $name (version $version), sha256 $sha, $bytes bytes."
Write-Host "Install-ManaDriver.ps1 is now version $newScriptVersion, and the guest manifest is regenerated."
Write-Host 'Next: run the unit tests, and record the new version in the work item.'
[pscustomobject]@{ Changed = $true; Name = $name; Version = $version; Sha256 = $sha; Bytes = $bytes; ScriptVersion = $newScriptVersion; SignatureCheck = $signatureChecked }
