#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-H13: authentication on the control plane was OPTIONAL.
#
# apiAppId defaulted to empty and the whole Easy Auth block was conditional on
# it, so a deployment using the documented bootstrap order produced an
# internet-reachable migration control plane with no authentication: every
# function is authLevel anonymous, and the only identity check in code decodes
# the x-ms-client-principal header without verifying who sent it. An anonymous
# caller could forge it and approve a wave, start it against production
# machines, halt a run, or discard one with its safety copies - and the forged
# name is what would be written as the approver of record.
#
# The test that appeared to guard this matched the template's TEXT for
# 'authsettingsV2', which passes whether the block is reachable or dead.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:template = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
    $script:deployTool = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1') -Raw
}

Describe 'EVAL-H13: the template cannot produce an unauthenticated control plane' {
    It 'apiAppId is required, with no default that turns sign-in off' {
        $script:template | Should -Not -Match "param apiAppId string = ''"
        $script:template | Should -Match '(?m)^param apiAppId string\s*$'
    }

    It 'no path skips the auth block' {
        # This is the assertion the old text-match could not make: the block
        # existing in the file proves nothing if it is behind a condition that
        # is false by default.
        $script:template | Should -Not -Match 'empty\(apiAppId\)'
    }

    It 'the auth block still says what it must' {
        $script:template | Should -Match 'requireAuthentication: true'
        $script:template | Should -Match "unauthenticatedClientAction: 'Return401'"
    }
}

Describe 'EVAL-H13: publishing verifies the app itself, not the template' {
    It 'the deploy tool reads the running configuration back' {
        # A template can be right and an app reconfigured by hand afterwards.
        # This tool is the last thing to touch the app before it serves.
        $script:deployTool | Should -Match 'authsettingsV2'
        $script:deployTool | Should -Match 'requireAuthentication'
        $script:deployTool | Should -Match 'Refusing to publish'
    }

    It 'it refuses on any of the three conditions, not just the first' {
        # AUTHREAD-1 moved the three values into variables read by name, so
        # this matches the comparisons rather than a property path. What each
        # SHAPE of answer actually does is measured in
        # tests/unit/AuthGateRead.Tests.ps1, which runs the shipped walker -
        # this file only holds that all three conditions are still tested.
        $script:deployTool | Should -Match "\`$unauthAction -ne 'Return401'"
        $script:deployTool | Should -Match '\$requireAuth -ne \$true'
        $script:deployTool | Should -Match '\$aadEnabled -ne \$true'
        $script:deployTool | Should -Match "'identityProviders', 'azureActiveDirectory', 'enabled'"
    }
}

Describe 'EVAL-H13: what was NOT built, and why' {
    It 'records that the platform exposes no auth state an app can check at start-up' {
        # The audit suggested throwing at host start when WEBSITE_AUTH_ENABLED
        # is not True. Checked against the live facade: no WEBSITE_AUTH*
        # setting exists, and the running process has NO auth variable at all -
        # so that check would have tested a phantom and passed for ever.
        # The guarantee is therefore made where it can actually be made: at
        # deployment, and at publish time.
        $profileText = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'profile.ps1') -Raw
        $profileText | Should -Not -Match 'WEBSITE_AUTH_ENABLED' -Because 'a check against a variable that does not exist is worse than no check - it reads as protection'
    }
}

# DIAG-3, 2026-09-09. Drill E: change the hosting plan to Basic, the way a
# customer would, and change it back.
#
# IT FAILED THE DEPLOYMENT OUTRIGHT.
#
#   BadRequest: Category 'AppServiceHTTPLogs' is not supported.
#   target: .../sites/vmf-facade-b1-.../diagnosticSettings/vmf-facade-to-logs
#
# The diagnostic settings are gated on facadePlan == 'Basic', and that path had
# NEVER RUN - the lab and the proof environment have always been Consumption.
# So one of the three answers the install asks every customer for was broken.
#
# The comment that shipped the list explained, confidently, that "Basic is B1,
# an ordinary App Service plan, and carries them". That was reasoning, not
# measurement. AppServiceHTTPLogs and AppServicePlatformLogs are WEB APP
# categories; the facade is a FUNCTION app and has neither, on any plan.
#
# MEASURED on the live B1 site with the command the old comment itself cites:
#   FunctionAppLogs, AppServiceAuditLogs, AppServiceIPSecAuditLogs,
#   AppServiceAuthenticationLogs, AllMetrics
Describe 'DIAG-3: the facade asks only for log categories it has' {

    BeforeAll {
        $script:platform = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        # What a B1 function app reports, read on 2026-09-09.
        $script:supported = @(
            'FunctionAppLogs', 'AppServiceAuditLogs', 'AppServiceIPSecAuditLogs',
            'AppServiceAuthenticationLogs'
        )
        # The FACADE's setting, found by its name. STORE-LOGS-1 put the
        # store's setting earlier in the template, and the first list in the
        # file is now the store's.
        $block = [regex]::Match($script:platform,
            "(?s)name: 'vmf-facade-to-logs'.*?logCategoriesAndGroups: \[(?<c>.*?)\]").Groups['c'].Value
        $script:asked = @([regex]::Matches($block, "category: '(?<n>[^']+)'") |
            ForEach-Object { $_.Groups['n'].Value })
    }

    It 'asks for at least one category' {
        $script:asked.Count | Should -BeGreaterThan 0
    }

    It 'and every one of them exists on a function app' {
        foreach ($c in $script:asked) {
            $script:supported | Should -Contain $c -Because "a B1 function app does not report $c"
        }
    }

    It 'the two WEB APP categories are gone' {
        # These are what failed the deployment. Naming them so a future edit
        # cannot quietly put them back.
        $script:asked | Should -Not -Contain 'AppServiceHTTPLogs'
        $script:asked | Should -Not -Contain 'AppServicePlatformLogs'
    }

    It 'and the function app category it actually wanted is there' {
        $script:asked | Should -Contain 'FunctionAppLogs'
    }

    It 'sign-in is still recorded, which was DIAG-1''s whole point' {
        $script:asked | Should -Contain 'AppServiceAuthenticationLogs'
    }

    It 'the reason is written where the list is, with the command that produced it' {
        $script:platform | Should -Match 'DIAG-3'
        $script:platform | Should -Match 'az monitor diagnostic-settings categories list'
        $script:platform | Should -Match '(?i)WEB APP categories'
    }
}

