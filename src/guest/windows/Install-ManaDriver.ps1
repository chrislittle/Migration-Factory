<#
.SYNOPSIS
    Put the Microsoft Azure Network Adapter (MANA) driver in the Windows driver
    store before a move, when the store has none.
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand, under Windows PowerShell 5.1:
    no ternary, no ??, no pwsh-only API.

    MANA-WIN-1. V5-LAB-1 measured where Windows gets its MANA driver: the
    driver STORE, not Windows Update. Windows binds a staged driver when the
    hardware appears, so a machine with no mana*.sys before the move is normal -
    but a machine whose store holds no MANA package falls back to the slower
    synthetic adapter (NetVSC) on the new size, and the check after the move
    then puts it back.

    So, in order:
      1. Read the driver store, four ways, because a driver reported missing
         when it is there would install one over it: a store folder named for
         a mana INF; a store INF that names the MANA PCI device
         (VEN_1414&DEV_00BA - Microsoft's own check, from
         accelerated-networking-mana-windows.md) or the adapter's name;
         `pnputil /enum-drivers` - the way V5-LAB-1 measured it; and a bound
         adapter. Any one: NO_CHANGE. A driver already present is never
         replaced.
      2. No pinned sha256: NEEDS_PREP - the store has no MANA driver, and
         this version of the product has nothing it may install.
      3. Otherwise download the ONE pinned package from Microsoft, compare its
         sha256 with the pin, and refuse on any difference - nothing is
         installed from a file nobody reviewed.
      3a. MANA-SIG-1: check that Microsoft signed every driver file in it, and
         refuse the package, with nothing installed, when one is not:
           - every .cat: Get-AuthenticodeSignature says Valid (Windows built
             the chain to a trusted root and the content matches), AND the
             signer certificate's chain, built again with the certificates the
             signature carries, ends in one of Microsoft's own root
             certificates, pinned here by thumbprint. "Valid" alone trusts ANY
             root this machine trusts, an enterprise root included, and a
             certificate can put "Microsoft Corporation" in its subject, so
             neither the status nor the name is proof on its own.
           - every .inf and .sys: listed, by its hash, in one of those
             catalogs. That is how Windows itself signs a driver package. An
             INF has no signature of its own, and Get-AuthenticodeSignature
             reads only the catalogs INSTALLED on this machine (Microsoft's
             documentation: "the Windows catalog signature is used"), never
             one inside a package that is not installed yet - so the catalog
             is read here with the Windows catalog API (wintrust.dll).
           - a .sys that ALSO has a signature of its own must have Microsoft's.
         A signature that cannot be read is a refusal, never a pass.
         The package is downloaded into a folder that only SYSTEM and the
         Administrators group can use (not the access list of the temporary
         folder, where any user can create files), and pnputil runs only when
         the package still holds exactly the files the check read, with the
         same sha256.
      4. Add every INF in the package that names the MANA device or the
         adapter to the store with `pnputil /add-driver <inf>`. That STAGES
         the driver; Windows binds it when the hardware appears on the new
         size, as V5-LAB-1 saw it bind the in-box one.
      5. FIXED only when every add succeeded AND a read of the store finds
         the driver - the read-back, not pnputil's word alone.

    The pin lives in this file, so the guest manifest's sha256 of this file
    covers it, and tools/Update-GuestManifest.ps1 lists it in manifest.json as
    a package. A new driver is adopted on purpose with
    tools/Update-VmfManaDriverPin.ps1; the daily drift check says when
    Microsoft's download link moves (tools/Test-UpstreamDrift.ps1).

    Output contract: schemas/guest-output.schema.json.
      NO_CHANGE  - a MANA driver is in the store, or an adapter is bound.
      NEEDS_PREP - none is, and no package is pinned: nothing installed.
      FIXED      - the pinned package is in the store now.
      BLOCKED    - it could not be installed; `error` says why, and the check
                   'packages added' says how many INF files pnputil added.
    The checks are INFO facts. The engine decides what a result means.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:VERSION = '1.1.0'

