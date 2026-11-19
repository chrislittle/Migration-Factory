#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:sampleDir = Join-Path $PSScriptRoot '..' '..' 'schemas' 'samples'
}

Describe 'ConvertFrom-VmfGuestOutput' {

    It 'parses the canonical sample' {
        $raw = Get-Content (Join-Path $sampleDir 'guest-output.sample.json') -Raw
        $doc = ConvertFrom-VmfGuestOutput -RawOutput $raw
        $doc.script | Should -Be 'Test-NvmeReady.ps1'
        $doc.result | Should -Be 'NEEDS_PREP'
        @($doc.checks).Count | Should -BeGreaterThan 0
    }

    It 'extracts the JSON object from surrounding RunCommand noise' {
        $json = '{"schema":"vmf.guest/2","script":"x.ps1","version":"1.0.0","result":"READY","checks":[{"name":"a","status":"PASS"}]}'
        $raw = "Enable succeeded:`n[stdout]`n$json`n[stderr]`n"
        (ConvertFrom-VmfGuestOutput -RawOutput $raw).result | Should -Be 'READY'
    }

    It 'throws on empty output' {
        { ConvertFrom-VmfGuestOutput -RawOutput '   ' } | Should -Throw '*empty*'
    }

    It 'throws when no vmf.guest object is present' {
        { ConvertFrom-VmfGuestOutput -RawOutput 'RESULT: READY (legacy text output)' } | Should -Throw '*No vmf.guest*'
    }

    It 'throws on an invalid result value' {
        $json = '{"schema":"vmf.guest/2","script":"x.ps1","version":"1.0.0","result":"MAYBE","checks":[]}'
        { ConvertFrom-VmfGuestOutput -RawOutput $json } | Should -Throw '*invalid result*'
    }

    It 'throws on a malformed version' {
        $json = '{"schema":"vmf.guest/2","script":"x.ps1","version":"1.0","result":"READY","checks":[]}'
        { ConvertFrom-VmfGuestOutput -RawOutput $json } | Should -Throw '*invalid version*'
    }

    It 'throws on a check with an invalid status' {
        $json = '{"schema":"vmf.guest/2","script":"x.ps1","version":"1.0.0","result":"READY","checks":[{"name":"a","status":"GOOD"}]}'
        { ConvertFrom-VmfGuestOutput -RawOutput $json } | Should -Throw '*invalid status*'
    }
}

Describe 'Guest scripts emit contract-shaped JSON (static self-description)' {
    # Static sanity: every PowerShell guest script declares the fields the contract requires.
    It '<Name> declares schema marker, version and script name' -TestCases @(
        Get-ChildItem (Join-Path $PSScriptRoot '..' '..' 'src' 'guest' 'windows') -Filter '*.ps1' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $content = Get-Content $Path -Raw
        $content | Should -Match "vmf\.guest/[234567]" -Because 'v3 (VERIFY-FP-1) adds the IMDS facts, v4 (CLUSTER-DETECT-1) the cluster facts, v5 (ORACLE-UEK-UPDATE-1) the UEK repositories, v6 (KERNEL-OFFER-EDGES-1) the releasever setting and the kernel package version, v7 (VF-UNMANAGED-CONFIG-1) the network facts; v2 is still valid'
        $content | Should -Match "VERSION\s*=\s*'(\d+\.\d+\.\d+)'"
        $content | Should -Match ([regex]::Escape($Name))
    }

    It '<Name> (bash) declares schema marker and collision-proof version variable' -TestCases @(
        Get-ChildItem (Join-Path $PSScriptRoot '..' '..' 'src' 'guest' 'linux') -Filter '*.sh' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $content = Get-Content $Path -Raw
        $content | Should -Match 'vmf\.guest/[234567]' -Because 'v3 (VERIFY-FP-1) adds the IMDS facts, v4 (CLUSTER-DETECT-1) the cluster facts, v5 (ORACLE-UEK-UPDATE-1) the UEK repositories, v6 (KERNEL-OFFER-EDGES-1) the releasever setting and the kernel package version, v7 (VF-UNMANAGED-CONFIG-1) the network facts; v2 is still valid'
        # MUST be VMF_VERSION: sourcing /etc/os-release clobbers a bare VERSION
        # variable (found by the P0-5 parity drill on real Ubuntu).
        $content | Should -Match '(?m)^VMF_VERSION="(\d+\.\d+\.\d+)"'
        $content | Should -Not -Match '(?m)^VERSION='
        $content | Should -Match '"\$VMF_VERSION"'
        $content | Should -Match ([regex]::Escape($Name))
    }

    It 'pagefile D:-content allowlist covers Windows crash-dump artifacts (REH-2 false-park)' {
        # DumpStack.log/.tmp are OS-created on the pagefile volume; treating
        # them as customer data parked EVERY Windows temp-disk VM under
        # park-policy rings (canary/nonprod/prod).
        # TEMPCHECK-FIRST-1: the list lives in the read-only check now.
        $content = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'guest' 'windows' 'Test-TempDiskContent.ps1') -Raw
        $content | Should -Match "'DumpStack\.log'"
        $content | Should -Match "'DumpStack\.log\.tmp'"
    }

    It 'Windows seed script probes occupied drive letters beyond partitions (CD-ROM trap)' {
        # A fresh Azure Windows VM can hold the provisioning DVD at E: - a CD-ROM
        # is a volume WITHOUT a partition, so a Get-Partition-only probe picks a
        # taken letter and New-Partition fails "access path is already in use"
        # (found by REH-1 on a freshly deployed fleet).
        $content = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'guest' 'windows' 'Set-DataDiskSeed.ps1') -Raw
        $content | Should -Match 'Win32_LogicalDisk'
        $content | Should -Match 'Get-Volume'
    }
}

