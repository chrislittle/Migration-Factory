<#
.SYNOPSIS
    The one way to run this project's checks locally: analyzer, ASD-STE100,
    inert-test detector, and the Pester unit suite - in CI's order.

.DESCRIPTION
    IT CHECKS THE PESTER INSTALL BEFORE IT USES IT, because that install has
    been silently corrupted three times.

    By 2026-09-02 the broken Pester install had come back again and again,
    and it needed a real fix.

    The cause is in CLAUDE.md: Pester's own scope owns $p, so a script that
    calls Invoke-Pester and then WRITES through a variable of that name writes
    over Pester itself. On 2026-08-27 that put a 1759-line HTML page into
    Pester.ScriptScope.ps1. What made it expensive was not the damage - it was
    that the damage is INVISIBLE until you run tests, and then every test in
    the file "fails" with a parse error naming a Pester source line and nothing
    of yours. Twenty minutes of reading your own change looking for a fault
    that is not there.

    So this asks the machine a question before it trusts it, and if the answer
    is bad it says so in one line and hands over the repair command.

    It also PINS the version. Several versions are installed here (Pester 6
    among them) and a bare Invoke-Pester takes the newest, which is not what
    CI runs.
#>
[CmdletBinding()]
param(
    # The version infra/part-versions.json pins, which .github/workflows/ci.yml
    # installs. Move it with tools/Test-VmfPartPinDrift.ps1 -UpdateBaseline.
    [Parameter()][string]$PesterVersion = '5.9.1',
    [Parameter()][string]$TestPath = 'tests/unit',
    # Skip the slow gates when you want the suite alone.
    [Parameter()][switch]$TestsOnly,
    # CI-SHARD-1: run one CI job's share of the files, as "Pester 2 of 3" in
    # the CI run is -Shard 2 -ShardCount 3. Both or neither.
    [Parameter()][int]$Shard,
    [Parameter()][int]$ShardCount
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {
    # ---- 0. is the toolchain itself intact? ------------------------------
    # Every installed version, not just the one we are about to use: a damaged
    # newer copy is exactly what a bare Invoke-Pester will pick up tomorrow.
    $damaged = @()
    foreach ($mod in Get-Module Pester -ListAvailable) {
        $dir = Split-Path $mod.Path -Parent
        $files = Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Extension -in '.ps1', '.psm1' }
        foreach ($file in $files) {
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
            if ($parseErrors.Count) {
                $damaged += [pscustomobject]@{
                    Version = $mod.Version
                    File    = $file.Name
                    First   = $parseErrors[0].Message
                }
            }
        }
    }
    if ($damaged.Count) {
        Write-Host ''
        Write-Host 'YOUR PESTER INSTALL IS DAMAGED. This is not a fault in your tests.' -ForegroundColor Red
        foreach ($d in $damaged) {
            Write-Host ("  Pester {0}  {1}" -f $d.Version, $d.File) -ForegroundColor Red
            Write-Host ("    {0}" -f $d.First) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host 'Repair it with:' -ForegroundColor Yellow
        foreach ($v in ($damaged.Version | Sort-Object -Unique)) {
            Write-Host ("  Install-Module Pester -RequiredVersion {0} -Force -SkipPublisherCheck -Scope CurrentUser" -f $v)
        }
        Write-Host ''
        Write-Host 'Cause and prevention: see the read-only-variable rule in CLAUDE.md.' -ForegroundColor DarkGray
        exit 2
    }

    # ---- 0b. pin Pester BEFORE anything else touches it ------------------
    # PSScriptAnalyzer LOADS THE PESTER ASSEMBLY - measured: no Pester module
    # is imported, but Pester 6.1.0.0 is in the AppDomain the moment
    # Invoke-ScriptAnalyzer returns. After that, importing 5.7.1 dies with
    # "Assembly with same name is already loaded", or worse gets far enough to
    # run 5.7.1's script against 6.1.0's types and fail deep inside Pester with
    # a missing-method error that names nothing of yours.
    #
    # So claim the version first. Nothing after this can pick a different one.
    Import-Module Pester -RequiredVersion $PesterVersion -Force
    # REVIEW-1: and the analyzer CI pins (CI-PIN-1). Unpinned, the gate below
    # loads the newest installed (a newer one than CI's, then), after which the pinned import
    # that CiRunner.Tests.ps1 runs fails nine of its tests in this process -
    # and the local gate checked with a different analyzer than CI.
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force

    if (-not $TestsOnly) {
        # ---- 1. analyzer ------------------------------------------------
        Write-Host 'PSScriptAnalyzer...' -ForegroundColor Cyan
        # PUBLIC-SYNC-1: lab/ does not ship to the public repository, so the
        # analyzer reads each folder that is there. src and tools always are.
        $found = @('src', 'tools', 'lab') | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
            Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
        }
        $analyzerErrors = @($found | Where-Object Severity -eq 'Error')
        if ($analyzerErrors.Count) {
            $found | Format-Table -AutoSize | Out-String | Write-Host
            throw "$($analyzerErrors.Count) PSScriptAnalyzer error(s)."
        }
        Write-Host ("  clean ({0} non-error finding(s))" -f @($found).Count) -ForegroundColor Green

        # ---- 2. ASD-STE100 ----------------------------------------------
        Write-Host 'Simplified Technical English...' -ForegroundColor Cyan
        # -Detailed, exactly as ci.yml calls it. WITHOUT it the tool PRINTS
        # "no findings" and that sentence IS its output, so a clean tree
        # counts as one finding and the runner fails on success. Found by
        # running it - which is the only way this kind of thing is found.
        $ste = ./tools/Test-SimplifiedEnglish.ps1 -Detailed
        # $ste.Count, NOT @($ste).Count - the tool returns an OBJECT carrying
        # a Count property, so wrapping it in an array makes a clean tree read
        # as one finding. ci.yml had it right; this did not. Found by running it.
        if ($ste.Count -gt 0) { throw "$($ste.Count) ASD-STE100 finding(s)." }
        Write-Host '  clean' -ForegroundColor Green

        # ---- 3. UX strings ----------------------------------------------
        Write-Host 'UX strings...' -ForegroundColor Cyan
        $ux = ./tools/Test-UxStrings.ps1
        if ($ux.Count -gt 0) { throw "$($ux.Count) UX string finding(s)." }
        Write-Host '  clean' -ForegroundColor Green

        # ---- 3b. dashboard behaviour ------------------------------------
        Write-Host 'Dashboard behaviour (JavaScript)...' -ForegroundColor Cyan
        $null = ./tools/Invoke-VmfJsTests.ps1
        Write-Host '  clean' -ForegroundColor Green

        # ---- 4. tests that cannot fail ----------------------------------
        Write-Host 'Tests that cannot fail...' -ForegroundColor Cyan
        $inert = ./tools/Test-InertTests.ps1
        if ($inert.Count -gt 0) { throw "$($inert.Count) test(s) that cannot fail." }
        Write-Host '  clean' -ForegroundColor Green
    }

    # ---- 4. the suite, on the version CI uses ---------------------------
    # CI-SPEED-3: a folder runs as groups of files at once, exactly as CI runs
    # it. TEST-AZURE-GUARD-1: and ONE file goes the same way, as one group.
    # It used to run here, in the caller's own process, where the tool's
    # second floor - test processes that cannot reach Azure - does not exist.
    # One file is what a person runs most, and what reached Azure on
    # 2026-10-10. The tool prints every failure with its message (SAY-WHY-1).
    # REVIEW-1: cleared first. On success the tool does not set it, so a
    # native command that failed earlier in the caller's session would make a
    # green run exit 1.
    $global:LASTEXITCODE = 0
    $shardArgs = @{}
    if ($PSBoundParameters.ContainsKey('Shard')) { $shardArgs.Shard = $Shard }
    if ($PSBoundParameters.ContainsKey('ShardCount')) { $shardArgs.ShardCount = $ShardCount }
    ./tools/Invoke-VmfPesterParallel.ps1 -TestPath $TestPath -PesterVersion $PesterVersion @shardArgs
    if ($LASTEXITCODE) { exit 1 }
}
finally {
    Pop-Location
}
