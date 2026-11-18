# TEST-1: make an unmocked Azure call fail as a TEST error, loudly, naming the
# call that escaped.
#
# Hard rule 8 says unit and contract tests must never require Azure, and nothing
# enforced it. Each test file mocks the azureops functions it happens to know
# about, so adding ONE call to PRECHECK (PERM-3) sent 22 existing tests straight
# to real ARM - they failed with HTTP 404s from Azure, not from a mock.
#
# The failure mode that matters is not the noise. It is that a test can PASS
# because a real Azure call succeeded, so the suite reports "verified" having
# verified nothing - and the escape is unbounded: today's were reads, but
# nothing stops the next one being a delete against a real machine.
#
# REACH, stated honestly: CI installs Pester and the analyzer only, so the Az
# cmdlets do not exist there and this guard mocks nothing. That is not a hole -
# a call that cannot resolve fails loudly on its own. The guard matters on a
# developer machine, where Az IS installed and signed in, which is exactly where
# a silent real call would otherwise succeed and make a test pass.
#
# Not named *.Tests.ps1 on purpose: Pester discovers only test files.

function Get-VmfAzCommandsInSource {
    <#
    .SYNOPSIS
        Every Az cmdlet the module actually calls, parsed out of the source.

        Derived, never listed by hand - the same approach PERM-1 uses for the
        role map. A new Az call is blocked the moment it is written, which is
        the whole point: a hand-maintained list would be missing precisely the
        call that escapes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        # TEST-AZURE-GUARD-2: the facade module calls Azure too, outside the
        # engine module, so its cmdlets are found the same way, from its own
        # source.
        [Parameter()][ValidateSet('VmMigrationFactory', 'FacadeCore')][string]$Module = 'VmMigrationFactory'
    )

    $moduleRoot = Join-Path $RepoRoot 'src' 'VmMigrationFactory'
    $sourceRoot = if ($Module -eq 'FacadeCore') { Join-Path $RepoRoot 'src' 'facade' 'FacadeCore' } else { $moduleRoot }
    # One kept answer per module. The engine module keeps the name it always had.
    $cacheName = if ($Module -eq 'FacadeCore') { 'VmfAzCommandsCacheFacadeCore' } else { 'VmfAzCommandsCache' }

    # CI-SPEED-2, MEASURED 2026-09-26: every test file calls this, and reading
    # the whole module each time cost about half a second a file - over two
    # minutes of a run, spent re-reading source that had not changed. The
    # answer is kept for the run, keyed by the source files' names, sizes and
    # times, so an edit between two runs in one session is still seen: a
    # changed key reads the source again. Only the READ is kept; the rbac map
    # below is read every time, because it is cheap.
    # The facade's code is one .psm1, so both kinds of file are read.
    $files = @(Get-ChildItem $sourceRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
    $key = ($files | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join ';'
    $kept = Get-Variable -Scope Global -Name $cacheName -ValueOnly -ErrorAction SilentlyContinue
    if ($kept -and $kept.Key -eq $key) {
        $found = $kept.Found
    }
    else {
    $found = @(
        $files | ForEach-Object {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object { $_ -match '^(Get|Set|New|Remove|Update|Start|Stop|Restart|Wait|Test|Invoke)-Az' }
        }
    ) | Sort-Object -Unique
    Set-Variable -Scope Global -Name $cacheName -Value @{ Key = $key; Found = @($found) }
    }

    # Left alone: what the role map records as needing NO permission AND what
    # only builds an object in memory - Get-AzContext reads the local session,
    # and the *Config / Set-AzVM* builders change a local object.
    #
    # TEST-AZURE-GUARD-1 review: "needs no permission" is NOT "talks to
    # nothing". Set-AzContext -Subscription asks Resource Manager for the
    # subscription, and Get-AzAccessToken asks Entra for a token - both are
    # role 'none' in the map, and both were left unblocked here. So a role
    # 'none' cmdlet is blocked unless its name says it is a local builder: a
    # new one is blocked until somebody decides otherwise.
    $mapPath = Join-Path $moduleRoot 'data' 'rbac-actions.json'
    $local = @()
    if (Test-Path $mapPath) {
        $map = Get-Content $mapPath -Raw | ConvertFrom-Json
        $local = @($map.operations | Where-Object { $_.role -eq 'none' -and
                $_.cmdlet -match '^(Get-AzContext|New-Az\w+Config|Set-AzVM(OSDisk|BootDiagnostic|SecurityProfile|Uefi))$' } |
            ForEach-Object { $_.cmdlet })
    }
    @($found | Where-Object { $_ -notin $local })
}

function Get-VmfOwnMockShape {
    <#
    .SYNOPSIS
        The parameter shape each of a test file's own mocks asks for: the names
        it passes to -RemoveParameterType and -RemoveParameterValidation, per
        command, read with the parser.

        TEST-AZURE-GUARD-1, MEASURED 2026-10-11: Pester builds ONE mock per
        command, with the shape of the FIRST Mock call. The guard mocks first,
        so a test's later `Mock Update-AzVM -RemoveParameterType 'VM'` got the
        guard's typed VM parameter and failed with "Cannot process argument
        transformation on parameter 'VM'" - 17 tests in 3 files, on a machine
        with Az installed. So the guard's mock takes the shape the file asks
        for. This decides a SHAPE only - it never decides whether the guard
        mocks a cmdlet.
    .OUTPUTS
        A hashtable: command name -> @{ Type = names; Validation = names }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TestFile)

    $shape = @{}
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($TestFile, [ref]$null, [ref]$null)
    $mocks = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Mock' }, $true)
    foreach ($m in $mocks) {
        $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($m, $true)
        $named = $bound.BoundParameters['CommandName']
        if (-not $named) { continue }
        $name = [string]$named.ConstantValue
        if (-not $name) { continue }
        foreach ($kind in @(@('RemoveParameterType', 'Type'), @('RemoveParameterValidation', 'Validation'))) {
            $arg = $bound.BoundParameters[$kind[0]]
            if (-not $arg) { continue }
            # A constant only. A name held in a variable cannot be read here,
            # and that test keeps the shape it had before this existed.
            try { $values = @($arg.Value.SafeGetValue()) } catch { continue }
            if (-not $shape.ContainsKey($name)) { $shape[$name] = @{ Type = @(); Validation = @() } }
            $shape[$name][$kind[1]] = @(@($shape[$name][$kind[1]]) + @($values | ForEach-Object { [string]$_ }) | Sort-Object -Unique)
        }
    }
    $shape
}

