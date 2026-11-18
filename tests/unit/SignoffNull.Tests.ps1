#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SIGNOFF-NULL-1: a plan that says nothing about approval is read ONE way.
#
# Four readers asked "does this wave need a person's sign-off?" and gave two
# answers. A stored null, a stored 0, or an entry with no such key:
#
#   * the engine's gate (Test-VmfWaveApproval) read a missing key as required
#     and a null or a 0 as NOT required ([bool]$null is false);
#   * Get-VmfPolicy read a null as required (the default) and a 0 as itself;
#   * the service (Get-VmfFacadeApprovalRemovals) read like the gate, and its
#     run summary read a missing key as NOT required;
#   * the pages read anything but true as NOT required, so the gate's refusal
#     named Approve and the page showed no Approve button.
#
# Now one function decides, and it fails safe: only a stored boolean false
# turns the sign-off off. Every reader below is run against the SAME cases
# (tests/fixtures/approval-required.json), which tests/js/signoff-null.test.js
# runs against the pages' copy of the rule.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'sgn'

    $script:fixtureText = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'approval-required.json') -Raw

    # One case's entry as a plan entry in wave w1, as JSON gives it back.
    function Script:CaseEntry([string]$Name, [string]$Id = '/s/rg/vm/a') {
        $c = @(($script:fixtureText | ConvertFrom-Json -Depth 10).cases | Where-Object name -EQ $Name)[0]
        $e = $c.entry
        $e | Add-Member -NotePropertyName vmId -NotePropertyValue $Id -Force
        $e | Add-Member -NotePropertyName wave -NotePropertyValue 'w1' -Force
        $e | Add-Member -NotePropertyName path -NotePropertyValue 'A' -Force
        $e | Add-Member -NotePropertyName schemaVersion -NotePropertyValue (Get-VmfTestPlanEntryVersion) -Force
        $e
    }

    # A run whose plan holds one machine: the case's entry.
    function Script:CaseRun([string]$Name) {
        $rp = Join-Path $script:temp "sgn-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $planText = @{ schemaVersion = 1; assessmentRunId = 'sgn'; entries = @(CaseEntry $Name) } | ConvertTo-Json -Depth 12
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; t = $planText } {
            Initialize-VmfRun -RunPath $rp -RunId 'sgn' | Out-Null
            Write-VmfStoreText -RunPath $rp -RelPath 'plan.json' -Content $t
        }
        @{ RunPath = $rp; PlanPath = (Join-Path $rp 'plan.json'); PlanText = $planText }
    }
}
AfterAll { if ($script:temp -and (Test-Path $script:temp)) { Remove-Item $script:temp -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'SIGNOFF-NULL-1: the one rule (Test-VmfApprovalRequired)' {
    BeforeDiscovery {
        $text = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'approval-required.json') -Raw
        $script:cases = @(($text | ConvertFrom-Json -Depth 10).cases | ForEach-Object { @{ Name = $_.name; Required = [bool]$_.required } })
    }

    It 'the fixture holds the cases that were read two ways' {
        $names = @(($script:fixtureText | ConvertFrom-Json -Depth 10).cases.name)
        foreach ($n in 'a stored null', 'a stored 0', 'a policy with no such key', 'an entry with no policy', 'an explicit false') {
            $names | Should -Contain $n
        }
        # Exactly one case turns the sign-off off.
        @(($script:fixtureText | ConvertFrom-Json -Depth 10).cases | Where-Object { -not $_.required }).Count | Should -Be 1
    }

    It '<Name>: required = <Required>, as JSON gives the plan back' -ForEach $script:cases {
        $e = CaseEntry $Name
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } { param($e) Test-VmfApprovalRequired -PlanEntry $e } | Should -Be $Required
    }

    It '<Name>: required = <Required>, as a hashtable' -ForEach $script:cases {
        $c = @(($script:fixtureText | ConvertFrom-Json -Depth 10 -AsHashtable).cases | Where-Object { $_.name -eq $Name })[0]
        InModuleScope VmMigrationFactory -Parameters @{ e = $c.entry } { param($e) Test-VmfApprovalRequired -PlanEntry $e } | Should -Be $Required
    }

    It 'no entry at all is required' {
        InModuleScope VmMigrationFactory { Test-VmfApprovalRequired -PlanEntry $null } | Should -BeTrue
    }

    It 'the answer is a boolean, never the stored value' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = (CaseEntry 'a stored 0') } { param($e) Test-VmfApprovalRequired -PlanEntry $e }
        $r | Should -BeOfType [bool]
    }
}

