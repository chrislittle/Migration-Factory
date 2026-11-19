#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
FACADE-PASS-SHARE-1: a store call does not wait for a thread-pool thread that
Azure PowerShell's data collection holds.

MEASURED on the lab install (Application Insights, 2026-11-10): during every
schedule pass about 270 thread-pool threads of the worker process were busy,
with the processor idle and the pool's minimum raised to 64; each of the
pass's about 530 store calls (about 2.5 a second) took 350-440 ms on average,
the longest about 1030 ms, in steps of about 500 ms. Between passes the
threads fell back to 6-9.

MEASURED on this computer (_StoreAzTelemetryPass.ps1: the REAL Az.Accounts
5.5.2, two processors, every request to a host outside the computer sent to a
proxy that never answers): 300 store calls, each asking Get-AzAccessToken for
its token as the service does. With Azure PowerShell's data collection on (its
default): 302 busy pool threads, median 1006 ms, the longest 1030 ms, 59 calls
under 50 ms and 240 between 250 and 1500 ms. With it off: 6 busy threads,
median 1.1 ms, the longest 32 ms. Each Az cmdlet call sends its usage data
from a pool thread that waits for the send.

So the store client turns the data collection off for the process when it is
made (Set-VmfAzDataCollectionOff), and says so in the VMF-POOL line and in
each VMF-CALLS line (azData).
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:modulePath = Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1'
    Import-Module $script:modulePath -Force
    . (Join-Path $PSScriptRoot '_ThreadPoolStarved.ps1')
    . (Join-Path $PSScriptRoot '_AzStandIns.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # One child process: the store client, and so the setting, is made once a
    # process. A stand-in module named Az.Accounts records each call.
    # -Mode: off (the setting reads back False), stuck (it reads back True),
    # throws (Update-AzConfig throws), absent (no Az.Accounts module loaded).
    $script:RunChild = { param([string]$Mode)
        $childScript = @'
param($m, $helper, $mode)
$ErrorActionPreference = 'Stop'
. $helper
$global:azCalls = [System.Collections.Generic.List[string]]::new()
$global:azMode = $mode
function Global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = 'stand-in-token' } }
if ($mode -ne 'absent') {
    New-Module -Name Az.Accounts -ScriptBlock {
        function Update-AzConfig { param($EnableDataCollection, $Scope, $WarningAction)
            $global:azCalls.Add("Update-AzConfig -EnableDataCollection $EnableDataCollection -Scope $Scope")
            if ($global:azMode -eq 'throws') { throw 'the setting was refused' }
            [pscustomobject]@{ Key = 'EnableDataCollection'; Value = [bool]$EnableDataCollection; Scope = $Scope }
        }
        function Get-AzConfig { param([switch]$EnableDataCollection, $WarningAction)
            $global:azCalls.Add('Get-AzConfig')
            [pscustomobject]@{ Key = 'EnableDataCollection'; Value = ($global:azMode -eq 'stuck'); Scope = 'Process' }
        }
        Export-ModuleMember -Function Update-AzConfig, Get-AzConfig
    } | Import-Module
}
else {
    # Present as commands, with no Az.Accounts module: never called.
    function Global:Update-AzConfig { $global:azCalls.Add('Update-AzConfig') }
    function Global:Get-AzConfig { $global:azCalls.Add('Get-AzConfig') }
}
Import-Module $m -Force
$server = [VmfThreadServer]::new()
try {
    $info = @(& (Get-Module VmMigrationFactory) { param($u)
        Start-VmfCallTimings
        $r = Invoke-VmfStorageRequest -Method GET -Uri $u
        $null = Get-VmfStorageHttpClient
        Write-Output ([pscustomobject]@{ status = $r.StatusCode })
        Complete-VmfCallTimings
    } "$($server.BaseUri)cont/doc1.json" 6>&1)
    $answer = @($info | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
    $lines = @($info | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
    [pscustomobject]@{
        status = $answer.status
        calls  = @($global:azCalls)
        pool   = @($lines | Where-Object { $_ -like 'VMF-POOL *' } | ForEach-Object { $_ -replace '^VMF-POOL ', '' })
        call   = @($lines | Where-Object { $_ -like 'VMF-CALLS *' } | ForEach-Object { $_ -replace '^VMF-CALLS ', '' })
    } | ConvertTo-Json -Compress -Depth 4
}
finally { $server.Dispose() }
'@
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-azdata-$([guid]::NewGuid().ToString('n')).ps1"
        Set-Content -LiteralPath $file -Value $childScript -Encoding utf8NoBOM
        try {
            $out = @(& ([System.Environment]::ProcessPath) -NoProfile -File $file -m $script:modulePath -helper (Join-Path $PSScriptRoot '_ThreadPoolStarved.ps1') -mode $Mode 2>&1)
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        $line = @($out | ForEach-Object { "$_" } | Where-Object { $_ -like '{"status":*' }) | Select-Object -Last 1
        $line | Should -Not -BeNullOrEmpty -Because "$($out -join ' | ')"
        $r = $line | ConvertFrom-Json
        [pscustomobject]@{
            Status = $r.status
            Calls  = @($r.calls)
            Pool   = @($r.pool | ForEach-Object { $_ | ConvertFrom-Json })
            Call   = @($r.call | ForEach-Object { $_ | ConvertFrom-Json })
        }
    }
}
AfterAll {
    Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'FACADE-PASS-SHARE-1: the store client turns Azure PowerShell''s data collection off for the process' {
    It 'turns it off at Process scope once, when the process makes the store client, and reads it back' {
        $r = & $script:RunChild 'off'
        $r.Status | Should -Be 200
        $r.Calls | Should -Be @('Update-AzConfig -EnableDataCollection False -Scope Process', 'Get-AzConfig') -Because 'once a process, at Process scope (nothing written to disk), then read back'
        @($r.Pool).Count | Should -Be 1
        $r.Pool[0].azData | Should -BeExactly 'off'
        $r.Call[0].pool.azData | Should -BeExactly 'off' -Because 'each service call''s line says what the process runs with'
    }

    It 'says on when the setting does not read back off' {
        $r = & $script:RunChild 'stuck'
        $r.Status | Should -Be 200
        $r.Pool[0].azData | Should -BeExactly 'on'
        $r.Call[0].pool.azData | Should -BeExactly 'on'
    }

    It 'makes the store client and sends store requests when the change throws, and says failed' {
        $r = & $script:RunChild 'throws'
        $r.Status | Should -Be 200 -Because 'a setting that is refused must never stop a store request'
        $r.Pool[0].azData | Should -BeExactly 'failed'
        $r.Call[0].pool.azData | Should -BeExactly 'failed'
    }

    It 'changes nothing when Az.Accounts is not loaded, and says notLoaded' {
        $r = & $script:RunChild 'absent'
        $r.Status | Should -Be 200
        @($r.Calls).Count | Should -Be 0 -Because 'it never loads Az.Accounts and never calls a command that is not that module''s'
        $r.Pool[0].azData | Should -BeExactly 'notLoaded'
    }

    It 'turns it off before the pool line is built and before the client is kept' {
        $file = Join-Path $script:repo 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsStorage.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-VmfAzDataCollectionOff' }, $true)
        $code = Get-VmfCodeOnly -Text $fn.Extent.Text -Language PowerShell
        $code | Should -Match 'Update-AzConfig\s+-EnableDataCollection\s+\$false\s+-Scope\s+Process' -Because 'Process scope: never written to disk, and every runspace of the process sees it'
        $code | Should -Not -Match 'Import-Module|CurrentUser' -Because 'it never loads Az.Accounts and never writes a user setting'
    }
}

Describe 'FACADE-PASS-SHARE-1: a timer pass through the real Az.Accounts module, with every outside request hanging' {
    BeforeDiscovery {
        # Az.Accounts is not installed in CI. Where it is, this runs it for real
        # against local stand-ins (no Azure, nothing leaves the computer).
        $script:azVersion = @(Get-Module -ListAvailable -Name Az.Accounts | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1 | ForEach-Object { $_.Version.ToString() })
        $script:noAz = $script:azVersion.Count -eq 0
    }

    It 'answers the pass''s store calls in milliseconds and keeps the thread pool free' -Skip:$script:noAz {
        $version = @(Get-Module -ListAvailable -Name Az.Accounts | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1)[0].Version.ToString()
        $hole = [VmfBlackHole]::new()
        # Import-Module Az.Accounts waits about 100 s for a request to the real
        # ARM address when it hangs (MEASURED here): refused at once, it takes
        # about 0.4 s. Every other outside request hangs, the usage data too.
        $hole.Refused = @('management.azure.com')
        $set = @{ HTTPS_PROXY = $hole.ProxyUri; HTTP_PROXY = $hole.ProxyUri; NO_PROXY = 'localhost,127.0.0.1'; DOTNET_PROCESSOR_COUNT = '2'; POWERSHELL_UPDATECHECK = 'Off'; POWERSHELL_TELEMETRY_OPTOUT = '1' }
        $saved = @{}
        try {
            foreach ($k in $set.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
            $out = @(& ([System.Environment]::ProcessPath) -NoProfile -File (Join-Path $PSScriptRoot '_StoreAzTelemetryPass.ps1') -ModulePath $script:modulePath -AzVersion $version -Calls 300 2>&1)
        }
        finally {
            foreach ($k in $set.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            $hole.Dispose()
        }
        $line = @($out | ForEach-Object { "$_" } | Where-Object { $_ -like '{"ms":*' }) | Select-Object -Last 1
        $line | Should -Not -BeNullOrEmpty -Because "the pass must run: $($out -join ' | ')"
        $result = $line | ConvertFrom-Json
        $result.tokenRequests | Should -BeLessOrEqual 3 -Because 'Az.Accounts keeps the token; each call still asks it'
        $sorted = @($result.ms | Sort-Object)
        $median = $sorted[[int]($sorted.Count / 2)]
        $mean = ($sorted | Measure-Object -Average).Average
        $slow = @($sorted | Where-Object { $_ -ge 250 }).Count
        $result.maxBusy | Should -BeLessThan 40 -Because "with the data collection on, 302 pool threads were busy here and about 270 on the lab install (here: $($result.maxBusy))"
        $median | Should -BeLessThan 50 -Because "with the data collection on, the median was 1006 ms here (here: median $median ms, mean $([int]$mean) ms, longest $($sorted[-1]) ms)"
        $mean | Should -BeLessThan 100
        $slow | Should -BeLessOrEqual 3 -Because 'with the data collection on, 240 of 300 calls took 250 ms or more'
        $result.dataCollection | Should -BeFalse -Because 'the store client turned it off for the process'
    }
}
