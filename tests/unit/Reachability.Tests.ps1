#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REACH-1 - every operator action must be reachable from the app.
#
# Since 2026-08-30, the product never sends a user to separate PowerShell
# commands outside the app.
#
# Seven exported commands had no path from the dashboard when this was
# written. Two of them had visible consequences a customer would meet:
# the wave editor offered "Reserved and guaranteed" with no control anywhere
# that could create the reservation, and the Reports page offered to open a
# customer report that nothing in the shipped product ever wrote.
#
# This test exists so that class of defect cannot come back quietly. It is
# derived - it reads the exported cmdlets from disk rather than listing them -
# so a NEW operator command with no app path fails CI on the PR that adds it,
# which is the only time it is cheap to fix.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:cmdlets = @(Get-ChildItem (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'Public') -Filter *.ps1 |
        ForEach-Object { $_.BaseName })
    # Everything the app can call: the facade's endpoints and core, plus the
    # hosted engine's operation dispatcher.
    $script:appSurface = @(
        (Get-ChildItem (Join-Path $repoRoot 'src' 'facade') -Recurse -Filter *.ps1 |
            ForEach-Object { (Get-VmfPageSource -Path $_.FullName) })
        (Get-Content (Join-Path $repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw)
        (Get-Content (Join-Path $repoRoot 'docker' 'entrypoint.ps1') -Raw)
    ) -join "`n"

    # REACH-2: the SECOND link in the chain.
    #
    # Everything above asks "can the app call this command". It cannot ask
    # whether a PERSON can, and the difference is not theoretical: this test
    # was satisfied for Test-VmfQuotaAndReservation by an endpoint created for that
    # purpose - GetWaveCapacity, whose own header says "(REACH-1, any role)" -
    # and no screen ever called it. The chain was command -> endpoint ->
    # nothing. The rule is that every operator action is reachable FROM THE
    # DASHBOARD, so the endpoint has to be on the other end of a call too.
    $script:dashboardText = (@(Get-ChildItem (Join-Path $repoRoot 'src' 'dashboard') -Filter '*.html' -File |
            ForEach-Object { (Get-VmfPageSource -Path $_.FullName) }) +
        @(Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'help.js') -Raw)) -join "`n"

    $script:endpoints = @(
        Get-ChildItem (Join-Path $repoRoot 'src' 'facade' 'app') -Directory | ForEach-Object {
            $cfgPath = Join-Path $_.FullName 'function.json'
            if (-not (Test-Path $cfgPath)) { return }
            $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $trigger = @($cfg.bindings | Where-Object { $_.type -like '*Trigger' })[0]
            if (-not $trigger) { return }
            [pscustomobject]@{
                Name    = $_.Name
                Type    = $trigger.type
                Route   = [string]$trigger.route
                Methods = @($trigger.methods) -join ','
            }
        })

    # A route becomes a pattern: {runId} is whatever the page interpolates,
    # which is never a quote or a slash. `runs/{runId}/waves/{wave}/approve`
    # then matches runs/${encodeURIComponent(runId)}/waves/${w}/approve.
    $script:RouteMatches = {
        param([string]$Route, [string]$Text)
        # [regex]::Escape turns { into \{ and LEAVES } ALONE, so the pattern to
        # find is \{name} - not \{name\}. Getting that wrong matched no route
        # at all and reported every endpoint as an orphan, which is as useless
        # as reporting none: a rule that fails on everything teaches people to
        # switch it off.
        $pattern = [regex]::Escape($Route) -replace '\\\{[A-Za-z0-9_]+\}', '[^''"`]*?'
        $Text -match $pattern
    }

    # Endpoints a SCREEN legitimately does not call. Same discipline as the
    # command list below: a category, never "not built yet".
    $script:endpointExempt = [ordered]@{
        # GetRunSummary was here as a "duplicate store read" until COUNT-TRUTH-1
        # (2026-09-24): the Reports page now reads it, because counting a run by
        # its machines is the service's job - the page doing it itself read the
        # engine's ONE-wave feed and called it the run.
    }

    # THE ONE DELIBERATE EXCEPTION TO HARD RULE 12 (2026-11-02,
    # TEMP-DISK-PREVIEW-1): registering the preview feature
    # Microsoft.Compute/VMTempDiskResizePreview. It is the customer's own
    # subscription-wide preview setting, which the product reads and never
    # changes - not as its identity and not as the signed-in user. The targets
    # step TELLS: it names the feature and the subscription, and its (?) gives
    # the Azure CLI and PowerShell commands, the portal path, the role
    # (Contributor or Owner on the subscription) and the wait, with Check again
    # to read the state with no reload. No exported command registers it, so
    # nothing here needs an exemption; TempDiskPreview.Tests.ps1 holds that no
    # code of the product registers a feature or a provider.
    #
    # An exemption is a claim that a command is NOT an operator action. It is
    # not a place to park work: "we have not built it yet" is a failure, not
    # an exemption. Each one says which category it is in.
    $script:exempt = [ordered]@{
        # Category 1: reads the run store and nothing else. The dashboard reads
        # store documents directly with the VIEWER'S OWN token, so there is
        # nothing for an endpoint to add - it would be a second way to read the
        # same file.
        'Get-VmfWaveSchedule'        = 'store read - the dashboard reads schedule documents directly'
        # Category 2: library functions the engine calls inside an operation.
        # They are exported because the guest pipeline and tests need them, not
        # because a person would ever invoke one.
        'ConvertFrom-VmfGuestOutput' = 'library - parses guest JSON inside the engine, never invoked by a person'
        'Get-VmfGuestScript'         = 'library - returns guest script content to the engine'
        'Get-VmfDiskArchitecture'    = 'library - pure size classification used by assessment and planning'
        # REPORT-AUTO-1: the engine writes the report by itself when a wave
        # finishes and when a machine is restored or rebuilt
        # (Save-VmfRecordAndReport). Nobody produces it any more; drills call it.
        'New-VmfReport'              = 'library - the engine writes the report itself after a wave, a restore and a rebuild'    }
}

