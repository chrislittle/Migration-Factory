#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SNAPSHOT-NAME-END-1: a safety copy's name ended with a hyphen.
#
# The final lab, day 2 (2026-11-17): a machine's move failed twice at the
# second safety copy with "The value of parameter snapshot.name is invalid"
# (ErrorTarget snapshot.name), then rolled back. Get-VmfSafetyCopyName cut
# '<vm>-vmf-<run>' to 75 characters and did not look at the last character:
# for the run id below the cut fell just after a hyphen.
#
# Microsoft, "Naming rules and restrictions for Azure resources",
# Microsoft.Compute: snapshots are 1-80 characters of alphanumerics,
# underscores, periods and hyphens, start with an alphanumeric, and end with
# an alphanumeric or an underscore. disks are 1-80 characters of
# alphanumerics, underscores and hyphens.
#
# The rule now: every name the product makes for an Azure resource goes
# through ConvertTo-VmfAzureName, which cuts to the length and never ends the
# name with a hyphen or a period. A name that was valid before is the same.
# The names below are made up.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # The snapshot rule, written from Microsoft's page and not from the code.
    function script:Test-SnapshotNameValid([string]$Name, [int]$Max = 80) {
        $Name.Length -ge 1 -and $Name.Length -le $Max -and
            $Name -cmatch '^[A-Za-z0-9][A-Za-z0-9_.\-]*$' -and $Name -cmatch '[A-Za-z0-9_]$'
    }
    function script:Test-DiskNameValid([string]$Name) {
        $Name.Length -ge 1 -and $Name.Length -le 80 -and $Name -cmatch '^[A-Za-z0-9_\-]+$' -and $Name -cmatch '[A-Za-z0-9_]$'
    }
    # The rule before this item, kept here so the test can prove a name that
    # was valid then is the same now.
    function script:Get-OldSafetyCopyName([string]$VmName, [string]$RunId, [string]$Kind, [int]$Attempt, [int]$Lun) {
        $tail = "$(if ($Kind -eq 'pristine') { '-pristine' })$(if ($Lun -ge 0) { "-d$Lun" })$(if ($Attempt -gt 1) { "-a$Attempt" })"
        $base = ('{0}-vmf-{1}' -f $VmName, $RunId) -replace '[^A-Za-z0-9\-]', '-'
        if ($base.Length + $tail.Length -gt 75) { $base = $base.Substring(0, 75 - $tail.Length) }
        "$base$tail"
    }

    # Text of any length with hyphens and dots in many places, so a cut lands
    # on one at every length.
    function script:Get-Filler([int]$Length, [string]$Pattern) {
        $text = ''
        while ($text.Length -lt $Length) { $text += $Pattern }
        $text.Substring(0, $Length)
    }
}

Describe 'SNAPSHOT-NAME-END-1: the lab case' {
    It 'the second safety copy of f-wr1 ends with a letter or a number, and Azure would take it' {
        $name = InModuleScope VmMigrationFactory {
            Get-VmfSafetyCopyName -VmName 'f-wr1' -RunId 'assessment-2026-11-17-1009day2-restore-policy-migration-20261117-151254' -Kind 'prepared'
        }
        $name | Should -Not -Match '-$'
        Test-SnapshotNameValid $name | Should -BeTrue -Because "'$name' must follow the snapshot naming rule"
        $name | Should -Be 'f-wr1-vmf-assessment-2026-11-17-1009day2-restore-policy-migration-20261117' -Because 'only the hyphen the cut left at the end comes off'
    }

    It 'the first safety copy of the same machine was valid, and it is the same' {
        $args1 = @{ VmName = 'f-wr1'; RunId = 'assessment-2026-11-17-1009day2-restore-policy-migration-20261117-151254'; Kind = 'pristine' }
        $name = InModuleScope VmMigrationFactory -Parameters @{ a = $args1 } { param($a) Get-VmfSafetyCopyName @a }
        $name | Should -Be (Get-OldSafetyCopyName -VmName 'f-wr1' -RunId $args1.RunId -Kind 'pristine' -Attempt 1 -Lun -1)
        Test-SnapshotNameValid $name | Should -BeTrue
    }
}

