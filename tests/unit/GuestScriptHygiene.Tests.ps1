#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Guest scripts run on customer machines, unattended, with no one watching the
# screen. A character you cannot see is therefore worse here than anywhere else
# in the tree.
#
# This exists because a control character reached these files THREE TIMES in one
# session, from the same cause: a shell heredoc collapsing a doubled backslash,
# after which "\5" became a literal 0x05 (octal escape) and "\vpci" became 0x0B
# followed by "pci" (vertical tab). Both PARSE FINE - PowerShell is happy, the
# analyzer is happy, the manifest hashes the damage and CI goes green - and both
# would have shipped a registry path pointing somewhere that does not exist.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:guestFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'guest') -File -Recurse |
        Where-Object { $_.Extension -in '.ps1', '.sh', '.rules', '.json' })
}

Describe 'Guest assets contain nothing invisible' {
    It 'found the guest files' {
        @($script:guestFiles).Count | Should -BeGreaterThan 8
    }

    It 'no control characters - only tab, CR and LF are legitimate' {
        $offenders = @(foreach ($f in $script:guestFiles) {
            $text = Get-Content $f.FullName -Raw
            if (-not $text) { continue }
            $lineNo = 0
            foreach ($line in ($text -split "`n")) {
                $lineNo++
                foreach ($ch in $line.ToCharArray()) {
                    $code = [int]$ch
                    # tab (9) is fine; CR (13) survives -split "`n"
                    if ($code -lt 32 -and $code -ne 9 -and $code -ne 13) {
                        "$($f.Name):$lineNo has 0x{0:X2}" -f $code
                        break
                    }
                }
            }
        })
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'these parse fine, hash fine, and point at a registry path that does not exist'
    }

    It 'registry paths in the Windows scripts look like registry paths' {
        # The specific damage both incidents caused: a backslash-escape eaten out
        # of the middle of a path.
        # The prep builds paths from the service loop, so the literal only
        # appears in the checker. Assert what each file actually says rather
        # than a shape neither of them quite has.
        $prep = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Set-NvmeReady.ps1') -Raw
        $check = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-NvmeReady.ps1') -Raw

        $prep | Should -Match 'Services\\stornvme\\Parameters' -Because 'the parameters key must be a real path'
        $check | Should -Match 'Services\\vpci' -Because 'the checker names the Virtual PCI service directly'

        # The exact damage both incidents did: the character after the backslash
        # swallowed into a control code. A real path has a printable one.
        foreach ($text in $prep, $check) {
            $text | Should -Match 'PnpInterface\\5' -Because 'the value is addressed as PnpInterface\5'
        }
    }
}

Describe 'UPST-2: the keys Microsoft added for the post-conversion BSOD' {
    BeforeAll {
        $script:prep = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Set-NvmeReady.ps1') -Raw
        $script:check = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-NvmeReady.ps1') -Raw
    }

    It 'prep clears vpci StartOverride as well as stornvme and pci' {
        # The one that stands out: NVMe on Boost arrives over Virtual PCI, so a
        # vpci StartOverride hides the controller the machine boots from.
        $script:prep | Should -Match "@\('stornvme', 'pci', 'vpci'\)"
    }

    It 'prep sets every stornvme parameter from the upstream fix' {
        foreach ($v in 'IoTimeoutValue', 'BusType', 'StorageSupportedFeatures') {
            $script:prep | Should -Match $v
        }
        $script:prep | Should -Match "Name '5' -Value 1"
    }

    It 'IoTimeoutValue is 240 - the same number we already use on Linux' {
        $script:prep | Should -Match "IoTimeoutValue';\s*Value = 240"
        $linux = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'nvme-fix.sh') -Raw
        $linux | Should -Match 'nvme_core\.io_timeout=240'
    }

    It 'and it does all of it across ALL ControlSets, like everything else here' {
        # LastKnownGood with a stale value is the original INACCESSIBLE_BOOT_DEVICE
        # lesson; new keys inherit it or they are worse than useless.
        #
        # This used to assert "within 4000 characters of the loop", which broke
        # the moment the loop grew - a distance is not a structure. Take the
        # loop's actual body and look inside it.
        $loopStart = $script:prep.IndexOf('foreach ($cs in $controlSets)')
        $loopStart | Should -BeGreaterThan 0 -Because 'the ControlSet loop must exist at all'
        $depth = 0; $bodyStart = -1; $bodyEnd = -1
        for ($i = $loopStart; $i -lt $script:prep.Length; $i++) {
            $ch = $script:prep[$i]
            if ($ch -eq '{') { if ($depth -eq 0) { $bodyStart = $i }; $depth++ }
            elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $bodyEnd = $i; break } }
        }
        $bodyEnd | Should -BeGreaterThan $bodyStart -Because 'the loop body must be findable'
        $body = $script:prep.Substring($bodyStart, $bodyEnd - $bodyStart)
        $body | Should -Match 'IoTimeoutValue' -Because 'the timeout must be written for EVERY control set'
        $body | Should -Match 'PnpInterface' -Because 'so must the PnP interface flag'
    }

    It 'the checker reports on them too, or validation cannot see them' {
        $script:check | Should -Match 'vpci StartOverride'
        $script:check | Should -Match 'IoTimeoutValue'
        $script:check | Should -Match 'PnpInterface'
    }

    It 'a missing vpci service is INFO, not a failure' {
        # Not every image has vpci. Absent is not the same as misconfigured, and
        # turning unknown into a fail is the mistake DRIVER-1 taught us.
        $script:check | Should -Match "vpci service not present"
        $script:check | Should -Match "'INFO'"
    }
}