# The pinned package. One version, chosen on purpose. An empty sha256 means
# nobody has pinned one yet, and the script then installs nothing.
$script:PACKAGE_NAME = 'mana_vf_drivers_2_0_18_52.zip'
$script:PACKAGE_VERSION = '2.0.18.52'
$script:PACKAGE_URL = 'https://download.microsoft.com/download/mana_vf_drivers_2_0_18_52.zip'
$script:PACKAGE_SHA256 = '9a9ef1466015649ae8c7dae94ed5602fc5b380f1d090139ea561106ad4baaaed'
$script:PACKAGE_BYTES = '3855798'

# The MANA PCI device, as Microsoft's own check names it, and the adapter's
# name, as Get-NetAdapter shows it (the Ethernet device the bus enumerates).
$script:MANA_DEVICE_ID = 'VEN_1414&DEV_00BA'
$script:MANA_ADAPTER_NAME = 'Microsoft Azure Network Adapter'

# MANA-SIG-1: Microsoft's root certificates for code and driver signing, by
# thumbprint (SHA-1 of the certificate, as Windows shows it in the Trusted
# Root store). A chain must END in one of these. Only these two: the 2010 root
# is the one Microsoft's driver signing (Hardware Compatibility Publisher, via
# the Third Party Component CA) and Windows' own signing chain to, and the
# 2011 root issues Microsoft's code signing CA. Other roots that Microsoft
# runs issue certificates to OTHER publishers (for example Microsoft Identity
# Verification Root 2020, used by Trusted Signing), so they are left out.
$script:MICROSOFT_ROOTS = @(
    '3B1EFD3A66EA28B16697394703A72CA340A05BD5', # Microsoft Root Certificate Authority 2010
    '8F43288AD272F3103B6FB1428485EA3014C0BCFE'  # Microsoft Root Certificate Authority 2011
)

# MANA-SIG-1: the Windows catalog API, from wintrust.dll. Add-Type compiles it
# with the .NET Framework compiler, which Windows PowerShell 5.1 uses. C# 5.
$script:CATALOG_SOURCE = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class VmfDriverCatalog {
    // CRYPTCAT_OPEN_EXISTING: open a catalog that is there, never make one.
    const uint OpenExisting = 0x00000004;

    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptCATAdminAcquireContext2(out IntPtr phCatAdmin, IntPtr pgSubsystem, string pwszHashAlgorithm, IntPtr pStrongHashPolicy, uint dwFlags);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATAdminReleaseContext(IntPtr hCatAdmin, uint dwFlags);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr hCatAdmin, IntPtr hFile, ref uint pcbHash, byte[] pbHash, uint dwFlags);
    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CryptCATOpen(string pwszFileName, uint fdwOpenFlags, IntPtr hProv, uint dwPublicVersion, uint dwEncodingType);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATClose(IntPtr hCatalog);
    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CryptCATGetMemberInfo(IntPtr hCatalog, string pwszReferenceTag);

    // The tag a catalog lists a file by: the hash Windows computes for it (for
    // a PE file, the Authenticode image hash), in upper-case hex.
    public static string Tag(string path, string algorithm) {
        IntPtr admin;
        if (!CryptCATAdminAcquireContext2(out admin, IntPtr.Zero, algorithm, IntPtr.Zero, 0)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                byte[] hash = new byte[64];
                uint size = (uint)hash.Length;
                if (!CryptCATAdminCalcHashFromFileHandle2(admin, file.SafeFileHandle.DangerousGetHandle(), ref size, hash, 0)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                StringBuilder tag = new StringBuilder();
                for (int i = 0; i < size; i++) { tag.Append(hash[i].ToString("X2")); }
                return tag.ToString();
            }
        }
        finally { CryptCATAdminReleaseContext(admin, 0); }
    }

    public static bool HasMember(string catalog, string tag) {
        IntPtr handle = CryptCATOpen(catalog, OpenExisting, IntPtr.Zero, 0, 0);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try { return CryptCATGetMemberInfo(handle, tag) != IntPtr.Zero; }
        finally { CryptCATClose(handle); }
    }
}
'@

