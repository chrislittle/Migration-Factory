#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEST-1: the guard is only worth having if it cannot be forgotten.
#
# Hard rule 8 - unit and contract tests must never require Azure - was enforced
# by nothing. Adding ONE azureops call to PRECHECK (PERM-3) sent 22 existing
# tests to real ARM, and turning the guard on then found six MORE in the restore
# tests that had been calling real Get-AzVM and PASSING. That is the failure
# that matters: a test can pass because the call succeeded, so the suite reports
# "verified" having verified nothing.
#
# So this file checks the guard is actually switched on everywhere it can be.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:unitDir = Join-Path $script:repoRoot 'tests' 'unit'
    . (Join-Path $script:unitDir '_AzureGuard.ps1')
    . (Join-Path $script:unitDir '_RecordVersion.ps1')

    # A file can only hold module-scoped mocks if it loads the module.
    # TEST-AZURE-GUARD-2: the facade module too - it calls Azure itself.
    $script:needsGuard = @(
        Get-ChildItem $script:unitDir -Filter '*.Tests.ps1' | Where-Object {
            (Get-Content $_.FullName -Raw) -match 'Import-Module .*(VmMigrationFactory|FacadeCore)\.psd1'
        }
    )

    # Each Block-VmfAzureCalls call in a parsed file, with the block its mocks
    # cover: a guard in a BeforeAll covers the block that holds that BeforeAll
    # and every block inside it; a guard called in an It covers that It only.
    function script:GetGuardScopes {
        param($Ast)
        foreach ($g in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Block-VmfAzureCalls' }, $true))) {
            $body = $g.Parent
            while ($body -and $body -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $body = $body.Parent }
            $scope = $body
            $owner = if ($body.Parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $body.Parent.Parent }
            if ($owner -is [System.Management.Automation.Language.CommandAst] -and $owner.GetCommandName() -in 'BeforeAll', 'BeforeEach') {
                $scope = $owner.Parent
                while ($scope -and $scope -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $scope = $scope.Parent }
            }
            [pscustomobject]@{ Guard = $g; Scope = $scope }
        }
    }
}

