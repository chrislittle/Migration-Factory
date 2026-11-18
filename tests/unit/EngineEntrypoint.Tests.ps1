#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# S3-3/S3-7: the hosted engine entrypoint. Static (AST) checks - the container
# is exercised live by the Stage 3 smoke; these tests pin the contract the
# facade relies on without needing Docker or Azure.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:entryPath = Join-Path $repoRoot 'docker' 'entrypoint.ps1'
    $script:entry = Get-Content $entryPath -Raw
    $errs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$null, [ref]$errs)
    $script:parseErrors = @($errs)

    # Code only: a function NAME inside a comment is not a call, and both of the
    # tests below matched their own explanatory comments before this existed.
    # Also drops `& (Get-Module VmMigrationFactory) { ... }` blocks, which run
    # INSIDE the module and can therefore legitimately see private functions.
    function Global:EntryCallSites([string]$Text) {
        # Line-based on purpose: a multi-line regex for this kept being the
        # thing that broke, and the rule is simple enough to state directly.
        $out = [System.Collections.Generic.List[string]]::new()
        $inModuleBlock = $false
        foreach ($raw in ($Text -split "`n")) {
            $line = $raw.TrimEnd()
            if ($line -match '^\s*#') { continue }   # a name in a comment is not a call
            if ($line -match '&\s*\(Get-Module VmMigrationFactory\)') { $inModuleBlock = $true; continue }
            # Code inside & (Get-Module ...) { } runs INSIDE the module, so it
            # may legitimately call private functions.
            if ($inModuleBlock) {
                if ($line -match '^\s*\}') { $inModuleBlock = $false }
                continue
            }
            $out.Add($line)
        }
        $out -join "`n"
    }
}

