# REBUILD-PROPS-1: the settings a rebuild must put back, read the same way
# from a machine before the move (Get-VmfVmCapture) and after it (Verifying).
#
# Every rebuild from a capture - the Path B move, its rollback, a restore that
# rebuilds, Rebuild this machine - creates the machine again around the same
# disks. A setting the capture did not record, or the rebuild did not send,
# was gone with the old definition. MEASURED 2026-11-01: the patch settings
# are lost, so Azure Update Manager stops patching the machine.
# NO-PLAN-SCOPE-1: a machine with a Marketplace purchase plan is outside the
# scope of this tool, and Checking stops it, so no rebuild carries a plan.
#
# One reader (Get-VmfRebuildSettingsFromVm) for both sides, so the comparison
# cannot read the two sides in two ways.
# VERIFY-HOST-HIBERNATION-UNUSED-1: the reader still gives the dedicated host,
# the host group and hibernation, for the stop at Checking
# (Get-VmfHostHibernationStop). A machine with any of them is outside the
# scope of this tool and stops there untouched, so the capture does not record
# them and the comparison does not read them.

function Get-VmfCapturedPatchSettings {
    <#
    .SYNOPSIS
        The patch settings of a machine (osProfile windowsConfiguration or
        linuxConfiguration patchSettings), or $null when it has none. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Vm)
    $osProfile = if ($Vm -and $Vm.PSObject.Properties['OSProfile']) { $Vm.OSProfile } else { $null }
    if (-not $osProfile) { return $null }
    $os = $null; $ps = $null
    foreach ($pair in @(@('Windows', 'WindowsConfiguration'), @('Linux', 'LinuxConfiguration'))) {
        $cfg = if ($osProfile.PSObject.Properties[$pair[1]]) { $osProfile.($pair[1]) } else { $null }
        if ($cfg -and $cfg.PSObject.Properties['PatchSettings'] -and $cfg.PatchSettings) { $os = $pair[0]; $ps = $cfg.PatchSettings; break }
    }
    if (-not $ps) { return $null }
    $field = { param($o, $n) if ($o -and $o.PSObject.Properties[$n] -and $null -ne $o.$n -and [string]$o.$n -ne '') { $o.$n } else { $null } }
    $auto = & $field $ps 'AutomaticByPlatformSettings'
    $out = [ordered]@{
        os                = $os
        patchMode         = $(if (& $field $ps 'PatchMode') { [string](& $field $ps 'PatchMode') } else { $null })
        assessmentMode    = $(if (& $field $ps 'AssessmentMode') { [string](& $field $ps 'AssessmentMode') } else { $null })
        enableHotpatching = $(if ($null -ne (& $field $ps 'EnableHotpatching')) { [bool](& $field $ps 'EnableHotpatching') } else { $null })
        rebootSetting     = $(if (& $field $auto 'RebootSetting') { [string](& $field $auto 'RebootSetting') } else { $null })
        bypassPlatformSafetyChecksOnUserSchedule = $(if ($null -ne (& $field $auto 'BypassPlatformSafetyChecksOnUserSchedule')) { [bool](& $field $auto 'BypassPlatformSafetyChecksOnUserSchedule') } else { $null })
    }
    if (-not $out.patchMode -and -not $out.assessmentMode) { return $null }
    $out
}

function Test-VmfPatchSettingsSame {
    <#
    .SYNOPSIS
        Does -Have carry every patch setting -Want names? A setting -Want does
        not name is not compared. Pure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Want, [Parameter()][AllowNull()]$Have)
    if (-not $Want) { return $true }
    if (-not $Have) { return $false }
    foreach ($n in 'patchMode', 'assessmentMode', 'enableHotpatching', 'rebootSetting', 'bypassPlatformSafetyChecksOnUserSchedule') {
        $w = Get-VmfRecordField -Object $Want -Name $n
        if ($null -eq $w) { continue }
        $h = Get-VmfRecordField -Object $Have -Name $n
        if ([string]$w -ne [string]$h) { return $false }
    }
    $true
}

