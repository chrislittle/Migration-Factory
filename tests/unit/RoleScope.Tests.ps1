#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RBAC-TEST-1 - "ideally testing to make sure no one escapes their scope."
#
# There are three ways to escape, and only one of them is exotic:
#
#   1. An endpoint that simply FORGETS to check a role. The dashboard hides the
#      button, so nobody notices - until somebody calls the API directly, which
#      is the entire threat model. This is checkable from source and is what
#      most of this file does.
#   2. An endpoint that checks the WRONG role - a mutating action gated on
#      Vmf.Viewer, say. Also checkable: read actions and write actions have
#      different role sets and must not be confused.
#   3. The gate working but the token being wrong. Only a live call can show
#      that; tests/lab/Invoke-RoleScopeDrill.ps1 does it with throwaway
#      service principals.
#
# The gate lives in TWO places by design - some FacadeCore functions assert it
# themselves, and the pure readers are gated by their HTTP handler instead. That
# split is fine, and it is exactly why this test derives the answer from both
# sides rather than assuming one of them.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    $script:handlers = Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade' 'app') -Directory |
        ForEach-Object {
            $run = Join-Path $_.FullName 'run.ps1'
            $fn = Join-Path $_.FullName 'function.json'
            if (-not (Test-Path $run) -or -not (Test-Path $fn)) { return }
            $cfg = Get-Content $fn -Raw | ConvertFrom-Json
            $http = @($cfg.bindings | Where-Object { $_.type -eq 'httpTrigger' })
            [pscustomobject]@{
                Name = $_.Name; Text = Get-Content $run -Raw
                IsHttp = ($http.Count -gt 0)
                Methods = @($http.methods)
            }
        } | Where-Object { $_ }

    $script:allRoles = @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')
    $script:writeRoles = @('Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')

    # Which FacadeCore functions assert a role themselves.
    function Script:CoreGate([string]$Fn) {
        $m = [regex]::Match($script:core, "(?ms)^function $([regex]::Escape($Fn)) \{(.*?)^\}")
        if (-not $m.Success) { return $null }
        $g = [regex]::Match($m.Groups[1].Value, "Assert-VmfFacadeRole -Principal \`$Principal -AnyOf @\(([^)]*)\)")
        if ($g.Success) { return $g.Groups[1].Value } else { return '' }
    }
}