$script:checks = [System.Collections.Generic.List[object]]::new()
$script:facts = [ordered]@{}

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

function Add-Fact {
    param([string]$Name, [string]$Value)
    $script:facts[$Name] = [string]$Value
}

function Get-DriverStoreRoot {
    # The driver store is exempt from the 32-bit file system redirector, so
    # System32 is right from either host.
    Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
}

function Test-InfNamesMana {
    param([string]$Path)
    # ReadAllText follows the byte order mark, and INF files are often UTF-16.
    $text = [System.IO.File]::ReadAllText($Path)
    return ($text.IndexOf($script:MANA_DEVICE_ID, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $text.IndexOf($script:MANA_ADAPTER_NAME, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-ManaStoreDrivers {
    <#
        The driver store folders that hold a MANA driver: named for a mana INF
        (the store names each folder after its INF), or with an INF that names
        the MANA device or the adapter. In-box and added packages both live
        here, so this answers for both.
    #>
    param([string]$Root = (Get-DriverStoreRoot))
    $found = @()
    if (-not (Test-Path -LiteralPath $Root)) { return $found }
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -like 'mana*.inf_*') { $found += $dir.Name; continue }
        foreach ($inf in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.inf' -File -ErrorAction SilentlyContinue)) {
            $names = $false
            try { $names = Test-InfNamesMana -Path $inf.FullName } catch { $names = $false }
            if ($names) { $found += $dir.Name; break }
        }
    }
    return $found
}

function Get-PnputilPath {
    $pnputil = Join-Path $env:SystemRoot 'Sysnative\pnputil.exe'
    if (-not (Test-Path -LiteralPath $pnputil)) { $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe' }
    return $pnputil
}

function Get-ManaPnputilDrivers {
    <#
        The way V5-LAB-1 measured the store: `pnputil /enum-drivers`, one
        block per published package, a block naming mana or the adapter.
    #>
    $ErrorActionPreference = 'Continue'
    $lines = @(& (Get-PnputilPath) /enum-drivers 2>$null)
    $found = @()
    $block = @()
    foreach ($line in ($lines + @(''))) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            $text = $block -join ' '
            if ($text -match '(?i)\bmana|Microsoft Azure Network Adapter') {
                $published = [regex]::Match($text, '(?i)(oem\d+\.inf)')
                if ($published.Success) { $found += $published.Groups[1].Value } else { $found += 'a package' }
            }
            $block = @()
        }
        else { $block += ([string]$line).Trim() }
    }
    return $found
}

function Get-ManaAdapterBound {
    $bound = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            [string]$_.InterfaceDescription -like '*Microsoft Azure Network Adapter*' })
    return ($bound.Count -gt 0)
}

