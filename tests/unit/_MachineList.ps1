# TARGETS-NO-LIST-1: targets are saved after the list of machines.
#
# Set-VmfTargetChoice refuses to save a target before machine-choices.json
# exists, as the wizard asks the machines first and their targets second. A
# test that only cares about the targets saves them through
# Set-VmfTestTargetChoice: unless the test names the list version it read
# (-ExpectedMachinesVersion), it keeps a list of every machine it saved a
# target for - the machines the engine planned when targets once stood for
# the list - and saves the targets against it. A test of the list's own rules
# (a 409, a machine not chosen) passes -ExpectedMachinesVersion, or calls
# Set-VmfTargetChoice itself, and sees them.
#
# Global, so a call inside InModuleScope finds it. Not named *.Tests.ps1 on
# purpose: Pester discovers only test files.

function global:Set-VmfTestTargetChoice {
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Choices,
        [Parameter(Mandatory)][string]$Default,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedAdviceVersion,
        [Parameter()][AllowEmptyString()][string]$ExpectedChoicesVersion = '',
        [Parameter()][AllowEmptyString()][string]$ExpectedMachinesVersion,
        [Parameter()][string]$KernelDefault = 'stop',
        [Parameter()][hashtable]$OnBehalfOf
    )
    $module = @(Get-Module VmMigrationFactory)[0]
    $listVersion = { & $module { param($rp)
            if (-not (Test-VmfStoreItem -RunPath $rp -RelPath 'machine-choices.json')) { return '' }
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $rp -RelPath 'machine-choices.json')) } $RunPath }
    $ids = @(@($Choices) | Where-Object { $_ } | ForEach-Object { [string]$_.vmId } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $PSBoundParameters.ContainsKey('ExpectedMachinesVersion') -and $ids.Count) {
        # The list the helper keeps: every machine a target was saved for. A
        # machine named now that is not on it joins it, as when the targets
        # once stood for the list.
        $before = & $listVersion
        $have = @(if ($before) { & $module { param($rp) @((Read-VmfStoreJson -RunPath $rp -RelPath 'machine-choices.json').machines) } $RunPath })
        $want = @(@($have) + @($ids) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        if (@($want).Count -ne @($have).Count -or -not $before) {
            $who = if ($OnBehalfOf) { $OnBehalfOf } else { @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } }
            Set-VmfMachineChoice -RunPath $RunPath -Machines $want -ExpectedAdviceVersion $ExpectedAdviceVersion -ExpectedChoiceVersion $before -OnBehalfOf $who | Out-Null
        }
        $ExpectedMachinesVersion = & $listVersion
    }
    $a = @{ RunPath = $RunPath; Choices = $Choices; Default = $Default; ExpectedAdviceVersion = $ExpectedAdviceVersion
            ExpectedChoicesVersion = $ExpectedChoicesVersion; KernelDefault = $KernelDefault }
    if ($null -ne $ExpectedMachinesVersion) { $a.ExpectedMachinesVersion = $ExpectedMachinesVersion }
    if ($OnBehalfOf) { $a.OnBehalfOf = $OnBehalfOf }
    Set-VmfTargetChoice @a
}

function global:Invoke-VmfTestFacadeSetTargets {
    # The service's save of the targets, as the page sends it after the
    # machines step: the same list as Set-VmfTestTargetChoice keeps, unless
    # the test names the version it read (-MachinesVersion).
    param(
        [Parameter()][AllowNull()]$Principal,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$Default,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Choices,
        [Parameter(Mandatory)][string]$AdviceVersion,
        [Parameter()][AllowEmptyString()][string]$ChoicesVersion = '',
        [Parameter()][AllowEmptyString()][string]$MachinesVersion,
        [Parameter()][string]$KernelDefault
    )
    $module = @(Get-Module VmMigrationFactory)[0]
    $a = @{} + $PSBoundParameters
    $ids = @(@($Choices) | Where-Object { $_ } | ForEach-Object { [string]$_.vmId } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $PSBoundParameters.ContainsKey('MachinesVersion') -and $ids.Count) {
        $version = { & $module { param($rp)
                if (-not (Test-VmfStoreItem -RunPath $rp -RelPath 'machine-choices.json')) { return '' }
                Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $rp -RelPath 'machine-choices.json')) } $StorePath }
        $before = & $version
        $have = @(if ($before) { & $module { param($rp) @((Read-VmfStoreJson -RunPath $rp -RelPath 'machine-choices.json').machines) } $StorePath })
        $want = @(@($have) + @($ids) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        if (@($want).Count -ne @($have).Count -or -not $before) {
            Set-VmfMachineChoice -RunPath $StorePath -Machines $want -ExpectedAdviceVersion $AdviceVersion -ExpectedChoiceVersion $before `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        }
        $a.MachinesVersion = & $version
    }
    Invoke-VmfFacadeSetTargets @a
}