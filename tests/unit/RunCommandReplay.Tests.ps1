#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RUNCMD-REPLAY-1: every guest script that changes the machine is followed at
# once by a neutral, read-only script.
#
# MEASURED 2026-10-11: after a machine went back to disks made from its first
# copy, Azure ran the machine's LAST Run Command again when it started. When
# the last Run Command before the put-back only read the machine, nothing came
# back. The first fix - remove the Run Command extension before the put-back
# starts the machine - had nothing to remove: a stopped machine lists no such
# extension. The decision the same day: after every script that changes
# the machine, run a neutral script that reads only the machine name and the
# time, so a command Azure runs again changes nothing.
#
# These tests pin: the follow-up is decided by the script, never by a call
# site; it runs after a changing script that failed too; it never runs after a
# read-only script; every script is classified; the neutral scripts change
# nothing and meet the output contract.
BeforeDiscovery {
    # TEST-BASH-WSL-1: the -Skip of the bash test is read at discovery.
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    $script:testBash = Get-VmfTestBash
}

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1'
    $script:guestRoot = Join-Path $script:repoRoot 'src' 'guest'
    $script:manifest = Get-Content (Join-Path $script:guestRoot 'manifest.json') -Raw | ConvertFrom-Json
    $script:followUp = InModuleScope VmMigrationFactory { @($script:VmfGuestFollowUpScripts) }

    # Every other script the manifest lists, classified by hand: a new script
    # fails the classification test until somebody decides which it is.
    $script:readOnly = @('Test-NvmeReady.ps1', 'Test-GuestValidation.ps1', 'Test-Imds.ps1', 'Test-ManaReady.ps1', 'Test-TempDiskContent.ps1',
        'Test-DataDiskSeed.ps1', 'nvme-check.sh', 'guest-validate.sh', 'imds-check.sh', 'mana-check.sh', 'data-disk-verify.sh', 'temp-disk-content.sh')
    # Lab only: the engine never runs them, and a drill runs them before the
    # move, so the product's own read-only checks always come after them.
    $script:labSeeds = @('Set-DataDiskSeed.ps1', 'data-disk-seed.sh')
    $script:neutral = @('Get-NeutralMark.ps1', 'neutral-mark.sh')

    # The script a run command carries, found by the name it declares.
    function Global:RcScriptOf([string]$Content) {
        foreach ($s in @($script:manifest.scripts)) {
            $text = Get-Content (Join-Path $script:guestRoot $s.os $s.name) -Raw
            if ($text -eq $Content) { return [string]$s.name }
        }
        'unknown'
    }
    function Global:RcRun([string]$Name) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'rc' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rc' -VmId $id | Out-Null
        }
        $rp
    }
    function Global:RcDrop($rp) { if ($rp -and (Test-Path $rp)) { [System.IO.Directory]::Delete($rp, $true) } }
    function Global:RcLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    # A Run Command answer in the contract, for the script that ran.
    function Global:RcAnswer([string]$Name, [string]$Result = 'READY') {
        '{"schema":"vmf.guest/2","script":"' + $Name + '","version":"1.0.0","result":"' + $Result + '","checks":[{"name":"a","status":"INFO"}]}'
    }
}
AfterAll {
    Remove-Item function:RcScriptOf, function:RcRun, function:RcDrop, function:RcLog, function:RcAnswer -ErrorAction SilentlyContinue
}