Describe 'TEST-1: no unit test may reach real Azure' {
    It 'there are test files that load the module, or this file is checking nothing' {
        @($script:needsGuard).Count | Should -BeGreaterThan 10
    }

    It 'every test file that loads the module turns the guard on' {
        $without = @($script:needsGuard | Where-Object {
            (Get-Content $_.FullName -Raw) -notmatch 'Block-VmfAzureCalls'
        } | ForEach-Object { $_.Name })
        $without -join ', ' | Should -BeNullOrEmpty -Because 'an unmocked Azure call in these would go to the network instead of failing'
    }

    It 'and turns it on BEFORE its own mocks, so its own mocks still win' {
        # Order is the whole design: the guard is the floor, not the ceiling. A
        # file that guards after mocking would have the guard override the very
        # mocks the tests depend on.
        $wrong = @(foreach ($f in $script:needsGuard) {
            $text = Get-Content $f.FullName -Raw
            $guardAt = $text.IndexOf('Block-VmfAzureCalls')
            # TEST-AZURE-GUARD-2: a mock in the facade module counts too.
            $firstMock = @(@($text.IndexOf('Mock -ModuleName VmMigrationFactory'), $text.IndexOf('Mock -ModuleName FacadeCore')) |
                Where-Object { $_ -ge 0 } | Sort-Object)[0]
            if ($guardAt -ge 0 -and $null -ne $firstMock -and $guardAt -gt $firstMock) { $f.Name }
        })
        $wrong -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'TEST-1: the guard blocks what the module can actually call' {
    It 'derives the Az cmdlets from the source, so a new call is covered the day it is written' {
        # A hand-maintained list would be missing exactly the call that escapes.
        $found = Get-VmfAzCommandsInSource -RepoRoot $script:repoRoot
        @($found).Count | Should -BeGreaterThan 15
        $found | Should -Contain 'Get-AzVM'
        $found | Should -Contain 'Invoke-AzRestMethod'
    }

    It 'leaves alone the calls that never touch Azure' {
        # Get-AzContext reads the local session. Blocking it would break tests
        # that are correctly offline. The role map already records this - those
        # operations need no permission - so the exclusion is derived too.
        $found = Get-VmfAzCommandsInSource -RepoRoot $script:repoRoot
        $found | Should -Not -Contain 'Get-AzContext'
        $found | Should -Not -Contain 'New-AzVMConfig'
        $found | Should -Not -Contain 'Set-AzVMOSDisk'
    }

    It 'but blocks the calls that need no permission and still go to Azure or Entra' {
        # TEST-AZURE-GUARD-1 review: both are role 'none' in the role map, and
        # the guard read that as "talks to nothing". Set-AzContext -Subscription
        # asks Resource Manager for the subscription; Get-AzAccessToken asks
        # Entra for a token that a storage request then uses.
        $found = Get-VmfAzCommandsInSource -RepoRoot $script:repoRoot
        $found | Should -Contain 'Set-AzContext'
        $found | Should -Contain 'Get-AzAccessToken'
    }

    It 'names the escaping call, because "something called Azure" is not actionable' {
        $guardSrc = Get-Content (Join-Path $script:unitDir '_AzureGuard.ps1') -Raw
        $guardSrc | Should -Match "reached the real Azure"
        $guardSrc | Should -Match '\$name'
    }
}

Describe 'TEST-1: and the ambient identity is gone too' {
    # Found by CI, 2026-09-01. Two tests passed here and failed there with "No
    # Az context - Connect-AzAccount first", because Get-AzContext reads the
    # LOCAL session: on a developer's signed-in machine the cmdlet under test
    # got an identity, and on CI it did not.
    #
    # Get-AzContext talks to nothing, so it is rightly exempt from the network
    # block - but a unit test whose result depends on who is logged in has
    # verified nothing about the product. The reverse case is the dangerous
    # one: a test that only passes because somebody was signed in.
    #
    # So the guard makes every machine look like the empty one. A cmdlet that
    # needs an identity must be TOLD it, which is what the facade does anyway.
    It 'a cmdlet that reads the signed-in identity gets nothing under the guard' {
        Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
        if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Az is not installed, so there is no ambient context to remove'
            return
        }
        Block-VmfAzureCalls -TestFile $PSCommandPath
        { InModuleScope VmMigrationFactory { Get-VmfSignedInIdentity } } |
            Should -Throw -ExpectedMessage '*No Az context*'
    }

    It 'unless the test file supplies its own context, which some must' {
        # A file that defines `function Global:Get-AzContext` is standing in for
        # Az on a machine where it is not installed. The guard leaves that
        # alone - and ONLY that: generalising the exemption to every
        # `function Global:*-Az*` let a real Get-AzSnapshot through to Azure,
        # because this file's own self-test defines one purely to have
        # something to mock.
        $guardSrc = Get-Content (Join-Path $script:unitDir '_AzureGuard.ps1') -Raw
        # Matched as literal text: the guard's own pattern is a regex, and
        # escaping it twice to assert on it is how a test starts checking its
        # own escaping instead of the code.
        $guardSrc | Should -BeLike '*Global|Script):Get-AzContext*'
        $guardSrc | Should -Not -BeLike '*Global|Script):([A-Za-z]+-Az*'
    }
}

# TEST-AZURE-GUARD-1, 2026-10-10: unit tests sent reads and one PUT to Azure.
# The guard skipped every Az cmdlet the file mocked ANYWHERE (a text match over
# the whole file), but a Pester 5 mock applies only to the block that defines
# it - so every other test in that file met the real cmdlet. The guard is now a
# floor that no mock can remove: it always mocks, and a test's own mock wins
# only inside its own block.
#
# Proved by RUNNING a test file, not by reading the guard: the file below goes
# through the project's own runner in its own process, on the pinned Pester.
# Every cmdlet in it has a stand-in that throws "STUB: no mock at all", so a
# call nothing mocks lands there - never on Azure, even under a mutation.
Describe 'TEST-AZURE-GUARD-1: a mock in one block never opens the guard in another' {

    BeforeAll {
        $script:tool = Join-Path $script:repoRoot 'tools' 'Invoke-VmfPesterParallel.ps1'
        $inner = @'
BeforeAll {
    Import-Module (Join-Path '__REPO__' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path '__REPO__' 'tests' 'unit' '_AzureGuard.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'STUB: no mock at all' }
    function Global:Update-AzDisk { throw 'STUB: no mock at all' }
    # A typed parameter, as on the installed cmdlet: a test relaxes it with -RemoveParameterType.
    function Global:New-AzDisk { [CmdletBinding()] param([System.Version]$Disk, [string]$ResourceGroupName, [string]$DiskName) throw 'STUB: no mock at all' }
    # The shape of an INSTALLED cmdlet, as the guard meets it on a machine with Az ...
    function Global:Update-AzVM { [CmdletBinding()] param([Parameter(Mandatory)][string]$ResourceGroupName, [Parameter(Mandatory)][object]$VM) throw 'STUB: no mock at all' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # ... and a stand-in defined AFTER the guard, the order the parser check forbids.
    function Global:Update-AzVM { throw 'STUB: no mock at all' }
}
AfterAll { Remove-Item 'function:\Invoke-AzRestMethod', 'function:\Update-AzDisk', 'function:\Update-AzVM', 'function:\New-AzDisk' -ErrorAction SilentlyContinue }

Describe 'a mock in one It' {
    It 'one-it: the test that mocks gets its own mock' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { 'own mock' }
        InModuleScope VmMigrationFactory { Invoke-AzRestMethod -Method GET -Path '/x' } | Should -Be 'own mock'
    }
    It 'one-it: the next test still meets the guard' {
        { InModuleScope VmMigrationFactory { Invoke-AzRestMethod -Method GET -Path '/x' } } |
            Should -Throw -ExpectedMessage "TEST-1: 'Invoke-AzRestMethod' reached the real Azure*"
    }
}

Describe 'a mock in one Context' {
    Context 'mocks it' {
        BeforeAll { Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { 'own mock' } }
        It 'one-context: the context that mocks gets its own mock' {
            InModuleScope VmMigrationFactory { Invoke-AzRestMethod -Method PUT -Path '/x' } | Should -Be 'own mock'
        }
    }
    Context 'does not mock it' {
        It 'one-context: another context still meets the guard' {
            { InModuleScope VmMigrationFactory { Invoke-AzRestMethod -Method PUT -Path '/x' } } |
                Should -Throw -ExpectedMessage "TEST-1: 'Invoke-AzRestMethod' reached the real Azure*"
        }
    }
}

Describe 'a cmdlet driven through the pipeline' {
    It 'pipeline: an object piped to the test own mock binds over the guard mock' {
        Mock -ModuleName VmMigrationFactory Update-AzDisk { [pscustomobject]@{ ProvisioningState = 'Succeeded' } }
        $r = InModuleScope VmMigrationFactory { [pscustomobject]@{ Name = 'disk1' } | Update-AzDisk }
        $r.ProvisioningState | Should -Be 'Succeeded'
    }
    It 'pipeline: and the guard still stops it in the next test' {
        { InModuleScope VmMigrationFactory { [pscustomobject]@{ Name = 'disk1' } | Update-AzDisk } } |
            Should -Throw -ExpectedMessage "TEST-1: 'Update-AzDisk' reached the real Azure*"
    }
    It 'late-stand-in: a stand-in defined after the guard breaks the same call - the reason for the order' {
        Mock -ModuleName VmMigrationFactory Update-AzVM { [pscustomobject]@{ ProvisioningState = 'Succeeded' } }
        { InModuleScope VmMigrationFactory { [pscustomobject]@{ Name = 'vm1' } | Update-AzVM } } |
            Should -Throw -ExpectedMessage '*missing mandatory parameters*'
    }
}

Describe 'a test mock that relaxes a parameter type' {
    It 'shape: an object of another type binds to the test own mock over the guard mock' {
        Mock -ModuleName VmMigrationFactory New-AzDisk -RemoveParameterType 'Disk' { [pscustomobject]@{ Name = $Disk.Name } }
        $r = InModuleScope VmMigrationFactory { New-AzDisk -Disk ([pscustomobject]@{ Name = 'disk1' }) -ResourceGroupName 'rg' -DiskName 'disk1' }
        $r.Name | Should -Be 'disk1'
    }
    It 'shape: and the guard still stops it in the next test' {
        { InModuleScope VmMigrationFactory { New-AzDisk -Disk ([pscustomobject]@{ Name = 'disk1' }) -ResourceGroupName 'rg' -DiskName 'disk1' } } |
            Should -Throw -ExpectedMessage "TEST-1: 'New-AzDisk' reached the real Azure*"
    }
}
'@
        $script:scopeDir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-guard-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:scopeDir | Out-Null
        Set-Content (Join-Path $script:scopeDir 'GuardScope.Tests.ps1') ($inner.Replace('__REPO__', $script:repoRoot))
        $script:scopeRun = & (Get-Process -Id $PID).Path -NoProfile -File $script:tool -TestPath $script:scopeDir -Groups 1 2>&1 | Out-String
        $script:scopeCode = $LASTEXITCODE
    }
    AfterAll { if ($script:scopeDir) { Remove-Item $script:scopeDir -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'every test in the file ran and passed' {
        $script:scopeRun | Should -Match '9 passed, 0 failed' -Because $script:scopeRun
        $script:scopeCode | Should -Be 0
    }

    It 'a mock in one It does not open the guard for the next It' {
        $script:scopeRun | Should -Not -Match 'FAIL .*one-it:' -Because $script:scopeRun
    }

    It 'a mock in one Context does not open the guard for another Context' {
        $script:scopeRun | Should -Not -Match 'FAIL .*one-context:' -Because $script:scopeRun
    }

    It 'a cmdlet driven through the pipeline still binds to the test''s own mock over the guard''s (e08d84a2)' {
        $script:scopeRun | Should -Not -Match 'FAIL .*pipeline:' -Because $script:scopeRun
    }

    It 'and a stand-in defined after the guard still breaks that call, which is why the order is checked below' {
        $script:scopeRun | Should -Not -Match 'FAIL .*late-stand-in:' -Because $script:scopeRun
    }

    It 'a test mock that relaxes a parameter type (-RemoveParameterType) still gets that shape over the guard''s' {
        $script:scopeRun | Should -Not -Match 'FAIL .*shape:' -Because $script:scopeRun
    }

    It 'the guard keeps no file-wide list of the file''s own Az mocks any more' {
        # The mechanism that made the gap. Read as code, not text, so the
        # comment explaining why it went cannot satisfy or fail this.
        . (Join-Path $script:unitDir '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:unitDir '_AzureGuard.ps1') -Raw)
        $code | Should -Not -Match '\$ownMocks'
    }
}

Describe 'TEST-AZURE-GUARD-1: a stand-in is defined BEFORE the guard, never after it' {
    # MEASURED 2026-10-11 on Pester 5.7.1 - the real cause of the old file-wide
    # skip (e08d84a2). Pester builds ONE mock per command, from the metadata it
    # resolves first. Where Az is installed, a `function Global:Update-AzDisk`
    # stand-in defined AFTER the guard leaves the guard's mock carrying the
    # REAL cmdlet's mandatory parameters, so `$disk | Update-AzDisk` under the
    # test's own mock fails with "missing mandatory parameters:
    # ResourceGroupName DiskName". CI has no Az, so only a developer machine
    # sees it. A stand-in defined first gives both mocks one shape. Found with
    # the parser, so a name in a comment or a string is not a definition.
    #
    # "After" means where the guard's mock still applies: a guard in a
    # BeforeAll covers the block that holds that BeforeAll and every block
    # inside it; a guard called in an It covers that It only.
    It 'no test file defines a stand-in for an Az cmdlet after it turns the guard on' {
        # Get-AzContext is not in the list, on purpose: a file that defines it
        # is supplying a context, and the guard leaves that one alone.
        $azNames = @(Get-VmfAzCommandsInSource -RepoRoot $script:repoRoot) + @(Get-VmfAzCommandsInSource -RepoRoot $script:repoRoot -Module FacadeCore)
        $late = @(foreach ($f in $script:needsGuard) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $stubs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    ($n.Name -replace '^(Global|Script):', '') -in $azNames }, $true))
            foreach ($gs in @(GetGuardScopes $ast)) {
                $g = $gs.Guard; $scope = $gs.Scope
                foreach ($s in $stubs) {
                    if ($s.Extent.StartOffset -gt $g.Extent.StartOffset -and
                        $s.Extent.StartOffset -ge $scope.Extent.StartOffset -and $s.Extent.EndOffset -le $scope.Extent.EndOffset) {
                        '{0}: {1}' -f $f.Name, $s.Name
                    }
                }
            }
        }) | Sort-Object -Unique
        $late -join '; ' | Should -BeNullOrEmpty -Because 'a stand-in after the guard makes the guard mock and the test mock disagree on the parameters'
    }
}

# TEST-AZURE-GUARD-2, filed by the review of TEST-AZURE-GUARD-1: the guard put
# its mocks in VmMigrationFactory only. The facade module calls
# Invoke-AzRestMethod itself (it starts the engine job and lists
# subscriptions), and the worker processes some tests start had no mocks at
# all. Both were stopped only by the process floor, and only after the HTTP
# client gave up.
Describe 'TEST-AZURE-GUARD-2: the facade module has the guard too' {

    It 'derives the facade''s Az cmdlets from its own source, the same way as the module''s' {
        $found = @(Get-VmfAzCommandsInSource -RepoRoot $script:repoRoot -Module FacadeCore)
        $found | Should -Contain 'Invoke-AzRestMethod'
        $found | Should -Not -Contain 'Get-AzContext'
        # Read from the facade's own source, not the engine module's.
        $found | Should -Not -Contain 'Get-AzVM'
    }

    It 'no test file loads a guarded module again after it turns the guard on' {
        # Import-Module -Force makes a NEW module, and the guard's mocks stay in
        # the old one: every test after that import has no guard at all. So a
        # module is imported first and guarded after, never the other way round.
        $late = @(foreach ($f in $script:needsGuard) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $imports = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Import-Module' -and $n.Extent.Text -match '(VmMigrationFactory|FacadeCore)\.psd1' }, $true))
            foreach ($gs in @(GetGuardScopes $ast)) {
                foreach ($i in $imports) {
                    if ($i.Extent.StartOffset -gt $gs.Guard.Extent.StartOffset -and
                        $i.Extent.StartOffset -ge $gs.Scope.Extent.StartOffset -and $i.Extent.EndOffset -le $gs.Scope.Extent.EndOffset) {
                        '{0}: line {1}' -f $f.Name, $i.Extent.StartLineNumber
                    }
                }
            }
        }) | Sort-Object -Unique
        $late -join '; ' | Should -BeNullOrEmpty -Because 'a module imported after the guard has none of its mocks'
    }

    Context 'a facade call that nothing mocks' {
        BeforeEach {
            Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
            Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
            # A stand-in, always - also where Az is installed, as a function
            # comes before a cmdlet. With the guard taken away, the call lands
            # HERE and never on Azure.
            function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'STUB: no mock at all' }
            $script:facadeManifest = Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1'
            $script:viewer = [pscustomobject]@{ Identity = 'viewer@example.com'; Roles = @('Vmf.Viewer') }
        }
        AfterEach { Remove-Item 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue }

        It 'meets the guard, not Azure' {
            Block-VmfAzureCalls -TestFile $PSCommandPath
            { Get-VmfFacadeScopeList -Principal $script:viewer } |
                Should -Throw -ExpectedMessage "TEST-1: 'Invoke-AzRestMethod' reached the real Azure*"
        }

        It 'and a facade imported again after the guard has no guard - the reason for the order check' {
            Block-VmfAzureCalls -TestFile $PSCommandPath
            # Through a variable on purpose: the order check above reads import
            # lines that name the manifest, and this one breaks the rule to show why.
            Import-Module $script:facadeManifest -Force
            { Get-VmfFacadeScopeList -Principal $script:viewer } | Should -Throw -ExpectedMessage 'STUB: no mock at all'
        }
    }
}

