#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# The registration the control plane trusts is never guessed by name.
#
# Every deploy script used to read its own Entra registration like this:
#
#     az ad app list --display-name $ApiDisplayName --query '[0].appId' -o tsv
#
# Entra does not make a display name unique, and any member of the tenant may
# register an application with any name. `[0]` then took whichever the
# directory listed first, and that id becomes clientId and allowedAudiences in
# platform.bicep's authsettingsV2 - the only check in front of the migration
# control plane - and clientId on the dashboard page. An application somebody
# else owns would decide who may call the engine: its owner writes its app
# roles, so they can issue themselves the Vmf.Admin role the facade reads out
# of the sign-in header.
#
# The rules these tests hold to:
#   1. the id comes from the identity deployment's own output where there is
#      one (infra/identity-deploy.ps1 returns it; the hooks carry it as
#      VMF_API_APP_ID);
#   2. a lookup matches the name EXACTLY and REFUSES when two applications
#      carry it;
#   3. a directory call that FAILED is never read as "the object does not
#      exist" - that is what turned a throttled call into "the sign-in gate is
#      open" and then deployed it open (GATE-1);
#   4. every directory object a run needs is resolved BEFORE the run changes
#      anything, so a refusal cannot leave the work half done.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')

    # `az` is an external command; a FUNCTION of the same name wins
    # resolution, so the helper is driven without Azure.
    function Global:az {
        $global:azSeen = @($args)
        if ($global:azExit -ne 0) {
            $global:LASTEXITCODE = $global:azExit
            $ErrorActionPreference = 'Continue'
            if ($global:azStderr) { Write-Error $global:azStderr }
            return
        }
        $global:LASTEXITCODE = 0
        if (@($args) -contains 'app') { return ($global:azApps | ConvertTo-Json -Depth 5 -AsArray) }
        if (@($args) -contains 'sp') { return ($global:azSps | ConvertTo-Json -Depth 5 -AsArray) }
        return '[]'
    }
    function Global:SetDirectory {
        param([object[]]$Apps = @(), [object[]]$ServicePrincipals = @(), [int]$Exit = 0, [string]$Stderr = '')
        $global:azApps = $Apps
        $global:azSps = $ServicePrincipals
        $global:azExit = $Exit
        $global:azStderr = $Stderr
        $global:LASTEXITCODE = 0
    }
    # Comment lines are not code. A rule that matches a comment explaining why
    # the code was removed is a rule that never fails.
    function Global:CodeOnly {
        param([string]$Text)
        (($Text -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }
}
AfterAll {
    Remove-Item 'function:\az', 'function:\SetDirectory', 'function:\CodeOnly' -ErrorAction SilentlyContinue
}

Describe 'The lookup matches the name exactly, and refuses to choose' {

    It 'takes the registration whose name matches EXACTLY, never the first answer' {
        # az lists what its filter matched, in its own order. The sibling name
        # comes first here, which is exactly how [0] used to pick the wrong one.
        SetDirectory -Apps @(
            @{ displayName = 'vmf-api-prod2'; appId = '11111111-1111-1111-1111-111111111111'; id = 'object-1' },
            @{ displayName = 'vmf-api-prod'; appId = '22222222-2222-2222-2222-222222222222'; id = 'object-2' }
        )
        $app = Get-VmfEntraApplication -DisplayName 'vmf-api-prod'
        [string]$app.appId | Should -Be '22222222-2222-2222-2222-222222222222'
    }

    It 'refuses when two registrations carry the one name, and names both and the way out' {
        SetDirectory -Apps @(
            @{ displayName = 'vmf-api-prod'; appId = '11111111-1111-1111-1111-111111111111'; id = 'object-1' },
            @{ displayName = 'vmf-api-prod'; appId = '22222222-2222-2222-2222-222222222222'; id = 'object-2' }
        )
        $err = { Get-VmfEntraApplication -DisplayName 'vmf-api-prod' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'Refusing to guess'
        $err.Exception.Message | Should -Match '11111111-1111-1111-1111-111111111111'
        $err.Exception.Message | Should -Match '22222222-2222-2222-2222-222222222222'
        # The remedy, not just the refusal: a person reading this has to know
        # what to do next.
        $err.Exception.Message | Should -Match 'directory administrator'
        $err.Exception.Message | Should -Match 'different environment name'
    }

    It 'a directory that holds no such registration is an empty answer, not a failure' {
        SetDirectory -Apps @(@{ displayName = 'something-else'; appId = '11111111-1111-1111-1111-111111111111' })
        Get-VmfEntraApplication -DisplayName 'vmf-api-prod' | Should -BeNullOrEmpty
    }
}

Describe 'A failed directory call is not an absent object' {

    It 'throws, and hands over what the directory said' {
        SetDirectory -Exit 1 -Stderr 'Insufficient privileges to complete the operation.'
        $err = { Get-VmfEntraApplication -DisplayName 'vmf-api-prod' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'Insufficient privileges'
        $err.Exception.Message | Should -Match 'FAILED'
    }

    It 'gives $null ONLY to a caller that says it can live with that, and warns' {
        SetDirectory -Exit 1 -Stderr 'Insufficient privileges to complete the operation.'
        $warnings = @()
        $app = Get-VmfEntraApplication -DisplayName 'vmf-api-prod' -AllowDirectoryFailure `
            -WarningVariable warnings -WarningAction SilentlyContinue
        $app | Should -BeNullOrEmpty
        @($warnings).Count | Should -BeGreaterThan 0
        [string]$warnings[0] | Should -Match 'Insufficient privileges'
    }

    It 'even a tolerated failure leaves no exit code behind' {
        # pwsh returns $LASTEXITCODE as the process exit code, so a probe that
        # is allowed to fail would otherwise fail the whole publish.
        SetDirectory -Exit 1
        Get-VmfEntraApplication -DisplayName 'vmf-api-prod' -AllowDirectoryFailure -WarningAction SilentlyContinue | Out-Null
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'and a tolerated failure never excuses two registrations with one name' {
        SetDirectory -Apps @(
            @{ displayName = 'vmf-dashboard-prod'; appId = '11111111-1111-1111-1111-111111111111' },
            @{ displayName = 'vmf-dashboard-prod'; appId = '22222222-2222-2222-2222-222222222222' }
        )
        { Get-VmfEntraApplication -DisplayName 'vmf-dashboard-prod' -AllowDirectoryFailure } |
            Should -Throw '*Refusing to guess*'
    }
}

Describe 'A service principal is found by application id, never by name' {

    It 'asks the directory for the application id and returns the one that reports it' {
        SetDirectory -ServicePrincipals @(
            @{ appId = '22222222-2222-2222-2222-222222222222'; id = 'sp-2'; appRoleAssignmentRequired = $true }
        )
        $sp = Get-VmfEntraServicePrincipal -AppId '22222222-2222-2222-2222-222222222222'
        [string]$sp.id | Should -Be 'sp-2'
        [bool]$sp.appRoleAssignmentRequired | Should -BeTrue
        @($global:azSeen) -join ' ' | Should -Match "appId eq '22222222-2222-2222-2222-222222222222'"
        @($global:azSeen) | Should -Not -Contain '--display-name'
    }

    It 'refuses a value that is not an application id, so nothing else reaches the filter' {
        SetDirectory
        { Get-VmfEntraServicePrincipal -AppId "vmf-api' or startswith(displayName,'vmf" } |
            Should -Throw '*not an application id*'
    }

    It 'an application with no service principal yet is an empty answer' {
        SetDirectory -ServicePrincipals @()
        Get-VmfEntraServicePrincipal -AppId '22222222-2222-2222-2222-222222222222' | Should -BeNullOrEmpty
    }
}

Describe 'No install script asks for a registration by name and takes the first answer' {
    BeforeAll {
        $script:scripts = @(
            (Join-Path $script:repoRoot 'infra' 'deploy.ps1'),
            (Join-Path $script:repoRoot 'infra' 'identity-deploy.ps1'),
            (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1'),
            (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1'),
            (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1'),
            (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1'),
            (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1'),
            (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1'),
            (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1')
        )
    }

    It 'found all nine, or this proves nothing' {
        @($script:scripts | Where-Object { Test-Path $_ }).Count | Should -Be 9
    }

    It 'none of them calls az ad app list or az ad sp list at all' {
        $hits = foreach ($file in $script:scripts) {
            $code = CodeOnly -Text (Get-Content $file -Raw)
            if ($code -match 'az ad (app|sp) list') { Split-Path $file -Leaf }
        }
        @($hits) -join ', ' | Should -BeNullOrEmpty -Because 'the one exact lookup lives in infra/Resolve-VmfRegistration.ps1'
    }

    It 'each of them dot-sources the one helper' {
        foreach ($file in $script:scripts) {
            $code = CodeOnly -Text (Get-Content $file -Raw)
            # The three hooks get it through AzdHooks.ps1, which they all
            # dot-source already.
            $viaHooks = $code -match "AzdHooks\.ps1"
            $direct = $code -match "Resolve-VmfRegistration\.ps1"
            ($viaHooks -or $direct) | Should -BeTrue -Because "$(Split-Path $file -Leaf) has to find registrations the one way"
        }
        (CodeOnly -Text (Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1') -Raw)) |
            Should -Match 'Resolve-VmfRegistration\.ps1'
    }
}

Describe 'The id the facade trusts comes from the deployment that created it' {
    BeforeAll {
        $script:identityBicep = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        $script:identityDeploy = Get-Content (Join-Path $script:repoRoot 'infra' 'identity-deploy.ps1') -Raw
        $script:pre = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw
        $script:post = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1') -Raw
    }

    It 'the template reports it, and the deploy script hands that output back' {
        $script:identityBicep | Should -Match 'output apiAppId string = apiApp\.appId'
        $script:identityDeploy | Should -Match '--query properties\.outputs'
        $script:identityDeploy | Should -Match 'ApiAppId\s+= \$apiAppId'
    }

    It 'the install records the reported id, and never looks it up again' {
        $script:pre | Should -Match 'Select-Object -ExpandProperty ApiAppId'
        $script:pre | Should -Match "Set-AzdValue -Name 'VMF_API_APP_ID' -Value \`$apiAppId"
        (CodeOnly -Text $script:pre) | Should -Not -Match 'az ad app list'
    }

    It 'and the step that closes the sign-in gate uses that same recorded id' {
        # GATE-1 must be closed on the application the facade validates tokens
        # against, and no other.
        $script:post | Should -Match "Get-AzdValue -Name 'VMF_API_APP_ID'"
        $script:post | Should -Match 'Get-VmfEntraServicePrincipal -AppId \$apiAppId'
        $script:post | Should -Match 'appRoleAssignmentRequired'
    }

    It 'the identity deploy still reads the LIVE gate before the deployment asserts it' {
        $script:identityDeploy | Should -Match '(?s)Get-VmfEntraServicePrincipal.*?requireAssignedRole='
        $script:identityDeploy | Should -Match 'appRoleAssignmentRequired'
    }
}

Describe 'Every directory object is resolved before a run changes anything' {
    BeforeAll {
        $script:grant = Get-Content (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1') -Raw
        # TEARDOWN-1: the removal moved to postdown, so the rule follows it.
        $script:predownText = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1') -Raw
    }

    It 'Grant-VmfAccess reads the registration before it creates a role or grants one' {
        # The refusal used to throw in the middle: the two custom roles were
        # created, and with -CloseTheGate the gate was then never closed.
        $resolve = $script:grant.IndexOf('Get-VmfEntraApplication')
        $resolve | Should -BeGreaterThan 0
        # ROLES-1 replaced the two inline deployments with one call that
        # creates or widens the roles, so THAT is now the mutation to order
        # against. The rule is the same: read the directory first, because the
        # refusal used to throw after the roles had already been made.
        foreach ($mutation in 'Set-VmfRoleScopes', 'az role assignment create', 'appRoleAssignmentRequired') {
            $at = $script:grant.IndexOf($mutation)
            $at | Should -BeGreaterThan 0 -Because "'$mutation' should still be in this script"
            $resolve | Should -BeLessThan $at -Because "'$mutation' changes something, so the directory read comes first"
        }
    }

    It 'Grant-VmfAccess reads the first administrator before it creates a role too' {
        $resolve = $script:grant.IndexOf('az ad user show')
        $resolve | Should -BeGreaterThan 0
        $script:grant.IndexOf('Set-VmfRoleScopes') | Should -BeGreaterThan $resolve
    }

    It 'the uninstall resolves both registrations before it deletes either' {
        $script:predownText | Should -Match '\$found = foreach \(\$want in @\(@\(\$names\.Api, ''VMF_API_APP_ID''\), @\(\$names\.Dashboard, ''VMF_DASHBOARD_APP_ID''\)\)\)'
        $script:predownText | Should -Match 'foreach \(\$entry in \$found\)'
        $script:predownText.IndexOf('$found = foreach') |
            Should -BeLessThan $script:predownText.IndexOf('az ad app delete')
    }
}

Describe 'GRANT-NAME-1: the grant script finds its registration rather than guessing a name' {
    # A run of it gave "The 'vmf-api' registration does not exist".
    # That default predates the names gaining the environment - one is
    # `vmf-api-contoso-demo` - so the script named a registration no install has
    # created for months. Nothing calls this script, so nothing noticed.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:grantPath = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'tools' 'Grant-VmfAccess.ps1'
        $script:grant = Get-VmfCodeOnly -Path $script:grantPath
    }

    It 'does not default to a bare name' {
        $script:grant | Should -Not -Match "ApiDisplayName = 'vmf-api'"
        $script:grant | Should -Match "ApiDisplayName = ''"
    }

    It 'finds it through the shared lookup, not with its own az call' {
        # The rule above: the one exact lookup lives in
        # infra/Resolve-VmfRegistration.ps1. The first version of this fix put
        # an `az ad app list` in the script and that rule caught it.
        $script:grant | Should -Match 'Find-VmfEntraApplications -NameStartsWith'
        $script:grant | Should -Not -Match 'az ad app list'
    }

    It 'and the shared lookup asks the DIRECTORY to filter, without parentheses' {
        # A tenant can hold hundreds of thousands of registrations, so the
        # filtering is server-side. But NOT with `--filter "startswith(...)"`:
        # measured on a Windows machine, the parentheses reach cmd, which
        # reads them as its own syntax and answers "-o was unexpected at this
        # time". az builds the filter itself from --display-name.
        $resolve = Get-VmfCodeOnly -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'infra' 'Resolve-VmfRegistration.ps1')
        $resolve | Should -Match 'function Find-VmfEntraApplications'
        $resolve | Should -Match "'--display-name', \`$NameStartsWith"
        # The az ARGUMENT, not the word: `-Match` is case-insensitive, so a
        # bare 'startswith\(' also matches the .NET .StartsWith() call three
        # lines below and fails on correct code.
        $resolve | Should -Not -Match '--filter\s*,?\s*"startswith\('
    }

    It 'and refuses rather than choosing, when the answer is not exactly one' {
        # Entra does not make a display name unique. Taking the first match is
        # the defect the rest of this file exists for.
        $script:grant | Should -Match '\$candidates\.Count -eq 1'
        $script:grant | Should -Match '\$candidates\.Count -gt 1'
        $script:grant | Should -Match 'Name the one for this install with -ApiDisplayName'
    }

    It 'the override is still there, because a person may have to name it' {
        $script:grant | Should -Match '\[string\]\$ApiDisplayName'
    }
}

Describe 'GRANT-NAME-1: the summary reports reach, not the parameters passed' {
    # Granting migrate alone printed "the service can SEE: (unchanged)", which
    # reads as "still blind". It is not: the migration role contains the
    # assessment role, so that grant gave sight too. Same shape as ROLES-UX-2 -
    # a line accurate about the mechanism, answering the wrong question.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:g = Get-VmfCodeOnly -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'tools' 'Grant-VmfAccess.ps1')
    }

    It 'a migrate grant alone does not report the product as unable to see' {
        $script:g | Should -Match 'the migration role includes assessment'
        # The old shape: SEE printed (unchanged) whenever -AssessScope was absent.
        $script:g | Should -Not -Match "can SEE\s+: \`$\(if \(\`$AssessScope\)"
    }

    It 'and (unchanged) survives for the case where nothing was granted' {
        # Removing it would make a run that granted nothing claim reach it
        # never had.
        $script:g | Should -Match "'\(unchanged\)'"
    }
}
