#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANA-READY-ADVICE-1: the Windows MANA readiness check (Test-ManaReady.ps1)
# told a machine with no mana*.sys to "apply latest Windows updates before
# migration". Two things in the product make that wrong:
#   - AN-KEEP-1: a Windows machine with no mana*.sys before the move is normal.
#     Windows installs the driver when the MANA hardware appears.
#   - MANA-WIN-1: when the target can use MANA, GUEST_PREP reads the driver
#     store and adds the pinned MANA driver when the store has none
#     (Install-ManaDriver.ps1, Test-VmfManaDriverInstallWanted).
# So a missing file is a FACT (INFO), not advice, and it never names a tool the
# customer may not use. And it is not a reason for NEEDS_PREP.
#
# The script is RUN, under Windows PowerShell 5.1 when it is here (the
# interpreter RunCommand uses), with only the reads of the machine replaced:
# Get-CimInstance, Get-ChildItem and Get-NetAdapter.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:scriptPath = Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-ManaReady.ps1'
    $script:work = New-VmfTestTemp -Prefix 'mready'

    $winPs = Get-Command powershell.exe -ErrorAction SilentlyContinue
    $script:shell = if ($winPs) { $winPs.Source } else { (Get-Process -Id $PID).Path }

    $harness = @'
param([string]$ScenarioPath, [string]$GuestScript)
$s = Get-Content -LiteralPath $ScenarioPath -Raw | ConvertFrom-Json
function Get-CimInstance { param([Parameter(Position = 0)]$ClassName) [pscustomobject]@{ Caption = 'Microsoft Windows Server (test)'; Version = [string]$s.osVersion } }
function Get-ChildItem {
    [CmdletBinding()] param([Parameter(Position = 0)]$Path, $Filter)
    if (-not $s.driverFile) { return }
    [pscustomobject]@{ Name = 'mana.sys'; VersionInfo = [pscustomobject]@{ FileVersion = '2.0.18.52' } }
}
function Get-NetAdapter { [CmdletBinding()] param() return @() }
& $GuestScript
'@
    $script:harnessPath = Join-Path $script:work 'harness.ps1'
    [System.IO.File]::WriteAllText($script:harnessPath, $harness, [System.Text.UTF8Encoding]::new($true))

    function script:Invoke-MreadyScenario {
        param([hashtable]$Scenario)
        $scenarioPath = Join-Path $script:work ('scenario-{0}.json' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Scenario | ConvertTo-Json | Set-Content -LiteralPath $scenarioPath -Encoding utf8
        $raw = & $script:shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:harnessPath -ScenarioPath $scenarioPath -GuestScript $script:scriptPath 2>&1
        $json = [string](@($raw | Where-Object { [string]$_ -match '^\{' }) | Select-Object -Last 1)
        if (-not $json) { throw "the guest script gave no JSON: $($raw -join ' ')" }
        ConvertFrom-VmfGuestOutput -RawOutput $json
    }
    function script:Get-MreadyCheck([object]$Doc, [string]$Name) {
        @($Doc.checks) | Where-Object { [string]$_.name -eq $Name } | Select-Object -First 1
    }
}
AfterAll { Remove-VmfTestTemp }

Describe 'MANA-READY-ADVICE-1: a Windows machine with no mana*.sys gets a fact, not advice' {
    It 'no mana*.sys: the check is INFO, and the result is READY on a supported version' {
        $doc = Invoke-MreadyScenario @{ osVersion = '10.0.20348'; driverFile = $false }
        $check = Get-MreadyCheck $doc 'mana driver file'
        $check | Should -Not -BeNullOrEmpty
        $check.status | Should -Be 'INFO'
        $doc.result | Should -Be 'READY'
    }

    It 'no mana*.sys: the detail does not tell a person to apply updates, and names no update tool' {
        $doc = Invoke-MreadyScenario @{ osVersion = '10.0.20348'; driverFile = $false }
        $detail = [string](Get-MreadyCheck $doc 'mana driver file').detail
        $detail | Should -Not -BeNullOrEmpty
        $detail | Should -Not -Match '(?i)update'
        $detail | Should -Not -Match '(?i)apply'
    }

    It 'no mana*.sys: the detail is the fact only (2026-11-11: short line)' {
        $doc = Invoke-MreadyScenario @{ osVersion = '10.0.20348'; driverFile = $false }
        $detail = [string](Get-MreadyCheck $doc 'mana driver file').detail
        $detail | Should -BeExactly 'No mana*.sys file is in System32\drivers.'
    }

    It 'a mana*.sys: PASS with its name and version, as before' {
        $doc = Invoke-MreadyScenario @{ osVersion = '10.0.20348'; driverFile = $true }
        $check = Get-MreadyCheck $doc 'mana driver file'
        $check.status | Should -Be 'PASS'
        $check.detail | Should -Match 'mana\.sys version 2\.0\.18\.52'
        $doc.result | Should -Be 'READY'
        $doc.facts.driverVersion | Should -Be '2.0.18.52'
    }

    It 'no mana*.sys: the driver version fact is empty, and the os fact is still Windows' {
        $doc = Invoke-MreadyScenario @{ osVersion = '10.0.20348'; driverFile = $false }
        [string]$doc.facts.driverVersion | Should -BeNullOrEmpty
        $doc.facts.os | Should -Be 'Windows'
    }
}