Describe 'SIGNOFF-NULL-1: every reader gives the rule''s answer' {
    BeforeDiscovery {
        $text = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'approval-required.json') -Raw
        $script:cases = @(($text | ConvertFrom-Json -Depth 10).cases | ForEach-Object { @{ Name = $_.name; Required = [bool]$_.required } })
    }

    It 'Get-VmfPolicy: <Name> -> <Required>' -ForEach $script:cases {
        $e = CaseEntry $Name
        $got = InModuleScope VmMigrationFactory -Parameters @{ e = $e } { param($e) Get-VmfPolicy -PlanEntry $e -Name 'requireApproval' }
        $got | Should -BeOfType [bool]
        $got | Should -Be $Required
    }

    It 'the engine gate (Test-VmfWaveApproval): <Name> -> refuses = <Required>' -ForEach $script:cases {
        $run = CaseRun $Name
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $run.RunPath; pp = $run.PlanPath; t = $run.PlanText } {
            param($rp, $pp, $t) Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave 'w1' -PlanText $t
        }
        $r.Pass | Should -Be (-not $Required)
        if ($Required) { $r.Detail | Should -Match '(?i)approve' }
    }

    It 'the service''s approver check (Get-VmfFacadeApprovalRemovals): <Name> -> taking it off needs an approver = <Required>' -ForEach $script:cases {
        $run = CaseRun $Name
        $taken = @(InModuleScope FacadeCore -Parameters @{ r = $run.RunPath } { param($r) Get-VmfFacadeApprovalRemovals -StorePath $r -Requested @{ '/s/rg/vm/a' = $false } })
        ($taken.Count -eq 1) | Should -Be $Required
    }

    It 'the service''s run summary (Get-VmfFacadeRunSummary): <Name> -> requiresApproval = <Required>' -ForEach $script:cases {
        $run = CaseRun $Name
        $s = Get-VmfFacadeRunSummary -StorePath $run.RunPath
        (@($s.waves) | Where-Object wave -EQ 'w1').requiresApproval | Should -Be $Required
    }

    It 'the wave editor''s save (Get-VmfWaveSettingWrites): <Name> -> taking it off writes the machine = <Required>' -ForEach $script:cases {
        $e = CaseEntry $Name
        $layout = @{ waves = @(@{ name = 'w1'; vmIds = @('/s/rg/vm/a'); requireApproval = $false; changed = @{ requireApproval = $true } }) }
        $judged = InModuleScope VmMigrationFactory -Parameters @{ e = @($e); l = $layout } {
            param($e, $l) Get-VmfWaveSettingWrites -Entries $e -Waves @(ConvertTo-VmfWaveLayout -Layout $l)
        }
        $w = @($judged.Writes | Where-Object Field -EQ 'requireApproval')
        ($w.Count -eq 1) | Should -Be $Required
        if ($Required) { $w[0].From | Should -BeTrue }
    }
}

Describe 'SIGNOFF-NULL-1 (review): the gate reads every machine of the wave' {
    It 'a machine the plan does not move still makes its wave need a sign-off - the set the pages read too' {
        # The wizard counted only machines on path A or B; the gate reads every
        # entry of the wave. tests/js/signoff-null.test.js holds the pages to
        # this same plan.
        $rp = Join-Path $script:temp "sgn-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $planText = @{ schemaVersion = 1; assessmentRunId = 'sgn'; entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/a'; wave = 'w1'; path = 'A'; policy = @{ requireApproval = $false } }
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/m'; wave = 'w1'; path = 'MANUAL' }) } | ConvertTo-Json -Depth 8
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; t = $planText } {
            param($rp, $t)
            Initialize-VmfRun -RunPath $rp -RunId 'sgn' | Out-Null
            Test-VmfWaveApproval -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'w1' -PlanText $t
        }
        $r.Pass | Should -BeFalse
    }
}