function Get-VmfRebuildSettingsFromVm {
    <#
    .SYNOPSIS
        The settings this item covers, read from a machine as Get-AzVM returns
        it. The capture and Verifying both read through this. Pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowNull()]$Vm)
    $prop = { param($o, $n) if ($o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $id = { param($o) $r = & $prop $o 'Id'; if ($r) { [string]$r } else { $null } }
    $storage = & $prop $Vm 'StorageProfile'
    $os = & $prop $storage 'OsDisk'
    $extra = & $prop $Vm 'AdditionalCapabilities'
    $billing = & $prop $Vm 'BillingProfile'
    $diag = & $prop (& $prop $Vm 'DiagnosticsProfile') 'BootDiagnostics'
    $security = & $prop $Vm 'SecurityProfile'
    $str = { param($v) if ($null -ne $v -and [string]$v -ne '') { [string]$v } else { $null } }
    [pscustomobject]@{
        patchSettings      = Get-VmfCapturedPatchSettings -Vm $Vm
        userDataPresent    = [bool](& $str (& $prop $Vm 'UserData'))
        hostId             = (& $id (& $prop $Vm 'Host'))
        hostGroupId        = (& $id (& $prop $Vm 'HostGroup'))
        priority           = (& $str (& $prop $Vm 'Priority'))
        evictionPolicy     = (& $str (& $prop $Vm 'EvictionPolicy'))
        maxPrice           = $(if ($billing -and $null -ne (& $prop $billing 'MaxPrice')) { [double](& $prop $billing 'MaxPrice') } else { $null })
        hibernationEnabled = [bool](& $prop $extra 'HibernationEnabled')
        encryptionAtHost   = [bool](& $prop $security 'EncryptionAtHost')
        bootDiagnosticsStorageUri = $(if ($diag -and [bool](& $prop $diag 'Enabled')) { & $str (& $prop $diag 'StorageUri') } else { $null })
        osDisk = [pscustomobject]@{
            caching                 = (& $str (& $prop $os 'Caching'))
            deleteOption            = (& $str (& $prop $os 'DeleteOption'))
            writeAcceleratorEnabled = [bool](& $prop $os 'WriteAcceleratorEnabled')
        }
        dataDisks = @(foreach ($dd in @(& $prop $storage 'DataDisks')) {
            if (-not $dd) { continue }
            [pscustomobject]@{ lun = [int](& $prop $dd 'Lun'); deleteOption = (& $str (& $prop $dd 'DeleteOption')); writeAcceleratorEnabled = [bool](& $prop $dd 'WriteAcceleratorEnabled') }
        })
        nics = @(foreach ($n in @(& $prop (& $prop $Vm 'NetworkProfile') 'NetworkInterfaces')) {
            if (-not $n) { continue }
            [pscustomobject]@{ id = (& $id $n); deleteOption = (& $str (& $prop $n 'DeleteOption')) }
        })
    }
}

function Test-VmfRebuildSettingsFidelity {
    <#
    .SYNOPSIS
        REBUILD-PROPS-1: did the machine come back with every setting this
        item covers? Pure comparison, run by Verifying on every move.
    .DESCRIPTION
        A setting is compared only when the capture recorded one.
        OLD-VERSION-READERS-REMOVE-4: every capture of this version holds the
        fields, null for none (Get-VmfVmCapture). A capture without them
        fails the compare - the product never passes a machine whose settings
        it could not compare.
        REBUILD-REMOVE-ENGINE-1: the patch settings are held to what the
        capture recorded on every move. The rebuilt variant (REBUILD-PATCH-MODE-1)
        went with the rebuild.
    .PARAMETER Live
        Get-VmfRebuildSettingsFromVm of the machine as it is now.
    .OUTPUTS
        @{ Ok; Verdict = 'MATCH'|'MISMATCH'; Detail }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Captured, [Parameter()][AllowNull()]$Live)
    # patchSettings is written with the other fields on every capture, $null
    # for none, so a capture without the field does not hold them.
    if (-not $Captured -or -not (Test-VmfRecordHasField -Object $Captured -Name 'patchSettings')) {
        return @{ Ok = $false; Verdict = 'MISMATCH'; Detail = 'the record of the machine before the move does not hold its patch, Spot, boot diagnostics, encryption at host, disk and network interface settings, so the product cannot compare them' }
    }
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $same = { param($a, $b) ([string]$a).TrimEnd('/') -ieq ([string]$b).TrimEnd('/') }
    $problems = [System.Collections.Generic.List[string]]::new()

    $wantPatch = & $f $Captured 'patchSettings'
    if ($wantPatch -and -not (Test-VmfPatchSettingsSame -Want $wantPatch -Have (& $f $Live 'patchSettings'))) {
        $havePatch = & $f $Live 'patchSettings'
        $problems.Add("its patch mode was $(& $f $wantPatch 'patchMode') before the move and is $(if ($havePatch -and (& $f $havePatch 'patchMode')) { & $f $havePatch 'patchMode' } else { 'not set' }) now, so the machine may not be patched as before")
    }

    $wantEvict = [string](& $f $Captured 'evictionPolicy')
    if ($wantEvict -and -not (& $same $wantEvict (& $f $Live 'evictionPolicy'))) {
        $problems.Add("its Spot eviction policy was $wantEvict before the move and is $(& $f $Live 'evictionPolicy') now")
    }
    $wantPrice = & $f $Captured 'maxPrice'
    if ($null -ne $wantPrice -and [string]$wantPrice -ne '' -and [double]$wantPrice -ne [double](& $f $Live 'maxPrice')) {
        $problems.Add("its Spot maximum price was $wantPrice before the move and is $(& $f $Live 'maxPrice') now")
    }

    if ([bool](& $f (& $f $Captured 'securityProfile') 'encryptionAtHost') -and -not [bool](& $f $Live 'encryptionAtHost')) {
        $problems.Add('it had encryption at host before the move and does not now')
    }
    $diag = & $f $Captured 'bootDiagnostics'
    $wantUri = if ($diag -and [bool](& $f $diag 'enabled')) { [string](& $f $diag 'storageUri') } else { '' }
    if ($wantUri -and -not (& $same $wantUri (& $f $Live 'bootDiagnosticsStorageUri'))) {
        $problems.Add("its boot diagnostics storage account was $wantUri before the move and is $(if (& $f $Live 'bootDiagnosticsStorageUri') { & $f $Live 'bootDiagnosticsStorageUri' } else { 'the managed storage account' }) now")
    }

    $capOs = & $f $Captured 'osDisk'
    $liveOs = & $f $Live 'osDisk'
    foreach ($pair in @(@('caching', 'caching'), @('deleteOption', 'delete option'))) {
        $want = [string](& $f $capOs $pair[0])
        if ($want -and -not (& $same $want (& $f $liveOs $pair[0]))) { $problems.Add("its OS disk $($pair[1]) was $want before the move and is $(& $f $liveOs $pair[0]) now") }
    }
    if ([bool](& $f $capOs 'writeAcceleratorEnabled') -and -not [bool](& $f $liveOs 'writeAcceleratorEnabled')) {
        $problems.Add('its OS disk had Write Accelerator before the move and does not now')
    }
    $liveData = @{}; foreach ($d in @(& $f $Live 'dataDisks')) { if ($d) { $liveData[[int](& $f $d 'lun')] = $d } }
    foreach ($d in @(& $f $Captured 'dataDisks')) {
        if (-not $d) { continue }
        $lun = [int](& $f $d 'lun')
        $now = $liveData[$lun]
        $want = [string](& $f $d 'deleteOption')
        if ($want -and $now -and -not (& $same $want (& $f $now 'deleteOption'))) { $problems.Add("the data disk on LUN $lun had the delete option $want before the move and has $(& $f $now 'deleteOption') now") }
        if ([bool](& $f $d 'writeAcceleratorEnabled') -and -not ($now -and [bool](& $f $now 'writeAcceleratorEnabled'))) { $problems.Add("the data disk on LUN $lun had Write Accelerator before the move and does not now") }
    }
    $liveNics = @{}; foreach ($n in @(& $f $Live 'nics')) { if ($n -and (& $f $n 'id')) { $liveNics[([string](& $f $n 'id')).ToLowerInvariant()] = $n } }
    foreach ($n in @(& $f $Captured 'nics')) {
        $nid = [string](& $f $n 'id')
        $want = [string](& $f $n 'deleteOption')
        if (-not $nid -or -not $want) { continue }
        $now = $liveNics[$nid.ToLowerInvariant()]
        if ($now -and -not (& $same $want (& $f $now 'deleteOption'))) { $problems.Add("the network interface $(($nid -split '/')[-1]) had the delete option $want before the move and has $(& $f $now 'deleteOption') now") }
    }

    if ($problems.Count) { return @{ Ok = $false; Verdict = 'MISMATCH'; Detail = ($problems -join '; ') } }
    # REBUILD-PATCH-MODE-1: patch settings not compared are not said to have come back.

    if (-not $wantPatch -and (& $f $Captured 'patchSettings')) { return @{ Ok = $true; Verdict = 'MATCH'; Detail = 'No machine setting changed.' } }
    @{ Ok = $true; Verdict = 'MATCH'; Detail = 'No machine setting changed.' }
}