# MANA-READY-OS-FLOOR-1: the OS check said "<version> is below WS2019 - MANA
# unsupported" and set NEEDS_PREP below Windows Server 2019. Microsoft's
# accelerated networking overview (driver-floors.json, mana.windows.
# supportedProducts) lists Windows Server 2016. So the OS line is a fact: the
# version read. Only a version below every Windows Server release Microsoft
# lists says so, in Microsoft's terms, and only that one is NEEDS_PREP.
Describe 'MANA-READY-OS-FLOOR-1: the OS version check agrees with the product data' {
    BeforeAll {
        # The build of each Windows Server release (Microsoft's release
        # information). A release the data names and this table does not is a
        # test failure, never a silent pass.
        $script:serverBuilds = @{ '2016' = '10.0.14393'; '2019' = '10.0.17763'; '2022' = '10.0.20348'; '2025' = '10.0.26100' }
        $floors = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'driver-floors.json') -Raw | ConvertFrom-Json
        $years = @($floors.mana.windows.supportedProducts | ForEach-Object { if ([string]$_ -match '^Windows Server (\d{4})$') { $Matches[1] } })
        $script:lowestYear = ($years | Sort-Object | Select-Object -First 1)
        $script:lowestName = "Windows Server $script:lowestYear"
        $script:lowestBuild = $script:serverBuilds[[string]$script:lowestYear]
        $script:guestCode = Get-VmfCodeOnly -Path $script:scriptPath
    }

    It 'the data lists a Windows Server release this test knows the build of' {
        $script:lowestYear | Should -Not -BeNullOrEmpty
        $script:lowestBuild | Should -Not -BeNullOrEmpty
    }

    It 'the script holds the lowest Windows Server release the data lists, by name and by build' {
        $script:guestCode | Should -Match ([regex]::Escape("`$script:LowestListedBuild = '$script:lowestBuild'"))
        $script:guestCode | Should -Match ([regex]::Escape("`$script:LowestListedName = '$script:lowestName'"))
    }

    It 'Windows Server 2016 (10.0.14393): the version as a fact, no "unsupported", and READY' {
        $doc = Invoke-MreadyScenario @{ osVersion = '10.0.14393'; driverFile = $false }
        $check = Get-MreadyCheck $doc 'os version floor'
        $check.status | Should -Be 'INFO'
        $check.detail | Should -BeExactly 'Version 10.0.14393 is installed.'
        $check.detail | Should -Not -Match '(?i)unsupported|below'
        $doc.result | Should -Be 'READY'
        $doc.facts.osVersion | Should -Be '10.0.14393'
    }

    It 'Windows Server 2022 (10.0.20348): the version as a fact, and READY' {
        $doc = Invoke-MreadyScenario @{ osVersion = '10.0.20348'; driverFile = $true }
        $check = Get-MreadyCheck $doc 'os version floor'
        $check.status | Should -Be 'INFO'
        $check.detail | Should -BeExactly 'Version 10.0.20348 is installed.'
        $doc.result | Should -Be 'READY'
    }

    It 'the lowest listed build itself is a listed release: no below line' {
        $doc = Invoke-MreadyScenario @{ osVersion = $script:lowestBuild; driverFile = $false }
        (Get-MreadyCheck $doc 'os version floor').status | Should -Be 'INFO'
        $doc.result | Should -Be 'READY'
    }

    It 'below every listed release (Windows Server 2012 R2, 6.3.9600): the version and the Microsoft list, NEEDS_PREP' {
        $doc = Invoke-MreadyScenario @{ osVersion = '6.3.9600'; driverFile = $false }
        $check = Get-MreadyCheck $doc 'os version floor'
        $check.status | Should -Be 'WARN'
        $check.detail | Should -BeExactly 'Version 6.3.9600 is installed. Microsoft lists Windows Server 2016 and later.'
        $check.detail | Should -Not -Match '(?i)unsupported'
        $doc.result | Should -Be 'NEEDS_PREP'
    }

    It 'one build below the lowest listed release is below it' {
        $v = [version]$script:lowestBuild
        $doc = Invoke-MreadyScenario @{ osVersion = ('{0}.{1}.{2}' -f $v.Major, $v.Minor, ($v.Build - 1)); driverFile = $false }
        (Get-MreadyCheck $doc 'os version floor').status | Should -Be 'WARN'
        $doc.result | Should -Be 'NEEDS_PREP'
    }
}