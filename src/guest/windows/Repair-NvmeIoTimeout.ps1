<#
.SYNOPSIS
    Put stornvme's IoTimeoutValue back to 240 AFTER the first boot on NVMe.

.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand, once the machine is up on its
    new hardware. Idempotent.

    WHY THIS EXISTS, measured rather than assumed. Microsoft's Azure-NVMe-Utils
    2026082514 changelog says IoTimeout "gets reset after first boot on NVMe"
    and ships a post-conversion command for it. The UPST-2 drill reproduced it
    exactly, on vmf-upst2-win:

        before the conversion   ControlSet001 = 240   ControlSet002 = 240
        after the first NVMe boot ControlSet001 = 10    ControlSet002 = 240

    So the value we set during prep does NOT survive - Windows re-initialises
    the parameter for the newly enumerated controller in the ControlSet it
    booted from. Setting it earlier cannot fix that; it has to be set again
    afterwards.

    What 10 seconds costs: an NVMe I/O that stalls longer than the timeout is
    treated as a failed device. 240 is what Microsoft specifies for Azure NVMe,
    where a stall can legitimately outlast a short timeout during host
    maintenance. A machine left at 10 is not visibly broken - it is a machine
    that will drop a disk under a transient stall that it should have ridden out.

    ALL ControlSets, then a synchronous flush, for the same reason as prep: the
    set the machine boots from next is not necessarily the one it is in now.

    Output contract: schemas/guest-output.schema.json.
    result: FIXED | NO_CHANGE | BLOCKED
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.0.0'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:facts = [ordered]@{}
$script:changed = $false
$script:osCaption = ''
$script:ioBefore = [System.Collections.Generic.List[string]]::new()

# GUEST-2: facts are DECLARED fields now, not checks with a naming convention.
# They used to travel as "fact:<name>" checks because the contract had nowhere
# to put them - which meant nothing declared which facts existed, so a guest
# could simply omit one and nothing noticed. That is how every Windows machine
# came to report an UNKNOWN driver state.
function Add-Fact {
    param([string]$Name, [string]$Value)
    $script:facts[$Name] = [string]$Value
}

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
    if ($Status -eq 'FIXED') { $script:changed = $true }
}

function Emit {
    param([string]$Result, [string]$ErrorDetail = $null)
    $doc = [ordered]@{
        schema  = 'vmf.guest/2'
        script  = 'Repair-NvmeIoTimeout.ps1'
        version = $script:VERSION
        os      = $script:osCaption
        result  = $Result
        checks  = @($script:checks)
        facts = $script:facts; warnings = @()
    }
    if ($ErrorDetail) { $doc.error = $ErrorDetail }
    $doc | ConvertTo-Json -Depth 6 -Compress
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $script:osCaption = '{0} ({1})' -f $os.Caption, $os.Version

    $controlSets = @(Get-ChildItem 'HKLM:\SYSTEM' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^ControlSet\d+$' } |
        ForEach-Object { $_.PSChildName })

    if ($controlSets.Count -eq 0) {
        Add-Check 'ControlSets' 'FAIL' 'none found'
        Emit -Result 'BLOCKED' -ErrorDetail 'No ControlSets found under HKLM:\SYSTEM'
        exit 0
    }

    foreach ($cs in $controlSets) {
        $paramsPath = "HKLM:\SYSTEM\$cs\Services\stornvme\Parameters"
        if (-not (Test-Path $paramsPath)) {
            New-Item -Path $paramsPath -Force | Out-Null
            Add-Check "$cs stornvme Parameters" 'FIXED' 'key created'
        }
        $cur = (Get-ItemProperty -Path $paramsPath -Name 'IoTimeoutValue' -ErrorAction SilentlyContinue).IoTimeoutValue
        if ($cur -eq 240) {
            Add-Check "$cs IoTimeoutValue" 'PASS' '240'
        }
        else {
            Set-ItemProperty -Path $paramsPath -Name 'IoTimeoutValue' -Value 240 -Type DWord
            Add-Check "$cs IoTimeoutValue" 'FIXED' "was '$cur', restored to 240"
        }
        # A fact, not a judgement: the engine decides what a reset means.
        # GUEST-2: one flat fact carrying every ControlSet, rather than one fact
        # per ControlSet with a dynamic name - a declared facts contract cannot
        # describe names it cannot know.
        $script:ioBefore.Add("$cs=$(if ($null -eq $cur) { 'not set' } else { $cur })") | Out-Null
    }

    try {
        $systemKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM', $false)
        $systemKey.Flush()
        $systemKey.Close()
        Add-Check 'registry flush' 'PASS' 'SYSTEM hive flushed synchronously'
    }
    catch {
        Add-Check 'registry flush' 'WARN' "flush threw: $($_.Exception.Message)"
    }

    foreach ($cs in $controlSets) {
        $after = (Get-ItemProperty -Path "HKLM:\SYSTEM\$cs\Services\stornvme\Parameters" -Name 'IoTimeoutValue' -ErrorAction SilentlyContinue).IoTimeoutValue
        if ($after -ne 240) {
            Add-Check "$cs post-flush verify" 'FAIL' "still '$after'"
            Emit -Result 'BLOCKED' -ErrorDetail "$cs IoTimeoutValue did not persist"
            exit 0
        }
    }
    Add-Check 'post-flush verify' 'PASS' '240 in every ControlSet'
    Add-Fact 'ioTimeoutBefore' (($script:ioBefore) -join ' ')

    if ($script:changed) { Emit -Result 'FIXED' } else { Emit -Result 'NO_CHANGE' }
}
catch {
    Add-Check 'unhandled' 'FAIL' $_.Exception.Message
    Emit -Result 'BLOCKED' -ErrorDetail $_.Exception.Message
}