# TEST-AZURE-GUARD-2: a worker is a new process, so no Pester mock reaches it.
# The runner gives every test process VMF_TEST_AZURE_GUARD, a worker started by
# a test inherits it, and worker.ps1 then loads the guard's stand-ins from the
# repository's tests folder before it imports the module.
Describe 'TEST-AZURE-GUARD-2: a worker a test starts has the guard too' {

    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
        Block-VmfAzureCalls -TestFile $PSCommandPath
        # The fake engine asks the worker's own process. It CALLS Azure only
        # when the command is the guard's stand-in, so with the guard taken away
        # it says so and calls nothing.
        $script:guardEngine = @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
$report = [ordered]@{ rest = 'NO GUARD'; context = '' }
$stand = Get-Command Invoke-AzRestMethod -CommandType Function -ErrorAction SilentlyContinue
if ($stand -and $stand.Definition -match 'TEST-1') {
    $report.rest = try { & (Get-Module VmMigrationFactory) { Invoke-AzRestMethod -Method GET -Path '/subscriptions?api-version=2022-12-01' } | Out-Null; 'NOT BLOCKED' } catch { $_.Exception.Message }
    $report.context = [string]([bool](Get-Command Get-AzContext -CommandType Function -ErrorAction SilentlyContinue) -and
        (& (Get-Module VmMigrationFactory) { $null -eq (Get-AzContext) }))
}
$report | ConvertTo-Json | Set-Content (Join-Path $RunPath 'guard-report.json')
& (Get-Module VmMigrationFactory) { param($id, $rp, $rid)
    New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $id | Out-Null
    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
} $entry.vmId $RunPath $RunId
'@
        function script:RunGuardWorker {
            param([string]$WorkerScript, [string]$Root)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $Root } { Initialize-VmfRun -RunPath $rp -RunId 'guard-run' | Out-Null }
            $planFile = Join-Path $Root 'plan.json'
            @{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion)
                        vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-g/providers/Microsoft.Compute/virtualMachines/guard1'
                        wave = 'w1'; path = 'A'; assessment = [ordered]@{ location = 'centralus'; availabilitySetId = '' }
                        target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [ordered]@{ requireApproval = $true } })
            } | ConvertTo-Json -Depth 12 | Set-Content $planFile
            $fake = Join-Path $Root 'fake-engine.ps1'
            Set-Content $fake $script:guardEngine
            $env:VMF_TEST_ENGINE = $fake
            try {
                $out = & (Get-Process -Id $PID).Path -NoProfile -File $WorkerScript -RunPath $Root -PlanPath $planFile -Wave 'w1' -RunId 'guard-run' `
                    -WorkerId 'worker-guard' -IdleWaitSeconds 1 2>&1 | Out-String
            }
            finally { Remove-Item Env:\VMF_TEST_ENGINE -ErrorAction SilentlyContinue }
            $reportFile = Join-Path $Root 'guard-report.json'
            [pscustomobject]@{ Out = $out; Report = if (Test-Path $reportFile) { Get-Content $reportFile -Raw | ConvertFrom-Json } }
        }
    }

    It 'the runner gives every test process the value a worker needs' {
        $env:VMF_TEST_AZURE_GUARD | Should -Be '1' -Because 'tools/Invoke-VmfPesterParallel.ps1 sets it for every test process, and a worker inherits it'
    }

    It 'an Az call in a worker meets the guard''s stand-in, not Azure, and the worker has no signed-in context' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-guard-w-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
            $r = RunGuardWorker -WorkerScript (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1') -Root $root
            $r.Report | Should -Not -BeNullOrEmpty -Because $r.Out
            $r.Report.rest | Should -BeLike "TEST-1: 'Invoke-AzRestMethod' reached the real Azure*" -Because $r.Out
            $r.Report.context | Should -Be 'True'
        }
        finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the value does nothing in an install: the engine image carries no tests folder, so a worker there loads no stand-in' {
        # The image copies src/VmMigrationFactory to /app/src/VmMigrationFactory
        # and nothing from tests (docker/Dockerfile, .dockerignore). The same
        # layout here, with the value set on purpose.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-guard-i-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $app = Join-Path $root 'app' 'src'
        New-Item -ItemType Directory -Path $app | Out-Null
        Copy-Item (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') $app -Recurse
        $run = Join-Path $root 'run'
        New-Item -ItemType Directory -Path $run | Out-Null
        $before = $env:VMF_TEST_AZURE_GUARD
        $env:VMF_TEST_AZURE_GUARD = '1'
        try {
            $r = RunGuardWorker -WorkerScript (Join-Path $app 'VmMigrationFactory' 'Workers' 'worker.ps1') -Root $run
            $r.Report.rest | Should -Be 'NO GUARD' -Because $r.Out
        }
        finally {
            $env:VMF_TEST_AZURE_GUARD = $before
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the worker reads the guard from one fixed place, never from a path in the environment, and before it imports the module' {
        . (Join-Path $script:unitDir '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1')
        $code | Should -Match "'tests' 'unit' '_AzureGuard\.ps1'"
        $code | Should -Not -Match '\.\s+\$env:' -Because 'the value is a switch, not a path a setting could point anywhere'
        $code.IndexOf('VMF_TEST_AZURE_GUARD') | Should -BeGreaterThan -1
        $code.IndexOf('VMF_TEST_AZURE_GUARD') | Should -BeLessThan $code.IndexOf('Import-Module')
    }

    It 'and no image carries the tests folder' {
        $ignore = Get-Content (Join-Path $script:repoRoot '.dockerignore')
        @($ignore | Where-Object { $_ -match '^\s*!\s*/?tests' }) | Should -BeNullOrEmpty
        foreach ($df in @(Get-ChildItem (Join-Path $script:repoRoot 'docker') -Recurse -Filter 'Dockerfile*')) {
            @(Get-Content $df.FullName | Where-Object { $_ -match '^\s*(COPY|ADD)\b.*\btests\b' }) | Should -BeNullOrEmpty -Because $df.FullName
        }
    }
}

Describe 'TEST-1: the guard actually fires' {
    It 'an unmocked Az call throws a test error instead of going to the network' {
        # Prove the mechanism, not just its presence. Load the module, guard it,
        # and call something nothing has mocked.
        Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
        # CI does not install Az (ci.yml installs Pester and the analyzer only),
        # so the cmdlet has to exist before it can be mocked - otherwise this
        # proves nothing there and fails for the wrong reason. Same stub trick
        # AzureOps.Tests.ps1 uses.
        if (-not (Get-Command Get-AzSnapshot -ErrorAction SilentlyContinue)) {
            function Global:Get-AzSnapshot { param($ResourceGroupName, $SnapshotName) throw 'stub' }
        }
        Block-VmfAzureCalls -TestFile $PSCommandPath
        {
            InModuleScope VmMigrationFactory { Get-AzSnapshot -ResourceGroupName 'rg' -SnapshotName 'nope' }
        } | Should -Throw -ExpectedMessage '*reached the real Azure*'
    }
}

# CI-SPEED-1, 2026-09-09. Each CI run took more than 5 minutes, and it needed
# to be faster.
#
# MEASURED, and the answer was not where anyone would look. The Pester step is
# 74% of the CI job, and within it three files were a third of the wall clock.
# The cause was not the tests:
#
#   file setup and teardown, per test .....   41 ms   (3%)
#   module-scoped mocks, 21 of them .......   64 ms   (4%)
#   the rest .............................. 1445 ms  (93%)
#
# The rest was THE PRODUCT'S OWN WAITING. The module sleeps on purpose in eight
# places - retry backoff, poll intervals, the role propagation wait - and a
# test driving those paths pays every second of it against mocks that were
# going to answer immediately.
#
# A unit test must not reach Azure. It must not WAIT for Azure either.
#
#   Pester total   283s -> 227s
#   StateMachine    47s ->  14s
#
# Orchestrator.Tests.ps1 did NOT get faster, and that is correct: its sleeps
# are its own, around a real spawned process, testing ordering and kill-resume.
# The guard does not touch a test file's own waits.
Describe 'CI-SPEED-1: the guard stops a unit test waiting for Azure' {

    BeforeAll {
        $script:guard = Get-Content (Join-Path $PSScriptRoot '_AzureGuard.ps1') -Raw
    }

    It 'the guard neutralises the module''s own sleeping' {
        $script:guard | Should -Match "Mock -ModuleName VmMigrationFactory -CommandName Start-Sleep"
    }

    It 'and a file that mocks Start-Sleep itself still wins' {
        # Same rule the Az cmdlets get: the guard never takes a mock away from
        # a test that asked for one. A test that ASSERTS on backoff has to be
        # able to.
        $script:guard | Should -Match '\$ownWaits'
        $script:guard | Should -Match "'Start-Sleep' -notin \`$ownWaits"
    }

    It 'the module really does sleep, so this is worth doing' {
        # If the product ever stops sleeping, this guard is dead weight and
        # should go. Read it rather than assume it.
        $moduleRoot = Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'src' 'VmMigrationFactory'
        $sleepers = @(Get-ChildItem $moduleRoot -Recurse -Filter *.ps1 |
            Where-Object { (Get-Content $_.FullName -Raw) -match 'Start-Sleep' })
        $sleepers.Count | Should -BeGreaterThan 0 -Because 'the guard exists to neutralise these'
    }

    It 'and the reason is written down where the change is' {
        # A future reader finding a mocked Start-Sleep needs to know it was a
        # measurement, not a habit.
        $script:guard | Should -Match '47\.2s -> 14\.6s|47\.2s|CI-SPEED-1'
        $script:guard | Should -Match '(?i)does not change the product'
    }
}