Describe 'RBAC-TEST-1: every HTTP endpoint checks a role before it does anything' {
    It 'found the endpoints to check' {
        @($script:handlers | Where-Object IsHttp).Count | Should -BeGreaterThan 8
    }

    It 'no HTTP endpoint is reachable without a role check' {
        # The escape that matters: a new endpoint added without a gate. The
        # dashboard hiding its button proves nothing - the API is the boundary.
        $ungated = foreach ($h in $script:handlers | Where-Object IsHttp) {
            $gatesItself = $h.Text -match 'Assert-VmfFacadeRole'
            # or it delegates to a FacadeCore function that gates
            $callsGated = $false
            foreach ($m in [regex]::Matches($h.Text, '\b(Invoke-VmfFacade\w+|Get-VmfFacade\w+)\b')) {
                $g = Script:CoreGate $m.Groups[1].Value
                if ($g) { $callsGated = $true; break }
            }
            if (-not $gatesItself -and -not $callsGated) { $h.Name }
        }
        $ungated -join ', ' | Should -BeNullOrEmpty `
            -Because 'an endpoint with no role check is reachable by anyone who can sign in'
    }

    It 'every endpoint reads the principal from the platform header, never from the body' {
        # A principal a caller can state is not a principal.
        $offenders = foreach ($h in $script:handlers | Where-Object IsHttp) {
            if ($h.Text -notmatch "ConvertFrom-VmfClientPrincipal -Header \`$Request\.Headers\['x-ms-client-principal'\]") { $h.Name }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty
    }

    It 'a MUTATING endpoint never accepts Vmf.Viewer' {
        # Escape #2: the gate present but wrong. Viewer is read-only, always.
        $offenders = foreach ($h in $script:handlers | Where-Object { $_.IsHttp -and ($_.Methods -contains 'post' -or $_.Methods -contains 'POST') }) {
            $gates = [regex]::Matches($h.Text, "Assert-VmfFacadeRole[^\r\n]*-AnyOf @\(([^)]*)\)")
            foreach ($g in $gates) {
                if ($g.Groups[1].Value -match 'Vmf\.Viewer') { "$($h.Name) lets a Viewer through" }
            }
            # and the same for whatever FacadeCore function it delegates to
            foreach ($m in [regex]::Matches($h.Text, '\b(Invoke-VmfFacade\w+)\b')) {
                $cg = Script:CoreGate $m.Groups[1].Value
                if ($cg -and $cg -match 'Vmf\.Viewer') { "$($h.Name) -> $($m.Groups[1].Value) lets a Viewer through" }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty
    }

    It 'every mutating FacadeCore function asserts a role itself' {
        # These are callable from more than one handler and from the timer, so
        # the gate belongs with the ACTION, not only with one of its callers.
        $mutators = @([regex]::Matches($script:core, '(?m)^function (Invoke-VmfFacade\w+)') |
            ForEach-Object { $_.Groups[1].Value }) |
            # ODCR-STATUS-1: the five-minute pass is the only caller of the read of
            # a capacity reservation stuck at RESERVING. It starts nothing, reads
            # Azure as the service, and writes only what Azure answered onto the
            # quota record, version-checked (OdcrStatus.Tests.ps1).
            Where-Object { $_ -ne 'Invoke-VmfFacadeReadReservingClaims' } |
            # Timer-driven functions have no caller to assert: the schedule release
            # and RESUME-1's stalled-wave resume both build an Operator principal and
            # hand it to StartEngine, which asserts it. Named here, not waved through.
            # PLANRUN-1's plan continuation is the third: the timer calls it, and it
            # hands StartEngine an Operator principal naming the approver.
            # RESTORE-END-JOB-1's restore resume is the fourth: the timer calls
            # it, and it hands StartEngine an Operator principal, as the wave
            # resume does (RestoreEndJob.Tests.ps1 runs it through StartEngine).
            # STALE-WAVE-HOLD-1's ended-hold removal is the fifth: the timer is
            # its only caller, it starts nothing, and it removes only the
            # expired hold of a stopped wave worker on a machine whose move
            # ended (StaleWaveHold.Tests.ps1).
            # SCAN-FAIL-SHOWN-1's scan end is the sixth: the timer is its only
            # caller, it starts nothing, and it writes only the engine:assess
            # fail line of a scan whose execution Azure lists as ended with no
            # answer (ScanFailShown.Tests.ps1).
            Where-Object { $_ -notin @('Invoke-VmfFacadeReleaseDueSchedules', 'Invoke-VmfFacadeResumeStalledWaves', 'Invoke-VmfFacadeContinuePlan', 'Invoke-VmfFacadeResumeStalledPutBacks', 'Invoke-VmfFacadeResumeStalledVolumeChecks', 'Invoke-VmfFacadeRemoveEndedWaveHolds', 'Invoke-VmfFacadeEndSilentScan') }
        @($mutators).Count | Should -BeGreaterThan 8
        $ungated = foreach ($fn in $mutators) { if (-not (Script:CoreGate $fn)) { $fn } }
        $ungated -join ', ' | Should -BeNullOrEmpty
    }

    It 'and every role named in a gate is a role that actually exists' {
        # A gate naming a role nobody can hold refuses everyone; a gate naming a
        # typo'd role may refuse no one, depending on how it is written.
        $declared = @([regex]::Matches(
            (Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw),
            "value: '(Vmf\.\w+)'") | ForEach-Object { $_.Groups[1].Value })
        @($declared).Count | Should -Be 4
        $used = @([regex]::Matches(($script:core + ($script:handlers.Text -join "`n")), "'(Vmf\.\w+)'") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $strays = @($used | Where-Object { $_ -notin $declared })
        $strays -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'RBAC-TEST-1: the roles are for PEOPLE, and a daemon cannot hold one' {
    It 'every app role is assignable to Users only, never to Applications' {
        # Found while trying to drill the live gate with service principals:
        # the attempt FAILED, and the reason is a property worth keeping. An
        # app role with 'Application' in allowedMemberTypes can be held by any
        # daemon with a client secret - which for Vmf.Operator would mean a
        # background process able to stop and rebuild production machines with
        # no person anywhere in the loop.
        #
        # It also means the live half of RBAC-TEST-1 cannot be run with service
        # principals without WIDENING this, which would be trading a real
        # security property for test convenience. See
        # tests/lab/Invoke-RoleScopeDrill.ps1 for what it needs instead.
        $bicep = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        $decls = @([regex]::Matches($bicep, "allowedMemberTypes:\s*\[([^\]]*)\]"))
        @($decls).Count | Should -BeGreaterThan 0
        foreach ($d in $decls) {
            $d.Groups[1].Value | Should -Match "'User'"
            $d.Groups[1].Value | Should -Not -Match "'Application'" `
                -Because 'an app role a daemon can hold is a role with no person behind it'
        }
    }
}

Describe 'RBAC-TEST-1: the timer is not a way round the gate' {
    It 'the schedule runner is the ONE ungated core function, and it is not an endpoint' {
        # It has no $Principal because nobody calls it - the timer does. What
        # matters is that it cannot be reached over HTTP.
        $sched = $script:handlers | Where-Object { $_.Name -eq 'ScheduleRunner' }
        $sched | Should -Not -BeNullOrEmpty
        $sched.IsHttp | Should -BeFalse -Because 'a timer-triggered function must not also be an HTTP endpoint'
    }

    It 'it acts as an OPERATOR and says whose schedule it is running' {
        # A synthetic principal is fine as long as it is honest: the audit
        # record must name the person who scheduled it, not just "the timer".
        # Read per FUNCTION, not "the first match in the file": PLANRUN-1 added a
        # second timer path above the schedule release, and the first match
        # became that one.
        $principal = "Invoke-VmfFacadeStartEngine -Principal \(\[pscustomobject\]@\{ Identity = ([^;]*); Roles = @\(([^)]*)\) \}\)"
        $body = { param($fn) $s = $script:core.IndexOf("function $fn "); $script:core.Substring($s, $script:core.IndexOf("`nfunction ", $s + 10) - $s) }
        foreach ($case in @(@('Invoke-VmfFacadeReleaseDueSchedules', 'scheduledBy'), @('Invoke-VmfFacadeContinuePlan', '\$by'))) {
            $m = [regex]::Match((& $body $case[0]), $principal)
            $m.Success | Should -BeTrue -Because "$($case[0]) starts the engine"
            $m.Groups[1].Value | Should -Match $case[1] -Because "$($case[0]): the audit trail must name a person"
            $m.Groups[2].Value | Should -Match "Vmf\.Operator"
            $m.Groups[2].Value | Should -Not -Match 'Vmf\.Admin' -Because 'the timer needs no more than it uses'
        }
        # And the person the plan continuation names is the one who APPROVED
        # the wave it starts - WAVE-APPROVE-1: the wave's own approval, which
        # may be a later one by another approver; the sign-off's approver when
        # the wave has none. (PlanRun.Tests.ps1 runs it with two approvers.)
        # The CODE of the function (Get-VmfCodeOnly), so a comment that still
        # quotes the rule cannot pass for it (COMMENT-TRAP-1).
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $continue = [regex]::Match($code, '(?ms)^function Invoke-VmfFacadeContinuePlan \{.*?^\}').Value
        $continue | Should -Not -BeNullOrEmpty
        $continue | Should -Match '\$by = if \(\$waveApproval -and \$waveApproval\.approvedBy -and \[string\]\$waveApproval\.approvedBy\.identity\) \{ \[string\]\$waveApproval\.approvedBy\.identity \}'
        $continue | Should -Match 'elseif \(\$signed -and \$signed\.approvedBy\) \{ \[string\]\$signed\.approvedBy\.identity \}'
    }
}
