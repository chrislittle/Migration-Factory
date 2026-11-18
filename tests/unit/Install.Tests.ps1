#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-1: `azd up` installs the product. The three decisions (2026-09-05:
# B, B, A) and the four pieces behind the one command.
#
# The azd project, the main template, the hooks and the guide are held to
# the decisions here; the install itself is proven by running it on a fresh
# resource group, which is the guide's own test.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:azure = Get-Content (Join-Path $script:repoRoot 'azure.yaml') -Raw
    $script:main = Get-Content (Join-Path $script:repoRoot 'infra' 'main.bicep') -Raw
    $script:mainParams = Get-Content (Join-Path $script:repoRoot 'infra' 'main.parameters.json') -Raw | ConvertFrom-Json
    $script:platform = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
    $script:pre = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw
    $script:post = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1') -Raw
    $script:down = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1') -Raw
    # TEARDOWN-1: the removal is TWO hooks now. predown reports; postdown
    # removes the registrations, after the platform is actually gone.
    $script:postdown = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1') -Raw
    $script:ready = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'Test-VmfReadiness.ps1') -Raw
    $script:common = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1') -Raw
    $script:guide = Get-Content (Join-Path $script:repoRoot 'docs' 'install.md') -Raw
    $script:readme = Get-Content (Join-Path $script:repoRoot 'README.md') -Raw
}