Describe 'UPST-2: the I/O timeout is restored AFTER the first NVMe boot' {
    # MEASURED on vmf-upst2-win, not inferred. Prep set 240 in both ControlSets;
    # after the conversion the set the machine booted from read 10 and the other
    # still read 240. Microsoft's changelog says the same and ships a
    # post-conversion command. A machine left at 10 is not visibly broken - it
    # will drop a disk under a transient stall it should have ridden out.
    BeforeAll {
        $script:root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:sm = Get-Content (Join-Path $script:root 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $script:repair = Get-Content (Join-Path $script:root 'src' 'guest' 'windows' 'Repair-NvmeIoTimeout.ps1') -Raw
    }

    It 'the repair runs in STARTING - after the boot that resets it' {
        # Ordering is the entire finding. Setting it in prep cannot survive the
        # boot, so a repair anywhere earlier is a repair that does nothing.
        $starting = [regex]::Match($script:sm, '(?s)function Invoke-VmfStepStarting.*?\n\}').Value
        $starting | Should -Match 'Repair-NvmeIoTimeout\.ps1'
        $starting | Should -Match "Next = 'VALIDATING'"
        $idxRepair = $starting.IndexOf('Repair-NvmeIoTimeout.ps1')
        $idxNext = $starting.IndexOf("Next = 'VALIDATING'")
        $idxRepair | Should -BeLessThan $idxNext -Because 'validation must judge the machine after the repair, not before'
    }

    It 'and only for Windows machines going to NVMe' {
        $script:sm | Should -Match "assessment\.os -eq 'Windows' -and .*controller -eq 'NVMe'"
    }

    It 'it restores 240 across ALL ControlSets and flushes' {
        $script:repair | Should -Match 'IoTimeoutValue'
        $script:repair | Should -Match '-Value 240'
        $script:repair | Should -Match 'ControlSet'
        $script:repair | Should -Match 'Flush\(\)'
    }

    It 'reports what it FOUND as a fact, so the engine judges the reset' {
        # The guest says "it was 10"; the engine decides that is worth telling
        # an operator about. Guests report facts.
        # GUEST-2 flattened this: one declared fact carrying every ControlSet
        # ("ControlSet001=10 ControlSet002=240"), because a declared contract
        # cannot describe field names it does not know in advance.
        $script:repair | Should -Match "Add-Fact 'ioTimeoutBefore'"
        $script:sm | Should -Match 'ioTimeoutBefore'
    }

    It 'a repair that cannot persist BLOCKS rather than reporting success' {
        $script:repair | Should -Match "post-flush verify"
        $script:repair | Should -Match "'FAIL'"
        $script:repair | Should -Match "Emit -Result 'BLOCKED'"
    }

    It 'validation reports the timeout per ControlSet, so a reset cannot pass unseen' {
        $val = Get-Content (Join-Path $script:root 'src' 'guest' 'windows' 'Test-GuestValidation.ps1') -Raw
        $val | Should -Match "Add-Fact 'ioTimeout'"
    }

    It 'the new script is in the manifest with a correct hash' {
        # CI fails on manifest drift; this fails sooner and says why.
        $manifest = Get-Content (Join-Path $script:root 'src' 'guest' 'manifest.json') -Raw | ConvertFrom-Json
        $entry = @($manifest.scripts | Where-Object { $_.name -match 'Repair-NvmeIoTimeout' })
        @($entry).Count | Should -Be 1
        $file = Join-Path $script:root 'src' 'guest' 'windows' 'Repair-NvmeIoTimeout.ps1'
        $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $entry[0].sha256 | Should -Be $hash
    }
}

Describe 'LVM-1: the Linux scripts report LVM as a FACT' {
    BeforeAll {
        $script:lvmScripts = @('guest-validate.sh', 'nvme-check.sh') | ForEach-Object {
            [pscustomobject]@{
                Name = $_
                Text = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'guest' 'linux' $_) -Raw
            }
        }
    }

    It 'both scripts say whether the root is on LVM' {
        # Nothing in the guest scripts knew what LVM was, so an
        # LVM machine was indistinguishable from a plain one at assessment time.
        foreach ($s in $script:lvmScripts) {
            $s.Text | Should -Match 'add_check "lvm root"' -Because "$($s.Name) must report it"
        }
    }

    It 'and they REPORT, never judge - every LVM check is INFO' {
        # The SCSI-direction rule: guests report facts, the ENGINE judges them
        # against the plan. An LVM root is not a problem; it is a fact that
        # changes what "the initramfs is ready" means.
        foreach ($s in $script:lvmScripts) {
            $lvm = [regex]::Matches($s.Text, 'add_check "lvm[^"]*" "([A-Z]+)"')
            @($lvm).Count | Should -BeGreaterThan 1
            foreach ($m in $lvm) {
                $m.Groups[1].Value | Should -Be 'INFO' -Because "$($s.Name) must not decide anything about LVM"
            }
        }
    }

    It 'they report whether LVM is in the initramfs, which is the thing that breaks a boot' {
        # On an LVM root the volume group must be assembled BEFORE the root can
        # be mounted, so the initramfs needs both the LVM tooling and the NVMe
        # modules - miss either and the machine cannot find its own root.
        foreach ($s in $script:lvmScripts) {
            $s.Text | Should -Match 'lvm in initramfs'
        }
    }

    It 'and name the physical volumes - the devices that must survive the change' {
        foreach ($s in $script:lvmScripts) {
            $s.Text | Should -Match 'lvm physical volumes'
        }
    }

    It 'a machine with no LVM says so, rather than staying silent' {
        # Silence is indistinguishable from "the script is too old to know".
        foreach ($s in $script:lvmScripts) {
            $s.Text | Should -Match 'no LVM in use'
        }
    }

    It 'the inspection tolerates an image that has neither lsinitrd nor lsinitramfs' {
        foreach ($s in $script:lvmScripts) {
            $s.Text | Should -Match 'could not be inspected on this image'
        }
    }
}

