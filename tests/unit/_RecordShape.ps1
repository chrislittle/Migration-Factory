# OLD-VERSION-READERS-REMOVE-4: a hand-made state document in a test holds
# what every capture of this version holds (vm-state v47).
#
# PRECHECK writes the first capture (captured.original) with this attempt's
# capture; Get-VmfVmCapture writes capacityReservationGroupId and
# patchSettings on every capture, null for none; Add-VmfDiskEncryptionFacts
# records each disk's encryption. The engine reads no record without them - a
# put-back of such a record stops - so a fixture that leaves them out tests a
# record no 1.0 install can write.
#
# Complete-VmfTestCapture fills only what is MISSING, so a test that sets a
# field on purpose (a first capture that differs from this attempt's, a group,
# a customer-managed key) keeps it. Call it on the document (or on its
# captured part) after the test built it, before it is written or read.
#
# Not named *.Tests.ps1 on purpose: Pester discovers only test files.

function global:Set-VmfTestField {
    param($Object, [string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function global:Test-VmfTestField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return [bool]$Object.Contains($Name) }
    $null -ne $Object.PSObject.Properties[$Name]
}

function global:Get-VmfTestField {
    param($Object, [string]$Name)
    if (-not (Test-VmfTestField $Object $Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $Object.$Name
}

function global:Complete-VmfTestCaptureShape {
    # One capture: the group, the patch settings and each disk's encryption.
    param($Capture)
    if ($null -eq $Capture) { return }
    foreach ($n in 'capacityReservationGroupId', 'patchSettings') {
        if (-not (Test-VmfTestField $Capture $n)) { Set-VmfTestField $Capture $n $null }
    }
    $disks = @(@(Get-VmfTestField $Capture 'osDisk') + @(Get-VmfTestField $Capture 'dataDisks')) | Where-Object { $null -ne $_ }
    foreach ($d in $disks) {
        if (-not [string](Get-VmfTestField $d 'encryptionType')) {
            Set-VmfTestField $d 'encryptionType' 'EncryptionAtRestWithPlatformKey'
            if (-not (Test-VmfTestField $d 'diskEncryptionSetId')) { Set-VmfTestField $d 'diskEncryptionSetId' $null }
        }
    }
}

function global:Complete-VmfTestCapture {
    <#
    .SYNOPSIS
        Fill what a 1.0 capture always holds, on a test's state document (or
        its captured part). Returns what it was given.
    #>
    param($Doc)
    if ($null -eq $Doc) { return $Doc }
    $captured = if (Test-VmfTestField $Doc 'vmConfig') { $Doc } else { Get-VmfTestField $Doc 'captured' }
    $vm = Get-VmfTestField $captured 'vmConfig'
    if ($null -eq $vm) { return $Doc }
    Complete-VmfTestCaptureShape $vm
    $original = Get-VmfTestField $captured 'original'
    if ($null -eq $original) {
        # As PRECHECK writes it: the capture, its extensions and what its size
        # can carry (New-VmfOriginalCaptureRecord).
        $copy = $vm | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $first = [pscustomobject]@{ vmConfig = $copy }
        foreach ($n in 'extensions', 'sourceAcceleratedNetworking') {
            if (Test-VmfTestField $captured $n) { $first | Add-Member -NotePropertyName $n -NotePropertyValue (Get-VmfTestField $captured $n) }
        }
        Set-VmfTestField $captured 'original' $first
    }
    else { Complete-VmfTestCaptureShape (Get-VmfTestField $original 'vmConfig') }
    $Doc
}

function global:Add-VmfTestMachineCapture {
    <#
    .SYNOPSIS
        A machine with a safety copy passed PRECHECK, which captured it. For a
        test document that has no capture: one OS disk, no data disks, no
        network interfaces. Keeps any captured field the test set.
    #>
    param($Doc, [string]$Name, [string]$OsDiskId, [string]$Size = 'Standard_D2s_v6')
    $captured = Get-VmfTestField $Doc 'captured'
    if ($null -eq $captured) { $captured = [pscustomobject]@{}; Set-VmfTestField $Doc 'captured' $captured }
    if (Get-VmfTestField $captured 'vmConfig') { return $Doc }
    Set-VmfTestField $captured 'vmConfig' ([pscustomobject]@{
            name = $Name; location = 'centralus'; size = $Size; controller = 'SCSI'
            osDisk = [pscustomobject]@{ name = (($OsDiskId -split '/')[-1]); managedDiskId = $OsDiskId; skuName = 'Premium_LRS' }
            dataDisks = @(); nics = @() })
    $Doc
}