Describe 'INSTALL-1: one command, azd up' {
    It 'the azd project names the main template and the three hooks' {
        $script:azure | Should -Match '(?m)^name: vm-migration-factory'
        $script:azure | Should -Match '(?m)^\s+provider: bicep'
        $script:azure | Should -Match '(?m)^\s+module: main'
        foreach ($h in 'preprovision', 'postprovision', 'predown') {
            $script:azure | Should -Match "(?m)^\s+${h}:\s*\n\s+shell: pwsh\s*\n\s+run: \./infra/hooks/${h}\.ps1"
        }
    }

    It 'decision 1 REVERSED: a resource group holds the platform, and no stack does' {
        # A deployment stack was chosen on 2026-09-05 and reversed on
        # 2026-09-11, after three teardown failures in two days - none of them
        # a fault of the Azure service. See NO-STACKS-1 and
        # docs/research/option-b-dropping-deployment-stacks.md.
        $script:azure | Should -Not -Match '(?m)^\s+deploymentStacks:'
        $script:azure | Should -Not -Match 'denyDelete'
        # AND THE FLAG, which is the half that is not in azure.yaml. The block
        # supplies a stack's options; this setting enables the code path, and
        # azd falls back to its own defaults when the block is absent. Leaving
        # this in would have meant stacks with settings nobody chose.
        #
        # CODE ONLY. preprovision still QUOTES that command, in the comment
        # explaining what it stopped doing and why - and that history is worth
        # keeping. This assertion matched the comment on its first run, which
        # is COMMENT-TRAP-1 catching a test written the day it was fixed.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $preCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')
        $preCode | Should -Not -Match 'azd config set alpha\.deployment\.stacks on'
        # and it does not turn it OFF either: the setting is machine-wide and
        # belongs to the person, not to this product.
        # A COMMAND, not the string. The hook PRINTS that line as advice, and
        # Get-VmfCodeOnly keeps string literals - correctly, because a printed
        # instruction is code. So this asks whether anything RUNS it.
        $preCode | Should -Not -Match '(?m)^\s*azd config set alpha\.deployment\.stacks' -Because 'the setting is machine-wide and belongs to the person'
        $script:pre | Should -Match 'Turn it off if nothing else needs it'
    }

    It 'decision 2, REVERSED by FIRSTRUN-1: the install may grant, and only when asked' {
        # On 2026-09-05 the engine's first scope became a separate step in the
        # app. On 2026-09-14 a real install showed what that costs: a bad
        # experience for a user who only wants to migrate a few machines in
        # one subscription. Every route to a working state
        # ran through a page needing DIRECTORY permissions that a person with
        # one subscription may not hold.
        #
        # What the decision protected is kept: the product still grants itself
        # nothing. A person answers a question, and the default answer is no.
        $script:pre | Should -Match "VMF_FIRST_SCOPE"
        # The default follows what the person can do (FIRSTRUN-1 again, after
        # the first draft: a new user cannot know what each answer implies).
        # What must hold in every case is that
        # the answer granting nothing exists and nothing is granted without an
        # answer.
        $script:pre | Should -Match 'Get-VmfInstallerRights -SubscriptionId'
        $script:pre | Should -Match "'no\|Nothing now"
        # The TEMPLATE still grants nothing over machines. The grant is a
        # deliberate step, made by the person, with their own rights - not a
        # role assignment buried in a deployment.
        $script:main | Should -Not -Match 'Microsoft\.Authorization/roleAssignments|roleAssignments:' -Because 'main.bicep composes; it grants nothing over machines'
        $script:pre | Should -Not -Match 'roleAssignments|role assignment create'
        # And the scope offered is the subscription being installed into.
        # Never wider, and never a list of everything the installer can see.
        $script:post | Should -Match '/subscriptions/\$subId'
        # The two custom roles are DEFINED by the install, at the subscription
        # and outside the stack - every install in a subscription shares them,
        # and a stack that adopted them would delete them on azd down (found
        # by the what-if against our own lab). Defining a role grants nothing.
        $script:main | Should -Not -Match "module roles 'roles\.bicep'"
        # ROLES-1 moved the deployment behind Set-VmfRoleScopes, which reads
        # what the roles already reach and passes the UNION - so running the
        # install again after somebody onboarded a management group does not
        # take that group away and break every grant made through it.
        $script:pre | Should -Match 'Resolve-VmfRoleScopes\.ps1'
        $script:pre | Should -Match 'Set-VmfRoleScopes -SubscriptionId'
        # And the switch that used to skip this step is gone. It existed for a
        # shape - roles living at a management group instead - that only made
        # sense while we believed a subscription role could never be granted
        # there. It can. Measured 2026-09-07.
        $script:pre | Should -Not -Match '(?m)^[^#
]*VMF_CREATE_ROLES'
        $script:mainParams.parameters.PSObject.Properties.Name | Should -Not -Contain 'createRoles'
        # The hook makes no role assignment ITSELF. It asks the script that has
        # done it since ONBOARD-1, so there is one implementation of a grant.
        $script:post | Should -Not -Match 'role assignment create'
        # It reads app role assignments to report whether you can sign in.
        # A READ, and this proves it is one: FIRSTRUN-1 needs the closing line
        # to be measured rather than claimed.
        foreach ($line in ($script:post -split "`n")) {
            if ($line -notmatch 'appRoleAssignments') { continue }
            $line | Should -Match '--method GET'
        }
        $script:post | Should -Match 'give the product permission to look at your machines'
        $script:post | Should -Match 'The install gave the product no reach over your machines\.'
    }

    It 'ROLES-UX-1: the roles step says what it does, and that it grants nobody anything' {
        # On 2026-09-10, during a real install, this line did not say what it
        # meant.
        #
        # It read: 'The assess and migrate roles at the subscription (outside
        # the stack; shared by every install here)'. A noun phrase with no verb,
        # so a reader cannot tell whether it CHECKS or CREATES; "the stack" is a
        # word the operator has not met at that point in the output; and "here"
        # could mean this machine or this subscription.
        # Assert on what the OPERATOR SEES, never on the file. The first version
        # of this test matched the raw source and failed on the code comment
        # that quotes the old wording - which proves the point: a source match
        # cannot tell a printed string from a comment about one.
        $visible = (@($script:pre -split "`n" | Where-Object { $_ -match '^\s*Write-(Step|Host)\b' })) -join "`n"
        $visible | Should -Not -BeNullOrEmpty -Because 'or this test is checking nothing'

        $visible | Should -Not -Match 'The assess and migrate roles at the subscription'
        $visible | Should -Not -Match 'shared by every install here'

        # It names the roles Azure will show, using Azure's own names.
        $visible | Should -Match 'VMF Assessment and VMF Migration'

        # And it says the thing that matters most, which the old text never did.
        $visible | Should -Match 'This step gives nobody access to your machines'

        # The reason they sit outside the deployment stack, in words rather than
        # jargon: a removal must not take another install's roles with it.
        $visible | Should -Match 'A removal of the product keeps them'

        # ROLES-UX-2, 2026-09-11, from the corrected line during an install:
        # the product uses no Azure built-in roles, only custom roles, and the
        # line did not say so clearly.
        #
        # It is a consent question rather than a wording one.
        # "The two Azure roles the product uses" reads as two roles Azure
        # already has. What the step does is CREATE two role definitions in the
        # customer's subscription, holding exactly the operations this product performs -
        # a materially different thing to agree to.
        $visible | Should -Match '(?i)custom roles'
        $visible | Should -Not -Match 'The two Azure roles the product uses'
        $visible | Should -Match '(?i)no built-in Azure role'
        # and it says what bounds them, because "custom" alone says nothing
        # about how wide they are.
        $visible | Should -Match '(?i)contains the operations the product performs'
    }

    It 'WARM-1: ONE hosting parameter covers both apps, default Free' {
        $script:main | Should -Match "@allowed\(\[ 'Free', 'Basic' \]\)\s*\n@description\('''[\s\S]*?'''\)\s*\nparam hostingPlan string = 'Free'"
        $script:platform | Should -Match "param hostingPlan string = 'Free'"
        $script:platform | Should -Match "var warm = hostingPlan == 'Basic'"
        $script:mainParams.parameters.hostingPlan.value | Should -Be '${VMF_HOSTING_PLAN=Free}'
        # The old name is gone from the templates entirely, so nothing can read
        # a value that no longer arrives.
        $script:main | Should -Not -Match 'facadePlan'
        $script:mainParams.parameters.PSObject.Properties.Name | Should -Not -Contain 'facadePlan'
    }

    It 'WARM-1: Basic puts BOTH apps on ONE plan, and Free leaves them apart' {
        # Two Basic plans would cost about $110 a month to deliver what one
        # delivers for $55: Azure bills the plan, not the apps on it.
        # The Basic-only name is written inline, in the one var that is empty
        # on a Free install.
        $script:platform | Should -Match "var sharedPlanName = warm \? 'vmf-plan-b1-\$\{baseSuffix\}' : ''"
        $script:platform | Should -Match "var dashboardPlanName = warm \? sharedPlanName :"
        $script:platform | Should -Match "var facadeHostingPlanName = warm \? sharedPlanName : facadePlanName"
        # And the facade's own plan is NOT built when it has nothing to host -
        # a second plan nobody sits on still bills.
        $script:platform | Should -Match "module facadeHostingPlan '[^']+' = if \(!warm\) \{"
        $script:platform | Should -Match "skuName: warm \? 'B1' : 'F1'"
    }

    It 'WARM-1: both apps are warm together, or neither is' {
        # Always On is the whole of what Basic buys here. A site left false
        # would sleep on a plan that was paid for to keep it awake.
        @([regex]::Matches($script:platform, 'alwaysOn: warm')).Count |
            Should -Be 2 -Because 'the dashboard and the facade each state it'
        $script:platform | Should -Not -Match 'alwaysOn: false'
    }

    It 'WARM-1: a Basic facade is still a differently named SITE, and the dashboard is not' {
        $script:platform | Should -Match "var facadeSiteName = warm \? 'vmf-facade-b1-\$\{baseSuffix\}' : facadeName" -Because 'Azure does not move a function app between plan kinds'
        $script:platform | Should -Match "var facadeName = 'vmf-facade-\$\{baseSuffix\}'" -Because 'the Free name is unchanged, so the lab does not move'
        $script:platform | Should -Match "output facadeName string = facadeSiteName" -Because 'the hooks publish to whichever site the choice made'
        # The dashboard site name does NOT branch: both its plans are ordinary
        # Windows plans, and Azure moves a web app between them.
        $script:platform | Should -Not -Match 'dashboardName = warm'
    }

    It 'the decision page is asked once, recorded, and never assumed: hosting plan' {
        # PIPELINE-LATER-1 removed the update model question
        # (2026-11-02): a person runs every update, so there is nothing to ask.
        # tests/unit/PipelineLater.Tests.ps1 holds that it stays gone.
        $script:pre | Should -Match "Read-VmfChoice -Name 'VMF_HOSTING_PLAN' -Default 'Free'"
        # WARM-1: an environment that answered the OLD question keeps its
        # answer rather than being asked again or silently downgraded.
        $script:pre | Should -Match "Get-AzdValue -Name 'VMF_FACADE_PLAN'"
        $script:pre | Should -Match "if \(\`$was -eq 'Basic'\) \{ 'Basic' \} else \{ 'Free' \}"
        # IDENTITY-4 removed a THIRD question - may the dashboard read sign-in
        # logs - with the control that used the answer. An install asks one
        # question fewer, and nobody decides about a permission nothing uses.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')) |
            Should -Not -Match 'VMF_SIGN_IN_ACTIVITY'
        $script:common | Should -Match 'if \(\$have\) \{ return \$have \}' -Because 'a recorded answer is never asked again'
        $script:common | Should -Match 'no console; the default is taken' -Because 'an install with no console must not hang on a prompt'
    }

    It 'the Entra registrations stay outside the stack and are named after the environment' {
        $script:pre | Should -Match "identity-deploy\.ps1'\) @identityArgs"
        $script:common | Should -Match '"vmf-api-\$envName"'
        $script:common | Should -Match '"vmf-dashboard-\$envName"'
        $script:pre | Should -Match "Set-AzdValue -Name 'VMF_API_APP_ID' -Value \`$apiAppId"
        $script:mainParams.parameters.apiAppId.value | Should -Be '${VMF_API_APP_ID}'
    }

    It 'an existing platform in the group is adopted, never duplicated (INSTALL-0 rules through the same helper)' {
        $script:pre | Should -Match 'Resolve-VmfSuffix -ResourceGroup \$rg'
        $script:pre | Should -Match 'Resolve-VmfEngineImage -ResourceGroup \$rg'
        $script:mainParams.parameters.baseSuffix.value | Should -Be '${VMF_BASE_SUFFIX=}'
        $script:mainParams.parameters.engineImage.value | Should -Be '${VMF_ENGINE_IMAGE=}'
        $script:main | Should -Match "engineImage: empty\(engineImage\) \? 'mcr\.microsoft\.com/k8se/quickstart-jobs:latest' : engineImage"
        $script:main | Should -Match 'baseSuffix: empty\(baseSuffix\) \? uniqueString\(rg\.id\) : baseSuffix'
    }

    It 'the code goes on after the stack: image built in the customer registry, job pinned by digest and recorded, facade and dashboard published, the facade proven' {
        $script:post | Should -Match 'az acr build -r \$acr -t "vmf-engine:\$tag" -f docker/Dockerfile \.'
        $script:post | Should -Match 'az containerapp job update -g \$rg -n \$job --image \$image'
        # INSTALL-THROTTLE-RETRY-1: the wait on OperationInProgress (and on a
        # throttle) is Invoke-VmfAzUpdateWhileBusy, whose default it is.
        $script:post | Should -Match "Invoke-VmfAzUpdateWhileBusy -Step `"point the engine job" -Because 'a concurrent operation on the job is transient, not a failure'
        (Get-Content (Join-Path $PSScriptRoot '..' '..' 'infra' 'Invoke-VmfAzStep.ps1') -Raw) | Should -Match "\[string\]\`$BusyPattern = 'OperationInProgress'"
        $script:post | Should -Match "Set-AzdValue -Name 'VMF_ENGINE_IMAGE' -Value \`$image" -Because 'the next azd up must adopt the digest, not reset the placeholder'
        $script:post | Should -Match 'Deploy-VmfFacade\.ps1'
        $script:post | Should -Match 'Deploy-VmfDashboard\.ps1'
        $script:post | Should -Match 'az functionapp function list -g \$rg -n \$facade'
        # GATE-1 is the install's own last act, never a script a person has to know about.
        $script:post | Should -Match "\`$adminRoleId = '6f1c3a10-0004-4b6e-9e6a-100000000004'"
        $script:post | Should -Match 'appRoleAssignedTo' -Because 'the gate closes only once the directory shows an administrator'
        $script:post | Should -Match 'appRoleAssignmentRequired'
        $script:post | Should -Match 'The sign-in rule is NOT set yet' -Because 'a directory that has not caught up is a warning, never a lock-out'
        $script:post | Should -Match 'Remove-Item \$stampPath' -Because 'only a build carries a stamp; the checkout reads +local again'
    }

    It 'piece 5: the readiness check says what it checked, what it could not, and refuses only on a definite blocker' {
        foreach ($p in 'Microsoft.App', 'Microsoft.Web', 'Microsoft.Storage', 'Microsoft.ContainerRegistry', 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.ManagedIdentity') {
            $script:ready | Should -Match ([regex]::Escape("'$p'"))
        }
        $script:ready | Should -Match 'workload-profile list-supported'
        $script:ready | Should -Match "ManagedEnvironmentCount"
        $script:ready | Should -Match "'StorageAccounts'"
        # READY-QUOTA-1. This used to assert the OPPOSITE: that plan quota
        # "surfaces only at deploy time". That was wrong (2026-09-10): App
        # Service plans do have a quota API, and the check used the wrong one.
        $script:ready | Should -Match 'providers/Microsoft\.Quota'
        # READINESS-FIX-WORDS-1: room per hosting plan answer, not per plan
        # (behaviour in ReadinessFixWords.Tests.ps1).
        $script:ready | Should -Match "Free = @\('F1', 'Y1'\); Basic = @\('B1'\)"
        $script:ready | Should -Match 'Get-VmfHostingPlanRoom -Plans \$plans'
        $script:ready | Should -Not -Match 'plan quota only at deploy time'
        $script:pre | Should -Match "Where-Object \{ \`$_\.Result -eq 'blocker' \}"
        $script:pre | Should -Match 'VMF_SKIP_READINESS'
    }

    It 'the plan quota read joins the limit to the usage, per plan type' {
        # BEHAVIOURAL. The quota takes TWO reads - /quotas for the limit,
        # /usages for what is used - and joining them is the only real logic in
        # the check. A source match cannot tell a correct join from a wrong one.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot 'infra' 'hooks' 'Test-VmfReadiness.ps1'), [ref]$null, [ref]$null)
        $found = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WebPlanQuota'
        }, $true))
        $found.Count | Should -Be 1
        $run = {
            param($fnText)
            Set-StrictMode -Version Latest       # the hook sets it; child scopes inherit it
            $global:LASTEXITCODE = 0
            $SubscriptionId = 's'
            $Location = 'centralus'
            function az {
                if ((@($args) -join ' ') -match '/quotas\?') {
                    '{"value":[' +
                    '{"name":"Y1","properties":{"isQuotaApplicable":true,"limit":{"value":3}}},' +
                    '{"name":"B1","properties":{"isQuotaApplicable":true,"limit":{"value":31}}},' +
                    '{"name":"NoLimit","properties":{"isQuotaApplicable":true,"limit":{}}},' +
                    '{"name":"NotApplicable","properties":{"isQuotaApplicable":false,"limit":{"value":9}}}]}'
                }
                else {
                    '{"value":[{"name":"Y1","properties":{"usages":{"value":2}}},' +
                    '{"name":"Unheardof","properties":{"usages":{"value":7}}}]}'
                }
            }
            # INSTALL-THROTTLE-RETRY-2: the reads go through the step helper.
            . (Join-Path $PSScriptRoot '..' '..' 'infra' 'Invoke-VmfAzStep.ps1')
            . ([scriptblock]::Create($fnText))
            Get-WebPlanQuota
        }
        $plans = & $run "function Get-WebPlanQuota $($found[0].Body.Extent.Text)"

        $plans['Y1'].Limit | Should -Be 3
        $plans['Y1'].Used | Should -Be 2 -Because 'the usage read has to reach the right plan type'
        $plans['B1'].Limit | Should -Be 31
        $plans['B1'].Used | Should -Be 0 -Because 'no usage reported means none used, not unknown'
        $plans.ContainsKey('NoLimit') | Should -BeFalse -Because 'a plan type with no limit cannot be judged'
        $plans.ContainsKey('NotApplicable') | Should -BeFalse -Because 'Azure says the quota does not apply'
        $plans.ContainsKey('Unheardof') | Should -BeFalse -Because 'usage must never invent a plan type the limits did not report'
    }

    It 'QUOTA-REGION-1: a region that limits nothing is an EMPTY answer, never a missing one' {
        # MEASURED 2026-09-10 across every physical region. All of them report
        # one entry named '*', "Total Regional VMs", with isQuotaApplicable
        # FALSE. Some ALSO report 66 per-plan entries with it TRUE; the rest
        # report only the '*' - in those, Azure is saying App Service plans are
        # not limited by type there, and the portal greys out "Request
        # adjustment".
        #
        # Returning $null for that case made the check report "the quota API did
        # not answer" for a region where it answered perfectly clearly. $null
        # must mean ONLY that the read failed.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot 'infra' 'hooks' 'Test-VmfReadiness.ps1'), [ref]$null, [ref]$null)
        $found = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WebPlanQuota'
        }, $true))
        $found.Count | Should -Be 1
        $run = {
            param($fnText)
            Set-StrictMode -Version Latest
            $global:LASTEXITCODE = 0
            $SubscriptionId = 's'
            $Location = 'swedencentral'
            function az {
                # Exactly what Sweden Central returns, for both reads.
                '{"value":[{"name":"*","properties":{"isQuotaApplicable":false,"limit":{"value":30}}}]}'
            }
            # INSTALL-THROTTLE-RETRY-2: the reads go through the step helper.
            . (Join-Path $PSScriptRoot '..' '..' 'infra' 'Invoke-VmfAzStep.ps1')
            . ([scriptblock]::Create($fnText))
            Get-WebPlanQuota
        }
        $plans = & $run "function Get-WebPlanQuota $($found[0].Body.Extent.Text)"

        # NOT `Should -Not -BeNullOrEmpty`: Pester counts an empty hashtable as
        # empty, which is exactly the distinction under test. Compare to $null.
        ($null -eq $plans) | Should -BeFalse -Because 'an empty hashtable is a real answer; $null means the read failed'
        $plans.GetType().Name | Should -Be 'Hashtable'
        $plans.Count | Should -Be 0
        $plans.ContainsKey('*') | Should -BeFalse -Because 'Total Regional VMs is informational, not a plan type'

        # And the caller must tell the two apart.
        $script:ready | Should -Match 'if \(\$null -eq \$plans\)' -Because 'only a failed READ is unknown'
        $script:ready | Should -Match 'elseif \(\$plans\.Count -eq 0\)'
        $script:ready | Should -Match '(?i)does not limit App Service plans by type'

        # QUOTA-ROUTE-1: where no plan type is shown there is NO SELF-SERVICE
        # PATH - the portal has nothing to request. Microsoft's guidance is to
        # deploy, read the error, and open a support ticket if one says quota is
        # needed. The operator cannot discover that from the portal, so the
        # check has to say it.
        $script:ready | Should -Match "(?i)Function or Web App \(Windows and Linux\)" -Because 'the support ticket needs the right quota type'
        # QUOTA-PREVIEW-1, 2026-10-26: Azure's term, never 'ask Azure'.
        $script:ready | Should -Match '(?i)open an Azure support request'
        $script:ready | Should -Not -Match '(?i)\bask Azure\b'

        # And a failed read must not sound like a fault. MEASURED: 13 of 63
        # physical regions answer nothing, mostly restricted-access and canary
        # regions where the STORAGE usage read fails too.
        $script:ready | Should -Match '(?i)which may not offer it'
    }

    It 'azd down says what the safety copies are and where to find them, and offers to remove the registrations' {
        # FIND-COPY-1: it used to REFUSE while copies were pending, with
        # VMF_ACCEPT_PENDING_COPIES to walk past the refusal. It tells and
        # continues now - the gate only fired on this one route, and the thing
        # that helps is a command that outlives the product.
        $script:down | Should -Match "\`$_\.name -eq 'vmf-safety-copy'"
        $script:down | Should -Match 'az resource list --tag vmfSafetyCopy=true -o table'
        $script:down | Should -Not -Match 'VMF_ACCEPT_PENDING_COPIES true'
        # PUBLISH-IN-1 took the run-store read out of this hook; nothing here
        # reaches the store's data plane any more.
        $script:down | Should -Not -Match 'retention-status\.json'
        $script:down | Should -Match 'copies taken without a lock are not counted here'
        # TEARDOWN-1: the registration question moved to postdown, which runs
        # only when the removal SUCCEEDED. Asking in predown meant the
        # registrations were deleted before anything else was even attempted.
        $script:down | Should -Not -Match 'VMF_REMOVE_REGISTRATIONS'
        $script:postdown | Should -Match "Read-VmfChoice -Name 'VMF_REMOVE_REGISTRATIONS'"
    }

    It 'the install chapter of the manual says the decision page, the two decisions made for the reader, the account changes and the way out; docs/install.md and the README point at it' {
        $m = Join-Path $script:repoRoot 'docs' 'manual' 'install'
        $choices = Get-Content (Join-Path $m 'choices.md') -Raw
        # WARM-1: the heading names BOTH apps now, because one answer covers
        # both. It used to name the service alone, which is what let the
        # dashboard sit on a plan nobody could choose.
        $choices | Should -Match '(?m)^## Choice 1: the hosting plan for the dashboard and the service'
        # THE COUNT IS CHECKED, not just the presence. A page that promises
        # three questions and then asks two is the kind of small lie that makes
        # a reader distrust the rest of it. IDENTITY-4 removed a third choice
        # with the feature that needed it; FIRSTRUN-1 added a different one;
        # PIPELINE-LATER-1 removed "who runs updates", which was Choice 1.
        $choices | Should -Match '(?m)^## Choice 2: what the product may do with your machines'
        $choices | Should -Match 'asks two questions once'
        $choices | Should -Not -Match '(?m)^## Choice 3'
        $choices | Should -Match 'One resource group holds the platform'
        $choices | Should -Match 'The product gets no permission you did not give it'
        $after = Get-Content (Join-Path $m 'after-install.md') -Raw
        $after | Should -Match '(?m)^## What the install did to your account'
        $after | Should -Match 'a person needs a role to sign in at all'
        $after | Should -Match '(?m)^## Step 2: give other people access'
        (Get-Content (Join-Path $m 'step-by-step.md') -Raw) | Should -Match '(?m)^> azd up$'
        $remove = Get-Content (Join-Path $m 'remove.md') -Raw
        $remove | Should -Match '(?m)^azd down$'
        $remove | Should -Match 'az resource list --tag vmfSafetyCopy=true -o table'
        $remove | Should -Not -Match 'VMF_ACCEPT_PENDING_COPIES'
        $script:guide | Should -Match 'manual/install/step-by-step\.md'
        $script:readme | Should -Match '\(docs/manual/README\.md\)'
    }

    It 'the manual says what the install gives the account and how it hands over admin consent, as the install does it' {
        # DEPLOYER-ROLES-WORDS-1. The install gives the user who runs it one
        # app role, Vmf.Admin (tools/Deploy-VmfFacade.ps1, ROLE-3), and ends
        # with an admin consent link, not a command (INSTALL-CONSENT-PUSH-1).
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $after = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'after-install.md') -Raw
        $after | Should -Match 'It gave your account the administrator role\. .* so it is the only role the install gives\.'
        $after | Should -Match 'Until your organization has admin consent, the install ends with a link for it\.'
        $after | Should -Not -Match 'printed the command' -Because 'the install prints an admin consent link, never a command'
        $internals = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'technical' 'install-internals.md') -Raw
        $internals | Should -Match 'It gives the installer the administrator role\. The publish job uploads the program code of the service with its own identity\.'
        $internals | Should -Not -Match 'right to upload' -Because 'PUBLISH-IN-1: the installer holds no data role (tools/Deploy-VmfFacade.ps1)'
        $internals | Should -Not -Match 'installer the four roles' -Because 'the install grants one app role, Vmf.Admin'
        $hook = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1') -Raw)
        $hook | Should -Not -Match 'admin-consent' -Because 'the manual says the install gives a link'
        $hook | Should -Match 'Get-VmfConsentClosing'
        $deploy = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1') -Raw)
        @([regex]::Matches($deploy, "appRoleId = \`$RoleIds\['([^']+)'\]") | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('Vmf.Admin')
    }

    It 'the main template compiles, with its modules' {
        $az = Get-Command az -ErrorAction SilentlyContinue
        if (-not $az) { Set-ItResult -Skipped -Because 'az is not installed'; return }
        $out = az bicep build --file (Join-Path $script:repoRoot 'infra' 'main.bicep') --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }
}