function Get-PackageFile {
    param([string]$Url, [string]$Path)
    # Windows PowerShell 5.1 on an older image may not offer TLS 1.2 by
    # default, and Microsoft's download site requires it. WebClient uses the
    # proxy set for this account's internet settings (none, usually, for
    # SYSTEM) - NOT a `netsh winhttp` proxy. A machine that reaches the
    # internet only through one stops here, and the stop says what to do.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($Url, $Path) }
    finally { $client.Dispose() }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Expand-Package {
    param([string]$ZipPath, [string]$Destination)
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Get-DriverFileSignature {
    param([string]$Path)
    return (Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop)
}

function New-SignerChain {
    # The chain policy Get-SignerRoot builds with, in one place, so a test can
    # build a chain of its own with exactly this policy.
    param([string]$Path)
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]'IgnoreNotTimeValid, IgnoreCtlNotTimeValid, IgnoreNotTimeNested'
    if ($Path) {
        $carried = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        # A file that carries no certificate adds none; the build says the rest.
        try { $carried.Import($Path) } catch { $carried = $null }
        if ($carried) { $chain.ChainPolicy.ExtraStore.AddRange($carried) }
    }
    return , $chain
}

function Get-SignerRoot {
    <#
        MANA-SIG-1: the root a signer certificate chains to. The chain is built
        with the certificates the signed file carries (its intermediate CA),
        so it does not depend on what this machine has stored or can download.
        Time validity is not asked: Microsoft's driver signing certificates
        live about a year, and its signatures carry a time stamp, which is
        what Get-AuthenticodeSignature's Valid already proves. Revocation is
        not asked either: the sha256 pin already fixes the exact bytes, and a
        machine that cannot reach the revocation list must not fail for it.
    #>
    param([object]$Certificate, [string]$Path)
    $chain = New-SignerChain -Path $Path
    try {
        $built = $chain.Build($Certificate)
        $top = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        return @{
            Built       = [bool]$built
            Root        = ([string]$top.Thumbprint).ToUpperInvariant()
            RootSubject = [string]$top.Subject
            Status      = (@($chain.ChainStatus | ForEach-Object { [string]$_.Status }) -join ', ')
        }
    }
    finally { $chain.Reset() }
}

function Test-MicrosoftRoot {
    # A chain that BUILDS (every signature in it checks out, to a trusted root)
    # and ends in a pinned Microsoft root. The name on the certificate is
    # never asked: a forged issuer can end its chain at the real Microsoft
    # root by name and fail only the build.
    param([object]$Certificate, [string]$Path)
    if (-not $Certificate) { return $false }
    $root = Get-SignerRoot -Certificate $Certificate -Path $Path
    return ($root.Built -and ($script:MICROSOFT_ROOTS -contains $root.Root))
}

function Test-SignatureFromMicrosoft {
    # $null when the signature is Microsoft's; otherwise why not, in words.
    param([object]$Signature, [string]$Path)
    if (-not $Signature) { return 'no signature was read' }
    if ([string]$Signature.Status -ne 'Valid') {
        return ('its signature status is {0} ({1})' -f $Signature.Status, (Get-ShortText ([string]$Signature.StatusMessage) 80))
    }
    if (-not (Test-MicrosoftRoot -Certificate $Signature.SignerCertificate -Path $Path)) {
        $subject = ''
        if ($Signature.SignerCertificate) { $subject = [string]$Signature.SignerCertificate.Subject }
        return ('it is signed by {0}, and that certificate does not chain to a Microsoft root certificate' -f (Get-ShortText $subject 100))
    }
    return $null
}

function Test-CatalogMember {
    param([string]$CatalogPath, [string]$FilePath)
    if (-not ('VmfDriverCatalog' -as [type])) { Add-Type -TypeDefinition $script:CATALOG_SOURCE -Language CSharp }
    $api = 'VmfDriverCatalog' -as [type]
    # A catalog lists its files by SHA256 or, in an older one, by SHA1.
    foreach ($algorithm in @('SHA256', 'SHA1')) {
        if ($api::HasMember($CatalogPath, $api::Tag($FilePath, $algorithm))) { return $true }
    }
    return $false
}

function Get-PackageFileSet {
    # Every file of the package, by full path, with its sha256.
    param([string]$Folder)
    $set = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -Recurse -Force -ErrorAction Stop)) {
        $set[$file.FullName] = Get-Sha256 -Path $file.FullName
    }
    return $set
}

