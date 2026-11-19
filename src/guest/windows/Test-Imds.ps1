<#
.SYNOPSIS
    Ask the Instance Metadata Service what this machine is (VERIFY-FP-1).
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand, under Windows PowerShell 5.1
    (CLAUDE.md): no -NoProxy, no ternary, no null-coalescing.

    Microsoft (instance-metadata-service): IMDS is at 169.254.169.254, and
    requests "must be sent using the VM's primary NIC and primary IP, and DHCP
    must be enabled". So one answer proves the part of the network a move
    rebuilds, and the answer says which size the machine is on and its
    security profile (securityType needs api-version 2021-12-13 or later).
    Rules from the same page: the header Metadata: true, no proxy, at most 5
    requests a second, and retry a 410 "for a max of 70 seconds" (and a 429 or
    a 5xx). So: tries two seconds apart, for up to 70 seconds, and the first
    answer ends it.

    Facts only. The ENGINE judges them against the plan and against the
    reading before the move; a machine that never reaches IMDS (a static
    address inside the guest) reports 'no' and is not failed for it.

    Output contract: schemas/guest-output.schema.json (vmf.guest/3). result:
    READY, or BLOCKED when the script itself failed (the engine reads that as
    unknown).
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.1.0'
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

function Get-ImdsCompute {
    $uri = 'http://169.254.169.254/metadata/instance/compute?api-version=2023-07-01'
    $deadline = (Get-Date).AddSeconds(70)
    $last = ''
    $tries = 0
    while ($true) {
        $tries++
        try {
            $req = [System.Net.WebRequest]::Create($uri)
            # No proxy: Microsoft says a default client proxy must be overridden.
            $req.Proxy = $null
            $req.Headers.Add('Metadata', 'true')
            $req.Timeout = 5000
            $resp = $req.GetResponse()
            try {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $reader.ReadToEnd()
            }
            finally { $resp.Close() }
            return ($body | ConvertFrom-Json)
        }
        catch {
            $last = $_.Exception.Message
            # An error answer holds a connection open until it is closed, and
            # .NET Framework allows two per host.
            $inner = $_.Exception.InnerException
            if ($inner -and $inner.PSObject.Properties['Response'] -and $inner.Response) { $inner.Response.Close() }
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 2
    }
    Add-Check 'instance metadata service' 'INFO' "no answer after $tries tries in 70 seconds: $last"
    return $null
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $osCaption = '{0} ({1})' -f $os.Caption, $os.Version
    Add-Fact 'os' 'Windows'

    $compute = Get-ImdsCompute
    if ($compute) {
        Add-Fact 'imdsReached' 'yes'
        Add-Fact 'imdsVmSize' ([string]$compute.vmSize)
        $sp = $compute.securityProfile
        if ($sp) {
            Add-Fact 'imdsSecurityType' ([string]$sp.securityType)
            Add-Fact 'imdsSecureBoot' ([string]$sp.secureBootEnabled)
            Add-Fact 'imdsVtpm' ([string]$sp.virtualTpmEnabled)
        }
        Add-Check 'instance metadata service' 'INFO' ("answered: size {0}" -f $compute.vmSize)
    }
    else {
        Add-Fact 'imdsReached' 'no'
    }

    [ordered]@{
        schema = 'vmf.guest/3'; script = 'Test-Imds.ps1'; version = $script:VERSION
        os = $osCaption; result = 'READY'; checks = @($script:checks); facts = $script:facts; warnings = @()
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
catch {
    [ordered]@{
        schema = 'vmf.guest/3'; script = 'Test-Imds.ps1'; version = $script:VERSION
        os = ''; result = 'BLOCKED'; checks = @($script:checks); facts = $script:facts; warnings = @()
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