Describe 'EXT-1: the containerapp extension check may not report an ok it did not measure' {
    # MEASURED 2026-09-10 on a corporate workstation, DURING an install:
    #
    #   az containerapp extension                    ok      version
    #   Region offers workload profiles              unknown could not list workload profiles for centralus
    #
    # The version was BLANK. `az extension list` named the extension and gave no
    # version, and the check printed an ok with nothing behind it - while the
    # very next line, which USES the extension, could not answer. An extension
    # directory can exist while its metadata does not; it lists, and then it
    # does not work.
    #
    # The logic is a pure function so these are behavioural, not source matches.

    BeforeAll {
        $readyPath = Join-Path $script:repoRoot 'infra' 'hooks' 'Test-VmfReadiness.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($readyPath, [ref]$null, [ref]$null)
        $found = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-VmfExtensionVerdict'
        }, $true))
        if ($found.Count -ne 1) { throw "expected one Get-VmfExtensionVerdict, found $($found.Count)" }
        $script:verdict = & ([scriptblock]::Create(
            "function Get-VmfExtensionVerdict $($found[0].Body.Extent.Text)`n`${function:Get-VmfExtensionVerdict}"))
    }

    It 'a real version is ok, and is not called broken' {
        $r = & $script:verdict -Extension ([pscustomobject]@{ name = 'containerapp'; version = '1.3.0b4' }) -InstallSucceeded $false
        $r.Result | Should -Be 'ok'
        $r.Detail | Should -Match '1\.3\.0b4'
        $r.Broken | Should -BeFalse
    }

    It 'an unreadable version ASKS the extension, and a working one is ok' {
        # MEASURED 2026-09-15 on a workstation. The installer met this blocker,
        # REMOVED NOTHING, reopened PowerShell as administrator, and the row
        # read 'ok version 1.3.0b5'. The extension was never broken; what
        # changed was who was asking.
        #
        # So an unreadable version is a symptom, and the check no longer
        # decides from it. It asks whether az containerapp runs, which costs
        # nothing - and telling somebody to remove a working extension is the
        # one action here that can leave them worse off.
        function global:az { $global:LASTEXITCODE = 0; 'usage: az containerapp job' }
        try {
            foreach ($blank in '', '   ', $null) {
                $r = & $script:verdict -Extension ([pscustomobject]@{ name = 'containerapp'; version = $blank }) -InstallSucceeded $false
                $r.Result | Should -Be 'ok' -Because 'it runs, whatever its metadata says'
                $r.Broken | Should -BeFalse
                $r.Detail | Should -Match '(?i)nothing to repair'
            }
        }
        finally { Remove-Item function:az -ErrorAction SilentlyContinue }
    }

    It 'and an extension that cannot run is still a blocker' {
        # The original finding, 2026-09-10: az could list the extension
        # directories and not read inside them, and every az containerapp
        # command was broken. postprovision needs one of them - after 10 to 15
        # minutes of deployment and real money.
        # az PRINTS AND FAILS. It writes its error and exits non-zero, so the
        # exit code is the answer and the output is not. A check reading only
        # the output would call this working.
        function global:az { $global:LASTEXITCODE = 1; "ERROR: 'containerapp' is misconfigured" }
        try {
            $r = & $script:verdict -Extension ([pscustomobject]@{ name = 'containerapp'; version = '' }) -InstallSucceeded $false
            $r.Result | Should -Be 'blocker'
            $r.Broken | Should -BeTrue
            # IT NAMES THE REAL CAUSE. Measured 2026-09-15:
            #   PermissionError: [WinError 5] Access is denied:
            #   '...\.azure\cliextensions\containerapp\containerapp-1.3.0b5.dist-info'
            # The extension is not broken. The files are in the person's own
            # profile and its permissions refuse them.
            $r.Detail | Should -Match '(?i)permissions refuse you'
            $r.Detail | Should -Match 'cliextensions'
            # AND IT MUST NOT PRESCRIBE WHAT CAUSED IT. The old message said to
            # remove and add the extension as administrator, which installs it
            # elevated again - so the next ordinary window fails the same way.
            $r.Detail | Should -Not -Match 'az extension add'
            $r.Detail | Should -Match '(?i)do not add the extension again as administrator'
        }
        finally { Remove-Item function:az -ErrorAction SilentlyContinue }
    }

    It 'and installing it without error, yet still not listing, is not ok either' {
        $r = & $script:verdict -Extension $null -InstallSucceeded $true
        $r.Result | Should -Be 'warn'
        $r.Broken | Should -BeTrue
    }

    It 'a failed install is a blocker, because nothing later can work' {
        $r = & $script:verdict -Extension $null -InstallSucceeded $false
        $r.Result | Should -Be 'blocker'
        $r.Broken | Should -BeTrue
    }

    It 'and the workload-profile failure names the extension as the likely cause' {
        # The operator got a message about REGIONS for a problem with their own
        # machine. The two checks are now linked.
        $script:ready | Should -Match '\$extensionLooksBroken = \$verdict\.Broken'
        $script:ready | Should -Match 'if \(\$extensionLooksBroken\)'
        $script:ready | Should -Match 'which is the likely cause'
    }
}

