#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ASSESS-PAGE-1 - review and approval as the gate.
#
# As in Azure Migrate, an assessment (a report) is required before any
# migration: only after the report is reviewed, approved and validated does a
# run start.
#
# So this is a gate, not a formality: New-VmfPlan refuses an assessment nobody
# has read. Enforced in the ENGINE rather than the wizard, because a wizard-only
# gate is bypassed by the API path - which is how the app actually runs.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'assessment-approval.schema.json'

    function Global:NewAssessment {
        param([int]$Blocked = 0, [switch]$NoScan)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-app-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp } {
            Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
        }
        if (-not $NoScan) {
            # Blocked machines only. A machine the planner would try to PLACE needs
            # the full assessment shape, and these tests are about the gate and the
            # approval record rather than about planning.
            $vms = @(1..$Blocked | Where-Object { $Blocked -gt 0 } | ForEach-Object {
                @{ vmId = "/vm/bad$_"; name = "bad$_"; classification = 'Blocked'; blockers = @('gen1-requires-redeploy') } })
            @{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-08-31T00:00:00Z'
               scope = @{ subscriptions = @() }; summary = @{}; vms = @($vms) } |
                ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'assessment.json')
        }
        $rp
    }
    function Global:Approve {
        param($Path, $Note = 'reviewed with the owners')
        InModuleScope VmMigrationFactory -Parameters @{ p = $Path; n = $Note } {
            Approve-VmfAssessment -RunPath $p -Note $n -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' }
        }
    }
}
AfterAll { Remove-Item 'function:\NewAssessment', 'function:\Approve' -ErrorAction SilentlyContinue }

Describe 'ASSESS-PAGE-1: the gate' {
    AfterEach { if ($script:a -and (Test-Path $script:a)) { Remove-Item $script:a -Recurse -Force } }

    It 'planning refuses an assessment nobody has reviewed' {
        $script:a = NewAssessment
        $m = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-gm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            { New-VmfPlan -AssessmentPath (Join-Path $script:a 'assessment.json') -OutPath $m } |
                Should -Throw '*has not been reviewed*'
            Test-Path $m | Should -BeFalse -Because 'nothing should be created for a plan that was refused'
        }
        finally { if (Test-Path $m) { Remove-Item $m -Recurse -Force } }
    }

    It 'and allows it once somebody has' {
        $script:a = NewAssessment
        Approve $script:a | Out-Null
        $m = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-gm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            { New-VmfPlan -AssessmentPath (Join-Path $script:a 'assessment.json') -OutPath $m } | Should -Not -Throw
        }
        finally { if (Test-Path $m) { Remove-Item $m -Recurse -Force } }
    }

    It 'the gate is in the ENGINE, not only the wizard' {
        # A wizard-only gate is bypassed by the API path, and the API path is
        # how the hosted engine actually runs.
        $plan = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1') -Raw
        $plan | Should -Match "RelPath 'approval\.json'"
        $plan | Should -Match 'has not been reviewed'
    }
}

Describe 'ASSESS-PAGE-1: what an approval records' {
    AfterEach { if ($script:a -and (Test-Path $script:a)) { Remove-Item $script:a -Recurse -Force } }

    It 'conforms to its contract' {
        $script:a = NewAssessment
        Approve $script:a | Out-Null
        $doc = Get-Content (Join-Path $script:a 'approval.json') -Raw
        { Test-Json -Json $doc -SchemaFile $script:schemaFile -ErrorAction Stop } | Should -Not -Throw
    }

    It 'names the person from their sign-in, never from a parameter somebody typed' {
        # An approval somebody can put a name into is not an approval. The
        # facade passes the VALIDATED principal; there is no other way in.
        $script:a = NewAssessment
        $r = Approve $script:a
        $r.ApprovedBy | Should -Be 'sam@example.com'
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Approve-VmfAssessment.ps1') -Raw
        $src | Should -Not -Match '\[Parameter\(\)\]\[string\]\$ApprovedBy'
    }

    It 'binds the decision to the exact assessment that was read' {
        # Evidence rather than change detection - an assessment cannot be
        # overwritten - so this is what proves WHICH findings were signed off.
        $script:a = NewAssessment
        $r = Approve $script:a
        $text = Get-Content (Join-Path $script:a 'assessment.json') -Raw
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $expected = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) |
                ForEach-Object { $_.ToString('x2') }) -join ''
        }
        finally { $sha.Dispose() }
        $r.AssessmentHash | Should -Be $expected
    }

    It 'records how many machines could NOT migrate when it was approved' {
        # Approving with blocked machines is a legitimate decision - move the
        # eighty that can - but the record should say it was known.
        $script:a = NewAssessment -Blocked 3
        (Approve $script:a).Blocked | Should -Be 3
    }

    It 'accepts an approval with no note - the record still says who and when' {
        # It used to demand a sentence. That only produced "ok" and "approved",
        # and it blocked the wizard's review step, where the person has just
        # read the findings on screen and pressing the button IS the decision.
        # What makes the record trustworthy is the identity, the timestamp and
        # the hash of what was approved - none of which come from prose.
        $script:a = NewAssessment
        $r = Approve $script:a -Note ''
        $r.Note | Should -Be ''
        $r.ApprovedBy | Should -Be 'sam@example.com'
        $r.AssessmentHash | Should -Not -BeNullOrEmpty -Because 'the record must still pin WHAT was approved'

        # And the record ON DISK - the thing the gate and the audit read - is
        # complete without a note.
        $doc = Get-Content (Join-Path $script:a 'approval.json') -Raw | ConvertFrom-Json
        $doc.approvedBy.identity | Should -Be 'sam@example.com'
        $doc.approvedUtc | Should -Not -BeNullOrEmpty
        $doc.assessmentHash | Should -Be $r.AssessmentHash
    }

    It 'refuses an assessment that has not finished scanning' {
        # There is nothing to review yet, and approving one would let a
        # migration be planned from an assessment with no findings at all.
        $script:a = NewAssessment -NoScan
        { Approve $script:a } | Should -Throw '*has not finished scanning*'
    }

    It 'refuses a MIGRATION - those are approved per wave' {
        $m = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-am-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ p = $m } {
                Initialize-VmfRun -RunPath $p -RunId 'mig' -Kind 'migration' | Out-Null
            }
            { Approve $m } | Should -Throw '*is a migration, not an assessment*'
        }
        finally { if (Test-Path $m) { Remove-Item $m -Recurse -Force } }
    }
}