Describe 'GUEST-2: facts are part of the contract now' {
    # They used to travel as checks named "fact:<name>" - a convention, not a
    # contract. Nothing declared which facts existed, so a guest could omit one
    # and nothing noticed. That is exactly how every Windows machine came to
    # report an UNKNOWN driver state: the Windows guest emitted no os fact and
    # the engine fell back to guessing from an OS caption string (DRIVER-2).
    BeforeAll {
        $script:root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:schema = Get-Content (Join-Path $script:root 'schemas' 'guest-output.schema.json') -Raw | ConvertFrom-Json
        $script:guestDir = Join-Path $script:root 'src' 'guest'
    }

    It 'the contract accepts v2, v3 (VERIFY-FP-1), v4 (CLUSTER-DETECT-1), v5 (ORACLE-UEK-UPDATE-1), v6 (KERNEL-OFFER-EDGES-1) and v7 (VF-UNMANAGED-CONFIG-1) and declares a facts object' {
        @($script:schema.properties.schema.enum) | Should -Be @('vmf.guest/2', 'vmf.guest/3', 'vmf.guest/4', 'vmf.guest/5', 'vmf.guest/6', 'vmf.guest/7')
        $script:schema.properties.facts | Should -Not -BeNullOrEmpty
    }

    # ORACLE-UEK-UPDATE-1: mana-check.sh reports which UEK repositories are
    # enabled on Oracle Linux, so the engine can decide whether Update the
    # kernel reaches UEK R8. A fact, never a verdict.
    It 'ORACLE-UEK-UPDATE-1: v5 declares uekRepositories, and KERNEL-OFFER-EDGES-1: mana-check.sh emits v6, which keeps it; the reader takes v5 and v6, and the migration notes say so' {
        $script:schema.properties.facts.properties.uekRepositories | Should -Not -BeNullOrEmpty
        $script:schema.properties.facts.properties.uekRepositories.type | Should -Be 'string'
        $mana = Get-VmfCodeOnly -Path (Join-Path $script:guestDir 'linux' 'mana-check.sh')
        $mana | Should -Match 'add_fact "uekRepositories"'
        $mana | Should -Match '"schema":"vmf\.guest/6"'
        # 1.2.0 brought v5; AN-TRAFFIC-VERIFY-1 and KERNEL-OFFER-EDGES-1 each made it 1.3.0, and both together are 1.4.0. Any later version keeps v6.
        $manaVersion = if ($mana -match '(?m)^VMF_VERSION="(\d+\.\d+\.\d+)"') { [version]$Matches[1] } else { $null }
        $manaVersion | Should -BeGreaterOrEqual ([version]'1.3.0')
        $mana | Should -Match 'add_fact "releaseverLock"'
        $mana | Should -Match 'add_fact "kernelPackageVersion"'
        $v5 = '{"schema":"vmf.guest/5","script":"mana-check.sh","version":"1.2.0","result":"READY","checks":[],"facts":{"uekRepositories":"ol9_UEKR7 ol9_UEKR8"}}'
        (ConvertFrom-VmfGuestOutput -RawOutput $v5).facts.uekRepositories | Should -Be 'ol9_UEKR7 ol9_UEKR8'
        (ConvertFrom-VmfGuestOutput -RawOutput ($v5 -replace 'guest/5', 'guest/6')).facts.uekRepositories | Should -Be 'ol9_UEKR7 ol9_UEKR8'
        (ConvertFrom-VmfGuestOutput -RawOutput ($v5 -replace 'guest/5', 'guest/7')).facts.uekRepositories | Should -Be 'ol9_UEKR7 ol9_UEKR8'
        # VF-UNMANAGED-CONFIG-1 took vmf.guest/7, so the first version no reader takes is 8.
        { ConvertFrom-VmfGuestOutput -RawOutput ($v5 -replace 'guest/5', 'guest/8') } | Should -Throw '*Unsupported*'
        $notes = Get-Content (Join-Path $script:root 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'guest-output vmf\.guest/4 -> vmf\.guest/5 \(2026-11-14, ORACLE-UEK-UPDATE-1\)'
        $notes | Should -Match 'guest-output vmf\.guest/5 -> vmf\.guest/6 \(2026-11-14, KERNEL-OFFER-EDGES-1'
    }

    It 'and that object is CLOSED, so a misspelled fact is a failure not a silence' {
        $script:schema.properties.facts.additionalProperties | Should -BeFalse
    }

    It 'facts stay optional - most scripts have none to report' {
        @($script:schema.required) | Should -Not -Contain 'facts'
    }

    It 'EVERY fact any guest emits is declared in the contract' {
        # Derived from the scripts, so the next undeclared fact fails here
        # rather than being silently dropped by a closed schema.
        $declared = @($script:schema.properties.facts.properties.PSObject.Properties.Name)
        $emitted = @(
            Get-ChildItem $script:guestDir -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.sh' } | ForEach-Object {
                $text = Get-Content $_.FullName -Raw
                [regex]::Matches($text, "Add-Fact\s+'([A-Za-z][A-Za-z0-9]*)'") | ForEach-Object { $_.Groups[1].Value }
                [regex]::Matches($text, 'add_fact\s+"([A-Za-z][A-Za-z0-9]*)"') | ForEach-Object { $_.Groups[1].Value }
            }
        ) | Sort-Object -Unique

        @($emitted).Count | Should -BeGreaterThan 5 -Because 'the fact emitters should have been found'
        $undeclared = @($emitted | Where-Object { $_ -notin $declared })
        $undeclared -join ', ' | Should -BeNullOrEmpty -Because 'a closed schema rejects the whole document over one unknown fact'
    }

    It 'no guest still smuggles facts through the checks list' {
        $smugglers = @(
            Get-ChildItem $script:guestDir -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.sh' } | ForEach-Object {
                $code = (Get-VmfCodeOnly -Path $_.FullName)
                if ($code -match '"fact:') { $_.Name }
            }
        )
        $smugglers -join ', ' | Should -BeNullOrEmpty
    }

    It 'the os fact is emitted by BOTH readiness checks - the DRIVER-2 gap' {
        (Get-Content (Join-Path $script:guestDir 'windows' 'Test-ManaReady.ps1') -Raw) | Should -Match "Add-Fact 'os' 'Windows'"
        (Get-Content (Join-Path $script:guestDir 'linux' 'mana-check.sh') -Raw) | Should -Match 'add_fact "os" "Linux"'
    }

    It 'v1 evidence still reads, so old runs and support bundles stay readable' {
        InModuleScope VmMigrationFactory {
            $v1 = [pscustomobject]@{
                schema = 'vmf.guest/1'; os = 'Ubuntu 22.04'
                checks = @([pscustomobject]@{ name = 'fact:kernelVersion'; status = 'INFO'; detail = '5.15.0-1139' })
            }
            (ConvertTo-VmfGuestFacts -GuestOutput $v1).kernelVersion | Should -Be '5.15.0-1139'
        }
    }

    It 'and the declared object WINS over a leftover fact check' {
        InModuleScope VmMigrationFactory {
            $mixed = [pscustomobject]@{
                schema = 'vmf.guest/2'
                facts = [pscustomobject]@{ os = 'Windows' }
                checks = @([pscustomobject]@{ name = 'fact:os'; status = 'INFO'; detail = 'Linux' })
            }
            (ConvertTo-VmfGuestFacts -GuestOutput $mixed).os | Should -Be 'Windows'
        }
    }
}
