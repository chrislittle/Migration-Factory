# TEST-BASH-WSL-1 (2026-11-15): the ONE place a test asks how to run
# bash. Dot-source it, then:
#   Get-VmfTestBash                  which bash, or $null when there is none
#   ConvertTo-VmfTestBashPath <path> a Windows path in the form that bash reads
#   Invoke-VmfTestBash -ArgumentList <args> [-Environment @{...}]
#
# Why: on a Windows PC every start of Git's bash.exe takes 0.8 to 2.4 s
# (measured; a Process Monitor trace showed file filters pause each open of
# that exe). A file that starts bash thousands of times took 37 minutes. A WSL
# start takes about 0.28 s, and inside WSL bash forks natively.
#
# The choice:
#   Linux (or macOS)  the bash on PATH, exactly as before.
#   Windows           WSL bash when a distribution runs bash as a user that is
#                     not root; else Git's bash, as before.
#   GitHub Actions    Git's bash, as before: CI behaves as it did.
#   VMF_TEST_BASH     'git' or 'wsl' forces that one (nothing, if it is absent).
#
# Not root, because the guest scripts are written to change a real machine
# (nvme-fix.sh edits grub and the initramfs when it may). Under a user they
# cannot change the distribution; under root they could.
#
# A path a test gives bash goes through ConvertTo-VmfTestBashPath:
#   C:\x\y  ->  /mnt/c/x/y (WSL)  |  /c/x/y (Git's bash)  |  unchanged (Linux)
# A variable a test sets for the script goes through -Environment: WSL takes
# only the names in WSLENV across, so Invoke-VmfTestBash adds them there. The
# values pass as they are; give a path in the bash form.

function Get-VmfGitBashPath {
    # Git's bash, never a WSL launcher in System32 or WindowsApps (with no
    # distribution, those print nothing). The search the tests made before.
    @(
        @(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source) +
        @(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git' 'bin' 'bash.exe' }) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) -and $_ -notmatch 'WindowsApps|System32' }
    ) | Select-Object -First 1
}

function ConvertFrom-VmfWslProbe {
    # Reads the one line the probe prints: "<bash version>|<uid>|<wslpath -a C:/>".
    # Returns the mount root ('/mnt/') when WSL bash may be used, else $null.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $line = @("$Text" -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d[^|]*\|\d+\|/' }) | Select-Object -First 1
    if (-not $line) { return $null }
    $parts = $line -split '\|'
    if ($parts.Count -ne 3) { return $null }
    if ([int]$parts[1] -eq 0) { return $null }
    if ($parts[2] -match '^(/(?:.*/)?)c/$') { return $matches[1] }
    $null
}

function Select-VmfTestBash {
    # Pure: which bash to use, from what was found. Returns the object
    # Get-VmfTestBash returns, or $null.
    param(
        [bool]$OnWindows,
        [string]$Want = '',
        [bool]$InCi,
        [string]$NativeBash,
        [string]$GitBash,
        [string]$WslExe,
        [string]$WslMountRoot
    )
    $Want = "$Want".Trim().ToLowerInvariant()
    if (-not $OnWindows) {
        if (-not $NativeBash) { return $null }
        return [pscustomobject]@{ Kind = 'native'; Exe = $NativeBash; Prefix = @(); MountRoot = '' }
    }
    $wsl = if ($WslExe -and $WslMountRoot) { [pscustomobject]@{ Kind = 'wsl'; Exe = $WslExe; Prefix = @('-e', 'bash'); MountRoot = $WslMountRoot } }
    $git = if ($GitBash) { [pscustomobject]@{ Kind = 'git'; Exe = $GitBash; Prefix = @(); MountRoot = '/' } }
    switch ($Want) {
        'git' { return $git }
        'wsl' { return $wsl }
    }
    if ($InCi) { return $git }
    if ($wsl) { return $wsl }
    $git
}

function Get-VmfWslMountRoot {
    # Starts WSL bash once and reads the probe. $null when there is no WSL,
    # no distribution, no bash, a root user, or no answer in 30 seconds.
    $exe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32' 'wsl.exe' }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return $null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($a in @('-e', 'bash', '-c', 'printf "%s|%s|%s\n" "$BASH_VERSION" "$(id -u)" "$(wslpath -a C:/ 2>/dev/null)"')) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $read = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(30000)) { try { $proc.Kill($true) } catch { $null = $_ }; return $null }
        if ($proc.ExitCode -ne 0) { return $null }
        ConvertFrom-VmfWslProbe -Text $read.Result
    }
    catch { $null }
}