Describe 'REACH-1: every operator command has a path from the app' {

    It 'finds the exported commands to check' {
        # If this ever reads zero, the test below passes vacuously and proves
        # nothing - which is the way a derived test dies without anyone noticing.
        $script:cmdlets.Count | Should -BeGreaterThan 20
    }

    It 'every exported command is either reachable from the app or explicitly exempt' {
        $unreachable = @($script:cmdlets |
            Where-Object { $_ -notin $script:exempt.Keys } |
            Where-Object { $script:appSurface -notmatch "\b$([regex]::Escape($_))\b" })
        $unreachable -join ', ' | Should -BeNullOrEmpty -Because @'
these commands can only be run by hand in PowerShell. Either give the command a
path from the app - a facade endpoint, or an operation the hosted engine
dispatches - or add it to the exemption list above WITH THE CATEGORY IT IS IN.
"Not built yet" is not a category.
'@
    }
}

Describe 'REACH-1: the exemption list cannot rot' {

    It 'every exemption names a command that still exists' {
        # A stale exemption is worse than none: it looks like a considered
        # decision about a command nobody can find.
        $ghosts = @($script:exempt.Keys | Where-Object { $_ -notin $script:cmdlets })
        $ghosts -join ', ' | Should -BeNullOrEmpty -Because 'these exemptions name commands that no longer exist'
    }

    It 'no exemption covers a command that is in fact reachable' {
        # If it became reachable, the exemption is a lie about the product.
        $dead = @($script:exempt.Keys |
            Where-Object { $_ -in $script:cmdlets } |
            Where-Object { $script:appSurface -match "\b$([regex]::Escape($_))\b" })
        $dead -join ', ' | Should -BeNullOrEmpty -Because 'these are reachable from the app - drop the exemption'
    }

    It 'every exemption gives a reason, and none of them is "later"' {
        foreach ($k in $script:exempt.Keys) {
            $reason = [string]$script:exempt[$k]
            $reason | Should -Not -BeNullOrEmpty -Because "$k must say why it is not an operator action"
            $reason | Should -Not -Match '(?i)\b(later|todo|not built|pending|backlog|for now)\b' `
                -Because "$k is deferred work, not an exemption"
        }
    }
}

Describe 'REACH-2: an endpoint nobody calls is not a path from the app' {

    It 'finds the endpoints to check' {
        # Reads zero and everything below passes on nothing.
        $script:endpoints.Count | Should -BeGreaterThan 15
        @($script:endpoints | Where-Object Type -eq 'httpTrigger').Count | Should -BeGreaterThan 15
    }

    It 'every HTTP endpoint is called by a dashboard page' {
        # THE DEFECT THIS EXISTS FOR. GetWaveCapacity was created to give
        # Test-VmfQuotaAndReservation a path from the app, satisfied the command rule
        # because its name then appeared in the facade, and no screen ever
        # called it. An operator still could not ask whether a wave would fit.
        $orphans = foreach ($e in $script:endpoints) {
            if ($e.Type -ne 'httpTrigger') { continue }
            if ($script:endpointExempt.Contains($e.Name)) { continue }
            if (-not (& $script:RouteMatches $e.Route $script:dashboardText)) {
                "$($e.Name) ($($e.Methods) $($e.Route))"
            }
        }
        $orphans -join ', ' | Should -BeNullOrEmpty -Because @'
no page calls these, so whatever they reach is not reachable BY A PERSON. Give
the endpoint a control on a screen, or - if a screen legitimately should not
call it - add it to the endpoint exemption list WITH ITS CATEGORY. "No screen
yet" is not a category.
'@
    }

    It 'a non-HTTP endpoint is exempt by what it is, not by a list' {
        # The timer runners are the platform calling us. Nothing on a screen
        # should reach them, and that is a property of the trigger rather than
        # a decision somebody has to keep making.
        $timers = @($script:endpoints | Where-Object Type -ne 'httpTrigger')
        $timers.Count | Should -BeGreaterThan 0
        foreach ($t in $timers) { $t.Type | Should -Be 'timerTrigger' }
    }
}

Describe 'REACH-2: the endpoint exemption list cannot rot either' {

    It 'every endpoint exemption names an endpoint that still exists' {
        $ghosts = @($script:endpointExempt.Keys | Where-Object { $_ -notin $script:endpoints.Name })
        $ghosts -join ', ' | Should -BeNullOrEmpty
    }

    It 'no endpoint exemption covers one a page does in fact call' {
        $dead = foreach ($name in $script:endpointExempt.Keys) {
            $e = $script:endpoints | Where-Object Name -eq $name
            if ($e -and (& $script:RouteMatches $e.Route $script:dashboardText)) { $name }
        }
        $dead -join ', ' | Should -BeNullOrEmpty -Because 'a page calls these - drop the exemption'
    }

    It 'every endpoint exemption gives a category, and none of them is "later"' {
        foreach ($k in $script:endpointExempt.Keys) {
            $reason = [string]$script:endpointExempt[$k]
            $reason | Should -Not -BeNullOrEmpty
            $reason | Should -Not -Match '(?i)\b(later|todo|not built|no screen yet|pending|backlog|for now)\b' `
                -Because "$k is deferred work, not an exemption"
        }
    }
}
