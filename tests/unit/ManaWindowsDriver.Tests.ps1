#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANA-WIN-1: a Windows machine whose move can land it on MANA hardware gets
# the MANA driver put in its driver store BEFORE the move, when the store has
# none. A driver already present is never replaced (decided 2026-10-04).
#
# Why: V5-LAB-1 measured that Windows takes its MANA driver from the driver
# STORE, not from Windows Update. A machine with no store package falls back to
# the synthetic adapter on the new size, and the check after the move then puts
# it back - caught, but at the end instead of the start.
#
# Three halves:
#   1. the guest script, RUN under Windows PowerShell 5.1 (the interpreter
#      RunCommand uses) with only the parts that touch the outside world
#      replaced: the store, the adapter, the download and pnputil. The sha256
#      check, the unzip and the INF search are the real functions;
#   2. the pin, as the manifest and the script both say it;
#   3. the engine step that decides whether to run it, and what a result means.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:scriptPath = Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Install-ManaDriver.ps1'
    $script:schemaPath = Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json'
    $script:work = New-VmfTestTemp -Prefix 'mwin'

    # Windows PowerShell 5.1 when it is here (CI's Windows runner has it), so
    # a pwsh-only construct fails the test the way it would fail in a guest.
    $winPs = Get-Command powershell.exe -ErrorAction SilentlyContinue
    $script:shell = if ($winPs) { $winPs.Source } else { (Get-Process -Id $PID).Path }

    # The script's own constants and functions, without its main block.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$null)
    $script:lifted = (@($ast.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                ($_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -like '$script:*')
            }) | ForEach-Object { $_.Extent.Text }) -join "`r`n"

    # A package shaped like Microsoft's: an INF that names the MANA device, in
    # UTF-16 as INF files often are, beside one that does not.
    $pkgDir = Join-Path $script:work 'pkg-src'
    New-Item -ItemType Directory -Path (Join-Path $pkgDir 'x64') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $pkgDir 'x64' 'mana.inf'),
        "[Manufacturer]`r`n%MSFT%=MANA,NTamd64`r`n[MANA.NTamd64]`r`n%MANA.DeviceDesc%=MANA_Inst, PCI\VEN_1414&DEV_00BA`r`n",
        [System.Text.UnicodeEncoding]::new($false, $true))
    [System.IO.File]::WriteAllText((Join-Path $pkgDir 'x64' 'other.inf'), "[Version]`r`nClass=System`r`n")
    [System.IO.File]::WriteAllText((Join-Path $pkgDir 'x64' 'mana.sys'), 'a driver binary, for the test')
    [System.IO.File]::WriteAllText((Join-Path $pkgDir 'readme.txt'), 'test package')

    # MANA-SIG-1: every package carries a catalog that lists its files by
    # hash, as Microsoft's does. New-FileCatalog writes a real catalog, so the
    # script's catalog read (the Windows catalog API) runs for real; only the
    # Authenticode read of the catalog's signature is replaced in the harness.
    function script:Add-MwinCatalog([string]$Dir, [string]$Into) {
        $cat = Join-Path $script:work ('cat-{0}.cat' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-FileCatalog -Path $Dir -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
        Move-Item -LiteralPath $cat -Destination (Join-Path $Dir $Into)
    }
    function script:New-MwinZip([string]$Dir, [string]$Name) {
        $zipPath = Join-Path $script:work $Name
        Compress-Archive -Path (Join-Path $Dir '*') -DestinationPath $zipPath
        return @{ Zip = $zipPath; Sha = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    # A copy of the signed package, changed by $Change AFTER its catalog was
    # written - the way a file is changed after Microsoft signed it.
    function script:New-MwinChangedZip([string]$Name, [scriptblock]$Change) {
        $dir = Join-Path $script:work ('pkg-' + [IO.Path]::GetFileNameWithoutExtension($Name))
        Copy-Item -LiteralPath $script:pkgDir -Destination $dir -Recurse
        & $Change $dir
        return New-MwinZip $dir $Name
    }
    $script:pkgDir = $pkgDir
    $noCat = New-MwinChangedZip 'no_catalog.zip' { param($d) }
    $script:zipNoCat = $noCat.Zip; $script:zipNoCatSha = $noCat.Sha
    Add-MwinCatalog $pkgDir 'x64\mana.cat'
    $signed = New-MwinZip $pkgDir 'mana_vf_drivers_test.zip'
    $script:zip = $signed.Zip; $script:zipSha = $signed.Sha
    $badInf = New-MwinChangedZip 'changed_inf.zip' { param($d) [System.IO.File]::AppendAllText((Join-Path $d 'x64' 'mana.inf'), "; changed`r`n", [System.Text.UnicodeEncoding]::new($false, $false)) }
    $script:zipBadInf = $badInf.Zip; $script:zipBadInfSha = $badInf.Sha
    $badSys = New-MwinChangedZip 'changed_sys.zip' { param($d) [System.IO.File]::AppendAllText((Join-Path $d 'x64' 'mana.sys'), 'changed') }
    $script:zipBadSys = $badSys.Zip; $script:zipBadSysSha = $badSys.Sha
    $badCat = New-MwinChangedZip 'broken_catalog.zip' { param($d) [System.IO.File]::WriteAllText((Join-Path $d 'x64' 'mana.cat'), 'not a catalog') }
    $script:zipBadCat = $badCat.Zip; $script:zipBadCatSha = $badCat.Sha

    $emptyDir = Join-Path $script:work 'pkg-empty'
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $emptyDir 'other.inf'), "[Version]`r`nClass=System`r`n")
    Add-MwinCatalog $emptyDir 'other.cat'
    $noMana = New-MwinZip $emptyDir 'no_mana.zip'
    $script:zipNoMana = $noMana.Zip; $script:zipNoManaSha = $noMana.Sha

    # A package with many MANA INF files, as one built for several Windows
    # versions might be - to prove the result still fits what RunCommand returns.
    $manyDir = Join-Path $script:work 'pkg-many'
    foreach ($n in 1..8) {
        New-Item -ItemType Directory -Path (Join-Path $manyDir "os$n") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $manyDir "os$n" 'mana.inf'), "%D%=I, PCI\VEN_1414&DEV_00BA&REV_0$n`r`n")
    }
    Add-MwinCatalog $manyDir 'mana.cat'
    $many = New-MwinZip $manyDir 'many.zip'
    $script:zipMany = $many.Zip; $script:zipManySha = $many.Sha

    $harness = @'
