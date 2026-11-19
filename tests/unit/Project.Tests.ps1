#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PROJECT-1 - the container the assessment/migration split implied.
#
# The 'new migration' button raised a question: with assessment and migration
# split, the larger thing that holds an assessment and its migrations is a
# 'project'.
#
# Before this, an assessment and the migrations planned from it were one piece
# of work with nothing saying so except `fromAssessment` pointing backwards.
# There was no name for the engagement and nowhere to see "this estate, assessed
# three times over two months, with two migrations run from it".
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'project.schema.json'

    function Global:NewStore {
        $s = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-proj-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $s -Force | Out-Null
        $s
    }
    function Global:MakeProject {
        param($Store, $Id = 'contoso-exit', $Name = 'Contoso datacentre exit', $Scope, $Note)
        $a = @{ StorePath = $Store; ProjectId = $Id; Name = $Name
                OnBehalfOf = @{ Identity = 'sam@example.com'; TenantId = 't1' } }
        if ($Scope) { $a.Scope = $Scope }
        if ($Note)  { $a.Note = $Note }
        New-VmfProject @a -Confirm:$false
    }
}
AfterAll { Remove-Item 'function:\NewStore', 'function:\MakeProject' -ErrorAction SilentlyContinue }

Describe 'PROJECT-1: a project is a named container' {
    AfterEach { if ($script:s -and (Test-Path $script:s)) { Remove-Item $script:s -Recurse -Force } }

    It 'writes a document that conforms to its contract' {
        $script:s = NewStore
        $r = MakeProject $script:s -Scope @{ Subscriptions = @('sub-1'); ResourceGroups = @('rg-app') } -Note 'the lease ends in March'
        $doc = Get-Content (Join-Path $r.ProjectPath 'project.json') -Raw
        { Test-Json -Json $doc -SchemaFile $script:schemaFile -ErrorAction Stop } | Should -Not -Throw
    }

    It 'records who created it from their sign-in, never a typed parameter' {
        $script:s = NewStore
        (MakeProject $script:s).CreatedBy | Should -Be 'sam@example.com'
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfProject.ps1') -Raw
        $src | Should -Not -Match '\[Parameter\(\)\]\[string\]\$CreatedBy'
    }

    It 'refuses to recreate one that exists, rather than overwriting it' {
        # Overwriting would rename somebody's engagement and rewrite who created
        # it, while its runs carried on underneath.
        $script:s = NewStore
        MakeProject $script:s | Out-Null
        { MakeProject $script:s -Name 'Something else' } | Should -Throw '*already exists*'
    }

    It 'insists the id is a path segment, not a title' {
        $script:s = NewStore
        foreach ($bad in 'Contoso Exit', 'contoso_exit', 'UPPER', 'a', '-leading') {
            { MakeProject $script:s -Id $bad } | Should -Throw
        }
    }

    It 'stores the name ONCE - members carry only the id' {
        # A name copied onto every member is a name that can disagree with itself.
        $manifest = Get-Content (Join-Path $script:repoRoot 'schemas' 'run-manifest.schema.json') -Raw | ConvertFrom-Json
        $manifest.properties.PSObject.Properties.Name | Should -Contain 'project'
        $manifest.properties.PSObject.Properties.Name | Should -Not -Contain 'projectName'
    }
}

Describe 'PROJECT-1: listing is derived from the store' {
    AfterEach { if ($script:s -and (Test-Path $script:s)) { Remove-Item $script:s -Recurse -Force } }

    It 'finds the projects that are actually there' {
        # Not from an index. An index of projects is a second source of truth
        # that can disagree with the projects - a shape this codebase has paid
        # for twice already.
        $script:s = NewStore
        MakeProject $script:s -Id 'one' -Name 'First'  | Out-Null
        MakeProject $script:s -Id 'two' -Name 'Second' | Out-Null
        $found = @(Get-VmfProject -StorePath $script:s)
        @($found).Count | Should -Be 2
        ($found.ProjectId | Sort-Object) -join ',' | Should -Be 'one,two'
    }

    It 'ignores a prefix that is not a project' {
        # A loose run sitting beside the projects is not one, and must not be
        # listed as one.
        $script:s = NewStore
        MakeProject $script:s -Id 'real' -Name 'Real' | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:s 'just-a-run') -Force | Out-Null
        '{}' | Set-Content (Join-Path $script:s 'just-a-run' 'run.json')
        @(Get-VmfProject -StorePath $script:s).ProjectId | Should -Be 'real'
    }

    It 'returns nothing for an id that does not exist, rather than throwing' {
        $script:s = NewStore
        @(Get-VmfProject -StorePath $script:s -ProjectId 'nope').Count | Should -Be 0
    }
}