Describe 'ASSESS-PAGE-1: reachable from the app (hard rule 10)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        # COMMENT-TRAP-1: this function now EXPLAINS in prose why Vmf.Operator
        # is absent, so a whole-file match for 'Vmf.Operator' finds the
        # explanation and the test passes for the wrong reason. Strip comments.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $script:page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'assessments.html'))
    }

    It 'has a facade endpoint, gated on the same role as wave approval' {
        $script:core | Should -Match 'function Invoke-VmfFacadeApproveAssessment'
        $fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeApproveAssessment \{(.*?)^\}').Groups[1].Value
        $fn | Should -Match "Assert-VmfFacadeRole -Principal \`$Principal -AnyOf @\('Vmf\.Approver'"
        $fn | Should -Not -Match 'Vmf\.Viewer'
    }

    # SEC-F3. The assertion above passed for a year while the gate ALSO admitted
    # Vmf.Operator: it only checks that the list STARTS with Vmf.Approver, so
    # anything after that was invisible to it. This checks the whole list, as a
    # SET, against wave approval's - which is what "the same role as wave
    # approval" has always claimed.
    It 'admits exactly the roles wave approval admits, and no others' {
        $code = Get-VmfCodeOnly -Text $script:core -Language powershell
        $assessFn = [regex]::Match($code, '(?ms)^function Invoke-VmfFacadeApproveAssessment \{(.*?)^\}').Groups[1].Value
        $waveFn = [regex]::Match($code, '(?ms)^function Invoke-VmfFacadeApprove \{(.*?)^\}').Groups[1].Value
        $rolesOf = {
            param($text)
            $m = [regex]::Match($text, "Assert-VmfFacadeRole[^\r\n]*-AnyOf @\(([^)]*)\)")
            $m.Success | Should -BeTrue
            @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") }) | Sort-Object
        }
        $assessRoles = & $rolesOf $assessFn
        $waveRoles = & $rolesOf $waveFn
        ($assessRoles -join ',') | Should -Be ($waveRoles -join ',')
        $assessRoles | Should -Not -Contain 'Vmf.Operator' -Because 'an operator who records the review then plans from it is not a separation of duties'
        $assessRoles | Should -Contain 'Vmf.Approver'
    }

    It 'approves on behalf of the SIGNED-IN person, not the service' {
        # The facade runs as a managed identity. Stamping that on an approval
        # would be a lie about who decided.
        $fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeApproveAssessment \{(.*?)^\}').Groups[1].Value
        $fn | Should -Match 'OnBehalfOf'
        $fn | Should -Match 'Principal\.Identity'
    }

    It 'and the page offers it where the report is read' {
        # The decision belongs next to the thing being decided about.
        $script:page | Should -Match 'data-approve'
        $script:page | Should -Match 'assessments/\$\{VmfHelp\.VmfRun\.routeSegment\(id\)\}/approve'
        # PROJECT-1: an id is `project/run` inside a project, and a slash does
        # not survive the route, so the project goes in the body. RUNID-2: this
        # page split the id by hand and was the only one that did - the rule
        # lives in help.js now, so the assertion follows it there.
        $script:page | Should -Match 'VmfHelp\.VmfRun\.withProject\('
        $script:page | Should -Match 'notReviewedWhy'
    }
}