Describe 'SNAPSHOT-NAME-END-1: every safety copy name follows the snapshot rule' {
    BeforeAll {
        $script:cases = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $add = { param($vm, $run) if ($seen.Add("$vm|$run")) { $script:cases.Add(@{ VmName = $vm; RunId = $run }) } }
        foreach ($len in 1..120) {
            foreach ($pattern in 'ab-', 'a.b-c_', 'x--', 'srv1') {
                & $add (Get-Filler $len $pattern) 'run-2026-11-17-151254'
                & $add 'vm1' (Get-Filler $len $pattern)
            }
        }
        $script:results = InModuleScope VmMigrationFactory -Parameters @{ cases = $script:cases } {
            param($cases)
            foreach ($c in $cases) {
                foreach ($kind in 'pristine', 'prepared') {
                    foreach ($lun in -1, 0, 7, 31) {
                        foreach ($attempt in 1, 2, 10) {
                            [pscustomobject]@{
                                VmName = $c.VmName; RunId = $c.RunId; Kind = $kind; Lun = $lun; Attempt = $attempt
                                Name = (Get-VmfSafetyCopyName -VmName $c.VmName -RunId $c.RunId -Kind $kind -Lun $lun -Attempt $attempt)
                            }
                        }
                    }
                }
            }
        }
    }

    It 'made a name for every case' {
        @($script:results).Count | Should -Be ($script:cases.Count * 24)
    }

    It 'every name is at most 75 characters, starts with a letter or a number, ends with a letter, a number or an underscore, and has only allowed characters' {
        $bad = @($script:results | Where-Object { -not (Test-SnapshotNameValid $_.Name 75) } | Select-Object -First 5 | ForEach-Object { $_.Name })
        $bad | Should -BeNullOrEmpty
    }

    It 'every name keeps its whole tail: kind, LUN and attempt' {
        $bad = @($script:results | Where-Object {
            $tail = "$(if ($_.Kind -eq 'pristine') { '-pristine' })$(if ($_.Lun -ge 0) { "-d$($_.Lun)" })$(if ($_.Attempt -gt 1) { "-a$($_.Attempt)" })"
            -not $_.Name.EndsWith($tail)
        } | Select-Object -First 5 | ForEach-Object { $_.Name })
        $bad | Should -BeNullOrEmpty
    }

    It 'a name that was valid before this change is the same now' {
        $changed = @($script:results | Where-Object {
            $old = Get-OldSafetyCopyName -VmName $_.VmName -RunId $_.RunId -Kind $_.Kind -Attempt $_.Attempt -Lun $_.Lun
            (Test-SnapshotNameValid $old 75) -and $old -cne $_.Name
        } | Select-Object -First 5 | ForEach-Object { $_.Name })
        $changed | Should -BeNullOrEmpty
    }

    It 'the sweep holds names the old rule made invalid, so it tests the new rule' {
        $wasBad = @($script:results | Where-Object {
            -not (Test-SnapshotNameValid (Get-OldSafetyCopyName -VmName $_.VmName -RunId $_.RunId -Kind $_.Kind -Attempt $_.Attempt -Lun $_.Lun) 75)
        })
        $wasBad.Count | Should -BeGreaterThan 0
    }

    It 'two names that differ only in the kind, the LUN or the attempt stay different' {
        $groups = @($script:results | Group-Object VmName, RunId | Where-Object { @($_.Group.Name | Sort-Object -Unique).Count -ne $_.Count })
        $groups.Count | Should -Be 0
    }
}