Describe 'SIGNOFF-NULL-1: a request to change the sign-off is yes or no' {
    It 'the wave editor''s save refuses <Label>, by name' -ForEach @(
        @{ Label = 'a 0'; Value = 0 }, @{ Label = 'a 1'; Value = 1 }, @{ Label = 'the text false'; Value = 'false' }
        @{ Label = 'an empty string'; Value = '' }) {
        $layout = @{ waves = @(@{ name = 'w1'; vmIds = @('/s/rg/vm/a'); requireApproval = $Value }) }
        { InModuleScope VmMigrationFactory -Parameters @{ l = $layout } { param($l) ConvertTo-VmfWaveLayout -Layout $l } } |
            Should -Throw "The setting 'Someone must sign off before this wave runs' must be true or false - got '*' for wave 'w1'."
    }

    It 'and takes <Value>' -ForEach @(@{ Value = $true }, @{ Value = $false }) {
        $layout = @{ waves = @(@{ name = 'w1'; vmIds = @('/s/rg/vm/a'); requireApproval = $Value }) }
        $w = InModuleScope VmMigrationFactory -Parameters @{ l = $layout } { param($l) ConvertTo-VmfWaveLayout -Layout $l }
        $w.Settings['requireApproval'] | Should -Be $Value
        $w.Settings['requireApproval'] | Should -BeOfType [bool]
    }

    It 'the service hands the value on as sent, so the engine judges it - not a [bool] cast first' {
        $body = [regex]::Match((Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')), '(?s)function Invoke-VmfFacadeSetWaves \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Match ([regex]::Escape('$h.requireApproval = $w.requireApproval'))
        $body | Should -Not -Match '\[bool\]\$w\.requireApproval'
    }
}

Describe 'SIGNOFF-NULL-1: no reader reads the stored value on its own' {
    It 'no PowerShell file reads policy.requireApproval outside Test-VmfApprovalRequired' {
        # The product, and the lab drills and tools that decide whether to
        # approve (APPR-AGREE-1: the flow drill had its own copy).
        # PUBLIC-SYNC-1: lab/ and tests/lab do not ship to the public
        # repository; there src and tools are read. src and tools must be here.
        $files = @(foreach ($dir in 'src', 'tools', 'lab', (Join-Path 'tests' 'lab')) {
                if ($dir -in 'src', 'tools' -or (Test-Path (Join-Path $script:repoRoot $dir))) {
                    Get-ChildItem (Join-Path $script:repoRoot $dir) -Recurse -Include '*.ps1', '*.psm1' -File
                }
            })
        $files.Count | Should -BeGreaterThan 50
        $found = foreach ($f in $files) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            # The rule's own body is the one place allowed to read it.
            $code = [regex]::Replace($code, '(?s)function Test-VmfApprovalRequired \{.*?\n\}', '')
            # A dot read, a property-table read, or a bracket read of the key.
            foreach ($m in [regex]::Matches($code, "(?i)policy\s*\.\s*requireApproval|PSObject\s*\.\s*Properties\s*\[\s*['`"]requireApproval['`"]\s*\]|policy\s*\??\s*\[\s*['`"]requireApproval['`"]\s*\]")) {
                "$($f.Name): $($m.Value)"
            }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'the rule is defined once, and the gate, the policy, the service and its summary call it' {
        $engine = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'Orchestrator.ps1')
        $gate = [regex]::Match($engine, '(?s)function Test-VmfWaveApproval \{.*?\n\}').Value
        $gate | Should -Match 'Test-VmfApprovalRequired'
        $sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        [regex]::Match($sm, '(?s)function Get-VmfPolicy \{.*?\n\}').Value | Should -Match 'Test-VmfApprovalRequired'
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        foreach ($fn in 'Get-VmfFacadeApprovalRemovals', 'Get-VmfFacadeRunSummary') {
            [regex]::Match($core, "(?s)function $fn \{.*?\n\}").Value | Should -Match 'Test-VmfApprovalRequired' -Because "$fn reads the sign-off"
        }
        $defs = @(Get-ChildItem (Join-Path $script:repoRoot 'src') -Recurse -Include '*.ps1', '*.psm1' -File |
            Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match 'function Test-VmfApprovalRequired\b' })
        $defs.Count | Should -Be 1
    }

    It 'no page reads policy.requireApproval outside VmfHelp.approvalRequired' {
        $pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Include '*.html', '*.js' -File -Recurse |
            Where-Object { $_.Name -ne 'msal-browser.min.js' })
        $pages.Count | Should -BeGreaterThan 5
        $found = foreach ($f in $pages) {
            $code = Get-VmfCodeOnly -Path $f.FullName -Language CStyle
            if ($f.Name -eq 'help.js') { $code = [regex]::Replace($code, '(?s)function approvalRequired\(.*?\n  \}', '') }
            # `lever` is a page's name for one machine's policy.
            foreach ($m in [regex]::Matches($code, '(policy|lever)\s*\??\.\s*requireApproval')) { "$($f.Name): $($m.Value)" }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'the Migrations page decides "needs approval" with the rule' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html') -Language CStyle
        $code | Should -Match ([regex]::Escape('const needsApproval = info.entries.some(VmfHelp.approvalRequired);'))
    }
}