Describe 'UPLOAD-WAIT-1: the code upload waits long enough, and says what Azure said' {
    # MEASURED 2026-09-10, a FIRST install into a corporate subscription:
    #
    #   2/2 build the code package and upload it...
    #      waiting for the code container permission to apply...
    #   Could not upload the code package to https://<store>.blob.core.windows.net/...
    #   The account that publishes needs Storage Blob Data Contributor ...
    #
    # Two defects. It waited six attempts 10 seconds apart - about a minute -
    # when Microsoft documents RBAC propagation to the DATA PLANE as taking up
    # to ten minutes, and on a first install the grant is seconds old. And it
    # discarded Azure's error with 2>$null on every attempt, then ASSERTED the
    # cause. A storage firewall or a subscription policy refuses the same
    # upload, and that message sends somebody to fix a permission that was
    # never wrong.
    #
    # PUBLISH-IN-1 MOVED THE UPLOAD, and both lessons moved with it. It no
    # longer happens on the laptop at all - it happens in a Container Apps job,
    # because a locked-down store refuses the laptop and no perimeter rule can
    # admit one. So these read the job's entrypoint. The lessons got HARDER to
    # hold there, not easier: this runs where nobody is watching, and the only
    # thing an installer ever sees is the exit code and the log.
    BeforeAll {
        $script:publishJob = Get-Content (Join-Path $script:repoRoot 'docker' 'publish' 'entrypoint.ps1') -Raw
    }

    It 'the wait is minutes, not one minute' {
        $script:publishJob | Should -Match '\$backoff = @\(' -Because 'a fixed 10-second retry is not a wait'
        # Read the real numbers out of the source and add them up, rather than
        # trusting that a variable called backoff contains a long one.
        $line = @($script:publishJob -split "`n" | Where-Object { $_ -match '^\s*\$backoff = @\(' })[0]
        $line | Should -Not -BeNullOrEmpty
        $seconds = @([regex]::Matches($line, '\d+') | ForEach-Object { [int]$_.Value })
        ($seconds | Measure-Object -Sum).Sum | Should -BeGreaterOrEqual 300 -Because 'RBAC can take up to ten minutes to reach the data plane'
    }

    It 'and the job is allowed to run for longer than it waits' {
        # The wait is worthless if Container Apps kills the replica first. This
        # is a NEW way to get the old defect: the numbers live in two files now.
        $template = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $timeout = [int]([regex]::Match($template, '(?s)vmf-publish-job-deploy.*?replicaTimeout: (\d+)').Groups[1].Value)
        $line = @($script:publishJob -split "`n" | Where-Object { $_ -match '^\s*\$backoff = @\(' })[0]
        $waited = (@([regex]::Matches($line, '\d+') | ForEach-Object { [int]$_.Value }) | Measure-Object -Sum).Sum
        $timeout | Should -BeGreaterThan $waited -Because 'a replica killed mid-wait reports a timeout, not the refusal underneath it'
    }

    It 'it keeps the error instead of discarding it' {
        # The whole defect in one character: 2>$null threw away the evidence.
        # The upload is a cmdlet now, so the equivalent mistake is a bare catch
        # that keeps nothing.
        $script:publishJob | Should -Match '\$lastError = \[string\]\$_\.Exception\.Message'
        $script:publishJob | Should -Not -Match 'catch \{ \}'
        $script:publishJob | Should -Match '-ErrorAction Stop' -Because 'a non-terminating error never reaches the catch'
    }

    It 'and it only blames a permission when Azure actually said so' {
        $script:publishJob | Should -Match 'AuthorizationPermissionMismatch'
        $script:publishJob | Should -Match '(?i)Azure did not refuse this for a permission'
        $script:publishJob | Should -Match '(?i)a network rule on the storage account'
    }

    It 'the message ends with what Azure said' {
        $script:publishJob | Should -Match 'throw \(\$head \+ \[Environment\]::NewLine \+ \$why\)'
    }

    It 'and the failure reaches the person, who is not watching it happen' {
        # The upload used to fail in front of the installer. It now fails inside
        # a job, so the publish has to fetch the outcome and refuse - a job that
        # STARTED is not a job that worked, and a publish that carried on would
        # restart the service onto whatever package was there before.
        # PUBLISH-RUN-LOG-1 moved the wait into infra/Wait-VmfJobRun.ps1, which
        # also reads the run's console; PublishRunLog.Tests.ps1 runs it.
        $waiter = Get-Content (Join-Path $script:repoRoot 'infra' 'Wait-VmfJobRun.ps1') -Raw
        $waiter | Should -Match 'job execution show'
        $script:deployTool | Should -Match "Status -ne 'Succeeded'"
        $script:deployTool | Should -Match 'throw \(Format-VmfJobRunFailure'
    }
}