Describe 'SNAPSHOT-NAME-END-1: every disk name made from a disk name follows the disk rule' {
    BeforeAll {
        $script:diskCases = [System.Collections.Generic.List[object]]::new()
        foreach ($len in 1..120) {
            foreach ($pattern in 'ab-', 'a_b-c', 'osdisk1') {
                $base = Get-Filler $len $pattern
                if (-not ($base -cmatch '^[A-Za-z0-9]')) { continue }
                foreach ($suffix in '-asitwas-202611171512', '-d0-asitwas-202611171512', '-d31-restored-202611171512', '-restored-202611171512', '-rtmp-202611171512', '-d7-rtmp-202611171512') {
                    $script:diskCases.Add(@{ Base = $base; Suffix = $suffix })
                }
            }
        }
        $script:diskResults = InModuleScope VmMigrationFactory -Parameters @{ cases = $script:diskCases } {
            param($cases)
            foreach ($c in $cases) { [pscustomobject]@{ Base = $c.Base; Suffix = $c.Suffix; Name = (Get-VmfBoundedDiskName -BaseName $c.Base -Suffix $c.Suffix) } }
        }
    }

    It 'every name is a valid disk name and keeps its suffix' {
        $bad = @($script:diskResults | Where-Object { -not (Test-DiskNameValid $_.Name) -or -not $_.Name.EndsWith($_.Suffix) } | Select-Object -First 5 | ForEach-Object { $_.Name })
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'SNAPSHOT-NAME-END-1 review: a disk name with a period or a space is made as before, never refused' {
    # Azure names a Linux machine's OS disk '<vm>_OsDisk_1_<guid>', and a Linux
    # machine name may hold a period. A derived disk name is made inside the
    # stopped window, so a refusal here would leave the machine stopped.
    BeforeAll {
        $script:oddCases = [System.Collections.Generic.List[object]]::new()
        foreach ($len in 1..120) {
            foreach ($pattern in 'web.01_osdisk', 'a.b-', 'x..y_', 'app 1.') {
                $base = Get-Filler $len $pattern
                foreach ($suffix in '-asitwas-202611171512', '-d0-asitwas-202611171512', '-d31-restored-202611171512', '-rtmp-202611171512') {
                    $script:oddCases.Add(@{ Base = $base; Suffix = $suffix })
                }
            }
        }
        $script:oddResults = InModuleScope VmMigrationFactory -Parameters @{ cases = $script:oddCases } {
            param($cases)
            foreach ($c in $cases) {
                # The rule before SNAPSHOT-NAME-END-1, step by step.
                $base = Remove-VmfDiskNameSuffix -Name $c.Base -MaxLength 80
                $room = 80 - $c.Suffix.Length
                if ($base.Length -gt $room) { $base = $base.Substring(0, $room) }
                $base = $base.TrimEnd('-', '.', '_')
                $old = "$base$($c.Suffix)"
                $new = try { Get-VmfBoundedDiskName -BaseName $c.Base -Suffix $c.Suffix } catch { "THREW: $($_.Exception.Message)" }
                [pscustomobject]@{ Base = $c.Base; Suffix = $c.Suffix; Old = $old; New = $new; OldBaseEmpty = (-not $base) }
            }
        }
    }

    It 'the reviewer''s case: web.01_osdisk gets its suffix' {
        InModuleScope VmMigrationFactory { Get-VmfBoundedDiskName -BaseName 'web.01_osdisk' -Suffix '-asitwas-202611171512' } |
            Should -BeExactly 'web.01_osdisk-asitwas-202611171512'
    }

    It 'every name is the name the old rule made, and none is refused' {
        $changed = @($script:oddResults | Where-Object { -not $_.OldBaseEmpty -and $_.New -cne $_.Old } | Select-Object -First 5 | ForEach-Object { "$($_.Base) -> $($_.New)" })
        $changed | Should -BeNullOrEmpty
    }

    It 'the sweep holds names with a period and with a space' {
        @($script:oddResults | Where-Object { $_.New -like '*.*' }).Count | Should -BeGreaterThan 0
        @($script:oddResults | Where-Object { $_.New -like '* *' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'SNAPSHOT-NAME-END-1: ConvertTo-VmfAzureName, the one shared rule' {
    It 'cuts <name> with the suffix <suffix> to <max> and gives <want>' -TestCases @(
        @{ name = 'abc-def-'; suffix = ''; max = 8; rule = 'snapshot'; want = 'abc-def' }
        @{ name = 'abc-def-ghi'; suffix = ''; max = 8; rule = 'snapshot'; want = 'abc-def' }
        @{ name = 'abc-de.-ghi'; suffix = ''; max = 7; rule = 'snapshot'; want = 'abc-de' }
        @{ name = 'abc-def_ghi'; suffix = ''; max = 8; rule = 'snapshot'; want = 'abc-def_' }
        @{ name = 'abc-def-ghi'; suffix = '-a2'; max = 8; rule = 'snapshot'; want = 'abc-d-a2' }
        @{ name = 'abc--def'; suffix = '-a2'; max = 7; rule = 'snapshot'; want = 'abc--a2' }
        @{ name = 'abcdef'; suffix = ''; max = 80; rule = 'snapshot'; want = 'abcdef' }
        @{ name = '-abc'; suffix = ''; max = 80; rule = 'snapshot'; want = 'abc' }
        @{ name = 'web.01_osdisk'; suffix = '-rtmp-202611171512'; max = 80; rule = 'disk'; want = 'web.01_osdisk-rtmp-202611171512' }
        @{ name = 'web.01_osdisk'; suffix = '-rtmp-202611171512'; max = 20; rule = 'disk'; want = 'we-rtmp-202611171512' }
        @{ name = 'web.01 os.'; suffix = ''; max = 80; rule = 'disk'; want = 'web.01 os.' }
        @{ name = 'vmf-run-wave-1234567-'; suffix = '-0a1b2c3d'; max = 30; rule = 'capacityReservationGroup'; want = 'vmf-run-wave-1234567--0a1b2c3d' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ n = $name; s = $suffix; m = $max; r = $rule } {
            param($n, $s, $m, $r) ConvertTo-VmfAzureName -Name $n -Suffix $s -MaxLength $m -Rule $r
        } | Should -BeExactly $want
    }

    It 'refuses a name it cannot make valid: <why>' -TestCases @(
        @{ why = 'nothing is left'; name = '---'; suffix = ''; max = 80; rule = 'snapshot' }
        @{ why = 'the suffix fills the length'; name = 'abc'; suffix = '-pristine'; max = 9; rule = 'snapshot' }
        @{ why = 'the suffix ends with a hyphen'; name = 'abc'; suffix = '-x-'; max = 80; rule = 'snapshot' }
        @{ why = 'a disk name has nothing before its suffix'; name = ''; suffix = '-rtmp-202611171512'; max = 80; rule = 'disk' }
        @{ why = 'a disk name is longer than 80'; name = 'abc'; suffix = '-rtmp-202611171512'; max = 81; rule = 'disk' }
        @{ why = 'a snapshot name holds a space'; name = 'abc def'; suffix = ''; max = 80; rule = 'snapshot' }
    ) {
        { InModuleScope VmMigrationFactory -Parameters @{ n = $name; s = $suffix; m = $max; r = $rule } {
            param($n, $s, $m, $r) ConvertTo-VmfAzureName -Name $n -Suffix $s -MaxLength $m -Rule $r
        } } | Should -Throw
    }

    It 'the capacity reservation group name of a long run and wave ends with its code, as before' {
        $claim = [pscustomobject]@{ runId = (Get-Filler 90 'run-2026-'); wave = 'wave-1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
                                    region = 'westus3'; zone = '1'; size = 'Standard_D2ds_v6'; resourceGroup = 'rg-example' }
        $names = InModuleScope VmMigrationFactory -Parameters @{ c = $claim } { param($c) Get-VmfReservationNames -Claim $c -ForNewAsk }
        $names.GroupName.Length | Should -Be 76
        $names.GroupName | Should -Match '-[0-9a-f]{8}$'
        $names.GroupName | Should -Match '^[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9]$'
    }
}

Describe 'SNAPSHOT-NAME-END-1: every name the product makes goes through the shared rule' {
    It '<function> calls ConvertTo-VmfAzureName' -TestCases @(
        @{ function = 'Get-VmfSafetyCopyName'; file = 'Private/engine/StateMachine.ps1' }
        @{ function = 'Get-VmfBoundedDiskName'; file = 'Private/azureops/AzureOpsVm.ps1' }
        @{ function = 'Get-VmfReservationNames'; file = 'Private/capacity/CapacityClaim.ps1' }
    ) {
        $path = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $file
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $function }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $calls = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertTo-VmfAzureName' }, $true))
        $calls.Count | Should -BeGreaterThan 0
    }
}