Describe 'TEMP-LOCK-1: a temporary file is unique to the RUN, and is always removed' {
    # WHAT HAPPENED, 2026-09-17, stopping azd up after the facade had published:
    #
    #   New-Object: Exception calling ".ctor" with "2" argument(s): "The process
    #   cannot access the file 'C:\Users\...\Temp\vmf-dash-28800.zip' because it
    #   is being used by another process."
    #
    # WHAT HELD THE FILE IS NOT KNOWN. By the time it was looked into, process
    # 28800 was gone and the file was gone. TWO THEORIES WERE CHECKED ON THE
    # MACHINE THAT FAILED AND BOTH WERE WRONG: it was the personal machine
    # rather than the managed corporate one, and Windows Defender real-time
    # protection is switched off there, so it was not a scanner either.
    #
    # SO THE FIX DOES NOT DEPEND ON KNOWING, and neither does this test. Two
    # things were wrong on their own terms, whatever held the file:
    #
    #   1. the name came from $PID. Windows RECYCLES process ids, azd starts a
    #      fresh process per hook, and two scripts in one process share it - so
    #      a leftover from any earlier run could be the file this run opens;
    #   2. the zip was removed only on the SUCCESS path, so every failed
    #      publish left one behind, and that day had a great many.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:tempRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:shellScripts = @(Get-ChildItem (Join-Path $script:tempRepoRoot 'tools') -Filter '*.ps1') +
        @(Get-ChildItem (Join-Path $script:tempRepoRoot 'infra') -Recurse -Filter '*.ps1')
        $script:publishCode = Get-VmfCodeOnly -Path (Join-Path $script:tempRepoRoot 'tools' 'Deploy-VmfDashboard.ps1')
    }

    It 'found the scripts that make temp files, or nothing below proves anything' {
        @($script:shellScripts).Count | Should -BeGreaterThan 10
        $makers = @($script:shellScripts | Where-Object {
                (Get-VmfCodeOnly -Path $_.FullName) -match 'GetTempPath' })
        @($makers).Count | Should -BeGreaterThan 2
    }

    It 'NOTHING names a temp file after the process id' {
        # The rule is over every script, not the four that were wrong. A list
        # goes out of date the first time somebody adds one.
        $offenders = foreach ($file in $script:shellScripts) {
            $code = Get-VmfCodeOnly -Path $file.FullName
            foreach ($line in ($code -split "`n")) {
                if ($line -notmatch 'GetTempPath') { continue }
                if ($line -match '\$PID') { "$($file.Name): $($line.Trim())" }
            }
        }
        @($offenders) | Should -BeNullOrEmpty `
            -Because 'Windows recycles process ids, so that name is not unique and a leftover can be reopened'
    }

    It 'and the tag really is different every time' {
        # Driven, because a tag that returned a constant would satisfy the rule
        # above and be exactly as broken.
        . (Join-Path $script:tempRepoRoot 'infra' 'New-VmfRunTag.ps1')
        $tags = @(1..20 | ForEach-Object { New-VmfRunTag })
        @($tags | Sort-Object -Unique).Count | Should -Be 20
        foreach ($tag in $tags) { $tag | Should -Match '^[0-9a-f]{8}$' }
    }

    It 'the dashboard zip is cleaned in the FINALLY, not only on success' {
        # The leak that made a collision possible. It used to be removed one
        # line after the deploy, inside the try - so any failure left it.
        $finallyAt = $script:publishCode.IndexOf('finally {')
        $finallyAt | Should -BeGreaterThan 0
        $script:publishCode.Substring($finallyAt) | Should -Match 'Remove-Item \$zip' `
            -Because 'a temp file cleaned only on the happy path is a temp file that accumulates'
    }

    It 'a held file is waited out, then NAMED, and never waited on for ever' {
        # The .NET message says a process has the file and not which process,
        # nor what the file was for. A deployment that stops must say where.
        $script:publishCode | Should -Match 'Start-Sleep -Milliseconds' -Because 'a holder may be transient'
        $script:publishCode | Should -Match 'Could not package the dashboard into' -Because 'the failure must name the file'
        $script:publishCode | Should -Match '\$try -eq 5' -Because 'it must give up rather than hang'
    }

    It 'and it claims nothing about WHAT held the file' {
        # Both theories were checked and both were wrong. A comment or a
        # message that names a cause nobody measured sends the next person to
        # the wrong place, which is how five live runs were spent that day.
        $script:publishCode | Should -Not -Match 'endpoint protection'
        $script:publishCode | Should -Not -Match 'antivirus|virus scanner'
    }
}


