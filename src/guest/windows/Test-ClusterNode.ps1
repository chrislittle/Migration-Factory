<#
.SYNOPSIS
    Report the facts that show whether this machine is a node of a cluster.
    Read-only (CLUSTER-DETECT-1).
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand, under Windows PowerShell 5.1
    (CLAUDE.md): no ternary, no null-coalescing, no .NET Core-only API.

    The engine runs this at Checking, before any safety copy and before any
    stop. A cluster node that Azure has no record of - a failover cluster with
    no shared disk, an availability group built by hand, SQL Server installed
    from media - looks like a machine that is alone, and a stop of the primary
    replica causes a failover or an outage.

    FACTS ONLY. The ENGINE judges them (Get-VmfClusterNodeVerdict):
      clusterService - the ClusSvc service: running, installed (and not
                       running), or absent
      clusterKey     - the registry key HKLM\Cluster: yes or no
      sqlHadr        - a SQL Server instance has HADR_Enabled set to 1: yes or
                       no. It names the kind of cluster, and never decides.

    It reads the service list and the registry. It writes nothing, starts
    nothing and stops nothing, and it needs no SQL Server login.

    Output contract: schemas/guest-output.schema.json (vmf.guest/4). result:
    READY when every fact was read; BLOCKED when a read failed. The engine
    reads BLOCKED as unknown, never as "not a cluster node".
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.0.0'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:facts = [ordered]@{}
$script:osCaption = ''

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

function Add-Fact {
    param([string]$Name, [string]$Value)
    $script:facts[$Name] = [string]$Value
}

function Write-Answer {
    param([string]$Result, [string]$ErrorDetail = '')
    $doc = [ordered]@{
        schema   = 'vmf.guest/4'
        script   = 'Test-ClusterNode.ps1'
        version  = $script:VERSION
        os       = $script:osCaption
        result   = $Result
        checks   = @($script:checks)
        facts    = $script:facts
        warnings = @()
    }
    if ($ErrorDetail) { $doc.error = $ErrorDetail }
    $doc | ConvertTo-Json -Depth 6 -Compress
}

try {
    Add-Fact 'os' 'Windows'
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $script:osCaption = '{0} ({1})' -f $os.Caption, $os.Version

    # Win32_Service gives nothing for a service that is not installed, and
    # throws when WMI cannot answer - so "absent" is an answer, never a guess.
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='ClusSvc'"
    $state = 'absent'
    if ($svc) {
        if ([string]$svc.State -eq 'Running') { $state = 'running' } else { $state = 'installed' }
    }
    Add-Fact 'clusterService' $state
    $svcDetail = 'not installed'
    if ($svc) { $svcDetail = 'installed, state ' + [string]$svc.State }
    Add-Check 'ClusSvc service' 'INFO' $svcDetail

    # The cluster database is loaded at HKLM\Cluster on a cluster node.
    $key = 'no'
    if (Test-Path -LiteralPath 'HKLM:\Cluster') { $key = 'yes' }
    Add-Fact 'clusterKey' $key
    Add-Check 'HKLM\Cluster' 'INFO' $key

    # Each SQL Server instance keeps HADR_Enabled under its own key. Read
    # from the registry, so no SQL Server login is needed.
    $hadr = [System.Collections.Generic.List[string]]::new()
    $instances = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    $skip = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    if (Test-Path -LiteralPath $instances) {
        $map = Get-ItemProperty -LiteralPath $instances
        foreach ($p in @($map.PSObject.Properties)) {
            if ($skip -contains $p.Name) { continue }
            $hadrKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\' + [string]$p.Value + '\MSSQLServer\HADR'
            if (-not (Test-Path -LiteralPath $hadrKey)) { continue }
            $values = Get-ItemProperty -LiteralPath $hadrKey
            if ($values.PSObject.Properties['HADR_Enabled'] -and [string]$values.HADR_Enabled -eq '1') { $hadr.Add([string]$p.Name) }
        }
    }
    $sql = 'no'
    if ($hadr.Count -gt 0) { $sql = 'yes' }
    Add-Fact 'sqlHadr' $sql
    $sqlDetail = 'no SQL Server instance has HADR_Enabled set'
    if ($hadr.Count -gt 0) { $sqlDetail = 'HADR_Enabled is set on: ' + ($hadr -join ', ') }
    Add-Check 'SQL Server HADR_Enabled' 'INFO' $sqlDetail

    Write-Answer -Result 'READY'
    exit 0
}
catch {
    Write-Answer -Result 'BLOCKED' -ErrorDetail ([string]$_.Exception.Message)
    exit 0
}