Describe 'STORAGE-SPACES-1: our temp pool never touches a customer pool' {
    BeforeAll {
        $script:root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:tempInit = Get-Content (Join-Path $script:root 'src' 'guest' 'windows' 'Install-TempDiskInit.ps1') -Raw
        $script:winValidate = Get-Content (Join-Path $script:root 'src' 'guest' 'windows' 'Test-GuestValidation.ps1') -Raw
    }

    It 'only ever pools disks Azure named NVMe Direct Disk' {
        # This is the line standing between our temp-disk setup and a
        # customer's data. If the filter is ever widened, New-StoragePool
        # starts consuming disks somebody else owns - and pooling a disk
        # destroys what is on it.
        $script:tempInit | Should -Match "Get-PhysicalDisk \| Where-Object \{ \`$_\.FriendlyName -like ""\*NVMe Direct Disk\*"" \}"
        $script:tempInit | Should -Not -Match 'Get-PhysicalDisk \| Where-Object \{ \$_\.CanPool'
    }

    It 'and only ever deletes a pool of its OWN name' {
        # Remove-StoragePool on a customer pool would destroy their data. The
        # only pool this script may remove is the one it created.
        $removals = [regex]::Matches($script:tempInit, 'Remove-StoragePool')
        @($removals).Count | Should -BeGreaterThan 0
        $script:tempInit | Should -Match '\$poolName = "NVMeTempPool"'
        # the removal must be reached only via a lookup BY THAT NAME
        $script:tempInit | Should -Match "Get-StoragePool -FriendlyName \`$poolName"
        $script:tempInit | Should -Not -Match 'Get-StoragePool \| Remove-StoragePool'
        $script:tempInit | Should -Not -Match 'Get-StoragePool -ErrorAction SilentlyContinue \| Remove'
    }

    It 'the validator REPORTS a customer pool, and excludes ours from the report' {
        # A pool on data disks fails silently - the machine boots,
        # every other check passes, and the volume holding the data is gone.
        $script:winValidate | Should -Match "storage pool"
        $script:winValidate | Should -Match "\`$ourPool = 'NVMeTempPool'"
        $script:winValidate | Should -Match "-not \`$_\.IsPrimordial"
    }

    It 'it reports health AND attachment, because a pool can look present while its volume is not' {
        $script:winValidate | Should -Match 'HealthStatus'
        $script:winValidate | Should -Match 'OperationalStatus'
        $script:winValidate | Should -Match 'storage pool disks missing'
    }

    It 'and an image with no Storage module says so rather than reporting none' {
        $script:winValidate | Should -Match 'could not be inspected on this image'
    }

    It 'every storage-spaces check is INFO - the engine judges, the guest reports' {
        $checks = [regex]::Matches($script:winValidate, "Add-Check ""?'?storage[^']*'?""? '([A-Z]+)'")
        @($checks).Count | Should -BeGreaterThan 2
        foreach ($m in $checks) { $m.Groups[1].Value | Should -Be 'INFO' }
    }
}