param([string]$ScenarioPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
__LIFTED__
$s = Get-Content -LiteralPath $ScenarioPath -Raw | ConvertFrom-Json
if (-not $s.keepPin) { $script:PACKAGE_SHA256 = [string]$s.pin }
$global:mwinInstalled = $false
$global:mwinCalls = @()
$global:mwinDownloads = 0
function Get-ManaStoreDrivers { if ($s.storeBefore -or $global:mwinInstalled) { return @('mana.inf_amd64_test') }; return @() }
function Get-ManaPnputilDrivers { if ($s.pnputilListed) { return @('oem7.inf') }; return @() }
function Get-ManaAdapterBound { return [bool]$s.bound }
function Get-PackageFile {
    param([string]$Url, [string]$Path)
    $global:mwinDownloads++
    if ($s.downloadFails) { throw 'The remote name could not be resolved' }
    Copy-Item -LiteralPath $s.zip -Destination $Path
}
# MANA-SIG-1: the Authenticode read and the chain build are replaced; the
# decision on them (Test-SignatureFromMicrosoft, Test-MicrosoftRoot) and the
# catalog read are the real functions. Unnamed files: a catalog signed by
# Microsoft, a .sys with no signature of its own (signed through the catalog).
$global:mwinSigReads = @()
function Get-DriverFileSignature {
    param([string]$Path)
    $leaf = Split-Path -Leaf $Path
    $global:mwinSigReads += $leaf
    $kind = ''
    if ($s.sig -and $s.sig.PSObject.Properties[$leaf]) { $kind = [string]$s.sig.$leaf }
    if (-not $kind) { if ($leaf -like '*.cat') { $kind = 'microsoft' } else { $kind = 'unsigned' } }
    $ms = [pscustomobject]@{ Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation'; Marker = 'ms' }
    switch ($kind) {
        'microsoft' { return [pscustomobject]@{ Status = 'Valid'; StatusMessage = 'Signature verified.'; SignerCertificate = $ms } }
        'other' { return [pscustomobject]@{ Status = 'Valid'; StatusMessage = 'Signature verified.'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso Drivers, O=Contoso'; Marker = 'other' } } }
        'spoof' { return [pscustomobject]@{ Status = 'Valid'; StatusMessage = 'Signature verified.'; SignerCertificate = [pscustomobject]@{ Subject = $ms.Subject; Marker = 'spoof' } } }
        'fakeissuer' { return [pscustomobject]@{ Status = 'Valid'; StatusMessage = 'Signature verified.'; SignerCertificate = [pscustomobject]@{ Subject = $ms.Subject; Marker = 'fakeissuer' } } }
        'untrusted' { return [pscustomobject]@{ Status = 'UnknownError'; StatusMessage = 'A certificate chain processed, but terminated in a root certificate which is not trusted by the trust provider.'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso Drivers, O=Contoso'; Marker = 'other' } } }
        'mismatch' { return [pscustomobject]@{ Status = 'HashMismatch'; StatusMessage = 'The contents of file might have been changed.'; SignerCertificate = $ms } }
        'unsigned' { return [pscustomobject]@{ Status = 'NotSigned'; StatusMessage = 'The file is not digitally signed.'; SignerCertificate = $null } }
        'unreadable' { throw 'The process cannot access the file because it is being used by another process.' }
    }
}
function Get-SignerRoot {
    param([object]$Certificate, [string]$Path)
    # What X509Chain.Build answers for each kind of signer certificate.
    switch ([string]$Certificate.Marker) {
        'ms' { return @{ Built = $true; Root = '3B1EFD3A66EA28B16697394703A72CA340A05BD5'; RootSubject = 'CN=Microsoft Root Certificate Authority 2010'; Status = '' } }
        'fakeissuer' { return @{ Built = $false; Root = '3B1EFD3A66EA28B16697394703A72CA340A05BD5'; RootSubject = 'CN=Microsoft Root Certificate Authority 2010'; Status = 'NotSignatureValid' } }
        default { return @{ Built = $true; Root = 'D4DE20D05E66FC53FE1A50882C78DB2852CAE474'; RootSubject = 'CN=Contoso Root'; Status = '' } }
    }
}
function Add-StoreDriver {
    param([string]$InfPath)
    $global:mwinCalls += $InfPath
    if ($s.failAt -and $global:mwinCalls.Count -eq [int]$s.failAt) { return @{ ExitCode = 1; Output = 'Failed to add driver package: The hash for the file is not present in the specified catalog file.' } }
    if ($s.pnputilWorks) { $global:mwinInstalled = $true }
    if ($s.longOutput) { return @{ ExitCode = 0; Output = ('Adding driver package. Driver package added successfully. Published Name: oem12.inf. ' * 40) } }
    return @{ ExitCode = 0; Output = 'Driver package added successfully.' }
}
# MANA-SIG-1 (security review): a file added, changed or removed in the
# package AFTER the real signature check, before pnputil.
$global:mwinRealCheck = ${function:Test-DriverPackageSignatures}
function Test-DriverPackageSignatures {
    param([string]$Folder)
    $checked = & $global:mwinRealCheck -Folder $Folder
    switch ([string]$s.afterCheck) {
        'add' { [System.IO.File]::WriteAllText((Join-Path $Folder 'x64\extra.inf'), "%D%=I, PCI\VEN_1414&DEV_00BA`r`n") }
        'addOther' { [System.IO.File]::WriteAllText((Join-Path $Folder 'x64\helper.dll'), 'not checked') }
        'change' { [System.IO.File]::AppendAllText((Join-Path $Folder 'x64\other.inf'), "; changed`r`n") }
        'remove' { [System.IO.File]::Delete((Join-Path $Folder 'readme.txt')) }
    }
    return $checked
}
$outcome = Invoke-ManaDriverInstall
$json = Write-Result -Outcome $outcome -OsCaption 'Windows Server (test)'
[pscustomobject]@{ json = $json; calls = @($global:mwinCalls); downloads = $global:mwinDownloads; sigReads = @($global:mwinSigReads) } | ConvertTo-Json -Depth 4 -Compress
'@
    $script:harnessPath = Join-Path $script:work 'harness.ps1'
    [System.IO.File]::WriteAllText($script:harnessPath, $harness.Replace('__LIFTED__', $script:lifted), [System.Text.UTF8Encoding]::new($true))

    # MANA-SIG-1: the script's real functions, NOTHING replaced, run under
    # Windows PowerShell on code a test passes in. $v holds the test's values.
    $codeHarness = @'
param([string]$CodePath, [string]$VarsPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
__LIFTED__
$v = [System.IO.File]::ReadAllText($VarsPath) | ConvertFrom-Json
$out = & ([scriptblock]::Create([System.IO.File]::ReadAllText($CodePath)))
ConvertTo-Json -InputObject $out -Depth 5 -Compress
'@
    $script:codeHarnessPath = Join-Path $script:work 'code-harness.ps1'
    [System.IO.File]::WriteAllText($script:codeHarnessPath, $codeHarness.Replace('__LIFTED__', $script:lifted), [System.Text.UTF8Encoding]::new($true))
    function script:Invoke-MwinCode {
        param([string]$Code, [hashtable]$Vars = @{})
        $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $codePath = Join-Path $script:work "code-$id.ps1"
        $varsPath = Join-Path $script:work "vars-$id.json"
        [System.IO.File]::WriteAllText($codePath, $Code, [System.Text.UTF8Encoding]::new($true))
        [System.IO.File]::WriteAllText($varsPath, ($Vars | ConvertTo-Json -Depth 5))
        $raw = & $script:shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:codeHarnessPath -CodePath $codePath -VarsPath $varsPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "code harness failed: $($raw -join ' ')" }
        return (($raw | Select-Object -Last 1) | ConvertFrom-Json)
    }

    $storeHarness = @'
param([string]$Root)
$ErrorActionPreference = 'Stop'
__LIFTED__
ConvertTo-Json -InputObject @(Get-ManaStoreDrivers -Root $Root) -Compress
'@
    $script:storeHarnessPath = Join-Path $script:work 'store-harness.ps1'
    [System.IO.File]::WriteAllText($script:storeHarnessPath, $storeHarness.Replace('__LIFTED__', $script:lifted), [System.Text.UTF8Encoding]::new($true))

    function script:Invoke-MwinScenario {
        param([hashtable]$Scenario)
        $scenarioPath = Join-Path $script:work ('scenario-{0}.json' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Scenario | ConvertTo-Json | Set-Content -LiteralPath $scenarioPath -Encoding utf8
        $raw = & $script:shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:harnessPath -ScenarioPath $scenarioPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "harness failed: $($raw -join ' ')" }
        $run = ($raw | Select-Object -Last 1) | ConvertFrom-Json
        $doc = ConvertFrom-VmfGuestOutput -RawOutput ([string]$run.json)
        [pscustomobject]@{ Doc = $doc; Json = [string]$run.json; Calls = @($run.calls | Where-Object { $_ }); Downloads = [int]$run.downloads; SigReads = @($run.sigReads | Where-Object { $_ }) }
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\MwinPlan', 'function:\MwinNics', 'function:\MwinOut' -ErrorAction SilentlyContinue
}

Describe 'MANA-WIN-1: the guest script, run under Windows PowerShell' {
    It 'a MANA driver in the store: NO_CHANGE - nothing downloaded, nothing installed' {
        $r = Invoke-MwinScenario @{ storeBefore = $true; bound = $false; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'NO_CHANGE'
        $r.Downloads | Should -Be 0
        $r.Calls.Count | Should -Be 0
        (@($r.Doc.checks) | Where-Object name -eq 'mana driver in store').detail | Should -Be 'mana.inf_amd64_test'
    }

    It 'a bound MANA adapter: NO_CHANGE - a working driver is never replaced' {
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $true; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'NO_CHANGE'
        $r.Downloads | Should -Be 0
        $r.Calls.Count | Should -Be 0
    }

    It 'none in the store: downloads, checks the sha256, adds ONLY the MANA INF, reads the store again - FIXED' {
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'FIXED'
        $r.Downloads | Should -Be 1
        $r.Calls.Count | Should -Be 1
        $r.Calls[0] | Should -Match 'x64[\\/]mana\.inf$'
        (@($r.Doc.checks) | Where-Object name -eq 'downloaded sha256').detail | Should -Be $script:zipSha
        (@($r.Doc.checks) | Where-Object name -eq 'mana driver in store after').detail | Should -Be 'mana.inf_amd64_test'
    }

    It 'a sha256 that does not match the pin: BLOCKED, and pnputil never runs' {
        $wrong = 'a' * 64
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = $wrong; zip = $script:zip; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'BLOCKED'
        $r.Doc.error | Should -Match 'does not match the pin'
        $r.Doc.error | Should -Match $script:zipSha
        $r.Doc.error | Should -Match 'Nothing was installed'
        $r.Calls.Count | Should -Be 0
    }

    It 'listed by pnputil /enum-drivers only (how V5-LAB-1 measured it): NO_CHANGE' {
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pnputilListed = $true; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'NO_CHANGE'
        $r.Downloads | Should -Be 0
        (@($r.Doc.checks) | Where-Object name -eq 'mana driver in pnputil').detail | Should -Be 'oem7.inf'
    }

    It 'THE SHIPPED PIN: a store with the driver is left alone' {
        $r = Invoke-MwinScenario @{ keepPin = $true; storeBefore = $true; bound = $false; zip = $script:zip; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'NO_CHANGE'
        $r.Downloads | Should -Be 0
    }

    It 'THE SHIPPED PIN: a store without it downloads, and a file that is not the pinned one is refused - never NEEDS_PREP' {
        $realPin = [regex]::Match((Get-Content $script:scriptPath -Raw), "(?m)^\`$script:PACKAGE_SHA256\s*=\s*'([^']*)'").Groups[1].Value
        $r = Invoke-MwinScenario @{ keepPin = $true; storeBefore = $false; bound = $false; zip = $script:zip; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'BLOCKED'
        $r.Downloads | Should -Be 1
        $r.Doc.error | Should -Match "pinned $realPin"
        $r.Calls.Count | Should -Be 0
    }

    It 'an unpinned copy of the script: NEEDS_PREP - nothing downloaded, nothing installed' {
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = ''; zip = $script:zip; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'NEEDS_PREP'
        (@($r.Doc.checks) | Where-Object name -eq 'pinned package').detail | Should -Match 'no sha256 pinned'
        $r.Downloads | Should -Be 0
        $r.Calls.Count | Should -Be 0
    }

    It 'pnputil refuses one INF of eight: BLOCKED, and it says how many were added' {
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = $script:zipManySha; zip = $script:zipMany; pnputilWorks = $true; failAt = 3 }
        $r.Doc.result | Should -Be 'BLOCKED'
        $r.Doc.error | Should -Match 'added 7 of 8'
        (@($r.Doc.checks) | Where-Object name -eq 'packages added').detail | Should -Be '7'
        (@($r.Doc.checks) | Where-Object name -eq 'pnputil').detail | Should -Match 'not present in the specified catalog'
    }

    It 'a download that fails (no internet): BLOCKED, says where it tried, nothing installed' {
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $true; downloadFails = $true }
        $r.Doc.result | Should -Be 'BLOCKED'
        $r.Doc.error | Should -Match 'download\.microsoft\.com'
        $r.Doc.error | Should -Match 'could not be resolved'
        $r.Calls.Count | Should -Be 0
    }

    It 'pnputil ran and the store still has none: BLOCKED - the read-back is the proof, not the exit code' {
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $false }
        $r.Doc.result | Should -Be 'BLOCKED'
        $r.Doc.error | Should -Match 'reported success, and the driver store still has no MANA driver'
        $r.Calls.Count | Should -Be 1
    }

    It 'a package with no INF that names the MANA device: BLOCKED, nothing added' {
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = $script:zipNoManaSha; zip = $script:zipNoMana; pnputilWorks = $true }
        $r.Doc.result | Should -Be 'BLOCKED'
        $r.Doc.error | Should -Match 'no INF file'
        $r.Calls.Count | Should -Be 0
    }

    It 'every result is one object the guest contract accepts' {
        foreach ($sc in @(
                @{ storeBefore = $true; bound = $false; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $true },
                @{ storeBefore = $false; bound = $false; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $true },
                @{ storeBefore = $false; bound = $false; pin = ''; zip = $script:zip; pnputilWorks = $true })) {
            $r = Invoke-MwinScenario $sc
            { Test-Json -Json $r.Json -SchemaFile $script:schemaPath -ErrorAction Stop } | Should -Not -Throw
            $r.Doc.script | Should -Be 'Install-ManaDriver.ps1'
        }
    }

    It 'the whole result fits in what RunCommand returns, even for a package of many INF files with long pnputil output' {
        # RunCommand returns only the LAST 4096 bytes of output. A longer
        # result loses its start, and the engine then reads no answer at all.
        $r = Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = $script:zipManySha; zip = $script:zipMany; pnputilWorks = $true; longOutput = $true }
        $r.Doc.result | Should -Be 'FIXED'
        $r.Calls.Count | Should -Be 8
        [System.Text.Encoding]::UTF8.GetByteCount($r.Json) | Should -BeLessThan 3000
        (@($r.Doc.checks) | Where-Object name -eq 'pnputil').detail | Should -Match '^exit codes 0, 0, 0, 0, 0, 0, 0, 0; output: \.\.\.'
    }

    It 'reads the store the way Windows keeps it: a UTF-16 INF naming the device counts, others do not' {
        $root = Join-Path $script:work 'FileRepository'
        foreach ($d in 'mana.inf_amd64_1111', 'netvsc.inf_amd64_2222', 'manabus.inf_amd64_3333', 'oemnet.inf_amd64_4444') { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
        # Named for a mana INF, whatever it says inside.
        [System.IO.File]::WriteAllText((Join-Path $root 'manabus.inf_amd64_3333' 'manabus.inf'), "[Version]`r`n")
        # Names the adapter, not the PCI device - the Ethernet driver's INF.
        [System.IO.File]::WriteAllText((Join-Path $root 'oemnet.inf_amd64_4444' 'oemnet.inf'), "[Strings]`r`nDesc = `"Microsoft Azure Network Adapter`"`r`n")
        [System.IO.File]::WriteAllText((Join-Path $root 'mana.inf_amd64_1111' 'mana.inf'),
            "[Models]`r`n%Desc%=Inst, PCI\VEN_1414&DEV_00BA&SUBSYS_00000000`r`n", [System.Text.UnicodeEncoding]::new($false, $true))
        [System.IO.File]::WriteAllText((Join-Path $root 'netvsc.inf_amd64_2222' 'netvsc.inf'), "[Models]`r`n%Desc%=Inst, VMBUS\{f8615163}`r`n")
        $raw = & $script:shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:storeHarnessPath -Root $root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($raw -join ' ')
        @(($raw | Select-Object -Last 1) | ConvertFrom-Json) | Sort-Object | Should -Be @('mana.inf_amd64_1111', 'manabus.inf_amd64_3333', 'oemnet.inf_amd64_4444')

        $raw = & $script:shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:storeHarnessPath -Root (Join-Path $script:work 'no-such-folder') 2>&1
        @(($raw | Select-Object -Last 1) | ConvertFrom-Json).Count | Should -Be 0
    }

    It 'removes what it downloaded, whatever the outcome' {
        $before = @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'vmf-mana-*' -ErrorAction SilentlyContinue).Count
        Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = $script:zipSha; zip = $script:zip; pnputilWorks = $true } | Out-Null
        Invoke-MwinScenario @{ storeBefore = $false; bound = $false; pin = ('b' * 64); zip = $script:zip; pnputilWorks = $true } | Out-Null
        @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'vmf-mana-*' -ErrorAction SilentlyContinue).Count | Should -Be $before
    }

    It 'adds with pnputil /add-driver and /install, and takes the driver store from System32' {
        $code = Get-VmfCodeOnly -Path $script:scriptPath
        # Staged, not installed: before the move there is no device to install
        # on. Windows binds the staged driver when the hardware appears.
        $code | Should -Match '/add-driver \$InfPath 2>&1'
        $code | Should -Match "Add-StoreDriver \{[^}]*ErrorActionPreference = 'Continue'"
        $code | Should -Match "System32\\DriverStore\\FileRepository"
        $code | Should -Match "VEN_1414&DEV_00BA"
    }
}

Describe 'MANA-SIG-1: every driver file is signed by Microsoft, or nothing is installed' {
    BeforeAll {
        function script:Assert-MwinRefused([object]$Run, [string]$Pattern) {
            $Run.Doc.result | Should -Be 'BLOCKED'
            $Run.Doc.error | Should -Match 'does not have a valid signature from Microsoft|holds no catalog'
            $Run.Doc.error | Should -Match $Pattern
            $Run.Doc.error | Should -Match 'Nothing was installed\.$'
            # Nothing installed: pnputil never ran, and the engine reads no
            # 'packages added', so the stop says the machine is untouched.
            $Run.Calls.Count | Should -Be 0
            @($Run.Doc.checks | Where-Object name -eq 'packages added').Count | Should -Be 0
            (@($Run.Doc.checks) | Where-Object name -eq 'driver signatures').detail | Should -Match '^refused: '
        }
        $script:base = @{ storeBefore = $false; bound = $false; pnputilWorks = $true }
        function script:Invoke-MwinSig([string]$Zip, [string]$Sha, [hashtable]$Sig = @{}) {
            $sc = $script:base.Clone(); $sc.zip = $Zip; $sc.pin = $Sha; $sc.sig = $Sig
            Invoke-MwinScenario $sc
        }
    }

    It 'signed by Microsoft: the catalog by its own signature, the .sys and the .inf through the catalog - FIXED' {
        $r = Invoke-MwinSig $script:zip $script:zipSha
        $r.Doc.result | Should -Be 'FIXED'
        $r.Calls.Count | Should -Be 1
        (@($r.Doc.checks) | Where-Object name -eq 'driver signatures').detail | Should -Be 'Microsoft: 1 catalog, 1 .sys and 2 .inf files'
        # An INF has no signature of its own: it is never asked for one.
        $r.SigReads | Sort-Object | Should -Be @('mana.cat', 'mana.sys')
    }

    It 'a .sys with its own Microsoft signature, also listed in the catalog: FIXED' {
        (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.sys' = 'microsoft' }).Doc.result | Should -Be 'FIXED'
    }

    It 'an unsigned catalog: refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.cat' = 'unsigned' }) 'x64[\\/]mana\.cat in the pinned package does not have a valid signature from Microsoft: its signature status is NotSigned'
    }

    It 'a catalog signed by another publisher, trusted on this machine: refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.cat' = 'other' }) 'signed by CN=Contoso Drivers, O=Contoso, and that certificate does not chain to a Microsoft root certificate'
    }

    It 'a catalog whose certificate SAYS Microsoft Corporation but chains to another root: refused - the subject proves nothing' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.cat' = 'spoof' }) 'signed by CN=Microsoft Windows Hardware Compatibility Publisher.*does not chain to a Microsoft root'
    }

    It 'a chain that names the Microsoft root but does not build (a forged issuer): refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.cat' = 'fakeissuer' }) 'does not chain to a Microsoft root'
    }

    It 'a catalog signed by an untrusted publisher: refused, with the status Windows gives' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.cat' = 'untrusted' }) 'its signature status is UnknownError'
    }

    It 'a catalog signature that cannot be read: refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.cat' = 'unreadable' }) 'mana\.cat in the pinned package does not have a valid signature from Microsoft: its signature could not be read: The process cannot access the file'
    }

    It 'a .sys signed by another publisher, even though the catalog lists it: refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.sys' = 'other' }) 'x64[\\/]mana\.sys in the pinned package does not have a valid signature from Microsoft: it is signed by CN=Contoso Drivers'
    }

    It 'a .sys whose own signature does not match its content: refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.sys' = 'mismatch' }) 'mana\.sys in the pinned package does not have a valid signature from Microsoft: its signature status is HashMismatch'
    }

    It 'a .sys signature that cannot be read: refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.sys' = 'unreadable' }) 'mana\.sys in the pinned package does not have a valid signature from Microsoft: its signature could not be read'
    }

    It 'an .inf changed after the catalog was signed: refused - the catalog does not list it' {
        Assert-MwinRefused (Invoke-MwinSig $script:zipBadInf $script:zipBadInfSha) 'x64[\\/]mana\.inf in the pinned package does not have a valid signature from Microsoft: no catalog file in the package that Microsoft signed lists it'
    }

    It 'a .sys changed after the catalog was signed: refused, also with no signature of its own' {
        Assert-MwinRefused (Invoke-MwinSig $script:zipBadSys $script:zipBadSysSha) 'x64[\\/]mana\.sys in the pinned package does not have a valid signature from Microsoft: no catalog file in the package that Microsoft signed lists it'
    }

    It 'a package with no catalog: refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zipNoCat $script:zipNoCatSha) 'holds no catalog \(\.cat\) file'
    }

    It 'a catalog with a Microsoft signature that Windows cannot open as a catalog: refused' {
        Assert-MwinRefused (Invoke-MwinSig $script:zipBadCat $script:zipBadCatSha) 'the catalog file x64[\\/]mana\.cat could not be read'
    }

    It 'the signature check comes after the sha256 check: a wrong file is refused for its hash, and no signature is read' {
        $r = Invoke-MwinSig $script:zip ('d' * 64) @{ 'mana.cat' = 'unsigned' }
        $r.Doc.error | Should -Match 'does not match the pin'
        $r.SigReads.Count | Should -Be 0
    }

    It 'a file added, changed or removed after the signature check: refused, nothing installed' -ForEach @(
        @{ After = 'add'; Says = 'the file x64[\\/]extra\.inf was added after the signature check' },
        @{ After = 'addOther'; Says = 'the file x64[\\/]helper\.dll was added after the signature check' },
        @{ After = 'change'; Says = 'the file x64[\\/]other\.inf changed after the signature check' },
        @{ After = 'remove'; Says = 'the file readme\.txt was removed after the signature check' }) {
        $sc = $script:base.Clone(); $sc.zip = $script:zip; $sc.pin = $script:zipSha; $sc.sig = @{}; $sc.afterCheck = $After
        $r = Invoke-MwinScenario $sc
        $r.Doc.result | Should -Be 'BLOCKED'
        $r.Doc.error | Should -Match ('^The pinned package changed after its signature check: ' + $Says + '\. Nothing was installed\.$')
        $r.Calls.Count | Should -Be 0
        @($r.Doc.checks | Where-Object name -eq 'packages added').Count | Should -Be 0
    }

    It 'the work folder is private: no access list from the temporary folder, only SYSTEM, Administrators and the account that runs it' {
        # A parent that lets BUILTIN\Users write, and passes that on, as
        # C:\Windows\Temp does.
        $parent = Join-Path $script:work 'open-temp'
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $open = Get-Acl -LiteralPath $parent
        $open.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $parent -AclObject $open
        $r = Invoke-MwinCode -Code @'
$made = New-PrivateWorkFolder -Path $v.path
[System.IO.File]::WriteAllText((Join-Path $made 'probe.txt'), 'x')
$sids = { param($p) @((Get-Acl -LiteralPath $p).Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) }
$again = ''
try { New-PrivateWorkFolder -Path $v.path | Out-Null } catch { $again = $_.Exception.Message }
@{ protected = (Get-Acl -LiteralPath $made).AreAccessRulesProtected; folder = (& $sids $made); file = (& $sids (Join-Path $made 'probe.txt')); me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value; again = $again }
'@ -Vars @{ path = (Join-Path $parent 'vmf-mana-test') }
        (Get-Acl -LiteralPath $parent).Access.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value | Should -Contain 'S-1-5-32-545' -Because 'the parent must really let Users in, or the test proves nothing'
        $r.protected | Should -BeTrue
        $want = @('S-1-5-18', 'S-1-5-32-544', $r.me) | Sort-Object -Unique
        @($r.folder) | Sort-Object | Should -Be $want
        @($r.file) | Sort-Object | Should -Be $want
        @($r.folder) | Should -Not -Contain 'S-1-5-32-545'
        $r.again | Should -Match 'already there'
    }

    It 'a refusal is one object the guest contract accepts, and fits what RunCommand returns' {
        $r = Invoke-MwinSig $script:zip $script:zipSha @{ 'mana.cat' = 'spoof' }
        { Test-Json -Json $r.Json -SchemaFile $script:schemaPath -ErrorAction Stop } | Should -Not -Throw
        [System.Text.Encoding]::UTF8.GetByteCount($r.Json) | Should -BeLessThan 3000
    }
}

Describe 'MANA-SIG-1: the checks themselves, on real files, under Windows PowerShell' {
    BeforeAll {
        # Certificates made here, never put in a certificate store: a signer
        # that CALLS itself Microsoft, a leaf whose issuer has the name of
        # Microsoft's 2010 root but another key, and a test chain of three.
        $sha = [System.Security.Cryptography.HashAlgorithmName]::SHA256
        $pad = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        $msName = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        function script:New-MwinRequest([string]$Name, $Key) { [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Name, $Key, $sha, $pad) }
        function script:Add-MwinCa($Request) { $Request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true)); $Request }
        $from = [DateTimeOffset]::UtcNow.AddDays(-1); $to = [DateTimeOffset]::UtcNow.AddDays(30)

        $spoofKey = [System.Security.Cryptography.RSA]::Create(2048)
        $spoofRequest = New-MwinRequest $msName $spoofKey
        $codeSigning = [System.Security.Cryptography.OidCollection]::new()
        [void]$codeSigning.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
        $spoofRequest.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($codeSigning, $false))
        $script:spoof = $spoofRequest.CreateSelfSigned($from, $to)
        $script:spoofCer = Join-Path $script:work 'spoof.cer'
        [System.IO.File]::WriteAllBytes($script:spoofCer, $script:spoof.Export('Cert'))

        $fakeRootKey = [System.Security.Cryptography.RSA]::Create(2048)
        $fakeRoot = (Add-MwinCa (New-MwinRequest 'CN=Microsoft Root Certificate Authority 2010, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' $fakeRootKey)).CreateSelfSigned($from, $to)
        $fakeLeaf = (New-MwinRequest 'CN=Microsoft Corporation, O=Microsoft Corporation' $spoofKey).Create($fakeRoot, $from, $to.AddDays(-5), [byte[]](1, 2, 3, 4))
        $script:fakeIssuerCer = Join-Path $script:work 'fake-issuer.cer'
        [System.IO.File]::WriteAllBytes($script:fakeIssuerCer, $fakeLeaf.Export('Cert'))

        $rootKey = [System.Security.Cryptography.RSA]::Create(2048)
        $midKey = [System.Security.Cryptography.RSA]::Create(2048)
        $testRoot = (Add-MwinCa (New-MwinRequest 'CN=VMF Test Root, O=Contoso' $rootKey)).CreateSelfSigned($from, $to)
        $mid = (Add-MwinCa (New-MwinRequest 'CN=VMF Test Issuing CA, O=Contoso' $midKey)).Create($testRoot, $from, $to.AddDays(-1), [byte[]](5, 6, 7, 8))
        # Create gives a certificate with no private key; the issuer needs one.
        $midSigner = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($mid, $midKey)
        $testLeaf = (New-MwinRequest 'CN=Contoso Drivers, O=Contoso' $spoofKey).Create($midSigner, $from, $to.AddDays(-2), [byte[]](9, 10, 11, 12))
        $script:testRootThumb = $testRoot.Thumbprint
        $script:testLeafThumb = $testLeaf.Thumbprint
        $script:testLeafCer = Join-Path $script:work 'test-leaf.cer'
        [System.IO.File]::WriteAllBytes($script:testLeafCer, $testLeaf.Export('Cert'))
        # The certificates a signature carries, as a signed file carries them.
        $carried = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        [void]$carried.Add($mid); [void]$carried.Add($testRoot)
        $script:carriedP7b = Join-Path $script:work 'carried.p7b'
        [System.IO.File]::WriteAllBytes($script:carriedP7b, $carried.Export('Pkcs7'))

        # A catalog signed by the self-made "Microsoft" certificate.
        # CreateSelfSigned keeps the key; a PFX round trip gives the key a form
        # the Windows signing API takes.
        $script:spoofSigner = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($script:spoof.Export('Pfx', 'x'), 'x', 'Exportable')

        # An EXPIRED signer, made here: a root valid for 500 days and a leaf
        # that expired 10 days ago, with a current leaf beside it. Microsoft's
        # driver signing certificates expire within about a year, and their
        # time-stamped signatures stay Valid, so the chain policy must not
        # refuse an expired leaf.
        $oldRootKey = [System.Security.Cryptography.RSA]::Create(2048)
        $oldRoot = (Add-MwinCa (New-MwinRequest 'CN=VMF Test Old Root, O=Contoso' $oldRootKey)).CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-500), $to)
        $expiredLeaf = (New-MwinRequest 'CN=Contoso Expired Signer, O=Contoso' $spoofKey).Create($oldRoot, [DateTimeOffset]::UtcNow.AddDays(-400), [DateTimeOffset]::UtcNow.AddDays(-10), [byte[]](13, 14, 15, 16))
        $currentLeaf = (New-MwinRequest 'CN=Contoso Current Signer, O=Contoso' $spoofKey).Create($oldRoot, $from, $to.AddDays(-3), [byte[]](17, 18, 19, 20))
        $script:expiredLeafCer = Join-Path $script:work 'expired-leaf.cer'
        $script:currentLeafCer = Join-Path $script:work 'current-leaf.cer'
        [System.IO.File]::WriteAllBytes($script:expiredLeafCer, $expiredLeaf.Export('Cert'))
        [System.IO.File]::WriteAllBytes($script:currentLeafCer, $currentLeaf.Export('Cert'))
        $oldCarried = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        [void]$oldCarried.Add($oldRoot)
        $script:oldRootP7b = Join-Path $script:work 'old-root.p7b'
        [System.IO.File]::WriteAllBytes($script:oldRootP7b, $oldCarried.Export('Pkcs7'))

        # Microsoft's own, when this machine has it: the catalog in its catalog
        # store that lists the in-box stornvme driver. Every Windows Server
        # since 2016 has that driver; a machine without it SKIPS the two tests
        # that need it, by name and with the reason, never in silence.
        $script:real = Invoke-MwinCode -Code @'
$repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
$pkg = @(Get-ChildItem -LiteralPath $repo -Directory -Filter 'stornvme.inf_*' -ErrorAction SilentlyContinue | Select-Object -First 1)
$listing = ''; $inf = ''; $sys = ''
if ($pkg.Count -gt 0) {
    $inf = Join-Path $pkg[0].FullName 'stornvme.inf'
    $sys = Join-Path $pkg[0].FullName 'stornvme.sys'
}
if ($inf -and (Test-Path -LiteralPath $inf) -and (Test-Path -LiteralPath $sys)) {
    $catRoot = Join-Path $env:SystemRoot 'System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
    foreach ($c in @(Get-ChildItem -LiteralPath $catRoot -Filter '*.cat' -ErrorAction SilentlyContinue)) {
        try { if ((Test-CatalogMember -CatalogPath $c.FullName -FilePath $inf) -and (Test-CatalogMember -CatalogPath $c.FullName -FilePath $sys)) { $listing = $c.FullName; break } } catch { $null = $_ }
    }
}
@{ inf = $inf; sys = $sys; listing = $listing }
'@
        $script:noRealReason = ''
        if (-not $script:real.listing) {
            $script:noRealReason = 'SKIPPED ON PURPOSE: this machine has no in-box stornvme driver listed in a catalog of its catalog store, so there is no Microsoft-signed catalog to test with. The self-made chains still test every rule.'
        }
    }

    It 'the chain is built with the certificates the signature carries' {
        $r = Invoke-MwinCode -Code @'
$leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $v.leaf
@{ with = (Get-SignerRoot -Certificate $leaf -Path $v.p7b); without = (Get-SignerRoot -Certificate $leaf -Path '') }
'@ -Vars @{ leaf = $script:testLeafCer; p7b = $script:carriedP7b }
        $r.with.Root | Should -Be $script:testRootThumb
        $r.with.Built | Should -BeFalse -Because 'the test root is trusted nowhere'
        $r.without.Root | Should -Be $script:testLeafThumb
    }

    It 'the chain policy accepts an expired signer certificate (a self-made chain, so no machine state is needed)' {
        # The product's own policy (New-SignerChain), with ONE thing added for
        # the test: the self-made root is trusted nowhere, so an unknown root is
        # allowed. Without the policy's time flags the same build fails, which
        # proves the leaf really is expired.
        $r = Invoke-MwinCode -Code @'
$out = @{}
foreach ($k in 'expired', 'current') {
    $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $v.$k
    $chain = New-SignerChain -Path $v.p7b
    $chain.ChainPolicy.VerificationFlags = $chain.ChainPolicy.VerificationFlags -bor [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    $out[$k] = $chain.Build($leaf)
    $plain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $plain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $plain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    $plain.ChainPolicy.ExtraStore.AddRange($chain.ChainPolicy.ExtraStore)
    $out[$k + 'Plain'] = $plain.Build($leaf)
}
$out
'@ -Vars @{ expired = $script:expiredLeafCer; current = $script:currentLeafCer; p7b = $script:oldRootP7b }
        $r.expired | Should -BeTrue
        $r.current | Should -BeTrue
        $r.currentPlain | Should -BeTrue
        $r.expiredPlain | Should -BeFalse -Because 'without the time flags an expired leaf fails, so the leaf is really expired'
    }

    It 'Microsoft''s own catalog signature passes (when this machine has the in-box stornvme catalog)' {
        if ($script:noRealReason) { Set-ItResult -Skipped -Because $script:noRealReason; return }
        $r = Invoke-MwinCode -Code @'
$g = Get-AuthenticodeSignature -LiteralPath $v.listing
@{ microsoft = (Test-MicrosoftRoot -Certificate $g.SignerCertificate -Path $v.listing); problem = [string](Test-SignatureFromMicrosoft -Signature $g -Path $v.listing) }
'@ -Vars @{ listing = $script:real.listing }
        $r.microsoft | Should -BeTrue
        $r.problem | Should -BeNullOrEmpty
    }

    It 'a certificate that calls itself Microsoft, and one with a forged Microsoft issuer: not Microsoft' {
        $r = Invoke-MwinCode -Code @'
$spoof = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $v.spoof
$fake = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $v.fake
@{ spoof = (Test-MicrosoftRoot -Certificate $spoof -Path ''); fake = (Test-MicrosoftRoot -Certificate $fake -Path ''); fakeChain = (Get-SignerRoot -Certificate $fake -Path ''); none = (Test-MicrosoftRoot -Certificate $null -Path '') }
'@ -Vars @{ spoof = $script:spoofCer; fake = $script:fakeIssuerCer }
        $r.spoof | Should -BeFalse
        $r.fake | Should -BeFalse
        # The forged chain ENDS at Microsoft's real 2010 root - only the failed
        # build tells it apart, so the build result must be part of the rule.
        $r.fakeChain.Root | Should -Be '3B1EFD3A66EA28B16697394703A72CA340A05BD5'
        $r.fakeChain.Built | Should -BeFalse
        $r.none | Should -BeFalse
    }

    It 'a real package: Microsoft''s catalog with the files it lists passes; a changed file, an unsigned or a self-signed catalog is refused (when this machine has the in-box stornvme catalog)' {
        if ($script:noRealReason) { Set-ItResult -Skipped -Because $script:noRealReason; return }
        $pkgRoot = Join-Path $script:work 'real-pkg'
        $make = {
            param([string]$Name, [scriptblock]$Change)
            $dir = Join-Path $pkgRoot $Name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Copy-Item -LiteralPath $script:real.inf, $script:real.sys -Destination $dir
            Copy-Item -LiteralPath $script:real.listing -Destination (Join-Path $dir 'stornvme.cat')
            if ($Change) { & $Change $dir }
            $dir
        }
        $good = & $make 'good'
        $changed = & $make 'changed' { param($d) [System.IO.File]::AppendAllText((Join-Path $d 'stornvme.inf'), "; changed`r`n") }
        $unsigned = & $make 'unsigned' { param($d)
            Remove-Item -LiteralPath (Join-Path $d 'stornvme.cat')
            $c = Join-Path $script:work 'real-unsigned.cat'
            New-FileCatalog -Path $d -CatalogFilePath $c -CatalogVersion 2.0 | Out-Null
            Move-Item -LiteralPath $c -Destination (Join-Path $d 'stornvme.cat') }
        $selfSigned = & $make 'selfsigned' { param($d)
            Remove-Item -LiteralPath (Join-Path $d 'stornvme.cat')
            $c = Join-Path $script:work 'real-self.cat'
            New-FileCatalog -Path $d -CatalogFilePath $c -CatalogVersion 2.0 | Out-Null
            Set-AuthenticodeSignature -LiteralPath $c -Certificate $script:spoofSigner -HashAlgorithm SHA256 | Out-Null
            Move-Item -LiteralPath $c -Destination (Join-Path $d 'stornvme.cat') }
        $r = Invoke-MwinCode -Code @'
$out = @{}
foreach ($k in 'good', 'changed', 'unsigned', 'selfsigned') { $out[$k] = Test-DriverPackageSignatures -Folder $v.$k }
$out
'@ -Vars @{ good = $good; changed = $changed; unsigned = $unsigned; selfsigned = $selfSigned }
        $r.good.Problem | Should -BeNullOrEmpty
        $r.good.Checked | Should -Be '1 catalog, 1 .sys and 1 .inf files'
        $r.changed.Problem | Should -Match '^The driver file stornvme\.inf in the pinned package does not have a valid signature from Microsoft: no catalog file in the package that Microsoft signed lists it'
        $r.unsigned.Problem | Should -Match 'stornvme\.cat in the pinned package does not have a valid signature from Microsoft: its signature status is NotSigned'
        $r.selfsigned.Problem | Should -Match 'stornvme\.cat in the pinned package does not have a valid signature from Microsoft: its signature status is (UnknownError|NotTrusted)'
    }

    It 'the catalog read: a SHA1 catalog is read, and a catalog that is not there is an error, never created' {
        $dir = Join-Path $script:work 'sha1-pkg'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'a.inf'), "[Version]`r`n")
        $cat = Join-Path $script:work 'sha1.cat'
        New-FileCatalog -Path $dir -CatalogFilePath $cat -CatalogVersion 1.0 | Out-Null
        $missing = Join-Path $script:work 'no-such.cat'
        $r = Invoke-MwinCode -Code @'
$e = ''
try { Test-CatalogMember -CatalogPath $v.missing -FilePath $v.file | Out-Null } catch { $e = $_.Exception.Message }
@{ sha1 = (Test-CatalogMember -CatalogPath $v.cat -FilePath $v.file); other = (Test-CatalogMember -CatalogPath $v.cat -FilePath $v.cat); missingError = $e }
'@ -Vars @{ cat = $cat; file = (Join-Path $dir 'a.inf'); missing = $missing }
        $r.sha1 | Should -BeTrue
        $r.other | Should -BeFalse
        $r.missingError | Should -Not -BeNullOrEmpty
        $missing | Should -Not -Exist
    }

    It 'reads signatures with Get-AuthenticodeSignature, never takes the subject name as proof, and pins Microsoft''s roots by thumbprint' {
        $code = Get-VmfCodeOnly -Path $script:scriptPath
        $code | Should -Match 'Get-AuthenticodeSignature -LiteralPath \$Path -ErrorAction Stop'
        $code | Should -Not -Match 'Subject\s+-(c|i)?(like|match|eq)'
        $code | Should -Match "'3B1EFD3A66EA28B16697394703A72CA340A05BD5'"
        $code | Should -Match "'8F43288AD272F3103B6FB1428485EA3014C0BCFE'"
        $code | Should -Match 'X509RevocationMode\]::NoCheck'
        $code | Should -Match 'New-PrivateWorkFolder -Path \$work \| Out-Null'
    }
}

Describe 'MANA-WIN-1: the pin' {
    BeforeAll {
        $script:source = Get-Content $script:scriptPath -Raw
        $script:manifest = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'manifest.json') -Raw | ConvertFrom-Json
        function script:Pin([string]$Field) {
            if ($script:source -match "(?m)^\`$script:PACKAGE_$Field\s*=\s*'([^']*)'") { return $Matches[1] }
            throw "no PACKAGE_$Field"
        }
    }

    It 'the manifest lists the package exactly as the script pins it' {
        $pkg = @($script:manifest.packages | Where-Object script -eq 'Install-ManaDriver.ps1')
        $pkg.Count | Should -Be 1
        $pkg[0].name | Should -Be (Pin 'NAME')
        $pkg[0].version | Should -Be (Pin 'VERSION')
        $pkg[0].url | Should -Be (Pin 'URL')
        $pkg[0].sha256 | Should -Be (Pin 'SHA256')
        $pkg[0].sizeBytes | Should -Be ([long](Pin 'BYTES'))
    }

    It 'the pin is one Microsoft download of one version, named for that version' {
        $url = Pin 'URL'
        $url | Should -Match '^https://download\.microsoft\.com/'
        $url | Should -BeLike "*/$(Pin 'NAME')"
        (Pin 'NAME') | Should -Match ([regex]::Escape(((Pin 'VERSION') -replace '\.', '_')))
        # Pinned 2026-10-04 (MANA-WIN-2). An empty pin installs nothing, so
        # losing it by accident would quietly switch the install off.
        (Pin 'SHA256') | Should -Match '^[0-9a-f]{64}$' -Because 'the shipped script carries a pinned sha256'
    }

    It 'Get-VmfGuestScript hands the engine the pin for this script, and none for another' {
        $s = Get-VmfGuestScript -Name 'Install-ManaDriver.ps1'
        @($s.Packages).Count | Should -Be 1
        $s.Packages[0].version | Should -Be (Pin 'VERSION')
        @((Get-VmfGuestScript -Name 'Test-NvmeReady.ps1').Packages).Count | Should -Be 0
    }
}

Describe 'MANA-WIN-1: when the engine runs it, and what a result means' {
    It 'only Windows, only a target that can give MANA, only with accelerated networking on after the move' -ForEach @(
        @{ Os = 'Windows'; May = $true; On = $true; Want = $true },
        @{ Os = 'Windows'; May = $false; On = $true; Want = $false },
        @{ Os = 'Windows'; May = $true; On = $false; Want = $false },
        @{ Os = 'Linux'; May = $true; On = $true; Want = $false },
        @{ Os = ''; May = $true; On = $true; Want = $false }) {
        InModuleScope VmMigrationFactory -Parameters @{ o = $Os; m = $May; n = $On; w = $Want } {
            Test-VmfManaDriverInstallWanted -Os $o -TargetMayMana $m -AcceleratedNetworkingAfter $n | Should -Be $w
        }
    }

    It 'the accelerated networking decision says whether it is on after the move' {
        InModuleScope VmMigrationFactory {
            # DRIFT-11: v7, where the keep-it-off branch still exists - every v6
            # size requires accelerated networking since 2026-10-27.
            $plan = { param($an) [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/vm'; assessment = [pscustomobject]@{ os = 'Windows' }
                    target = [pscustomobject]@{ size = 'Standard_D2ds_v7'; controller = 'NVMe' }
                    policy = $(if ($an) { [pscustomobject]@{ acceleratedNetworking = $an } } else { [pscustomobject]@{} }) } }
            $on = @([pscustomobject]@{ id = 'n0'; primary = $true; acceleratedNetworking = $true })
            $off = @([pscustomobject]@{ id = 'n0'; primary = $true; acceleratedNetworking = $false })
            (Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (& $plan '') -CapturedNics $on -ManaDriver 'unknown').OnAfter | Should -BeTrue
            (Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (& $plan 'preserve') -CapturedNics $off -ManaDriver 'unknown').OnAfter | Should -BeFalse
            (Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (& $plan 'preserve') -CapturedNics $on -ManaDriver 'unknown').OnAfter | Should -BeTrue
            # AN-MANA-DRIVER-RULE-1: the keep-it-off branch is gone. A Linux-shaped
            # 'absent' on v7 is the driver stop, before any install: on after,
            # and stopped. An off setting on v7 is refused (the stop above
            # carries OnAfter false, so nothing installs either).
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (& $plan '') -CapturedNics $off -ManaDriver 'absent'
            $r.OnAfter | Should -BeTrue
            $r.Stop | Should -BeTrue
            (Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (& $plan 'preserve') -CapturedNics $off -ManaDriver 'unknown').Reason | Should -Be 'acceleratedNetworkingRequired'
        }
    }

    It 'reads each result: NO_CHANGE present, FIXED installed, anything else a stop' {
        InModuleScope VmMigrationFactory {
            $pkg = [pscustomobject]@{ name = 'mana_vf_drivers_2_0_18_52.zip'; version = '2.0.18.52'; sha256 = ('c' * 64) }
            $out = { param($r, $e) $o = [pscustomobject]@{ result = $r; checks = @([pscustomobject]@{ name = 'mana driver in store'; status = 'INFO'; detail = 'mana.inf_amd64_x' }) }
                if ($e) { $o | Add-Member -NotePropertyName error -NotePropertyValue $e }; $o }

            $p = Get-VmfManaDriverInstallOutcome -GuestOutput (& $out 'NO_CHANGE') -Package $pkg
            $p.Stop | Should -BeFalse
            $p.Record.outcome | Should -Be 'present'
            $p.Record.storeBefore | Should -Be 'mana.inf_amd64_x'
            $p.Record.Contains('packageVersion') | Should -BeFalse -Because 'nothing was installed, so no package is named'

            $n = Get-VmfManaDriverInstallOutcome -GuestOutput (& $out 'NEEDS_PREP') -Package $pkg
            $n.Stop | Should -BeFalse -Because 'no pin is never a stop: the move goes on as it did before'
            $n.Warn | Should -BeTrue
            $n.Record.outcome | Should -Be 'notPinned'
            $n.Detail | Should -Match 'no pinned MANA driver'

            $f = Get-VmfManaDriverInstallOutcome -GuestOutput (& $out 'FIXED') -Package $pkg
            $f.Stop | Should -BeFalse
            $f.Record.outcome | Should -Be 'installed'
            $f.Record.packageVersion | Should -Be '2.0.18.52'
            $f.Record.packageSha256 | Should -Be ('c' * 64)
            $f.Detail | Should -Match '2\.0\.18\.52'

            $b = Get-VmfManaDriverInstallOutcome -GuestOutput (& $out 'BLOCKED' 'The downloaded package does not match the pin') -Package $pkg
            $b.Stop | Should -BeTrue
            $b.Record.outcome | Should -Be 'failed'
            $b.Detail | Should -Match 'does not match the pin'

            foreach ($odd in @((& $out 'READY'), $null)) {
                $x = Get-VmfManaDriverInstallOutcome -GuestOutput $odd -Package $pkg
                $x.Stop | Should -BeTrue -Because 'an answer the engine does not know is never read as a driver'
                $x.Record.outcome | Should -Be 'failed'
            }
        }
    }
}

Describe 'MANA-WIN-1: RUN the preparation step' {
    BeforeAll {
        function Global:MwinNics([bool]$On = $true) {
            , @([pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic0'; primary = $true; acceleratedNetworking = $On })
        }
        function Global:MwinPlan([string]$Size = 'Standard_D2ds_v6', [string]$Controller = 'NVMe', [string]$Os = 'Windows', [string]$An = '',
            [string]$SourceArch = 'scsi-temp', [string]$TargetArch = 'nvme-temp') {
            $policy = [ordered]@{ onDriverBelowFloor = 'stop'; onDDataFound = 'stop' }
            if ($An) { $policy.acceleratedNetworking = $An }
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/mwinvm'
                wave = 'w1'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                    sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = $SourceArch; platformManaged = $false }
                target = [pscustomobject]@{ size = $Size; diskArch = $TargetArch; controller = $Controller }
                path = 'A'
                policy = [pscustomobject]$policy
            }
        }
        function Global:MwinOut([string]$Script, [string]$Result, [string]$Os = 'Windows', [string]$Err = '') {
            $facts = if ($Os -eq 'Windows') { [pscustomobject]@{ os = 'Windows'; osVersion = '10.0.20348'; fabric = 'mlx5'; driverVersion = '' } }
                     else { [pscustomobject]@{ os = 'Linux'; kernelVersion = '5.15.0-1100-azure'; distroId = 'ubuntu'; distroVersion = '22.04'; fabric = 'mlx5' } }
            $o = [pscustomobject]@{ schema = 'vmf.guest/2'; script = $Script; version = '1.0.0'; os = 'x'; result = $Result; warnings = @()
                checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = 'modinfo mana' }
                    [pscustomobject]@{ name = 'mana driver in store'; status = 'INFO'; detail = 'none' }); facts = $facts }
            if ($Err) { $o | Add-Member -NotePropertyName error -NotePropertyValue $Err }
            $o
        }
    }
    BeforeEach {
        $script:runPath = Join-Path $script:work ("run-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'mwin-test' | Out-Null }
        $global:mwinScripts = [System.Collections.Generic.List[string]]::new()
        $global:mwinInstallResult = 'FIXED'
        $global:mwinInstallError = ''
        $global:mwinOs = 'Windows'
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:mwinScripts.Add($ScriptName)
            switch ($ScriptName) {
                'Install-ManaDriver.ps1' {
                    $o = Global:MwinOut $ScriptName $global:mwinInstallResult 'Windows' $global:mwinInstallError
                    if ($global:mwinAdded) { $o.checks += [pscustomobject]@{ name = 'packages added'; status = 'INFO'; detail = $global:mwinAdded } }
                    return $o
                }
                'Test-NvmeReady.ps1' { return Global:MwinOut $ScriptName 'NEEDS_PREP' }
                default { return Global:MwinOut $ScriptName 'READY' $global:mwinOs }
            }
        }
    }
    AfterEach {
        Remove-Variable mwinScripts, mwinInstallResult, mwinInstallError, mwinOs, mwinAdded -Scope Global -ErrorAction SilentlyContinue
    }

    It 'absent from the store: installed BEFORE any script that changes the guest, and recorded' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            $rec = (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.manaDriverInstall
            $rec.outcome | Should -Be 'installed'
            $pin = (Get-VmfGuestScript -Name 'Install-ManaDriver.ps1').Packages[0]
            $rec.packageVersion | Should -Be $pin.version
            # The record names the package the SHIPPED pin installs.
            $rec.packageSha256 | Should -Be $pin.sha256
            $rec.packageSha256 | Should -Match '^[0-9a-f]{64}$'
        }
        $order = @($global:mwinScripts)
        $order | Should -Contain 'Install-ManaDriver.ps1'
        $order.IndexOf('Install-ManaDriver.ps1') | Should -BeLessThan $order.IndexOf('Set-NvmeReady.ps1')
        $order.IndexOf('Install-ManaDriver.ps1') | Should -BeLessThan $order.IndexOf('Move-Pagefile.ps1')
        $order.IndexOf('Install-ManaDriver.ps1') | Should -BeLessThan $order.IndexOf('Install-TempDiskInit.ps1')
    }

    It 'already in the store: nothing installed, and the record says present' {
        $global:mwinInstallResult = 'NO_CHANGE'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.manaDriverInstall.outcome | Should -Be 'present'
        }
    }

    It 'an install that fails: the machine stops UNTOUCHED, before the NVMe preparation, with a reason an operator can act on' {
        $global:mwinInstallResult = 'BLOCKED'
        $global:mwinInstallError = 'The downloaded package does not match the pin: sha256 x, pinned y. Nothing was installed.'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'FAILED_NEEDS_ATTENTION'
            $r.Reason | Should -Be 'manaDriverInstallFailed'
            $r.MachineState | Should -Be 'untouched'
            $r.Detail | Should -Match 'does not match the pin'
            (Get-VmfStopGuidance -Code $r.Reason).machine | Should -Be 'untouched'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.manaDriverInstall.outcome | Should -Be 'failed'
        }
        foreach ($changer in 'Set-NvmeReady.ps1', 'Move-Pagefile.ps1', 'Install-TempDiskInit.ps1', 'Test-NvmeReady.ps1') {
            $global:mwinScripts | Should -Not -Contain $changer
        }
    }

    It 'MANA-SIG-1: a package refused for its signature stops the machine UNTOUCHED, the same way as a wrong sha256' {
        $global:mwinInstallResult = 'BLOCKED'
        $global:mwinInstallError = 'The driver file mana_vf\mana.sys in the pinned package does not have a valid signature from Microsoft: its signature status is NotSigned. Nothing was installed.'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'FAILED_NEEDS_ATTENTION'
            $r.Reason | Should -Be 'manaDriverInstallFailed'
            $r.MachineState | Should -Be 'untouched'
            $r.Detail | Should -Match 'valid signature from Microsoft'
        }
        $global:mwinScripts | Should -Not -Contain 'Set-NvmeReady.ps1'
    }

    It 'MANA-SIG-1: the stop reason says the product checks the signature, and what to do when it does not match' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'manaDriverInstallFailed'
            $g.meaning | Should -Match 'checks that Microsoft signed each driver file'
            $g.whatToDo | Should -Match 'signature from Microsoft'
        }
    }

    It 'an unpinned script (NEEDS_PREP): the machine goes on, and the record and the log say the store had none' {
        $global:mwinInstallResult = 'NEEDS_PREP'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.manaDriverInstall.outcome | Should -Be 'notPinned'
            $events = @(Get-Content (Join-Path $rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $_.step -eq 'driverCheck' -and $_.outcome -eq 'warn' })
            ($events.detail -join ' ') | Should -Match 'no pinned MANA driver'
        }
        $global:mwinScripts | Should -Contain 'Set-NvmeReady.ps1'
    }

    It 'a failed install after pnputil added some files: the stop does NOT claim untouched' {
        $global:mwinInstallResult = 'BLOCKED'
        $global:mwinInstallError = 'pnputil added 7 of 8 INF files from the pinned package.'
        $global:mwinAdded = '7'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Reason | Should -Be 'manaDriverInstallFailed'
            # PREP-ROLLBACK-1 (review F7): said explicitly now - the audit trail does not
            # count a BLOCKED install, and the engine judges the step by it - so the
            # engine rolls this machine back.
            $r.MachineState | Should -Be 'changed'
        }
    }

    It 'a failed install on a second visit, after the NVMe preparation ran in this attempt: not untouched' {
        $global:mwinInstallResult = 'BLOCKED'
        $global:mwinInstallError = 'The download from https://download.microsoft.com/x failed.'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            Add-VmfStateTransition -RunPath $rp -VmId $ctx.VmId -NewState 'PRECHECK' -Outcome ok | Out-Null
            Start-Sleep -Milliseconds 20
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc | Add-Member -NotePropertyName guestExecutions -NotePropertyValue @([pscustomobject]@{
                    script = 'Set-NvmeReady.ps1'; version = '1.0.0'; sha256 = 'x'; tsUtc = (Get-Date).ToUniversalTime().ToString('o'); result = 'FIXED'; evidenceRef = 'e' }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Reason | Should -Be 'manaDriverInstallFailed'
            $r.ContainsKey('MachineState') | Should -BeFalse
        }
    }

    It 'an earlier attempt''s preparation does not count: a new attempt that fails here is untouched' {
        $global:mwinInstallResult = 'BLOCKED'
        $global:mwinInstallError = 'The download from https://download.microsoft.com/x failed.'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc | Add-Member -NotePropertyName guestExecutions -NotePropertyValue @([pscustomobject]@{
                    script = 'Set-NvmeReady.ps1'; version = '1.0.0'; sha256 = 'x'; tsUtc = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o'); result = 'FIXED'; evidenceRef = 'e' }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Add-VmfStateTransition -RunPath $rp -VmId $ctx.VmId -NewState 'PRECHECK' -Outcome ok | Out-Null
            (Invoke-VmfStepGuestPrep -Context $ctx).MachineState | Should -Be 'untouched'
        }
    }

    It 'a re-run after an install finds it present and goes on - the step stays safe to repeat' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan) -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            $global:mwinInstallResult = 'NO_CHANGE'
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
        }
        @($global:mwinScripts | Where-Object { $_ -eq 'Install-ManaDriver.ps1' }).Count | Should -Be 2
    }

    It 'Intel v5 can give MANA: it runs' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan -Size 'Standard_D2ds_v5' -Controller 'SCSI' -TargetArch 'scsi-temp') -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
        }
        $global:mwinScripts | Should -Contain 'Install-ManaDriver.ps1'
    }

    It 'a target that cannot give MANA (AMD v5): it does not run' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan -Size 'Standard_D2ads_v5' -Controller 'SCSI' -TargetArch 'scsi-temp') -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.PSObject.Properties.Name | Should -Not -Contain 'manaDriverInstall'
        }
        $global:mwinScripts | Should -Not -Contain 'Install-ManaDriver.ps1'
    }

    # AN-MANA-DRIVER-RULE-1: rewritten. A wave that turns it off on v7 is now
    # refused, untouched, before the install (v7 can give MANA, so it is
    # always on there). Either way the install does not run.
    It 'accelerated networking kept off by the wave: refused on v7, and the install does not run' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan -An 'preserve' -Size 'Standard_D2ds_v7') -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $false) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
        }
        $global:mwinScripts | Should -Not -Contain 'Install-ManaDriver.ps1'
    }

    It 'a Linux machine: it does not run' {
        $global:mwinOs = 'Linux'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:MwinPlan -Os 'Linux') -RunPath $rp -RunId 'mwin-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mwin-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:MwinNics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
        }
        $global:mwinScripts | Should -Not -Contain 'Install-ManaDriver.ps1'
    }
}

Describe 'MANA-WIN-1: the drift check watches Microsoft''s download' {
    BeforeAll {
        $script:driftTool = Join-Path $script:repoRoot 'tools' 'Test-UpstreamDrift.ps1'
        $script:pinSource = Get-Content $script:scriptPath -Raw
        $script:pinUrl = [regex]::Match($script:pinSource, "(?m)^\`$script:PACKAGE_URL\s*=\s*'([^']*)'").Groups[1].Value
        $script:pinBytes = [regex]::Match($script:pinSource, "(?m)^\`$script:PACKAGE_BYTES\s*=\s*'([^']*)'").Groups[1].Value
        # A baseline with no upstream FILES, so only the download is asked.
        $real = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'upstream.json') -Raw | ConvertFrom-Json -Depth 8
        $script:dlBaseline = Join-Path $script:work 'upstream-downloads.json'
        [ordered]@{ schemaVersion = 1; repo = $real.repo; branch = $real.branch; pinnedCommit = $real.pinnedCommit; pinnedUtc = $real.pinnedUtc
            files = @(); downloads = @($real.downloads) } | ConvertTo-Json -Depth 8 | Set-Content $script:dlBaseline
        function script:Drift([scriptblock]$Links) {
            & $script:driftTool -BaselinePath $script:dlBaseline -ContentProvider { throw 'no file is watched here' } -LinkProvider $Links 6>$null
        }
    }

    It 'the real baseline watches the link, and reads its pin from the install script' {
        $real = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'upstream.json') -Raw | ConvertFrom-Json -Depth 8
        $dl = @($real.downloads)
        $dl.Count | Should -Be 1
        $dl[0].link | Should -Be 'https://aka.ms/manawindowsdrivers'
        $dl[0].pinnedIn | Should -Be 'src/guest/windows/Install-ManaDriver.ps1'
        Join-Path $script:repoRoot $dl[0].pinnedIn | Should -Exist
    }

    It 'link and file as pinned: no drift' {
        $pinned = $script:pinUrl; $bytes = $script:pinBytes
        $r = Drift { param($Url) if ($Url -like '*aka.ms*') { [pscustomobject]@{ StatusCode = 301; Location = $pinned } }
                     else { [pscustomobject]@{ StatusCode = 200; ContentLength = [long]$bytes } } }.GetNewClosure()
        @($r.Drifted).Count | Should -Be 0
        $r.Checked | Should -Be 1
        $r.ExitCode | Should -Be 0
    }

    It 'the link points at a newer file: changed, and it names the pin tool' {
        $r = Drift { param($Url) [pscustomobject]@{ StatusCode = 301; Location = 'https://download.microsoft.com/download/mana_vf_drivers_2_0_19_1.zip' } }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match 'mana_vf_drivers_2_0_19_1\.zip'
        $r.Drifted[0].reason | Should -Match 'Update-VmfManaDriverPin'
        $r.Drifted[0].url | Should -Match 'accelerated-networking-mana-windows'
        $r.ExitCode | Should -Be 1
    }

    It 'the pinned file is gone: changed' {
        $pinned = $script:pinUrl
        $r = Drift { param($Url) if ($Url -like '*aka.ms*') { [pscustomobject]@{ StatusCode = 301; Location = $pinned } } else { [pscustomobject]@{ StatusCode = 404 } } }.GetNewClosure()
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match 'gone'
    }

    It 'the pinned file changed size: changed - the sha256 would refuse it' {
        $pinned = $script:pinUrl
        $r = Drift { param($Url) if ($Url -like '*aka.ms*') { [pscustomobject]@{ StatusCode = 301; Location = $pinned } } else { [pscustomobject]@{ StatusCode = 200; ContentLength = 12 } } }.GetNewClosure()
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match 'replaced'
    }

    It 'no answer is UNREACHABLE, never a change and never a pass' {
        $pinned = $script:pinUrl
        $noSize = { param($Url) if ($Url -like '*aka.ms*') { [pscustomobject]@{ StatusCode = 301; Location = $pinned } } else { [pscustomobject]@{ StatusCode = 200; ContentLength = $null } } }.GetNewClosure()
        foreach ($links in @({ param($Url) throw 'timed out' }, { param($Url) [pscustomobject]@{ StatusCode = 200 } }, $noSize)) {
            $r = Drift $links
            $r.Drifted[0].kind | Should -Be 'unreachable'
            $r.ExitCode | Should -Be 1
        }
    }
}

Describe 'MANA-WIN-1: pinning a new driver is one command' {
    BeforeAll {
        # MANA-PIN-SIG-1: the tool runs the guest script's own signature check.
        # A fixture catalog is real (New-FileCatalog) but nobody signed it, so a
        # test that pins must replace the READ of a signature - the same two
        # functions the guest harness above replaces. The decision on what is
        # read, and the catalog read, stay the guest script's own.
        $script:sigAsMicrosoft = {
            function Get-DriverFileSignature {
                param([string]$Path)
                if ($Path -notlike '*.cat') { return [pscustomobject]@{ Status = 'NotSigned'; StatusMessage = 'The file is not digitally signed.'; SignerCertificate = $null } }
                [pscustomobject]@{ Status = 'Valid'; StatusMessage = 'Signature verified.'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation'; Marker = 'ms' } }
            }
            function Get-SignerRoot {
                param([object]$Certificate, [string]$Path)
                @{ Built = $true; Root = '3B1EFD3A66EA28B16697394703A72CA340A05BD5'; RootSubject = 'CN=Microsoft Root Certificate Authority 2010'; Status = '' }
            }
        }
        # A catalog with a valid signature from a publisher that is not Microsoft.
        $script:sigAsContoso = {
            function Get-DriverFileSignature {
                param([string]$Path)
                if ($Path -notlike '*.cat') { return [pscustomobject]@{ Status = 'NotSigned'; StatusMessage = 'The file is not digitally signed.'; SignerCertificate = $null } }
                [pscustomobject]@{ Status = 'Valid'; StatusMessage = 'Signature verified.'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso Drivers, O=Contoso'; Marker = 'other' } }
            }
            function Get-SignerRoot {
                param([object]$Certificate, [string]$Path)
                @{ Built = $true; Root = 'D4DE20D05E66FC53FE1A50882C78DB2852CAE474'; RootSubject = 'CN=Contoso Root'; Status = '' }
            }
        }
        function script:Invoke-MwinPinRefused([string]$Zip, [object]$Override, [string]$Expected) {
            $download = { param($Url, $Path) Copy-Item -LiteralPath $Zip -Destination $Path }.GetNewClosure()
            $manifestBefore = [System.IO.File]::ReadAllText((Join-Path $script:pinRoot 'manifest.json'))
            $arguments = @{
                ScriptPath = $script:pinScript; GuestRoot = $script:pinRoot
                Resolver   = { param($Url) 'https://download.microsoft.com/download/mana_vf_drivers_2_0_19_1.zip' }
                Downloader = $download
            }
            if ($Override) { $arguments.SignatureOverride = $Override }
            { & $script:pinTool @arguments 6>$null } | Should -Throw -ExpectedMessage $Expected
            [System.IO.File]::ReadAllText($script:pinScript) | Should -Be $script:pinStart
            [System.IO.File]::ReadAllText((Join-Path $script:pinRoot 'manifest.json')) | Should -Be $manifestBefore
        }
    }
    BeforeEach {
        $script:pinRoot = Join-Path $script:work ("pin-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        Copy-Item (Join-Path $script:repoRoot 'src' 'guest') $script:pinRoot -Recurse
        $script:pinScript = Join-Path $script:pinRoot 'windows' 'Install-ManaDriver.ps1'
        $script:pinTool = Join-Path $script:repoRoot 'tools' 'Update-VmfManaDriverPin.ps1'
        # A COPY, set to a known starting point - unpinned, at a version of its
        # own - so these tests say nothing about whatever the real pin is today.
        $copy = [System.IO.File]::ReadAllText($script:pinScript)
        $copy = [regex]::Replace($copy, "(?m)^(\`$script:PACKAGE_SHA256\s*=\s*)'[^']*'", "`${1}''")
        $copy = [regex]::Replace($copy, "(?m)^(\`$script:VERSION\s*=\s*)'[^']*'", "`${1}'7.3.5'")
        [System.IO.File]::WriteAllText($script:pinScript, $copy, [System.Text.UTF8Encoding]::new($false))
        & (Join-Path $script:repoRoot 'tools' 'Update-GuestManifest.ps1') -GuestRoot $script:pinRoot 6>$null | Out-Null
        $script:pinStart = $copy
    }

    It 'pins an unpinned script: writes the pin, raises its version, and regenerates the manifest' {
        $zip = $script:zip
        $r = & $script:pinTool -ScriptPath $script:pinScript -GuestRoot $script:pinRoot `
            -Resolver { param($Url) 'https://download.microsoft.com/download/mana_vf_drivers_2_0_19_1.zip' } `
            -Downloader { param($Url, $Path) Copy-Item -LiteralPath $zip -Destination $Path }.GetNewClosure() `
            -SignatureOverride $script:sigAsMicrosoft 6>$null
        $r.Changed | Should -BeTrue
        $text = Get-Content $script:pinScript -Raw
        $text | Should -Match "(?m)^\`$script:PACKAGE_VERSION = '2\.0\.19\.1'"
        $text | Should -Match "(?m)^\`$script:PACKAGE_SHA256 = '$($script:zipSha)'"
        $text | Should -Match "(?m)^\`$script:PACKAGE_BYTES = '$((Get-Item $script:zip).Length)'"
        $text | Should -Match "(?m)^\`$script:VERSION = '7\.3\.6'"
        $manifest = Get-Content (Join-Path $script:pinRoot 'manifest.json') -Raw | ConvertFrom-Json
        (@($manifest.packages)[0]).sha256 | Should -Be $script:zipSha
        (@($manifest.scripts) | Where-Object name -eq 'Install-ManaDriver.ps1').sha256 |
            Should -Be (Get-FileHash $script:pinScript -Algorithm SHA256).Hash.ToLowerInvariant()
        (@($manifest.scripts) | Where-Object name -eq 'Install-ManaDriver.ps1').version | Should -Be '7.3.6'
        # MANA-PIN-SIG-1: the guest's check ran on the package, and passed.
        $r.SignatureCheck | Should -Be '1 catalog, 1 .sys and 2 .inf files'
    }

    It 'MANA-PIN-SIG-1: refuses a catalog nobody signed (the real signature read), and changes nothing' {
        Invoke-MwinPinRefused $script:zip $null '*would be refused by every Windows machine*x64?mana.cat in the pinned package does not have a valid signature from Microsoft: its signature status is NotSigned*It was not pinned.*'
        # The guest's own ending ("Nothing was installed.") is not part of a pin refusal.
        $zip = $script:zip
        $message = ''
        try {
            & $script:pinTool -ScriptPath $script:pinScript -GuestRoot $script:pinRoot `
                -Resolver { param($Url) 'https://download.microsoft.com/download/mana_vf_drivers_2_0_19_1.zip' } `
                -Downloader { param($Url, $Path) Copy-Item -LiteralPath $zip -Destination $Path }.GetNewClosure() 6>$null | Out-Null
        }
        catch { $message = $_.Exception.Message }
        $message | Should -Match '\)\. It was not pinned\.$'
        $message | Should -Not -Match 'Nothing was installed'
    }

    It 'MANA-PIN-SIG-1: refuses a catalog with a valid signature from a publisher that is not Microsoft' {
        Invoke-MwinPinRefused $script:zip $script:sigAsContoso '*would be refused by every Windows machine*signed by CN=Contoso Drivers, O=Contoso, and that certificate does not chain to a Microsoft root certificate*It was not pinned.*'
    }

    It 'MANA-PIN-SIG-1: refuses a .sys or an .inf file that no catalog lists (a file changed after it was signed)' {
        Invoke-MwinPinRefused $script:zipBadSys $script:sigAsMicrosoft '*would be refused by every Windows machine*The driver file x64?mana.sys in the pinned package*no catalog file in the package that Microsoft signed lists it*It was not pinned.*'
        Invoke-MwinPinRefused $script:zipBadInf $script:sigAsMicrosoft '*would be refused by every Windows machine*The driver file x64?mana.inf in the pinned package*no catalog file in the package that Microsoft signed lists it*It was not pinned.*'
    }

    It 'MANA-PIN-SIG-1: refuses a package with no catalog, and one whose catalog cannot be read' {
        Invoke-MwinPinRefused $script:zipNoCat $script:sigAsMicrosoft '*would be refused by every Windows machine*holds no catalog (.cat) file*It was not pinned.*'
        Invoke-MwinPinRefused $script:zipBadCat $script:sigAsMicrosoft '*would be refused by every Windows machine*the catalog file x64?mana.cat could not be read*It was not pinned.*'
    }

    It 'MANA-PIN-SIG-1: the check is the guest script''s own function, read from the script it pins (one rule)' {
        # A copy whose Test-DriverPackageSignatures refuses everything with a
        # text of its own: the tool must give that text, so it runs this rule,
        # not a copy of it.
        $code = [System.IO.File]::ReadAllText($script:pinScript)
        $marker = 'function Test-DriverPackageSignatures {'
        $code.Contains($marker) | Should -BeTrue
        $code = $code.Replace($marker, $marker + "`r`n    return @{ Checked = 'none'; Problem = 'the rule in the copy refused it' }")
        [System.IO.File]::WriteAllText($script:pinScript, $code, [System.Text.UTF8Encoding]::new($false))
        $script:pinStart = $code
        Invoke-MwinPinRefused $script:zip $script:sigAsMicrosoft '*would be refused by every Windows machine: the rule in the copy refused it*It was not pinned.*'
    }

    It 're-pins a pinned script to a newer file, and the same file twice changes nothing' {
        $zip = $script:zip
        $many = $script:zipMany
        $first = { param($Url, $Path) Copy-Item -LiteralPath $zip -Destination $Path }.GetNewClosure()
        $second = { param($Url, $Path) Copy-Item -LiteralPath $many -Destination $Path }.GetNewClosure()
        & $script:pinTool -ScriptPath $script:pinScript -GuestRoot $script:pinRoot `
            -Resolver { param($Url) 'https://download.microsoft.com/download/mana_vf_drivers_2_0_19_1.zip' } -Downloader $first `
            -SignatureOverride $script:sigAsMicrosoft 6>$null | Out-Null
        $r = & $script:pinTool -ScriptPath $script:pinScript -GuestRoot $script:pinRoot `
            -Resolver { param($Url) 'https://download.microsoft.com/download/mana_vf_drivers_2_0_20_3.zip' } -Downloader $second `
            -SignatureOverride $script:sigAsMicrosoft 6>$null
        $r.Changed | Should -BeTrue
        $text = Get-Content $script:pinScript -Raw
        $text | Should -Match "(?m)^\`$script:PACKAGE_SHA256 = '$($script:zipManySha)'"
        $text | Should -Match "(?m)^\`$script:PACKAGE_VERSION = '2\.0\.20\.3'"
        $text | Should -Match "(?m)^\`$script:VERSION = '7\.3\.7'"
        $again = & $script:pinTool -ScriptPath $script:pinScript -GuestRoot $script:pinRoot `
            -Resolver { param($Url) 'https://download.microsoft.com/download/mana_vf_drivers_2_0_20_3.zip' } -Downloader $second `
            -SignatureOverride $script:sigAsMicrosoft 6>$null
        $again.Changed | Should -BeFalse
        Get-Content $script:pinScript -Raw | Should -Be $text
    }

    It 'refuses a package with no INF that names the MANA device, and changes nothing' {
        $zip = $script:zipNoMana
        $download = { param($Url, $Path) Copy-Item -LiteralPath $zip -Destination $Path }.GetNewClosure()
        { & $script:pinTool -ScriptPath $script:pinScript -GuestRoot $script:pinRoot `
                -Resolver { param($Url) 'https://download.microsoft.com/download/mana_vf_drivers_2_0_19_1.zip' } `
                -Downloader $download 6>$null } |
            Should -Throw -ExpectedMessage '*holds no INF file that names the MANA device*'
        [System.IO.File]::ReadAllText($script:pinScript) | Should -Be $script:pinStart
    }

    It 'refuses a link that leads anywhere but a file on download.microsoft.com' {
        foreach ($bad in 'http://download.microsoft.com/download/mana_vf_drivers_2_0_19_1.zip',
                         'https://example.com/mana_vf_drivers_2_0_19_1.zip',
                         'https://download.microsoft.com/download/mana.exe') {
            # Built OUTSIDE the block Should runs: a closure made inside it does
            # not see $bad, returned nothing, and every case was refused for that.
            $resolve = { param($Url) $bad }.GetNewClosure()
            (& $resolve 'x') | Should -Be $bad
            { & $script:pinTool -ScriptPath $script:pinScript -GuestRoot $script:pinRoot -Resolver $resolve `
                    -Downloader { throw 'must not download' } 6>$null } | Should -Throw -ExpectedMessage '*Only an https .zip file on download.microsoft.com*'
        }
        [System.IO.File]::ReadAllText($script:pinScript) | Should -Be $script:pinStart
    }
}