Describe 'MISE-1: the sign-in layer validates with MISE, and reports it' {
    # WHY THIS EXISTS. The API registration the facade validates for was
    # flagged by Microsoft's S360 MISE compliance measure. The notice says a
    # registration that is not remediated is SCHEDULED FOR DELETION, with no
    # exemptions - and deleting it takes sign-in with it.
    #
    # THE FIRST ANSWER WAS WRONG, and it is worth recording why. Reading the
    # product alone, the conclusion was "nothing here validates a token, so
    # there is no MISE to upgrade and the only option is to delete the
    # registration". The first half is true: App Service Authentication
    # validates in front of the site and the application only reads the
    # identity header. The conclusion did not follow. The PLATFORM ships MISE
    # and will use it when asked, so the remediation is a setting rather than
    # code - and that fact lives in Microsoft's own guidance, not in this
    # repository. An answer derived only from what is in front of you is an
    # answer about what is in front of you.
    #
    # TWO CONDITIONS MAKE IT WORK, and both would stop being true silently.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:miseRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        # COMMENT-FREE. The block explaining this setting names the setting,
        # the plan types and the issuer - so a check over file text would match
        # its own explanation and pass with the setting deleted.
        $script:platform = Get-VmfCodeOnly -Path (Join-Path $script:miseRoot 'infra' 'platform.bicep') -Language CStyle
    }

    It 'the template really was read, and it is the one with the sign-in block' {
        $script:platform | Should -Match 'authsettingsV2'
        $script:platform | Should -Match 'FUNCTIONS_WORKER_RUNTIME'
    }

    It 'MISE is switched on for the site that validates the tokens' {
        $script:platform | Should -Match "WEBSITE_AAD_ENABLE_MISE: 'true'" `
            -Because 'App Service Authentication uses MISE only when asked, and the measure reads that telemetry'
    }

    It 'CONDITION ONE: the facade is not a Linux function app' {
        # MISE cannot be enabled on a Linux Consumption or Flex Consumption
        # function app. This site is a WINDOWS function app - Y1, or B1 when
        # the plan parameter says Basic. Moving it to Linux would take the
        # setting away with no error and no sign that anything changed.
        $script:platform | Should -Match "kind: 'functionapp'" -Because 'a Linux site is kind functionapp,linux'
        $script:platform | Should -Not -Match "kind: 'functionapp,linux'"
        $script:platform | Should -Not -Match 'reserved: true'
        # And the only two plans the parameter admits are Windows ones.
        $script:platform | Should -Match "skuName: warm \? 'B1' : 'F1'"
        $script:platform | Should -Match "skuName: 'Y1'"
    }

    It 'CONDITION TWO: the issuer is stated, or every caller gets 401' {
        # Enabling MISE without an issuer URL returns 401 for everything. This
        # template already states it, which is the condition the guidance names
        # - so the two changes are safe together and neither is safe alone.
        $script:platform | Should -Match 'openIdIssuer:' `
            -Because 'MISE validates the issuer, and an unstated one fails closed'
        $script:platform | Should -Match "environment\(\)\.authentication\.loginEndpoint" `
            -Because 'the issuer follows the cloud rather than being written out'
    }

    It 'and the sign-in gate itself is unchanged - this adds a validator, not a door' {
        # The point of the change is HOW a token is validated, never WHETHER.
        # A remediation that quietly relaxed the gate would be a far worse
        # outcome than a compliance flag.
        $script:platform | Should -Match 'requireAuthentication: true'
        $script:platform | Should -Match "unauthenticatedClientAction: 'Return401'"
    }
}

Describe 'HOSTING-CHOICE-WORDS-1: the hosting question names each plan in Azure terms, and quotes no old wake time' {

    BeforeAll {
        . (Join-Path $script:repoRoot 'tests' 'unit' '_CodeOnly.ps1')
        $script:hostingQuestion = [regex]::Match($script:pre, "(?s)Read-VmfChoice -Name 'VMF_HOSTING_PLAN'.*?Write-Host").Value
    }

    It 'the question names each plan in Azure terms' {
        # On 2026-10-24 the question named the trade-off; INSTALL-PLAN-WORDS-1
        # (2026-11-12) replaced it with the plans' Azure names and nothing
        # more: "slow" and "fast" came from times measured before the speed fixes.
        # The exact sentences, in every place, are tests/unit/InstallPlanWords.Tests.ps1.
        $script:hostingQuestion | Should -Match 'App Service Free \(F1\)'
        $script:hostingQuestion | Should -Match 'Azure Functions Consumption \(Y1\)'
        $script:hostingQuestion | Should -Match 'App Service Basic \(B1\)'
    }
    It 'nothing quotes the old 20 to 40 seconds: the lab install took about a minute to wake' {
        # MEASURED 2026-10-23 and 2026-10-24 on the lab install: after a quiet
        # period or a deploy, the first page needed about a minute.
        $files = @(
            (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1'),
            (Join-Path $script:repoRoot 'infra' 'main.bicep'),
            (Join-Path $script:repoRoot 'infra' 'platform.bicep')
        ) + @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -Filter *.md | ForEach-Object FullName)
        $hits = @($files | Where-Object { (Get-Content $_ -Raw) -match '20 to 40 seconds' })
        $hits | Should -BeNullOrEmpty
    }

    It 'the manual shows the same question the install asks' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'step-by-step.md') -Raw
        foreach ($line in [regex]::Matches($script:hostingQuestion, "'(?:Free\||Basic\|)?([^'|]+)'") | ForEach-Object { $_.Groups[1].Value }) {
            if ($line -match '^(VMF_HOSTING_PLAN|Free|Basic)$') { continue }
            $page | Should -Match ([regex]::Escape($line.Trim()))
        }
    }
}