Describe 'PROJECT-1: runs know which project they are in' {
    AfterEach { if ($script:s -and (Test-Path $script:s)) { Remove-Item $script:s -Recurse -Force } }

    It 'a run created inside a project records it' {
        $script:s = NewStore
        MakeProject $script:s | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:s } {
            $rp = Join-Path $s 'contoso-exit' | Join-Path -ChildPath 'august'
            Initialize-VmfRun -RunPath $rp -RunId 'august' -Kind 'assessment' `
                -Project (Resolve-VmfRunProject -RunPath $rp) | Out-Null
            (Read-VmfStoreJson -RunPath $rp -RelPath 'run.json' -Depth 6).project | Should -Be 'contoso-exit'
        }
    }

    It 'a run created OUTSIDE one records null, not a guess' {
        $script:s = NewStore
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:s } {
            $rp = Join-Path $s 'loose'
            Initialize-VmfRun -RunPath $rp -RunId 'loose' -Kind 'assessment' `
                -Project (Resolve-VmfRunProject -RunPath $rp) | Out-Null
            (Read-VmfStoreJson -RunPath $rp -RelPath 'run.json' -Depth 6).project | Should -BeNullOrEmpty
        }
    }

    It 'the project is DERIVED from the path, never taken as a second parameter' {
        # Asking the caller to state it as well as create the run there invites
        # the two to disagree, and the disagreement would be silent.
        $assess = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1') -Raw
        $assess | Should -Match 'Resolve-VmfRunProject -RunPath \$OutPath'
        $assess | Should -Not -Match '\[Parameter\(\)\]\[string\]\$Project'
    }

    It 'and resolving it never fails the run it is describing' {
        # Belonging to a project is metadata. A store that cannot answer must
        # not take the assessment down with it.
        InModuleScope VmMigrationFactory {
            { Resolve-VmfRunProject -RunPath 'X:\no\such\place' } | Should -Not -Throw
            Resolve-VmfRunProject -RunPath 'X:\no\such\place' | Should -BeNullOrEmpty
        }
    }
}