function Block-VmfAzureCalls {
    <#
    .SYNOPSIS
        Mock every Az cmdlet the module can call so that reaching one throws a
        test error instead of a network request.

        Call this FIRST in a test file's BeforeAll, before the file's own mocks
        and before any stand-in function for an Az cmdlet: Pester's later and
        inner mocks win, so a test that deliberately mocks Get-AzVM still
        behaves normally. Anything the test forgot hits this instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$RepoRoot,
        [Parameter()][string]$TestFile
    )

    # Work the repo out from THIS file's location. Test files set up their own
    # paths at different points, and taking a required parameter meant the guard
    # failed to bind in files that had not got there yet - which failed every
    # test in them. A guard that breaks the suite is worse than no guard.
    if (-not $RepoRoot) {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    }

    # TEST-AZURE-GUARD-2: the facade module calls Azure itself - it starts the
    # engine job and lists subscriptions with Invoke-AzRestMethod - so it gets
    # the same mocks, in its own module. A module is guarded only if it is
    # loaded when this runs: a file imports first and guards after, and
    # AzureGuardIsOn.Tests.ps1 fails on an import after the guard, because
    # Import-Module -Force makes a new module that has none of these mocks.
    $guarded = @(@('VmMigrationFactory', 'FacadeCore') | Where-Object { Get-Module $_ })
    if (-not $guarded) { return }   # nothing to guard

    # TEST-AZURE-GUARD-1: A FLOOR THAT NO MOCK CAN REMOVE.
    #
    # This used to skip every Az cmdlet the file mocked ANYWHERE, read as text
    # from the whole file. But a Pester 5 mock applies only to the block that
    # defines it, so a mock in one It left every other test in the file with
    # no mock at all - not the test's, and not this one. On 2026-10-10 unit
    # tests sent reads and one PUT to Azure that way. Now every Az cmdlet is
    # mocked here, always; a test's own mock wins inside its own block (Pester
    # takes the innermost and latest mock), and every other test meets this.
    #
    # The skip was added (e08d84a2) because the guard's mock broke tests that
    # drive a cmdlet through the PIPELINE ($disk | Update-AzDisk). MEASURED
    # 2026-10-11, the cause was not two mocks: it was two SHAPES. Pester builds
    # one mock per command from the metadata it resolves first, and a file that
    # defined `function Global:Update-AzDisk` AFTER this ran left the mock with
    # the installed cmdlet's mandatory parameters. A stand-in defined BEFORE
    # this call gives both mocks one shape, and AzureGuardIsOn.Tests.ps1 fails
    # on a stand-in defined after it. The same rule for the shape a test's own
    # mock asks for: see Get-VmfOwnMockShape.
    $ownWaits = @()
    $ownShape = @{}
    if ($TestFile -and (Test-Path $TestFile)) {
        $ownShape = Get-VmfOwnMockShape -TestFile $TestFile
        $text = Get-Content $TestFile -Raw
        # Waiting is not an Azure call, and a file that mocks Start-Sleep
        # itself keeps the old rule (CI-SPEED-1). The worst a missed block can
        # do here is wait.
        $ownWaits = @([regex]::Matches($text,
            '(?m)^\s*Mock\s+(?:-ModuleName\s+\S+\s+)?(?:-CommandName\s+)?''?(Start-Sleep)''?') |
            ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique

        # ONE stand-in is honoured, and only one: a file that DEFINES
        # `function Global:Get-AzContext` is supplying a context on a machine
        # where Az is not installed at all, and mocking over it would take that
        # away. Deliberately not generalised to every `function Global:*-Az*` -
        # the guard's own self-test defines a stub PURELY so there is something
        # to mock, and exempting that let a real Get-AzSnapshot through to Azure.
    }

    foreach ($moduleName in $guarded) {
        foreach ($name in (Get-VmfAzCommandsInSource -RepoRoot $RepoRoot -Module $moduleName)) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { continue }
            $mockArgs = @{ ModuleName = $moduleName; CommandName = $name; MockWith = (Get-VmfAzureGuardBody -Name $name) }
            if ($ownShape.ContainsKey($name)) {
                if ($ownShape[$name].Type) { $mockArgs.RemoveParameterType = @($ownShape[$name].Type) }
                if ($ownShape[$name].Validation) { $mockArgs.RemoveParameterValidation = @($ownShape[$name].Validation) }
            }
            Mock @mockArgs
        }
    }

    # AND THE ONE THAT IS NOT A NETWORK CALL.
    #
    # Get-AzContext reads the LOCAL session, so it is exempt from the block
    # above - correctly, it talks to nothing. But it makes a unit test depend on
    # whether the person running it happens to be signed in: Get-VmfSignedInIdentity
    # returns an identity on a developer's machine and throws
    # "No Az context" in CI. Two tests passed here and failed there for exactly
    # that reason (2026-09-01), and the reverse is worse - a test that only
    # passes because somebody was logged in has verified nothing about the
    # product.
    #
    # So the guard makes every machine look like the empty one. A cmdlet that
    # needs an identity must be TOLD it (-OnBehalfOf, -RemovedBy), which is
    # what the facade does in production anyway.
    $suppliesContext = $TestFile -and (Test-Path $TestFile) -and
        ((Get-Content $TestFile -Raw) -match '(?m)^\s*function\s+(?:Global|Script):Get-AzContext')
    # TEST-AZURE-GUARD-1: and like the network block, a file's own mock of it
    # in one block no longer removes this from every other block.
    if (-not $suppliesContext -and (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) {
        foreach ($moduleName in $guarded) {
            Mock -ModuleName $moduleName -CommandName Get-AzContext -MockWith { $null }
        }
    }

    # CI-SPEED-1: AND THE MODULE'S OWN WAITING.
    #
    # A unit test must not reach Azure. It must not WAIT for Azure either, and
    # that turned out to be most of the suite's wall clock. The module sleeps
    # on purpose in eight places - retry backoff, poll intervals, the role
    # propagation wait - and a test that drives those paths pays every second
    # of it against mocks that were going to answer immediately.
    #
    # MEASURED 2026-09-09 on StateMachine.Tests.ps1, changing nothing else:
    #   47.2s -> 14.6s, all 30 tests still passing. A 69% saving on one file.
    #
    # Two things this does NOT do. It does not change the product: the waits
    # are real and correct against a real Azure. And it does not bind a test
    # that wants them - a file that mocks Start-Sleep itself, or asserts on it,
    # wins here exactly as it does for the Az cmdlets above.
    #
    # The cost, stated: a runaway retry loop no longer shows itself as a slow
    # test. Nothing tested that before either - it showed as a slow suite
    # nobody could attribute.
    if ('Start-Sleep' -notin $ownWaits -and 'VmMigrationFactory' -in $guarded) {
        Mock -ModuleName VmMigrationFactory -CommandName Start-Sleep -MockWith { }
    }
}