function Test-PackageUnchanged {
    <#
        MANA-SIG-1 (security review): the install uses only the files the
        signature check read. A file added, removed or changed since the check
        refuses the install. $null when nothing changed; otherwise why, in
        words.
    #>
    param([string]$Folder, [hashtable]$Checked)
    $root = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    $now = Get-PackageFileSet -Folder $root
    foreach ($path in @($now.Keys | Sort-Object)) {
        $name = $path.Substring($root.Length).TrimStart('\', '/')
        if (-not $Checked.ContainsKey($path)) { return ('the file {0} was added after the signature check' -f $name) }
        if ($Checked[$path] -ne $now[$path]) { return ('the file {0} changed after the signature check' -f $name) }
    }
    foreach ($path in @($Checked.Keys | Sort-Object)) {
        if (-not $now.ContainsKey($path)) { return ('the file {0} was removed after the signature check' -f $path.Substring($root.Length).TrimStart('\', '/')) }
    }
    return $null
}

function New-PrivateWorkFolder {
    <#
        MANA-SIG-1 (security review): the folder the package is downloaded to
        and unpacked in. Under SYSTEM the temporary folder is C:\Windows\Temp,
        where any user can create files; this folder does not inherit that
        access list. Only SYSTEM, the Administrators group and the account
        that runs the script (SYSTEM, under Run Command) can use it.
    #>
    param([string]$Path)
    # A folder made with an access list of its own takes NO inherited entries
    # and is marked protected (measured under Windows PowerShell 5.1, with a
    # parent that passes BUILTIN\Users down, whatever SetAccessRuleProtection
    # says), so this list is the whole list. The unit test proves it.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $owners = @(
        (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'),
        (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'),
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    )
    foreach ($sid in $owners) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'
        $acl.AddAccessRule($rule)
    }
    if (Test-Path -LiteralPath $Path) { throw "The work folder $Path is already there." }
    [void][System.IO.Directory]::CreateDirectory($Path, $acl)
    return $Path
}

function Test-DriverPackageSignatures {
    <#
        MANA-SIG-1: every .cat, .sys and .inf in the package, as step 3a of the
        description says. Returns @{ Problem = $null or the refusal; Checked;
        Files = every file of the package and its sha256, read BEFORE the
        check, for Test-PackageUnchanged }.
    #>
    param([string]$Folder)
    $root = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    $files = Get-PackageFileSet -Folder $root
    $relative = { param([string]$Full) $Full.Substring($root.Length).TrimStart('\', '/') }
    $refuse = { param([string]$Full, [string]$Why)
        'The driver file {0} in the pinned package does not have a valid signature from Microsoft: {1}. Nothing was installed.' -f (& $relative $Full), $Why }
    $all = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction Stop)
    $cats = @($all | Where-Object { $_.Extension -eq '.cat' })
    $sys = @($all | Where-Object { $_.Extension -eq '.sys' })
    $infs = @($all | Where-Object { $_.Extension -eq '.inf' })
    $checked = '{0} catalog, {1} .sys and {2} .inf files' -f $cats.Count, $sys.Count, $infs.Count
    if ($cats.Count -eq 0) {
        return @{ Checked = $checked; Problem = 'The pinned package holds no catalog (.cat) file, so no driver file in it can be checked for a signature from Microsoft. Nothing was installed.' }
    }

    foreach ($cat in $cats) {
        try { $sig = Get-DriverFileSignature -Path $cat.FullName }
        catch { return @{ Checked = $checked; Problem = (& $refuse $cat.FullName ('its signature could not be read: ' + (Get-ShortText $_.Exception.Message 80))) } }
        $why = Test-SignatureFromMicrosoft -Signature $sig -Path $cat.FullName
        if ($why) { return @{ Checked = $checked; Problem = (& $refuse $cat.FullName $why) } }
    }

    foreach ($file in @($sys + $infs)) {
        if ($file.Extension -eq '.sys') {
            try { $sig = Get-DriverFileSignature -Path $file.FullName }
            catch { return @{ Checked = $checked; Problem = (& $refuse $file.FullName ('its signature could not be read: ' + (Get-ShortText $_.Exception.Message 80))) } }
            # NotSigned: no signature of its own; the catalog signs it.
            if (-not $sig -or [string]$sig.Status -ne 'NotSigned') {
                $why = Test-SignatureFromMicrosoft -Signature $sig -Path $file.FullName
                if ($why) { return @{ Checked = $checked; Problem = (& $refuse $file.FullName $why) } }
            }
        }
        $listed = $false
        foreach ($cat in $cats) {
            try { $listed = Test-CatalogMember -CatalogPath $cat.FullName -FilePath $file.FullName }
            catch { return @{ Checked = $checked; Problem = (& $refuse $file.FullName ('the catalog file {0} could not be read: {1}' -f (& $relative $cat.FullName), (Get-ShortText $_.Exception.Message 80))) } }
            if ($listed) { break }
        }
        if (-not $listed) { return @{ Checked = $checked; Problem = (& $refuse $file.FullName 'no catalog file in the package that Microsoft signed lists it') } }
    }
    return @{ Checked = $checked; Problem = $null; Files = $files }
}

function Find-ManaInfs {
    param([string]$Folder)
    $infs = @()
    foreach ($inf in @(Get-ChildItem -LiteralPath $Folder -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue)) {
        if (Test-InfNamesMana -Path $inf.FullName) { $infs += $inf.FullName }
    }
    return $infs
}

function Add-StoreDriver {
    param([string]$InfPath)
    # Windows PowerShell 5.1 turns a line on a native command's error stream
    # into a TERMINATING error when the preference is Stop, which would skip
    # the read-back. pnputil's own exit code says how it went.
    $ErrorActionPreference = 'Continue'
    $output = (& (Get-PnputilPath) /add-driver $InfPath 2>&1 | Out-String).Trim()
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Test-AddSucceeded {
    # 0 = added; 3010 = added, and Windows wants a restart to use it.
    param([object]$ExitCode)
    return ([string]$ExitCode -in @('0', '3010'))
}

function Get-ShortText {
    <#
        RunCommand returns only the LAST 4096 bytes of a script's output, so a
        long check would cut off the start of the one JSON object and the
        engine would read nothing. Every free text in a check is kept short.
    #>
    param([string]$Text, [int]$Max = 160)
    $flat = ([string]$Text -replace '\s+', ' ').Trim()
    if ($flat.Length -le $Max) { return $flat }
    return '...' + $flat.Substring($flat.Length - $Max)
}

function Get-ShortList {
    param([object[]]$Items, [int]$Max = 3)
    $all = @($Items | Where-Object { $_ })
    if ($all.Count -eq 0) { return 'none' }
    if ($all.Count -le $Max) { return ($all -join ', ') }
    return ('{0} and {1} more' -f (($all | Select-Object -First $Max) -join ', '), ($all.Count - $Max))
}

function Get-Blocked {
    param([string]$Message)
    return @{ Result = 'BLOCKED'; Error = $Message }
}

function Invoke-ManaDriverInstall {
    $before = @(Get-ManaStoreDrivers)
    $listed = @(Get-ManaPnputilDrivers)
    $bound = Get-ManaAdapterBound
    Add-Check 'mana driver in store' 'INFO' (Get-ShortList $before)
    Add-Check 'mana driver in pnputil' 'INFO' (Get-ShortList $listed)
    Add-Check 'mana adapter bound' 'INFO' ([string]$bound)
    if ($before.Count -gt 0 -or $listed.Count -gt 0 -or $bound) {
        return @{ Result = 'NO_CHANGE' }
    }

    if ($script:PACKAGE_SHA256 -notmatch '^[0-9a-f]{64}$') {
        Add-Check 'pinned package' 'INFO' ('{0} version {1}, no sha256 pinned' -f $script:PACKAGE_NAME, $script:PACKAGE_VERSION)
        return @{ Result = 'NEEDS_PREP' }
    }
    Add-Check 'pinned package' 'INFO' ('{0} version {1}' -f $script:PACKAGE_NAME, $script:PACKAGE_VERSION)

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-mana-' + [guid]::NewGuid().ToString('N'))
    New-PrivateWorkFolder -Path $work | Out-Null
    try {
        $zip = Join-Path $work $script:PACKAGE_NAME
        try { Get-PackageFile -Url $script:PACKAGE_URL -Path $zip }
        catch {
            return Get-Blocked ('The download from {0} failed: {1}. Nothing was installed.' -f $script:PACKAGE_URL, $_.Exception.Message)
        }
        $sha = Get-Sha256 -Path $zip
        Add-Check 'downloaded sha256' 'INFO' $sha
        if ($sha -ne $script:PACKAGE_SHA256) {
            return Get-Blocked ('The downloaded package does not match the pin: sha256 {0}, pinned {1}. Nothing was installed.' -f $sha, $script:PACKAGE_SHA256)
        }

        $folder = Join-Path $work 'package'
        Expand-Package -ZipPath $zip -Destination $folder
        # MANA-SIG-1: before anything is added. A refusal here is the same
        # BLOCKED, with nothing installed, as a sha256 that does not match.
        try { $signatures = Test-DriverPackageSignatures -Folder $folder }
        catch { $signatures = @{ Checked = ''; Problem = ('The signatures of the pinned package could not be checked: {0}. Nothing was installed.' -f $_.Exception.Message) } }
        if ($signatures.Problem) {
            Add-Check 'driver signatures' 'INFO' ('refused: ' + (Get-ShortText $signatures.Problem))
            return Get-Blocked $signatures.Problem
        }
        Add-Check 'driver signatures' 'INFO' ('Microsoft: ' + $signatures.Checked)
        $infs = @(Find-ManaInfs -Folder $folder)
        Add-Check 'package INF files' 'INFO' ([string]$infs.Count)
        if ($infs.Count -eq 0) {
            return Get-Blocked 'The pinned package holds no INF file that names the MANA device. Nothing was installed.'
        }
        # The install uses only the files the signature check read.
        $changed = Test-PackageUnchanged -Folder $folder -Checked $signatures.Files
        if ($changed) {
            return Get-Blocked ('The pinned package changed after its signature check: {0}. Nothing was installed.' -f $changed)
        }
        $exitCodes = @()
        $lastOutput = ''
        $addedCount = 0
        foreach ($inf in $infs) {
            $added = Add-StoreDriver -InfPath $inf
            $exitCodes += [string]$added.ExitCode
            if (Test-AddSucceeded $added.ExitCode) { $addedCount++ } else { $lastOutput = [string]$added.Output }
            if (-not $lastOutput) { $lastOutput = [string]$added.Output }
        }
        # One check for every INF together, so a package with many cannot push
        # the start of the result past what RunCommand returns.
        Add-Check 'pnputil' 'INFO' ('exit codes {0}; output: {1}' -f ($exitCodes -join ', '), (Get-ShortText $lastOutput))
        # The engine reads this to say whether the machine was changed.
        Add-Check 'packages added' 'INFO' ([string]$addedCount)
        if ($addedCount -lt $infs.Count) {
            return Get-Blocked ('pnputil added {0} of {1} INF files from the pinned package. Read the pnputil check for the reason.' -f $addedCount, $infs.Count)
        }

        $after = @(@(Get-ManaStoreDrivers) + @(Get-ManaPnputilDrivers))
        if ($after.Count -eq 0) {
            return Get-Blocked 'pnputil reported success, and the driver store still has no MANA driver.'
        }
        Add-Check 'mana driver in store after' 'INFO' (Get-ShortList $after)
        return @{ Result = 'FIXED' }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-Result {
    param([hashtable]$Outcome, [string]$OsCaption = '')
    $doc = [ordered]@{
        schema = 'vmf.guest/2'; script = 'Install-ManaDriver.ps1'; version = $script:VERSION
        os = $OsCaption; result = [string]$Outcome.Result; checks = @($script:checks); facts = $script:facts; warnings = @()
    }
    if ($Outcome.Error) {
        # The start of an error says what failed; keep it, and keep it short.
        $message = ([string]$Outcome.Error -replace '\s+', ' ').Trim()
        if ($message.Length -gt 600) { $message = $message.Substring(0, 600) + '...' }
        $doc.error = $message
    }
    $doc | ConvertTo-Json -Depth 6 -Compress
}

$osCaption = ''
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $osCaption = '{0} ({1})' -f $os.Caption, $os.Version
    Add-Fact 'os' 'Windows'
    Add-Fact 'osVersion' ([string]$os.Version)
    Write-Result -Outcome (Invoke-ManaDriverInstall) -OsCaption $osCaption
}
catch {
    Write-Result -Outcome (Get-Blocked $_.Exception.Message) -OsCaption $osCaption
}
exit 0