Describe 'RUNCMD-REPLAY-1: which scripts are followed' {
    It 'every script the engine runs that changes the machine is followed, the cluster check too, and nothing else is' {
        # CLUSTER-DETECT-1: the cluster check at Checking only reads, and the
        # design for it says the neutral script runs after it.
        @($script:followUp | Sort-Object) | Should -Be @(@('Set-NvmeReady.ps1', 'Move-Pagefile.ps1', 'Install-TempDiskInit.ps1', 'Install-ManaDriver.ps1', 'Repair-NvmeIoTimeout.ps1',
                'nvme-fix.sh', 'temp-disk-setup.sh', 'kernel-update.sh', 'Test-ClusterNode.ps1', 'cluster-node-check.sh',
                # VOLUMES-ONLINE-1: the refresh of the LVM devices file after a
                # rollback or a restore writes that file.
                'lvm-devices-refresh.sh',
                # VF-UNMANAGED-CONFIG-1: the read of the network settings at Checking, after the cluster check.
                'sriov-unmanaged-check.sh',
                # VOLUMES-ONLINE-V5-1: the start task of a move to v5 or Bsv2
                # (a preparation script). VOLUMES-ONLINE-WINDOWS-1: bringing a
                # Windows data disk online after a start on new disks.
                'lvm-devices-task.sh', 'Set-DataDisksOnline.ps1') | Sort-Object)
    }

    It 'every script in the manifest is classified - followed, read-only, a lab seed, or a neutral script' {
        $known = @($script:followUp) + $script:readOnly + $script:labSeeds + $script:neutral
        foreach ($s in @($script:manifest.scripts)) { $known | Should -Contain ([string]$s.name) -Because "$($s.name) must be classified: does it change the machine?" }
        @($known | Group-Object | Where-Object Count -GT 1).Count | Should -Be 0 -Because 'a script is in one class only'
    }

    It 'a neutral script is never followed itself' {
        foreach ($n in $script:neutral) { $script:followUp | Should -Not -Contain $n }
    }

    It 'every engine call of a changing script goes through the one runner that follows it' {
        # Invoke-VmfRunCommand is the only way a script reaches a guest, and
        # only the runner calls it - so no call site can skip the follow-up.
        $moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
        $callers = @(Get-ChildItem $moduleRoot -Filter '*.ps1' -Recurse | Where-Object {
                (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '(?<!function )\bInvoke-VmfRunCommand\b'
            } | ForEach-Object Name | Sort-Object -Unique)
        $callers | Should -Be @('GuestOps.ps1')
        foreach ($name in @($script:followUp)) {
            $sites = @(Get-ChildItem $moduleRoot -Filter '*.ps1' -Recurse | ForEach-Object {
                    [regex]::Matches((Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)), "Invoke-VmfGuestScriptOnVm\s+-ScriptName\s+'$([regex]::Escape($name))'")
                })
            $sites.Count | Should -BeGreaterThan 0 -Because "$name is run by the engine through Invoke-VmfGuestScriptOnVm"
        }
    }
}

