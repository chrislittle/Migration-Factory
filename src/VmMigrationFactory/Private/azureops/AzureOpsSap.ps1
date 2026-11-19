# SAP-1, 2026-09-19. Which machines carry the Azure VM extension for SAP
# solutions?
#
# WHY THE PRODUCT ASKS. Microsoft's rewritten migration guide (24 July 2026)
# put a hard gate above the readiness checklist: "Only sizes on the SAP-
# certified list are supported, regardless of platform readiness. Treat
# certification as a gate that comes before all other planning, not as a
# validation item."
#
# THAT LIST IS SAP NOTE 1928533, AND IT IS BEHIND AN SAP SERVICE MARKETPLACE
# LOGIN. This product cannot fetch it, ship it or keep it current, so it can
# never say whether a target size is certified - which is why an SAP machine is
# not the product's to move. Ruled 2026-09-19: block it, the way a
# network virtual appliance is blocked.
#
# WHY THIS FILE READS ONLY THE EXTENSION (SAP-2, 2026-09-19). The first version
# also asked Azure's SAP provider - Microsoft.Workloads/sapVirtualInstances -
# which names every machine of an SAP system by resource id. It was dropped for
# what it COSTS TO ASK.
#
# The three child reads are narrow: an application, central or database
# instance returns hostname, instance number, IP, subnet, ports, health and
# vmDetails. The PARENT read is not. `sapVirtualInstances/read` returns
# properties.configuration, and for a system deployed through Azure Center for
# SAP solutions that carries infrastructureConfiguration with a per-tier
# osProfile - documented as holding adminUsername, adminPassword and
# sshKeyPair.privateKey. Whether ARM redacts those on read was NOT PROVEN, and
# a permission grant is not something to justify with "Azure probably redacts
# it". Ruled: drop it. The scanning identity gains nothing new.
#
# WHAT THAT COSTS, STATED PLAINLY: a machine registered with Azure Center for
# SAP solutions that carries none of the other three signals is not detected.
# Azure Center for SAP solutions does install VM extensions on the application,
# central and database servers in order to discover them - but whether those
# are the same publisher and type this file matches was NOT VERIFIED, so it is
# not claimed here.
#
# NOTHING HERE MAY BLOCK A NORMAL MACHINE (ruled the same day). The extension
# exists only to feed SAP's own monitoring, and Microsoft's instruction is "To
# be sure SAP supports your environment, enable the Azure VM extension for SAP
# solutions". Nobody installs it on a machine that is not SAP; it has no other
# purpose.

$script:VmfSapExtensionQuery = @'
Resources
| where type =~ 'microsoft.compute/virtualmachines/extensions'
| extend publisher = tostring(properties.publisher), extType = tostring(properties.type)
| where publisher in~ ('Microsoft.AzureCAT.AzureEnhancedMonitoring', 'Microsoft.OSTCExtensions')
| where extType in~ ('MonitorX64Linux', 'MonitorX64Windows', 'AzureEnhancedMonitorForLinux')
| project id, publisher, extType
'@

function Get-VmfSapSystemVmIds {
    <#
    .SYNOPSIS
        SAP-1: the machines carrying the Azure VM extension for SAP solutions.
    .OUTPUTS
        @{ Ids = @{ lowercased vm id = why }; Verified = bool; Detail = string }

        Verified = $false means the question could not be answered, which is
        NOT the same as "no SAP here". The caller refuses the scan, the way it
        already does for AVD and for the platform-managed groups: an assessment
        that could call an SAP machine Ready is worse than no assessment.
    .PARAMETER Subscriptions
        The subscriptions the scanned machines are in.
    .NOTES
        SAP-2: this needs NO permission the scan does not already hold. It is a
        Resource Graph query over virtual machine extensions, which authorises
        off the machine reads the inventory query already uses.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Subscriptions)

    $ids = @{}
    try {
        $rows = @(Invoke-VmfSapExtensionQuery -Subscriptions $Subscriptions)
        foreach ($row in $rows) {
            # The extension's id is the machine's id plus /extensions/<name>.
            $extId = [string]$row.id
            $cut = $extId.LastIndexOf('/extensions/', [System.StringComparison]::OrdinalIgnoreCase)
            if ($cut -lt 1) { continue }
            $ids[$extId.Substring(0, $cut).ToLowerInvariant()] =
                "the Azure VM extension for SAP solutions is installed ($($row.publisher)/$($row.extType))"
        }
    }
    catch {
        return @{ Ids = @{}; Verified = $false
                  Detail = "could not read virtual machine extensions ($($_.Exception.Message)) - SAP membership CANNOT be verified" }
    }

    @{ Ids = $ids; Verified = $true
       Detail = "$($ids.Count) machine(s) carry the Azure VM extension for SAP solutions" }
}

function Invoke-VmfSapExtensionQuery {
    <#
    .SYNOPSIS
        SAP-1: every VM extension that is the Azure extension for SAP solutions.
    .DESCRIPTION
        Resource Graph rather than a per-machine extension call: a fleet scan
        cannot afford one round trip per machine, and this reads from the same
        place the inventory query already reads.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string[]]$Subscriptions)

    $all = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $body = @{ query = $script:VmfSapExtensionQuery; options = @{ '$top' = 500 } }
        if ($Subscriptions -and @($Subscriptions).Count -gt 0) { $body.subscriptions = @($Subscriptions) }
        if ($skipToken) { $body.options['$skipToken'] = $skipToken }
        $parsed = Invoke-VmfResourceGraphQuery -Body $body
        foreach ($row in @($parsed.data)) { $all.Add($row) }
        $skipToken = $parsed.'$skipToken'
    } while ($skipToken)
    , $all.ToArray()
}
