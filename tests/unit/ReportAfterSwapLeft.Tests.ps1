#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
REPORT-AFTER-SWAP-LEFT-1: the record and the report are written when a restore
leaves a machine stopped.

The restore operation wrote the migration record and the customer report
(Save-VmfRecordAndReport -Reason putBack) only after Restore-VmfVm returned. A
restore whose data disk swap Azure refused writes swapPending and the
restore's own record, and then throws - so the saved record and report kept
"migrated" until the daily check. The same is true of every restore that
throws AFTER it writes its record: a LUN left with no disk, and a data disk
that stopped part way on a machine that runs again.

The rule: when the restore throws, the engine writes them again in the same
finally as the summary, but only when THIS restore wrote its record - the
record names the engine operation (restore.operationId, the id
FINISH-NO-RESTORE-RECORD-1 already uses for it) - and the machine's document
changed during the operation (its PLANVER-2 version). A refusal before the
stop writes no record, so the report, which is built from the records, would
say the same; it is not written again. A failed write is a line in the engine
output, never a failed restore, and never hides the restore's own error.
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'

    # A run with one machine; -RecordOp puts a restore record that names that
    # operation on it.
    function Script:New-RasRun {
        param([string]$RecordOp)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ras-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vm = $script:vm; op = $RecordOp } {
            param($rp, $vm, $op)
            Initialize-VmfRun -RunPath $rp -RunId 'mig-ras' -Kind 'migration' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'mig-ras' -VmId $vm -Wave 'w1' | Out-Null
            if ($op) {
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
                $doc | Add-Member -NotePropertyName restore -Force -NotePropertyValue ([pscustomobject]@{ operationId = $op; restoredBy = 'user@example.com' })
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
        $rp
    }
    function Script:Set-RasRecord {
        param([string]$RunPath, [string]$Op)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; vm = $script:vm; op = $Op } {
            param($rp, $vm, $op)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName restore -Force -NotePropertyValue ([pscustomobject]@{ operationId = $op; restoredBy = 'user@example.com' })
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }
    function Script:Get-RasVersion {
        param([string]$RunPath)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; vm = $script:vm } {
            param($rp, $vm)
            Get-VmfStateDocVersion -RunPath $rp -VmId $vm
        }
    }
    function Script:Invoke-RasAfter {
        param([string]$RunPath, [string]$Op, [string]$Before = '')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; vm = $script:vm; op = $Op; before = $Before } {
            param($rp, $vm, $op, $before)
            Save-VmfRecordAndReportAfterRestore -RunPath $rp -VmId $vm -OperationId $op -VersionBefore $before
        }
    }
}