Describe 'LVM-ROOT-1: nothing in a guest script sits after the exit' {
    # THE DEFECT. nvme-check.sh emitted its JSON and ran `exit 0` at line 96 of
    # 208. Everything below - fourteen add_check calls, the entire LVM section
    # the engine's storage comparison depends on - had never executed, on any
    # distribution, since the day it was written. It was APPENDED beneath an
    # `exit 0` that had been in the file since the first scaffold.
    #
    # Nothing complains about this. bash does not, shellcheck does not, the
    # JSON contract test does not (the output is valid, just short), and the
    # manifest hashes the file happily. The script simply ends early.
    #
    # WHY IT SURVIVED TWO DRILLS. The engine's answer was not a crash, it was
    # UNKNOWN - "this machine was not asked about its storage volumes before or
    # after the move". UNKNOWN is the SAFE verdict, so it never blocked
    # anything, and both drills that saw it read it as the drill needing work.
    # The volume drill's committed evidence still says "storage volumes:
    # UNKNOWN; storage volumes: UNKNOWN".
    #
    # So the check that exists to catch a customer silently losing a filesystem
    # could never once have caught one. Found only by running LVM-ROOT-1 on a
    # real machine: it came back perfectly and the engine could not say so.

    It 'no shell guest script has code after its top-level exit' {
        # HEREDOC-AWARE, because the first version was not and said
        # temp-disk-setup.sh was broken. Its `exit 0` at column 0 is a line of
        # the init script it GENERATES - inside cat > ... <<INITEOF - not its
        # own control flow. A rule that cannot tell those apart reports a
        # correct file as broken, and the fix is to understand the shape rather
        # than to add an exemption.
        $bad = foreach ($file in (Get-ChildItem (Join-Path $script:repoRoot 'src' 'guest' 'linux') -Filter '*.sh')) {
            $lines = Get-Content $file.FullName
            $exitAt = -1
            $heredoc = $null
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($heredoc) {
                    if ($line.Trim() -eq $heredoc) { $heredoc = $null }
                    continue
                }
                # <<WORD, <<-WORD, <<'WORD', <<"WORD"
                $h = [regex]::Match($line, '<<-?\s*[''"]?([A-Za-z_][A-Za-z0-9_]*)[''"]?')
                if ($h.Success) { $heredoc = $h.Groups[1].Value; continue }
                # A TOP-LEVEL exit: column 0, so not one inside a function or an
                # if/else branch, which are legitimate early returns.
                if ($line -match '^exit\s') { $exitAt = $i; break }
            }
            if ($exitAt -lt 0 -or $exitAt -ge $lines.Count - 1) { continue }
            $after = $lines[($exitAt + 1)..($lines.Count - 1)] | Where-Object {
                $_.Trim() -and $_.Trim() -notmatch '^#'
            }
            if ($after) { "$($file.Name): $(@($after).Count) live line(s) after the exit on line $($exitAt + 1)" }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'code below a top-level exit never runs, and nothing else reports it'
    }

    It 'and the LVM facts the engine compares are actually reachable' {
        # Named individually, because "the file contains this string" is exactly
        # the check that passed for months while the string sat below an exit.
        $text = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'nvme-check.sh')
        $exitAt = 0
        for ($i = 0; $i -lt $text.Count; $i++) { if ($text[$i] -match '^exit\s') { $exitAt = $i; break } }
        foreach ($name in 'lvm root', 'lvm topology', 'lvm volume groups complete', 'lvm volumes mounted') {
            $at = -1
            for ($i = 0; $i -lt $text.Count; $i++) {
                if ($text[$i] -match [regex]::Escape("add_check `"$name`"")) { $at = $i; break }
            }
            $at | Should -BeGreaterThan -1 -Because "nvme-check.sh must report '$name'"
            $at | Should -BeLessThan $exitAt -Because "'$name' is below the exit, so it never runs"
        }
    }
}
