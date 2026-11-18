function Read-VmfPrecheckExtensions {
    <#
    .SYNOPSIS
        PRECHECK-EXT-READ-1: the extensions of the machine, read once at
        Checking - or the stop, when Azure did not return them.
    .DESCRIPTION
        PRECHECK records this list, and three things read it: the rebuild gate
        (REBUILD-ACCEPT-1) compares it with what the acceptance showed, the
        line after the delete of the definition names what to put back, and
        Verifying compares the machine with it. So a list that was not read
        must never stand in for "no extensions". The read used to return an
        empty list on a failure, which let a rebuild go on past an extension
        nobody accepted, with a line after the move that named none.

        Get-VmfVmExtensions throws on a failed read (REBUILD-PROPS-1), and
        Invoke-VmfAzOperation tries a transient failure again. A read that
        still fails is the stop extensionsNotRead, before anything changed -
        the way the encryption read stops (diskEncryptionUnknown). A lost
        lease is thrown to the worker, never a stop of the machine.
    .OUTPUTS
        @{ Extensions = <the list>; Stop = $null }, or @{ Extensions = $null;
        Stop = <the NEEDS_DECISION result> }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context)
    try {
        $extensions = Invoke-VmfAzOperation -Name 'getExtensions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfVmExtensions -ResourceGroupName $Context.Rg -Name $Context.VmName
        }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return @{
            Extensions = $null
            Stop = @{ Next = 'NEEDS_DECISION'; Reason = 'extensionsNotRead'; MachineState = 'untouched'
                Detail = "Azure did not return the extensions of this machine, so the product does not know which extensions it has: $($_.Exception.Message). Unknown is not the same as no extensions. Nothing on the machine changed." }
        }
    }
    @{ Extensions = @($extensions); Stop = $null }
}

# REBUILD-REMOVE-ACCEPT-1: Read-VmfPrecheckSqlVirtualMachine and
# Read-VmfPrecheckDataCollectionRuleAssociations (SQLVM-REREAD-1, DCR-READ-1)
# read again, before a rebuild, what the rebuild deletes. No plan that
# rebuilds reaches that point of PRECHECK any more, so they are gone with
# their stops.

# ADE-DETECT-ANY-NAME-1: the Azure Disk Encryption extension, by Microsoft's
# publisher and type. An ARM template can give it any name.
$script:VmfAdeExtensionPublisher = 'Microsoft.Azure.Security'
$script:VmfAdeExtensionTypes = @('AzureDiskEncryption', 'AzureDiskEncryptionForLinux')

function Test-VmfAdeExtension {
    <#
    .SYNOPSIS
        ADE-DETECT-ANY-NAME-1: $true when the machine's extensions hold an
        Azure Disk Encryption extension that is provisioned, for Windows or
        Linux, whatever its name. Pure.
    .DESCRIPTION
        It reads the list Checking already read (Read-VmfPrecheckExtensions).
        It used to ask Azure for two fixed NAMES, 'AzureDiskEncryption' and
        'AzureDiskEncryptionForLinux', so an extension a template named
        otherwise was not found. A list Azure did not return stops the
        machine before this (extensionsNotRead), so unknown is never "no"
        (EVAL-M6). Each disk's own setting is the second signal
        (Add-VmfDiskEncryptionFacts): it answers for an extension that is
        removed or not Succeeded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Extensions)
    foreach ($e in @($Extensions)) {
        if (-not $e) { continue }
        $publisher = [string](Get-VmfRecordField -Object $e -Name 'publisher')
        $type = [string](Get-VmfRecordField -Object $e -Name 'type')
        if ($publisher -eq $script:VmfAdeExtensionPublisher -and $type -in $script:VmfAdeExtensionTypes -and
            [string](Get-VmfRecordField -Object $e -Name 'provisioningState') -eq 'Succeeded') { return $true }
    }
    $false
}