function Get-VmfAzureGuardBody {
    <#
    .SYNOPSIS
        The body that stands in for one Az cmdlet: it throws a test error that
        names the cmdlet. "Something called Azure" is not actionable;
        "Get-AzSnapshot escaped its mocks" is.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    [scriptblock]::Create(@"
throw "TEST-1: '$name' reached the real Azure. Unit tests must never call Azure (hard rule 8) - mock it, or mock the azureops function that wraps it. A test that reaches Azure can PASS because the call succeeded, which means the suite verified nothing."
"@)
}

function Block-VmfAzureCallsInProcess {
    <#
    .SYNOPSIS
        TEST-AZURE-GUARD-2: the guard for a process that has no Pester - a
        worker that a test starts. Every Az cmdlet the module calls becomes a
        global function that throws the guard's test error, and Get-AzContext
        returns nothing.

        A function comes before a cmdlet when PowerShell looks up a name, and
        the module's code sees the global scope, so the module's own calls
        land here. Defined whether or not Az is installed: nothing in a worker
        that a test starts has any reason to call Azure.

        worker.ps1 calls this only when VMF_TEST_AZURE_GUARD is set AND this
        file exists beside it in a repository checkout. No image carries the
        tests folder (.dockerignore is an allow-list, docker/Dockerfile copies
        src only), so in an install the value does nothing.
    #>
    [CmdletBinding()]
    param([Parameter()][string]$RepoRoot)

    if (-not $RepoRoot) {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    }
    foreach ($name in (Get-VmfAzCommandsInSource -RepoRoot $RepoRoot)) {
        Set-Item -Path "function:global:$name" -Value (Get-VmfAzureGuardBody -Name $name)
    }
    Set-Item -Path 'function:global:Get-AzContext' -Value { $null }
}
