# VERIFY-FP-1 part 3: the evidence record.
#
# Each machine is read before the move and after it, and both readings are
# KEPT on its state document, for attestation and for supporting a customer
# later. Until this, VALIDATING read everything below, judged it, and threw it
# away: the migration record said "The product keeps no reading of the machine
# taken after the move".
#
# Scope set 2026-09-28: what the product already reads - Azure's
# view of the machine, the Instance Metadata Service, and the guest's storage,
# boot bus, temporary disk and network driver. Listening ports and services
# were dropped.
#
# THE RECORD IS NEVER A PASS OR A FAIL. Every reading here that matters is
# already judged by VALIDATING, and a failure there stops the move and restores
# the machine. So the comparison says only what is the same, what the move is
# meant to change, and what else changed - it cannot raise a false alarm, and
# it is never presented as proof that an application works.

# The readings, in the order a person reads them, and the words for each.
$script:VmfEvidenceReadings = [ordered]@{
    'azure.size'                         = @('azure', 'Size')
    'azure.controller'                   = @('azure', 'Disk controller')
    'azure.osDisk'                       = @('azure', 'OS disk')
    'azure.dataDisks'                    = @('azure', 'Data disks')
    'azure.networkInterfaces'            = @('azure', 'Network interfaces')
    'azure.acceleratedNetworking'        = @('azure', 'Accelerated networking')
    'azure.securityType'                 = @('azure', 'Security type')
    'azure.secureBootVtpm'               = @('azure', 'Secure Boot, vTPM')
    'imds.answered'                      = @('imds', 'Answered')
    'imds.size'                          = @('imds', 'Size')
    'imds.securityType'                  = @('imds', 'Security type')
    'imds.secureBootVtpm'                = @('imds', 'Secure Boot, vTPM')
    'guest.bootBus'                      = @('guest', 'Boot disk bus')
    'guest.nvmeDriver'                   = @('guest', 'NVMe driver')
    'guest.volumes'                      = @('guest', 'Volumes')
    'guest.storageGroups'                = @('guest', 'Storage pools or volume groups')
    'guest.tempDisk'                     = @('guest', 'Temporary disk')
    'guest.pageFile'                     = @('guest', 'Page file')
    'guest.acceleratedNetworkingDriver'  = @('guest', 'Accelerated networking driver')
}

# What a move is meant to change. A difference in any other reading is
# "changed" - a fact to look at, never a failure.
$script:VmfEvidencePlanned = @('azure.size', 'azure.controller', 'imds.size', 'guest.bootBus',
    'guest.nvmeDriver', 'guest.tempDisk', 'guest.acceleratedNetworkingDriver')

function ConvertTo-VmfEvidenceSide {
    <#
    .SYNOPSIS
        One side of the record - before or after - as named readings. Pure.
    .DESCRIPTION
        Every value is a string, or $null when it was not read. $null is never
        turned into a value: "not read" and "none" are different answers.
    .PARAMETER VmConfig
        Get-VmfVmCapture output (the state document's captured.vmConfig).
    .PARAMETER Imds
        Get-VmfImdsReading output.
    .PARAMETER Guest
        The guest validation script's output (Test-GuestValidation.ps1 or
        guest-validate.sh).
    .PARAMETER Fabric
        The accelerated networking script's facts (Test-ManaReady.ps1 or
        mana-check.sh).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter()][AllowNull()]$VmConfig,
        [Parameter()][AllowNull()]$Imds,
        [Parameter()][AllowNull()]$Guest,
        [Parameter()][AllowNull()]$Fabric
    )
    $side = [ordered]@{}
    foreach ($k in $script:VmfEvidenceReadings.Keys) { $side[$k] = $null }
    $text = { param($v) if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { $null } else { ([string]$v).Trim() } }
    $onOff = { param($v)
        if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { return $null }
        if ([string]$v -in @('true', 'True', 'yes', 'on', 'On')) { 'On' } elseif ([string]$v -in @('false', 'False', 'no', 'off', 'Off')) { 'Off' } else { [string]$v } }

    if ($VmConfig) {
        $side['azure.size'] = & $text $VmConfig.size
        # Azure leaves the setting unset on many older machines, and its
        # default then is SCSI (Get-VmfOsDiskInfo says the same).
        $side['azure.controller'] = $(if (& $text $VmConfig.controller) { & $text $VmConfig.controller } else { 'SCSI' })
        if ($VmConfig.PSObject.Properties['osDisk'] -and $VmConfig.osDisk) { $side['azure.osDisk'] = & $text $VmConfig.osDisk.name }
        if ($VmConfig.PSObject.Properties['dataDisks']) {
            $luns = @($VmConfig.dataDisks | Where-Object { $_ } | ForEach-Object { [int]$_.lun } | Sort-Object)
            $side['azure.dataDisks'] = if ($luns.Count) { ($luns | ForEach-Object { "LUN $_" }) -join ', ' } else { 'None' }
        }
        if ($VmConfig.PSObject.Properties['nics']) {
            $nics = @($VmConfig.nics | Where-Object { $_ })
            $side['azure.networkInterfaces'] = [string]$nics.Count
            $primary = @($nics | Where-Object { $_.primary }) + @($nics) | Select-Object -First 1
            if ($primary) { $side['azure.acceleratedNetworking'] = & $onOff $primary.acceleratedNetworking }
        }
        if ($VmConfig.PSObject.Properties['securityProfile'] -and $VmConfig.securityProfile) {
            $sp = $VmConfig.securityProfile
            $side['azure.securityType'] = & $text $sp.securityType
            $sb = & $onOff $sp.secureBootEnabled; $tpm = & $onOff $sp.vTpmEnabled
            if ($sb -or $tpm) { $side['azure.secureBootVtpm'] = "$(if ($sb) { $sb } else { 'Not read' }), $(if ($tpm) { $tpm } else { 'Not read' })" }
        }
    }

    if ($Imds -and [string]$Imds.reached -in @('yes', 'no')) {
        $side['imds.answered'] = if ([string]$Imds.reached -eq 'yes') { 'Yes' } else { 'No' }
        if ([string]$Imds.reached -eq 'yes') {
            $side['imds.size'] = & $text $Imds.vmSize
            $side['imds.securityType'] = & $text $Imds.securityType
            $sb = & $onOff $Imds.secureBoot; $tpm = & $onOff $Imds.vtpm
            if ($sb -or $tpm) { $side['imds.secureBootVtpm'] = "$(if ($sb) { $sb } else { 'Not read' }), $(if ($tpm) { $tpm } else { 'Not read' })" }
        }
    }

    if ($Guest -and $Guest.PSObject.Properties['checks']) {
        $check = { param([string[]]$names) & $text (@($Guest.checks | Where-Object { [string]$_.name -in $names } | Select-Object -First 1).detail) }
        $side['guest.bootBus'] = & $check @('boot disk bus', 'root device bus')
        $side['guest.nvmeDriver'] = & $check @('stornvme service', 'nvme driver')
        $side['guest.volumes'] = & $check @('volumes', 'fstab mounts')
        $side['guest.tempDisk'] = & $check @('nvme temp disk D:', 'temp disk mount')
        $side['guest.pageFile'] = & $check @('pagefile')
        $storage = Get-VmfStorageFacts -GuestOutput $Guest
        if ($storage.Reported -and $null -ne $storage.Groups) {
            $side['guest.storageGroups'] = if ([int]$storage.Groups -eq 0) { 'None' }
                else { "$($storage.Groups) group(s), $(if ($null -ne $storage.Volumes) { $storage.Volumes } else { '?' }) volume(s)" }
        }
    }

    if ($Fabric) {
        $f = if ($Fabric.PSObject.Properties['facts'] -and $Fabric.facts) { $Fabric.facts } else { $Fabric }
        if ($f.PSObject.Properties['fabric']) { $side['guest.acceleratedNetworkingDriver'] = & $text $f.fabric }
    }
    $side
}

