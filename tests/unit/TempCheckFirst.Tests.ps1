#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEMPCHECK-FIRST-1: files on a Windows machine's SCSI temporary disk stop the
# move BEFORE guest preparation changes anything. The rule since 2026-09-28: a move
# is one change window, and a machine that stops for a person is left as it
# was. The check used to come from Move-Pagefile.ps1, after the NVMe driver
# setting and the page file had already been changed.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    function Global:TcCtx([string]$Os = 'Windows', [string]$From = 'scsi-temp', [string]$To = 'nvme-temp', [string]$OnData = 'stop') {
        @{ Plan = [pscustomobject]@{
                assessment = [pscustomobject]@{ os = $Os; sourceDiskArch = $From }
                target = [pscustomobject]@{ diskArch = $To }
                policy = [pscustomobject]@{ onDDataFound = $OnData } }
           Rg = 'rg'; VmName = 'vm'; VmId = '/vm'; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-no-store') }
    }
}
AfterAll { Remove-Item 'function:\TcCtx' -ErrorAction SilentlyContinue }

Describe 'TEMPCHECK-FIRST-1: the stop for files on the temporary disk' {
    BeforeEach {
        $script:answer = [pscustomobject]@{ result = 'NEEDS_PREP'; warnings = @('D:\CustomerData') }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { $script:answer }
    }

    It 'files found and the wave says stop: the machine stops for a person' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTempDiskContentStop -Context (Global:TcCtx)
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'dataOnTempDrive'
            $r.Detail | Should -Match 'CustomerData'
        }
    }

    It 'files found and the wave says proceed: no stop' {
        InModuleScope VmMigrationFactory { Get-VmfTempDiskContentStop -Context (Global:TcCtx -OnData 'proceed') | Should -BeNullOrEmpty }
    }

    It 'the check itself failed: a guest preparation stop, with its error' {
        $script:answer = [pscustomobject]@{ result = 'BLOCKED'; error = 'access denied'; warnings = @() }
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTempDiskContentStop -Context (Global:TcCtx)
            $r.Reason | Should -Be 'guestPrepBlocked'
            $r.Detail | Should -Match 'access denied'
        }
    }

    It 'not asked where nothing is lost: <Why>' -ForEach @(
        # LINUX-TEMP-DISK-FILES-1: a Linux machine is asked now (LinuxTempDiskFiles.Tests.ps1).
        @{ Why = 'no operating system the product knows'; Os = ''; From = 'scsi-temp'; To = 'nvme-temp' },
        @{ Why = 'no SCSI temporary disk now'; Os = 'Windows'; From = 'diskless'; To = 'nvme-temp' }) {
        InModuleScope VmMigrationFactory -Parameters @{ os = $Os; from = $From; to = $To } {
            Get-VmfTempDiskContentStop -Context (Global:TcCtx -Os $os -From $from -To $to) | Should -BeNullOrEmpty
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 0
    }

    It 'asked even when the target keeps a SCSI temporary disk: every move stops the machine, which can empty it' {
        InModuleScope VmMigrationFactory { (Get-VmfTempDiskContentStop -Context (Global:TcCtx -To 'scsi-temp')).Reason | Should -Be 'dataOnTempDrive' }
    }

    It 'Move-Pagefile.ps1 no longer lists the files - one place owns the list' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Move-Pagefile.ps1')
        $code | Should -Not -Match 'DumpStack'
        $code | Should -Not -Match "Get-ChildItem -Path 'D:"
    }
}

Describe 'TEMPCHECK-FIRST-1: asked in PRECHECK, while the machine runs, before anything stops it' {
    It 'GUEST_PREP no longer asks; PRECHECK does, only for a running machine, and the stop says untouched' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $prep = [regex]::Match($code, '(?s)function Invoke-VmfStepGuestPrep.*?\n\}').Value
        $pre = [regex]::Match($code, '(?s)function Invoke-VmfStepPrecheck.*?\n\}').Value
        $prep | Should -Not -Match 'Get-VmfTempDiskContentStop'
        # CLUSTER-NOT-RUNNING-1: the power state found before the cluster check
        # started the machine - the live one unless that check started it.
        $pre | Should -Match "if \(\`$powerFound -eq 'PowerState/running'\) \{\s+\`$tempStop = Get-VmfTempDiskContentStop"
        $pre | Should -Match '\$powerFound = \$power\s'
        $pre | Should -Match "\`$tempStop\.MachineState = 'untouched'"
    }

    It 'a machine that is not running is not asked - its temporary disk holds nothing to ask about' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { [pscustomobject]@{ result = 'NEEDS_PREP'; warnings = @('D:\x') } }
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $pre = [regex]::Match($code, '(?s)function Invoke-VmfStepPrecheck.*?\n\}').Value
        ([regex]::Matches($pre, 'Get-VmfTempDiskContentStop')).Count | Should -Be 1 -Because 'one call, inside the running check'
    }
}