Describe 'REPORT-AFTER-SWAP-LEFT-1: the version of the machine''s record' {
    It 'is the PLANVER-2 version of the stored text' {
        $rp = New-RasRun
        try {
            $file = Join-Path $rp 'state' ((InModuleScope VmMigrationFactory -Parameters @{ vm = $script:vm } { param($vm) Get-VmfVmKey -VmId $vm }) + '.json')
            $want = InModuleScope VmMigrationFactory -Parameters @{ t = [System.IO.File]::ReadAllText($file) } { param($t) Get-VmfDocumentVersion -Text $t }
            Get-RasVersion -RunPath $rp | Should -Be $want
            $want | Should -Match '^[0-9a-f]{64}$'
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is empty for a machine with no record' {
        $rp = New-RasRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                param($rp)
                Get-VmfStateDocVersion -RunPath $rp -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/none'
            } | Should -Be ''
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'changes when the record is written' {
        $rp = New-RasRun
        try {
            $before = Get-RasVersion -RunPath $rp
            Set-RasRecord -RunPath $rp -Op 'op-1'
            Get-RasVersion -RunPath $rp | Should -Not -Be $before
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'REPORT-AFTER-SWAP-LEFT-1: writing them after a restore that threw' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Save-VmfRecordAndReport { [pscustomobject]@{ record = $true; report = $true } }
    }

    It 'writes them when this restore wrote its record during the operation (a swap left)' {
        $rp = New-RasRun
        try {
            $before = Get-RasVersion -RunPath $rp
            Set-RasRecord -RunPath $rp -Op 'op-1'
            Invoke-RasAfter -RunPath $rp -Op 'op-1' -Before $before | Should -BeTrue
            Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 1 -Exactly -ParameterFilter { $Reason -eq 'putBack' -and $RunPath -eq $rp }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes them when the version before is not known, and the record names this restore' {
        $rp = New-RasRun -RecordOp 'op-1'
        try {
            Invoke-RasAfter -RunPath $rp -Op 'op-1' -Before '' | Should -BeTrue
            Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 1 -Exactly
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not write them for a refusal before the stop: no restore record' {
        $rp = New-RasRun
        try {
            $before = Get-RasVersion -RunPath $rp
            Invoke-RasAfter -RunPath $rp -Op 'op-1' -Before $before | Should -BeFalse
            Invoke-RasAfter -RunPath $rp -Op 'op-1' -Before '' | Should -BeFalse
            Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 0 -Exactly
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not write them when the record is an earlier restore''s' {
        $rp = New-RasRun -RecordOp 'op-earlier'
        try {
            Invoke-RasAfter -RunPath $rp -Op 'op-1' -Before '' | Should -BeFalse
            Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 0 -Exactly
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not write them when the record names this restore but nothing changed during it (a refused resume)' {
        $rp = New-RasRun -RecordOp 'op-1'
        try {
            $before = Get-RasVersion -RunPath $rp
            Invoke-RasAfter -RunPath $rp -Op 'op-1' -Before $before | Should -BeFalse
            Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 0 -Exactly
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'compares the operation exactly: another case is another operation' {
        $rp = New-RasRun -RecordOp 'OP-1'
        try {
            Invoke-RasAfter -RunPath $rp -Op 'op-1' -Before '' | Should -BeFalse
            Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 0 -Exactly
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not write them with no operation id, even over a record that names none (before vm-state v32)' {
        $rp = New-RasRun
        try {
            Set-RasRecord -RunPath $rp -Op ''
            Invoke-RasAfter -RunPath $rp -Op '' -Before '' | Should -BeFalse
            Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 0 -Exactly
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a record that cannot be read throws, so the engine says it, and writes nothing' {
        $rp = New-RasRun -RecordOp 'op-1'
        try {
            Mock -ModuleName VmMigrationFactory Read-VmfStoreText { throw 'Store read failed: HTTP 503' }
            { Invoke-RasAfter -RunPath $rp -Op 'op-1' -Before '' } | Should -Throw '*HTTP 503*'
            Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 0 -Exactly
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'REPORT-AFTER-SWAP-LEFT-1: the restore operation, run with a fake module' {
    # RUN, not read: the restore branch of docker/entrypoint.ps1, with the
    # module and Restore-VmfVm replaced by fakes that record each call.
    BeforeAll {
        $entryFile = Join-Path $script:repo 'docker' 'entrypoint.ps1'
        $parsed = [System.Management.Automation.Language.Parser]::ParseFile($entryFile, [ref]$null, [ref]$null)
        $switch = @($parsed.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] -and
                    @($n.Clauses | Where-Object { $_.Item1.Extent.Text -eq "'restore'" }).Count }, $true))[0]
        $script:restoreBody = @($switch.Clauses | Where-Object { $_.Item1.Extent.Text -eq "'restore'" })[0].Item2.Extent.Text

        function Script:Invoke-RasBranch {
            param([string]$RestoreThrows, [string]$VersionThrows, [string]$AfterThrows, [string]$Version = 'v-before')
            $fake = New-Module -Name 'FakeVmfRestore' -ArgumentList $VersionThrows, $AfterThrows, $Version -ScriptBlock {
                param($vt, $at, $ver)
                $script:calls = [System.Collections.Generic.List[string]]::new()
                $script:vt = $vt; $script:at = $at; $script:ver = $ver
                function Add-Call([string]$c) { $script:calls.Add($c) }
                function Get-Calls { $script:calls.ToArray() }
                function Get-VmfStateDocVersion { param($RunPath, $VmId) Add-Call "version:$VmId"; if ($script:vt) { throw $script:vt }; $script:ver }
                function Update-VmfRunSummaryAfterPutBack { param($RunPath, $VmId) Add-Call 'summary' }
                function Save-VmfRecordAndReport { param($RunPath, $Reason) Add-Call "save:$Reason" }
                function Save-VmfRecordAndReportAfterRestore { param($RunPath, $VmId, $OperationId, $VersionBefore) Add-Call "after:${VmId}:${OperationId}:$VersionBefore"; if ($script:at) { throw $script:at }; $true }
                Export-ModuleMember -Function *
            }
            $restore = if ($RestoreThrows) {
                "function Restore-VmfVm { & `$fake { Add-Call 'restore' }; throw '$RestoreThrows' }"
            } else {
                "function Restore-VmfVm { & `$fake { Add-Call 'restore' }; [pscustomobject]@{ VmId = 'vm1'; RestoredFromSnapshotId = 's'; NewDiskName = 'd'; DiskIdChanged = `$true; DataDisks = @(); DataDisksKept = @() } }"
            }
            $body = "param(`$fake)`nfunction Get-Module { `$fake }`nfunction Write-Host { param([object]`$Object) & `$fake { param(`$o) Add-Call ""host:`$o"" } `$Object }`n$restore`n`$runPath = 'azblob://store/runs/r1'`n`$engineRunId = 'op-1'`n`$resumeId = ''`n& " + $script:restoreBody
            $saved = @{ vm = $env:VMF_VM_ID; by = $env:VMF_RESTORED_BY }
            $err = $null
            try {
                $env:VMF_VM_ID = 'vm-id-1'
                $env:VMF_RESTORED_BY = 'user@example.com'
                try { & ([scriptblock]::Create($body)) $fake } catch { $err = $_.Exception.Message }
            }
            finally { $env:VMF_VM_ID = $saved.vm; $env:VMF_RESTORED_BY = $saved.by }
            [pscustomobject]@{ Error = $err; Calls = @(& $fake { Get-Calls }) }
        }
    }

    It 'found the restore branch' {
        $script:restoreBody | Should -Match 'Restore-VmfVm @restoreParams'
    }

    It 'a restore that throws: the record and the report are written for this operation, with the version read BEFORE the restore, and the restore''s own error stands' {
        $out = Invoke-RasBranch -RestoreThrows 'The restore did not finish, and the machine is left STOPPED.'
        $out.Error | Should -Be 'The restore did not finish, and the machine is left STOPPED.'
        $out.Calls | Should -Contain 'after:vm-id-1:op-1:v-before'
        $out.Calls | Should -Contain 'summary' -Because 'RUN-SUMMARY-SWAP-1 still writes the summary'
        [array]::IndexOf($out.Calls, 'version:vm-id-1') | Should -BeLessThan ([array]::IndexOf($out.Calls, 'restore'))
        [array]::IndexOf($out.Calls, 'after:vm-id-1:op-1:v-before') | Should -BeGreaterThan ([array]::IndexOf($out.Calls, 'restore'))
        @($out.Calls | Where-Object { $_ -like 'save:*' }).Count | Should -Be 0 -Because 'the write after a restore that returned does not run'
    }

    It 'a restore that returns: written once, as before, and not by the call for a restore that threw' {
        $out = Invoke-RasBranch
        $out.Error | Should -BeNullOrEmpty
        @($out.Calls | Where-Object { $_ -eq 'save:putBack' }).Count | Should -Be 1
        @($out.Calls | Where-Object { $_ -like 'after:*' }).Count | Should -Be 0
    }

    It 'a write that fails is a line in the engine output, and the error is still the restore''s own' {
        $out = Invoke-RasBranch -RestoreThrows 'Azure did not swap these data disks back.' -AfterThrows 'Store read failed: HTTP 503'
        $out.Error | Should -Be 'Azure did not swap these data disks back.'
        $out.Calls | Should -Contain 'host:engine: the record and the report could not be written after this restore: Store read failed: HTTP 503'
    }

    It 'a version that cannot be read before the restore never stops it, and is passed as not known' {
        $out = Invoke-RasBranch -RestoreThrows 'The restore did not complete.' -VersionThrows 'Store read failed'
        $out.Calls | Should -Contain 'restore'
        $out.Calls | Should -Contain 'after:vm-id-1:op-1:'
        $out.Error | Should -Be 'The restore did not complete.'
    }

    It 'a version that cannot be read before a restore that returns changes nothing' {
        $out = Invoke-RasBranch -VersionThrows 'Store read failed'
        $out.Error | Should -BeNullOrEmpty
        @($out.Calls | Where-Object { $_ -eq 'save:putBack' }).Count | Should -Be 1
    }
}