Describe 'EASYAUTH-403-1: the template states the authorization policy' {
    # MEASURED on the affected install, one property at a time, with the same
    # two calls to /api/version after each change:
    #
    #   allowedApplications: []          -> 401 no token, 403 with one
    #   allowedApplications: absent      -> 401 no token, 200 with one
    #   allowedApplications: [] again    -> 403 again        <- isolates it
    #   allowedApplications: [two ids]   -> 401 no token, 200 with one
    #
    # An EMPTY ARRAY refuses every caller. Microsoft's documentation says the
    # opposite - that it restricts only when non-empty - and the measurement is
    # what shipped. The template never stated the policy, Azure materialised it
    # empty, and the install was dead with a dashboard blaming the person's
    # role.
    #
    # `allowedPrincipals: {}` was present in all four rows INCLUDING both that
    # returned 200, so it is not the cause. It was this project's own suspect
    # for a day; the mutation above disproved it.

    BeforeAll {
        # COMMENT-TRAP-1, and the report that produced this change warned about
        # this exact line: the comment beside the policy QUOTES the empty array
        # it exists to prevent, so a check over file text matches its own
        # explanation and can never fail. Code only.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:templateCode = Get-VmfCodeOnly `
            -Path (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Language CStyle
    }

    It 'the comment reader is dropping comments, or nothing below proves anything' {
        $script:template | Should -Match 'allowedApplications:\s*\[\s*\]'
        $script:templateCode | Should -Not -Match 'allowedApplications:\s*\[\s*\]'
    }

    It 'the policy is stated, not left for Azure to invent' {
        $script:templateCode | Should -Match 'defaultAuthorizationPolicy'
        $script:templateCode | Should -Match 'allowedApplications:\s*\[\s*dashboardAppId,\s*azCliClientId\s*\]'
    }

    It 'and it is never an empty list, which is the defect itself' {
        $script:templateCode | Should -Not -Match 'allowedApplications:\s*\[\s*\]'
    }

    It 'both applications are named - the dashboard AND the Azure CLI' {
        # Naming only the dashboard shuts out tools/Test-VmfHealth.ps1, which
        # asks the service a question as the operator through the CLI.
        $script:template | Should -Match "var azCliClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'"
    }

    It 'identity.bicep pre-authorises the SAME two, or the policy names a client that cannot get a token' {
        # Two files, one list. They have to agree.
        $identity = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        $identity | Should -Match 'preAuthorizedApplications'
        $identity | Should -Match "azCliClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'"
        $identity | Should -Match 'appId: dashboardApp\.appId'
    }

    It 'dashboardAppId is required here, so an empty value cannot deploy' {
        # An empty string would produce allowedApplications: [''] - a NON-empty
        # list matching nothing, which is the same 403 by another route. The
        # pattern is apiAppId's: empty default in main.bicep for azd's
        # pre-flight, refused by this template.
        $script:template | Should -Match '(?m)^param dashboardAppId string\s*$'
        $script:template | Should -Not -Match "param dashboardAppId string = ''"
        $outer = Get-Content (Join-Path $script:repoRoot 'infra' 'main.bicep') -Raw
        $outer | Should -Match "param dashboardAppId string = ''"
        $outer | Should -Match 'dashboardAppId: dashboardAppId'
    }

    It 'every path that deploys the platform supplies it' {
        # azd reads it from the environment the hook wrote; the hand path
        # resolves it. A path that forgets deploys a policy naming nothing.
        $params = Get-Content (Join-Path $script:repoRoot 'infra' 'main.parameters.json') -Raw
        $params | Should -Match 'VMF_DASHBOARD_APP_ID'
        $hook = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw
        $hook | Should -Match "Set-AzdValue -Name 'VMF_DASHBOARD_APP_ID'"
        $byHand = Get-Content (Join-Path $script:repoRoot 'infra' 'deploy.ps1') -Raw
        $byHand | Should -Match 'dashboardAppId=\$dashboardAppId'
        $byHand | Should -Match "vmf-api', 'vmf-dashboard'"
    }
}