Describe 'PROJECT-1: reachable from the app (hard rule 10)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $script:psd  = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Raw
        $script:page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'projects.html'))
    }

    It 'creating a project has a facade endpoint, gated at Operator' {
        # Naming a piece of work is the FIRST thing an operator does, so sending
        # them to PowerShell for it would be the worst possible place to break
        # the rule that every operator action is reachable from the app.
        $script:core | Should -Match 'function Invoke-VmfFacadeCreateProject'
        $fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeCreateProject \{(.*?)^\}').Groups[1].Value
        $fn | Should -Match "Assert-VmfFacadeRole -Principal \`$Principal -AnyOf @\('Vmf\.Operator'"
        $fn | Should -Not -Match 'Vmf\.Viewer'
    }

    It 'listing them is open to anyone who can see the app' {
        # Viewers already list runs; hiding the grouping would make the runs
        # list less legible without protecting anything.
        $fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeListProjects \{(.*?)^\}').Groups[1].Value
        $fn | Should -Match 'Vmf\.Viewer'
    }

    It 'both are EXPORTED - an endpoint can only call what the manifest exports' {
        $script:psd | Should -Match "'Invoke-VmfFacadeCreateProject'"
        $script:psd | Should -Match "'Invoke-VmfFacadeListProjects'"
    }

    It 'and the page creates one without leaving for PowerShell' {
        $script:page | Should -Match "api\('POST', 'projects'"
        $script:page | Should -Match 'projectId'
    }

    It 'the page shows runs that are NOT in a project rather than hiding them' {
        # Pretending they are not there is how somebody concludes their
        # migration has vanished.
        $script:page | Should -Match 'UX\.loose'
        $script:page | Should -Match 'nextLoose'
    }

    It 'and the page leads INTO the project, carrying it' {
        # A container you can make and then cannot put anything in is ornamental.
        # PAGE-SCALE-PROJECTS-1: New assessment is a row action of the shared
        # list, and help.js writes the address (listHref: ?project=).
        $script:page | Should -Match "dest: \{ page: 'wizard', project: id \}"
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match "case 'wizard': return l\.run \? runLink\('wizard\.html', l\.run\) : 'wizard\.html' \+ q;"
        $help | Should -Match '\?project=\$\{encodeURIComponent\(l\.project\)\}'
    }

    It 'the wizard reads the project from the address and prefixes its reads' {
        # A prefix applied to some reads and not others is a page that
        # half-loads: the manifest found, the assessment missing.
        $wiz = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $wiz | Should -Match "get\('project'\)"
        $wiz | Should -Match 'function runPrefix\(\)' -Because 'RUNID-2 made it a function so the harness can run it'
        # Nothing may still read the bare runId prefix.
        $wiz | Should -Not -Match 'blobJson\(`\$\{runId\}/'
        $wiz | Should -Not -Match 'blobList\(`\$\{runId\}/'
    }

    It 'and counts members from the store rather than a tally on the project' {
        # RETAIN-KIND-1: through the one rule for what a run is.
        $script:page | Should -Match "VmfHelp\.runKind\(m\) === 'assessment'"
        $script:page | Should -Not -Match 'assessmentCount'
    }
}

Describe 'PROJECT-1: a run can actually be created INSIDE a project from the app' {
    # FOUND BY TRYING IT, 2026-09-01. The store, the cmdlets and the page all
    # worked, and a project was still a container nothing could go into: the
    # facade route is `runs/{runId}/engine/{operation}` and a project-scoped id
    # needs a SLASH. Encoded (%2F) IIS rejects outright; raw, it does not match
    # the route. Both are a bare 404 that explains nothing. Measured against the
    # live facade before this was fixed.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:core  = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $script:entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $script:start = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1') -Raw
    }

    It 'the project travels in the BODY, not the route' {
        $script:start | Should -Match '\$body\.project'
        $fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeStartEngine \{(.*?)^\}').Groups[1].Value
        $fn | Should -Match '\[string\]\$Project'
        $fn | Should -Match "name = 'VMF_PROJECT'"
    }

    It 'and is validated case-sensitively before it becomes a path segment' {
        $fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeStartEngine \{(.*?)^\}').Groups[1].Value
        $fn | Should -Match '\$Project -cnotmatch'
    }

    It 'the engine puts the run inside the project' {
        $script:entry | Should -Match 'VMF_PROJECT'
        $script:entry | Should -Match '\$runPrefix'
    }

    It 'and puts the MIGRATION it plans beside the assessment, in the same project' {
        # A migration planned into the container root while its assessment sits
        # inside a project would separate the two things the project exists to
        # keep together.
        $script:entry | Should -Match '\$migrationPrefix'
        $script:entry | Should -Match '\$migrationPath = "azblob://\$\(\$env:VMF_STORE_ACCOUNT\)/\$\(\$env:VMF_STORE_CONTAINER\)/\$migrationPrefix"'
    }

    It 'a run with NO project still lands where it always did' {
        # Every existing run, and anyone not using projects, must be unaffected.
        $script:entry | Should -Match 'if \(\$env:VMF_PROJECT\) \{ "\$\(\$env:VMF_PROJECT\)/\$\(\$env:VMF_RUN_ID\)" \} else \{ \$env:VMF_RUN_ID \}'
    }
}