Describe 'RUNCMD-REPLAY-1: the runner follows a changing script at once' {
    BeforeEach {
        $global:rc = @{ ran = [System.Collections.Generic.List[string]]::new(); failChanger = $null; markFails = 0; markResult = 'READY'; markLease = $false }
        $script:rp = RcRun
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
            $n = RcScriptOf $ScriptString
            $global:rc.ran.Add($n)
            if ($n -in @('Get-NeutralMark.ps1', 'neutral-mark.sh')) {
                if ($global:rc.markLease) { throw "Lease for 'vm1' is held by 'w2', not 'w1' - abandon this VM." }
                if ($global:rc.markFails -gt 0) { $global:rc.markFails--; throw 'RunCommand on vm1 returned an empty result.' }
                return (RcAnswer $n $global:rc.markResult)
            }
            if ($global:rc.failChanger) { throw $global:rc.failChanger }
            RcAnswer $n 'FIXED'
        }
    }
    AfterEach { RcDrop $script:rp; Remove-Variable rc -Scope Global -ErrorAction SilentlyContinue }

    It '<Name> is followed by <Neutral>, and nothing runs between them' -TestCases @(
        @{ Name = 'Set-NvmeReady.ps1'; Neutral = 'Get-NeutralMark.ps1' }
        @{ Name = 'Move-Pagefile.ps1'; Neutral = 'Get-NeutralMark.ps1' }
        @{ Name = 'Install-TempDiskInit.ps1'; Neutral = 'Get-NeutralMark.ps1' }
        @{ Name = 'Install-ManaDriver.ps1'; Neutral = 'Get-NeutralMark.ps1' }
        @{ Name = 'Repair-NvmeIoTimeout.ps1'; Neutral = 'Get-NeutralMark.ps1' }
        @{ Name = 'nvme-fix.sh'; Neutral = 'neutral-mark.sh' }
        @{ Name = 'temp-disk-setup.sh'; Neutral = 'neutral-mark.sh' }
        @{ Name = 'kernel-update.sh'; Neutral = 'neutral-mark.sh' }
    ) {
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; n = $Name } {
            param($rp, $id, $n) Invoke-VmfGuestScriptOnVm -ScriptName $n -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp
        }
        @($global:rc.ran) | Should -Be @($Name, $Neutral)
        $doc.result | Should -Be 'FIXED' -Because 'the caller gets the answer of the script it ran, never the neutral one'
        $audit = @((InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }).guestExecutions)
        @($audit | ForEach-Object script) | Should -Be @($Name, $Neutral) -Because 'the record says which script ran last'
        $audit[-1].result | Should -Be 'READY'
    }

    It 'a read-only script is never followed: <Name>' -TestCases @(
        @{ Name = 'Test-NvmeReady.ps1' }, @{ Name = 'Test-GuestValidation.ps1' }, @{ Name = 'Test-Imds.ps1' }, @{ Name = 'Test-ManaReady.ps1' }
        @{ Name = 'Test-TempDiskContent.ps1' }, @{ Name = 'temp-disk-content.sh' }, @{ Name = 'nvme-check.sh' }, @{ Name = 'guest-validate.sh' }, @{ Name = 'imds-check.sh' }, @{ Name = 'mana-check.sh' }
        @{ Name = 'Set-DataDiskSeed.ps1' }, @{ Name = 'data-disk-seed.sh' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; n = $Name } {
            param($rp, $id, $n) Invoke-VmfGuestScriptOnVm -ScriptName $n -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp | Out-Null
        }
        @($global:rc.ran) | Should -Be @($Name)
    }

    It 'a changing script that failed may still have run: the neutral script goes after it, and the failure is still thrown' {
        # Not a transient error: the retry wrapper would ask four times.
        $global:rc.failChanger = 'RunCommand on vm1 returned no result - verify the VM is running.'
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
                param($rp, $id) Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-fix.sh' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp
            } } | Should -Throw '*returned no result*'
        @($global:rc.ran) | Should -Be @('nvme-fix.sh', 'neutral-mark.sh')
    }

    It 'a lost lease runs nothing more: another worker has the machine' {
        $global:rc.failChanger = 'Lease lost - abandon this VM'
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
                param($rp, $id) Invoke-VmfGuestScriptOnVm -ScriptName 'Set-NvmeReady.ps1' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp
            } } | Should -Throw '*abandon this VM*'
        @($global:rc.ran) | Should -Be @('Set-NvmeReady.ps1')
    }

    It 'a neutral script that fails once is tried once more, and the move goes on with no warning' {
        $global:rc.markFails = 1
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id) Invoke-VmfGuestScriptOnVm -ScriptName 'Move-Pagefile.ps1' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp | Out-Null
        }
        @($global:rc.ran) | Should -Be @('Move-Pagefile.ps1', 'Get-NeutralMark.ps1', 'Get-NeutralMark.ps1')
        RcLog $script:rp | Should -Not -Match 'could not run the read-only script'
    }

    It 'a neutral script that fails twice: the move goes on, and the run history says the protection is missing' {
        $global:rc.markFails = 5
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id) Invoke-VmfGuestScriptOnVm -ScriptName 'temp-disk-setup.sh' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp
        }
        $doc.result | Should -Be 'FIXED'
        @($global:rc.ran) | Should -Be @('temp-disk-setup.sh', 'neutral-mark.sh', 'neutral-mark.sh')
        RcLog $script:rp | Should -Match 'The product ran temp-disk-setup.sh, then could not run the read-only script neutral-mark.sh twice'
        RcLog $script:rp | Should -Match 'Azure can run temp-disk-setup.sh again on them'
        # Never 'the move goes on': a caller stops it after a BLOCKED answer.
        RcLog $script:rp | Should -Match 'This alone does not stop the move'
        # Review finding: on its own step, which the run page shows as this
        # sentence (SAYS_ITSELF). Under the neutral run's label the sentence
        # was only in the hover, and the label said the protection was there.
        RcLog $script:rp | Should -Match '"step"\s*:\s*"neutralMark"'
    }

    It 'after a changing script that FAILED, the warning never says the move goes on - the failure is thrown next' {
        # Review finding: the words were the same on both paths, and on this
        # one the stop or the rollback follows at once.
        $global:rc.failChanger = 'RunCommand on vm1 returned no result - verify the VM is running.'
        $global:rc.markFails = 5
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
                param($rp, $id) Invoke-VmfGuestScriptOnVm -ScriptName 'Set-NvmeReady.ps1' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp
            } } | Should -Throw '*returned no result*'
        @($global:rc.ran) | Should -Be @('Set-NvmeReady.ps1', 'Get-NeutralMark.ps1', 'Get-NeutralMark.ps1')
        $log = RcLog $script:rp
        $log | Should -Match 'Set-NvmeReady.ps1 did not finish and can have changed the machine'
        $log | Should -Match 'Azure can run Set-NvmeReady.ps1 again on them'
        $log | Should -Not -Match 'The move goes on'
    }

    It 'a lost lease DURING the neutral run stops the worker: no second try, no warning, the move does not go on' {
        # Swallowed as "did not run", the worker would carry on moving a
        # machine another worker owns.
        $global:rc.markLease = $true
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
                param($rp, $id) Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-fix.sh' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp
            } } | Should -Throw '*abandon this VM*'
        @($global:rc.ran) | Should -Be @('nvme-fix.sh', 'neutral-mark.sh')
        RcLog $script:rp | Should -Not -Match 'could not run the read-only script'
    }

    It 'a lost lease during the neutral run after a FAILED changing script: the lost lease wins' {
        $global:rc.failChanger = 'RunCommand on vm1 returned no result - verify the VM is running.'
        $global:rc.markLease = $true
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
                param($rp, $id) Invoke-VmfGuestScriptOnVm -ScriptName 'kernel-update.sh' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp
            } } | Should -Throw '*abandon this VM*'
        @($global:rc.ran) | Should -Be @('kernel-update.sh', 'neutral-mark.sh')
    }

    It 'a neutral script that answers anything but READY counts as not run, and is tried once more' {
        $global:rc.markResult = 'BLOCKED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id) Invoke-VmfGuestScriptOnVm -ScriptName 'Install-ManaDriver.ps1' -ResourceGroupName 'rg-lab' -VmName 'vm1' -VmId $id -RunPath $rp | Out-Null
        }
        @($global:rc.ran) | Should -Be @('Install-ManaDriver.ps1', 'Get-NeutralMark.ps1', 'Get-NeutralMark.ps1')
        RcLog $script:rp | Should -Match 'it answered BLOCKED'
    }
}