function Get-VmfTestBash {
    # Which bash, cached for the session: the probe starts WSL once.
    $want = "$env:VMF_TEST_BASH".Trim().ToLowerInvariant()
    $inCi = "$env:GITHUB_ACTIONS" -eq 'true'
    $key = "$want|$inCi"
    if ($global:VmfTestBashChoice -and $global:VmfTestBashChoice.Key -eq $key) { return $global:VmfTestBashChoice.Value }
    $onWindows = [bool]$IsWindows
    $native = if (-not $onWindows) { @(Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source)[0] }
    $git = if ($onWindows) { Get-VmfGitBashPath }
    $root = $null
    if ($onWindows -and $want -ne 'git' -and ($want -eq 'wsl' -or -not $inCi)) { $root = Get-VmfWslMountRoot }
    $wslExe = if ($root) { Join-Path $env:SystemRoot 'System32' 'wsl.exe' }
    $value = Select-VmfTestBash -OnWindows $onWindows -Want $want -InCi $inCi -NativeBash $native -GitBash $git -WslExe $wslExe -WslMountRoot $root
    $global:VmfTestBashChoice = @{ Key = $key; Value = $value }
    $value
}

function ConvertTo-VmfTestBashPath {
    # Pure when -Kind is given: a Windows path in the form the chosen bash
    # reads. A path that is already a bash path passes unchanged.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Kind,
        [string]$MountRoot
    )
    if (-not $PSBoundParameters.ContainsKey('Kind')) {
        $bash = Get-VmfTestBash
        $Kind = if ($bash) { $bash.Kind } else { 'native' }
        if (-not $PSBoundParameters.ContainsKey('MountRoot') -and $bash) { $MountRoot = $bash.MountRoot }
    }
    if ($Kind -notin 'wsl', 'git') { return $Path }
    if ($Path -match '^[\\/]{2}') { throw "TEST-BASH-WSL-1: a UNC path has no form in $Kind bash: $Path" }
    if ($Path -match '^([A-Za-z]):(?:[\\/](.*))?$') {
        $root = if ($Kind -eq 'wsl') { if ($MountRoot) { $MountRoot } else { '/mnt/' } } else { '/' }
        if (-not $root.EndsWith('/')) { $root += '/' }
        return $root + $matches[1].ToLowerInvariant() + '/' + ("$($matches[2])" -replace '\\', '/')
    }
    $Path -replace '\\', '/'
}

function Invoke-VmfTestBash {
    # Runs the chosen bash with these arguments and these variables. The
    # variables are set for the call and put back after it. stdout and stderr
    # stay apart (use 2>&1 at the call), and $LASTEXITCODE is the script's.
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [hashtable]$Environment = @{},
        $Bash = (Get-VmfTestBash)
    )
    if (-not $Bash) { throw 'TEST-BASH-WSL-1: no bash on this machine. Give the test a -Skip that asks Get-VmfTestBash.' }
    $names = @($Environment.Keys | ForEach-Object { "$_" })
    $saved = @{}
    foreach ($n in @($names + 'WSLENV')) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, [string]$Environment[$n]) }
        if ($Bash.Kind -eq 'wsl' -and $names.Count) {
            $across = @(@("$($saved['WSLENV'])" -split ':' | Where-Object { $_ }) + $names) | Select-Object -Unique
            [Environment]::SetEnvironmentVariable('WSLENV', ($across -join ':'))
        }
        & $Bash.Exe @($Bash.Prefix) @ArgumentList
    }
    finally {
        foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
}