Describe 'ASSESS-PAGE-1 + PROJECT-1: the app-started assessment was born mislabelled' {
    # FOUND LIVE, 2026-09-01, by starting an assessment through the real app
    # path and looking at what landed. This is the operator-visible half of
    # "no assessments show in the portal".
    #
    # Initialize-VmfRun writes the manifest ONLY IF ABSENT - first writer wins.
    # The facade's audit write runs BEFORE the engine, so it decided the
    # manifest for every run started from the app, using the DEFAULT kind:
    # 'migration'. Every assessment launched from the wizard was therefore
    # labelled a migration and listed on the wrong page. The unit suite could
    # not see it: it tests the engine's write, which never got the chance.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $script:fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeStartEngine \{(.*?)^\}').Groups[1].Value
    }

    It 'the audit write states the kind rather than taking the default' {
        $script:fn | Should -Not -BeNullOrEmpty
        $script:fn | Should -Match '\$auditKind'
        $script:fn | Should -Match 'Initialize-VmfRun -RunPath \$rp -RunId \$rid -Kind \$kind'
    }

    It "and 'assess' produces an ASSESSMENT, not a migration" {
        # REVIEW-1: 'advise' joined - its run id names an assessment too.
        $script:fn | Should -Match "if \(\`$Operation -in @\('assess', 'plan', 'advise'\)\) \{ 'assessment' \}"
    }

    It 'plan counts as an assessment too - its run id names the assessment' {
        # VMF_RUN_ID names the ASSESSMENT for plan; the migration gets its own
        # id (VMF_MIGRATION_ID). Auditing plan as a migration would relabel the
        # assessment it is planning from.
        $entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $entry | Should -Match 'VMF_RUN_ID names the assessment'
        $script:fn | Should -Match "'assess', 'plan'"
    }

    It 'and the audit lands INSIDE the project, not beside it' {
        # Auditing to the container root while the engine works inside the
        # project left a phantom empty run in the operator's list for every
        # scan. Seen in the store before this was fixed.
        $script:fn | Should -Match '\$storeRunId = if \(\$Project\) \{ "\$Project/\$RunId" \}'
        $script:fn | Should -Match 'Get-VmfFacadeStorePath -RunId \$storeRunId'
    }
}

Describe 'PROJECT-1: one front door, and it asks which piece of work' {
    # The top bar still had a big blue 'assess an estate' button, and it was
    # not clear what the entry point was: must a customer create a project
    # first, or does starting an assessment create one?
    #
    # THREE of the four doors into the wizard skipped projects entirely, so
    # the obvious blue button produced work belonging to nothing.
    # The rule now: always ask, in the wizard.
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:wiz = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')) }

    It 'the assess journey asks for the piece of work FIRST' {
        $script:wiz | Should -Match "stepsAssess: \['Which work'"
        $script:wiz | Should -Match 'function renderProjectPick'
        $script:wiz | Should -Match 'if \(step === STEP\.assess\.project\)\s+return void renderProjectPick'
    }

    It 'and will not move on without one' {
        # The whole point of the ruling: no silent path past the question.
        $script:wiz | Should -Match 'if \(!projectId && !runId\) return STEP\.assess\.project;'
    }

    It 'a project is never auto-created - a person names it' {
        # A generated name destroys the one thing a project is for. The step
        # offers a name field and creates through the same endpoint the page
        # uses; nothing invents one.
        $script:wiz | Should -Match "api\('POST', 'projects'"
        $script:wiz | Should -Not -Match 'autoCreateProject|generateProjectId'
    }

    It 'an EXISTING run without a project is opened as it is, not held hostage' {
        # A run outside a project (the command line can make one) must keep working. The guard is
        # `!projectId && !runId` - a run id present means carry on.
        $script:wiz | Should -Match '!projectId && !runId'
    }

    It 'and the four assess steps renumbered together' {
        # A step inserted at the front with the transitions left behind is a
        # wizard that jumps backwards. All three assess transitions moved.
        # WIZARD-BACK-TARGETS-1: the scan step waits (waitOn); a button's step is chosen (goStep).
        $script:wiz | Should -Match 'waitOn\(STEP\.assess\.findings\); render\(\); startPolling\(\);'
        $script:wiz | Should -Match "goStep\(STEP\.assess\.review\);"
    }
}