Describe 'Engine entrypoint (docker/entrypoint.ps1)' {

    It 'parses cleanly' {
        $parseErrors.Count | Should -Be 0
    }

    It 'refuses to run without its required environment' {
        foreach ($v in 'VMF_OPERATION', 'VMF_RUN_ID', 'VMF_STORE_ACCOUNT', 'VMF_STORE_CONTAINER') {
            $entry | Should -Match ([regex]::Escape($v))
        }
    }

    It 'authenticates with the managed identity, never a secret' {
        $entry | Should -Match 'Connect-AzAccount -Identity'
        $entry | Should -Not -Match 'password|clientSecret|AccountKey' -Because 'zero stored secrets'
    }

    It 'the plan operation owns the WHOLE plan-time stage: plan THEN quota check (S3-7)' {
        # Found live by the Stage 3 smoke: Start-VmfWave's capacity gate
        # (rightly) refuses a wave with no claims, and the facade has no
        # separate capacity trigger - so hosted 'plan' must produce claims.
        $planBranch = [regex]::Match($entry, "(?s)'plan'\s*\{.*?\n    \}").Value
        $planBranch | Should -Match 'New-VmfPlan'
        $planBranch | Should -Match 'Test-VmfQuota'
        ($planBranch.IndexOf('New-VmfPlan')) | Should -BeLessThan ($planBranch.IndexOf('Test-VmfQuota'))
    }

    It 'the assess operation honors the declared scan scope (SCOPE-1)' {
        $assessBranch = [regex]::Match($entry, "(?s)'assess'\s*\{.*?\n    \}").Value
        $assessBranch | Should -Match 'VMF_SCOPE_SUBS'
        $assessBranch | Should -Match 'VMF_SCOPE_MG'
        $assessBranch | Should -Match 'VMF_SCOPE_RG'
    }

    It 'the plan operation carries the capacity choice through (CAP-3)' {
        $planBranch = [regex]::Match($entry, "(?s)'plan'\s*\{.*?\n    \}").Value
        $planBranch | Should -Match 'VMF_CAPACITY_GATE'
    }

    It 'records a refusal THROUGH the module, because Write-VmfEvent is private' {
        # This wrapper exists so a refusal reaches the run store instead of dying
        # in a container log - "the owner pressed start, nothing happened, and
        # nothing anywhere said why". It called Write-VmfEvent bare, and
        # Write-VmfEvent is not exported, so the call always failed and every
        # refusal it was written to capture was lost. It had never worked once.
        # Found live by the PERM-2 roles drill.
        $catchBlock = [regex]::Match($script:entry, '(?s)^catch \{.*', 'Multiline').Value
        $catchBlock | Should -Match 'Get-Module VmMigrationFactory'
        (EntryCallSites $catchBlock) | Should -Not -Match 'Write-VmfEvent'
    }

    It 'and every module function the entrypoint calls directly is actually exported' {
        # The general form of the bug above. A private function called from this
        # script fails at the only moment it matters.
        $manifest = Import-PowerShellDataFile (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1')
        $exported = @($manifest.FunctionsToExport)
        $code = EntryCallSites $script:entry
        $called = @([regex]::Matches($code, '((?:Get|Set|New|Remove|Start|Stop|Invoke|Test|Write|Read|Confirm|Approve|Resolve|Clear|Restore|Request|ConvertFrom)-Vmf\w+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        @($called).Count | Should -BeGreaterThan 3 -Because 'the entrypoint must actually have been read'
        $private = @($called | Where-Object { $_ -notin $exported })
        $private -join ', ' | Should -BeNullOrEmpty -Because 'a private function called from the entrypoint fails at the only moment it matters'
    }

    It 'nothing in the container can ask a question (hard rule 7) - found by the SAFETY-3 drill' {
        # The scheduled retention run sat at "Are you sure you want to perform
        # this action?" until the platform killed it: the delete cmdlet is
        # ConfirmImpact High and the call never said no. Two belts.
        $script:entry | Should -Match "(?m)^\`$ConfirmPreference = 'None'"
        $ret = [regex]::Match($script:entry, "(?s)'retention' \{.*?Remove-VmfExpiredSafetyCopies @retParams").Value
        $ret | Should -Match 'Confirm\s+=\s+\$false'
        # And the two operations that already knew: restore and rebuild.
        ([regex]::Matches($script:entry, 'Confirm\s+=\s+\$false')).Count | Should -BeGreaterOrEqual 3
    }

    It 'the wave operation keeps the engine gates intact (no skip switches)' {
        $waveBranch = [regex]::Match($entry, "(?s)'wave'\s*\{.*?\n    \}").Value
        $waveBranch | Should -Match 'Start-VmfWave'
        $waveBranch | Should -Not -Match 'SkipCapacityGate' -Because 'gates are policy, not defaults to bypass'
    }
}

AfterAll { Remove-Item 'function:\EntryCallSites' -ErrorAction SilentlyContinue }

Describe 'RESTORE-END-LOST-1: the engine''s fail line names the machine of a restore' {
    # A FAILED restore writes no record, and its own fail line can be lost when
    # the run history cannot be written (STEP-LOG-2). The engine's catch then
    # writes its own fail line, and the Migrations page ends "Restoring" on it -
    # but only for the machine the line names. So the line must name it.
    # RUN, not read: the catch itself, with the module replaced by a fake that
    # records each line.
    BeforeAll {
        $entryFile = Join-Path $script:repoRoot 'docker' 'entrypoint.ps1'
        $parsed = [System.Management.Automation.Language.Parser]::ParseFile($entryFile, [ref]$null, [ref]$null)
        $tries = @($parsed.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $false) |
            Where-Object { $_.CatchClauses.Count -and $_.CatchClauses[0].Body.Extent.Text -match 'engine:\$\(\$env:VMF_OPERATION\)' -and $_.CatchClauses[0].Body.Extent.Text -match 'Outcome fail' })
        $script:engineCatch = $tries[0].CatchClauses[0].Extent.Text

        function script:Invoke-EngineCatch([string]$Operation, [string]$VmId, [string]$MigrationId) {
            $fake = New-Module -Name 'FakeVmfEngine' -ScriptBlock {
                $script:lines = [System.Collections.Generic.List[object]]::new()
                function Write-VmfEvent { param($RunPath, $Step, $Outcome, $VmId, $Detail, $CorrelationId, [hashtable]$Data) $script:lines.Add([pscustomobject]@{ Step = $Step; Outcome = $Outcome; VmId = $VmId; Detail = $Detail; CorrelationId = $CorrelationId; Data = $Data }) }
                function Get-Lines { , $script:lines.ToArray() }
                Export-ModuleMember -Function *
            }
            $body = "param(`$fake)`nfunction Get-Module { `$fake }`nfunction Find-VmfEngineRun { `$true }`nfunction Write-Host { }`n`$runPath = 'azblob://store/runs/r1'`n`$engineRunId = 'op-1'`ntry { throw 'The restore did not complete.' }`n" + $script:engineCatch
            $saved = @{ op = $env:VMF_OPERATION; vm = $env:VMF_VM_ID; mig = $env:VMF_MIGRATION_ID }
            try {
                $env:VMF_OPERATION = $Operation
                $env:VMF_VM_ID = $VmId
                $env:VMF_MIGRATION_ID = $MigrationId
                try { & ([scriptblock]::Create($body)) $fake } catch { $null = $_ }
            }
            finally { $env:VMF_OPERATION = $saved.op; $env:VMF_VM_ID = $saved.vm; $env:VMF_MIGRATION_ID = $saved.mig }
            & $fake { Get-Lines }
        }
    }

    It 'found the catch that writes the engine''s fail line' {
        $script:engineCatch | Should -Match '^catch'
    }

    It 'a failed restore: the line names the machine the restore was given' {
        $lines = @(Invoke-EngineCatch -Operation 'restore' -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1')
        $lines.Count | Should -Be 1
        $lines[0].Step | Should -Be 'engine:restore'
        $lines[0].Outcome | Should -Be 'fail'
        $lines[0].Detail | Should -Be 'The restore did not complete.'
        $lines[0].CorrelationId | Should -Be 'op-1' -Because 'the page ends only the restore whose start line carries the same id'
        $lines[0].VmId | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
    }

    It 'a failed rebuild: the same' {
        $lines = @(Invoke-EngineCatch -Operation 'rebuild' -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2')
        $lines[0].Step | Should -Be 'engine:rebuild'
        $lines[0].VmId | Should -Match 'vm2$'
    }

    It 'the engine makes one id per operation, before the operation, and gives the restore the same id' {
        $entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $made = [regex]::Match($entry, '(?m)^\$engineRunId = \[guid\]::NewGuid\(\)\.ToString\(\)')
        $made.Success | Should -BeTrue
        $made.Index | Should -BeLessThan $entry.IndexOf('switch ($env:VMF_OPERATION)')
        $restoreBranch = [regex]::Match($entry, "(?s)'restore' \{.*?Restore-VmfVm @restoreParams").Value
        $restoreBranch | Should -Match 'CorrelationId\s+=\s+\$engineRunId'
    }
    # WIZARD-PLAN-FAIL-1: the plan's fail line goes in the ASSESSMENT's log, and
    # the migration may never get a run.json. The wizard waits for ONE
    # migration's plan; this field is how it tells this refusal from the
    # refusal of an earlier plan of the same assessment.
    It 'a refused plan names the migration it was planning' {
        $lines = @(Invoke-EngineCatch -Operation 'plan' -VmId '' -MigrationId 'assess-1-migration-20261030-101500')
        $lines.Count | Should -Be 1
        $lines[0].Step | Should -Be 'engine:plan'
        $lines[0].Outcome | Should -Be 'fail'
        $lines[0].Data.migrationId | Should -Be 'assess-1-migration-20261030-101500'
    }
    It 'another operation names no migration, even with the setting there' {
        $lines = @(Invoke-EngineCatch -Operation 'advise' -VmId '' -MigrationId 'assess-1-migration-20261030-101500')
        $lines[0].Step | Should -Be 'engine:advise'
        $lines[0].Data | Should -BeNullOrEmpty
    }
    It 'a plan with no migration named (the command line) names none' {
        $lines = @(Invoke-EngineCatch -Operation 'plan' -VmId '' -MigrationId '')
        $lines[0].Data | Should -BeNullOrEmpty
    }
    It 'an operation without a machine names none' {
        $lines = @(Invoke-EngineCatch -Operation 'wave' -VmId '')
        $lines.Count | Should -Be 1
        $lines[0].Step | Should -Be 'engine:wave'
        [string]$lines[0].VmId | Should -BeNullOrEmpty
    }
}

Describe 'WIZARD-PLAN-FAIL-1: the real event writer puts the migration on the fail line' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
        . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
        Block-VmfAzureCalls -TestFile $PSCommandPath
    }
    It 'the real event writer puts the field on the line, where the wizard reads it' {
        $rp = Join-Path $TestDrive 'assess-1'
        New-Item -ItemType Directory -Path $rp -Force | Out-Null
        & (Get-Module VmMigrationFactory) { param($rp, $data)
            Write-VmfEvent -RunPath $rp -Step 'engine:plan' -Outcome fail -Detail 'No target was chosen.' -Data $data
        } $rp @{ migrationId = 'assess-1-migration-20261030-101500' }
        $line = Get-Content (Join-Path $rp 'logs' 'events.jsonl') | Select-Object -First 1 | ConvertFrom-Json
        $line.migrationId | Should -Be 'assess-1-migration-20261030-101500'
    }
}

Describe 'SCOPE-RG-LIST-1: a scan can name more than one resource group' {
    # The engine's own setting is documented as an ALLOWLIST and the assessment
    # takes ResourceGroups as an array - but the entrypoint wrapped one value,
    # so the list could only ever hold one. An estate spread across several
    # groups could then be scanned only by taking the WHOLE SUBSCRIPTION, which
    # in a work tenant means reading machines nobody asked about.
    BeforeAll {
        $script:entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $script:startEngine = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1') -Raw
    }

    It 'the engine splits the setting, the way it already splits subscriptions' {
        $script:entry | Should -Match "VMF_SCOPE_RG -split '\[,;\]'"
        $script:entry | Should -Not -Match '\$scope\.ResourceGroups = @\(\$env:VMF_SCOPE_RG\)$' `
            -Because 'wrapping one value is what made the allowlist hold one'
    }

    It 'and trims what it splits, because a list typed by a person has spaces' {
        $script:entry | Should -Match "ForEach-Object \{ \`$_\.Trim\(\) \}"
        $script:entry | Should -Match "Where-Object \{ \`$_ \}" -Because 'a trailing comma must not scan a group named empty'
    }

    It 'the service takes one or many and joins them into the one setting' {
        $script:core | Should -Match "\[Parameter\(\)\]\[string\[\]\]\`$ScopeRg"
        $script:core | Should -Match "name = 'VMF_SCOPE_RG'; value = \(\(@\(\`$ScopeRg\)"
    }

    It 'and the door accepts either shape, so the dashboard keeps working' {
        # The pages send one name today. An array must not be required of them.
        $script:startEngine | Should -Match '\$params\.ScopeRg = @\(\$body\.scopeRg\)'
    }

    It 'THE POINT: subscriptions were already a list, and this was not' {
        # Both are scope. One was separated and the other was not, which is the
        # shape of a rule applied once and never written down. They also have
        # to SEPARATE THE SAME WAY - subscriptions took a comma or a semicolon,
        # and the first version of this fix took only a comma. Two rules for
        # one idea is how the next person picks the wrong one.
        $script:entry | Should -Match "VMF_SCOPE_SUBS -split '\[,;\]'"
        $script:entry | Should -Match "VMF_SCOPE_RG -split '\[,;\]'"
    }
}
# MANUAL-REVIEW-1: the lines of the release operation say "on-demand capacity
# reservation", Azure's name, and never "reservation" alone. Read from the
# code only, so a comment that quotes an old line cannot pass or fail it.
Describe 'MANUAL-REVIEW-1: the release lines of the engine, in Azure''s names' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:entryCode = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'docker' 'entrypoint.ps1')
    }
    It 'the refusal names the on-demand capacity reservation of the wave, and what to do' {
        $script:entryCode | Should -Match ([regex]::Escape('"The product did not release the on-demand capacity reservation for wave $($env:VMF_WAVE): machines of the wave are migrating ($busy), and they can use it. Release it when the wave has finished."'))
    }
    It 'the count of released ones, and of ones not released, say on-demand capacity reservation(s)' {
        $script:entryCode | Should -Match ([regex]::Escape('"release $($env:VMF_WAVE): released $(@($r.Released).Count) on-demand capacity reservation(s)"'))
        $script:entryCode | Should -Match ([regex]::Escape('"release $($env:VMF_WAVE): the product did not release $(@($r.NotReleased).Count) on-demand capacity reservation(s). The activity log says why."'))
    }
    It 'no release line says reservation alone' {
        $script:entryCode | Should -Not -Match 'The reservation for wave|\) reservation\(s\)'
    }
}