Describe 'RUNCMD-REPLAY-1: the neutral scripts' {
    It 'both are in the manifest, for the right operating system, with the hash of the file' {
        foreach ($pair in @(@('Get-NeutralMark.ps1', 'windows'), @('neutral-mark.sh', 'linux'))) {
            $entry = @($script:manifest.scripts | Where-Object name -EQ $pair[0])
            $entry.Count | Should -Be 1
            $entry[0].os | Should -Be $pair[1]
            { InModuleScope VmMigrationFactory -Parameters @{ n = $pair[0] } { param($n) Get-VmfGuestScript -Name $n } } | Should -Not -Throw -Because 'the loader checks the hash'
        }
    }

    It 'the Windows script calls nothing but ConvertTo-Json - it changes nothing and checks nothing about the move' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:guestRoot 'windows' 'Get-NeutralMark.ps1'), [ref]$null, [ref]$null)
        $commands = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique)
        $commands | Should -Be @('ConvertTo-Json')
        $methods = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | ForEach-Object { [string]$_.Member.Value } | Sort-Object -Unique)
        $methods | Should -Be @('ToString')
    }

    It 'the Windows script runs under Windows PowerShell 5.1 rules: no ternary, no null-coalescing' {
        $code = Get-VmfCodeOnly -Language PowerShell -Path (Join-Path $script:guestRoot 'windows' 'Get-NeutralMark.ps1')
        $code | Should -Not -Match '\?\?'
        $code | Should -Not -Match '\s\?\s'
    }

    It 'the Linux script starts with #!/bin/bash and calls nothing that writes' {
        $text = Get-Content (Join-Path $script:guestRoot 'linux' 'neutral-mark.sh') -Raw
        $text | Should -Match '^#!/bin/bash'
        $code = Get-VmfCodeOnly -Language Shell -Text $text
        # The commands it may use: print, filter, read two values, end.
        $words = @([regex]::Matches($code, '(?m)(?:^|[|;(]|\$\()\s*([A-Za-z_][A-Za-z0-9_-]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($w in $words) { @('VMF_VERSION', 'SCRIPT_NAME', 'clean', 'printf', 'tr', 'NAME', 'NOW', 'cat', 'hostname', 'date', 'exit') | Should -Contain $w -Because "'$w' is not a command this script may call" }
        $code | Should -Not -Match '\btee\b|\btouch\b|\brm\b|\bmv\b|\bcp\b'
        # Review finding: the redirect check let '> /var/tmp/x' through (an
        # absolute path), so no redirect at all but the error one to /dev/null.
        ($code -replace '2>/dev/null', '') | Should -Not -Match '>'
        # And two of the allowed commands also SET what they read: hostname
        # with a name, date with -s. Each only in its reading form.
        @([regex]::Matches($code, '\bhostname\b[^)|;\r\n]*') | ForEach-Object { $_.Value.Trim() }) | ForEach-Object { $_ | Should -Match '^hostname(\s+2>/dev/null)?$' }
        @([regex]::Matches($code, '(?<![-/])\bdate\b[^)|;\r\n]*') | ForEach-Object { $_.Value.Trim() }) | ForEach-Object { $_ | Should -Match '^date -u \+\S+(\s+2>/dev/null)?$' }
    }

    It 'the Windows script, run here, prints one object in the output contract with the machine name and the time' {
        $out = & pwsh -NoProfile -File (Join-Path $script:guestRoot 'windows' 'Get-NeutralMark.ps1')
        $json = ($out | Out-String).Trim()
        Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -ErrorAction Stop | Should -BeTrue
        $doc = InModuleScope VmMigrationFactory -Parameters @{ raw = $json } { param($raw) ConvertFrom-VmfGuestOutput -RawOutput $raw }
        $doc.result | Should -Be 'READY'
        @($doc.checks | ForEach-Object name) | Should -Be @('machine name', 'time')
        @($doc.checks | ForEach-Object status) | Should -Be @('INFO', 'INFO')
        # Read from the text: the reader turns an ISO time into a date value.
        $json | Should -Match '"time","status":"INFO","detail":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"'
    }

    # TEST-BASH-WSL-1: the bash every shell test uses (_TestBash.ps1).
    It 'the Linux script, run here, prints one object in the output contract with the machine name and the time' -Skip:(-not $script:testBash) {
        $out = Invoke-VmfTestBash -ArgumentList @(ConvertTo-VmfTestBashPath -Path (Join-Path $script:guestRoot 'linux' 'neutral-mark.sh'))
        $json = ($out | Out-String).Trim()
        Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -ErrorAction Stop | Should -BeTrue
        $doc = InModuleScope VmMigrationFactory -Parameters @{ raw = $json } { param($raw) ConvertFrom-VmfGuestOutput -RawOutput $raw }
        $doc.result | Should -Be 'READY'
        @($doc.checks | ForEach-Object name) | Should -Be @('machine name', 'time')
        $json | Should -Match '"time","status":"INFO","detail":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"'

    }
}

Describe 'RUNCMD-REPLAY-1: the run page names the neutral script' {
    It 'its own words, matched before the generic "checks inside the machine"' {
        $page = Get-VmfCodeOnly -Language CStyle -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')
        $mark = $page.IndexOf("[/runcmd:(Get-NeutralMark|neutral-mark)/, 'guestMark']")
        $generic = $page.IndexOf("[/runcmd:/,                     'guestCheck']")
        $mark | Should -BeGreaterThan -1
        $mark | Should -BeLessThan $generic
        $page | Should -Match "guestMark:\s+'Running a read-only check, so that a restore cannot repeat the last change'"
    }
}