function Get-VmfEvidencePlanned {
    <#
    .SYNOPSIS
        The readings THIS move is meant to change, beyond the ones every move
        changes. Pure. Kept with the record, so every later reader compares
        by the same rule.
    .DESCRIPTION
        - A source with a SCSI temporary disk: guest prep moves the Windows
          page file off it, and the temporary disk changes size or goes.
        - The accelerated networking decision guest prep saved (AN-KEEP-1)
          turns it on or leaves it off, so the setting may change.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()]$PlanEntry,
        [Parameter()][AllowNull()]$Doc
    )
    $keys = [System.Collections.Generic.List[string]]::new()
    $sourceArch = if ($PlanEntry -and $PlanEntry.assessment) { [string]$PlanEntry.assessment.sourceDiskArch } else { '' }
    if ($sourceArch -eq 'scsi-temp') { $keys.Add('guest.pageFile'); $keys.Add('guest.volumes') }
    $an = if ($Doc -and $Doc.PSObject.Properties['captured'] -and $Doc.captured -and $Doc.captured.PSObject.Properties['acceleratedNetworking']) { $Doc.captured.acceleratedNetworking } else { $null }
    if ($an -and [string]$an.policy -and [string]$an.policy -ne 'preserve') { $keys.Add('azure.acceleratedNetworking') }
    @($keys)
}

function Compare-VmfEvidence {
    <#
    .SYNOPSIS
        The record's rows: each reading, before and after, and what it is -
        'same', 'planned' (the move is meant to change it), 'changed', or
        'notRead' (one side was not read). Pure. NEVER a pass or a fail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter()][AllowNull()]$Before,
        [Parameter()][AllowNull()]$After,
        # Readings this move is also meant to change (Get-VmfEvidencePlanned).
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$Planned = @()
    )
    $plannedKeys = @($script:VmfEvidencePlanned) + @($Planned | Where-Object { $_ })
    $get = { param($side, $key)
        if ($null -eq $side) { return $null }
        $v = if ($side -is [System.Collections.IDictionary]) { $side[$key] } elseif ($side.PSObject.Properties[$key]) { $side.$key } else { $null }
        if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { $null } else { [string]$v } }
    foreach ($key in $script:VmfEvidenceReadings.Keys) {
        $b = & $get $Before $key
        $a = & $get $After $key
        if ($null -eq $b -and $null -eq $a) { continue }
        $result = if ($null -eq $b -or $null -eq $a) { 'notRead' }
                  elseif ($b.Trim() -ieq $a.Trim()) { 'same' }
                  elseif ($key -in $plannedKeys) { 'planned' }
                  else { 'changed' }
        [pscustomobject]@{
            key = $key; group = $script:VmfEvidenceReadings[$key][0]; label = $script:VmfEvidenceReadings[$key][1]
            before = $b; after = $a; result = $result
        }
    }
}

function Save-VmfEvidence {
    <#
    .SYNOPSIS
        Keep both sides on the machine's state document (vm-state v10,
        `evidence`). The caller decides what happens when it throws; VALIDATING
        never lets it stop a move.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        [Parameter()][AllowEmptyCollection()][string[]]$Planned = @()
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $doc | Add-Member -NotePropertyName evidence -NotePropertyValue ([ordered]@{
        takenUtc = (Get-Date).ToUniversalTime().ToString('o')
        planned  = @($Planned)
        before   = $Before
        after    = $After
    }) -Force
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
}
