#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-CONSENT-PUSH-1: the install pushes the installer towards a role that
# can give admin consent, and never blocks an Owner (FIRSTSCOPE-1).
#
# Since 2026-11-02 the install pushes the installer to use a role that can give
# admin consent, not only a subscription role. A user who does not hold one is
# told to work with someone who does.
#
# Before this, an installer with no consent role read ONE line - "The Admin
# page needs admin consent in Microsoft Entra ID, and you cannot give it" - and
# the install went on. Nothing said who could give it or how to ask them, and
# the closing message handed that person an az command to run.
#
# The functions are CALLED here with az and azd stubbed out, never only read:
# a source match passes while the branch it names is never taken.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:rightsPath = Join-Path $script:repoRoot 'infra' 'Resolve-VmfInstallerRights.ps1'
    $script:prePath    = Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1'
    $script:postPath   = Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1'
    # AzdHooks first: it holds Read-VmfChoice and Set-AzdValue, which the push
    # uses. Then the rights reader, as preprovision loads them.
    . (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1')
    . $script:rightsPath

    # Placeholder ids only (rule 13): no real tenant, application or person.
    $script:tenant = '00000000-0000-0000-0000-000000000000'
    $script:client = '11111111-2222-3333-4444-555555555555'

    $script:allRoles = @($script:VmfConsentAnyPermission + $script:VmfConsentDelegatedOnly)

    function global:az {
        $joined = $args -join ' '
        $global:VmfTestAzCalls += , $joined
        $global:LASTEXITCODE = 0
        foreach ($key in $script:answers.Keys) {
            if ($joined -like $key) { return $script:answers[$key] }
        }
        $null
    }
    function global:azd {
        # Set-AzdValue: azd env set NAME VALUE
        $global:VmfTestAzdSets += , ($args -join ' ')
        $global:LASTEXITCODE = 0
    }

    function script:New-Rights {
        param([string]$CanConsent, [bool]$IsPerson = $true, [string[]]$ConsentRoles = @())
        [pscustomobject]@{
            IsPerson     = $IsPerson
            CanGrant     = 'yes'
            CanConsent   = $CanConsent
            GrantRoles   = @('Owner')
            ConsentRoles = $ConsentRoles
        }
    }

    # Runs a block and splits what it RETURNED from what it PRINTED.
    function script:Invoke-Captured {
        param([scriptblock]$Block)
        $all = @(& $Block 6>&1)
        [pscustomobject]@{
            Out  = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
            Text = (@($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                    ForEach-Object { [string]$_.MessageData }) -join "`n")
        }
    }
}

Describe 'INSTALL-CONSENT-PUSH-1' {

AfterAll {
    # TEST-STUB-1: the function:global: form removes nothing.
    Remove-Item 'function:\az' -ErrorAction SilentlyContinue
    Remove-Item 'function:\azd' -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('VMF_CONSENT_LATER', $null)
    Remove-Variable -Scope Global -Name VmfTestAzCalls, VmfTestAzdSets -ErrorAction SilentlyContinue
}

BeforeEach {
    $script:answers = @{}
    $global:VmfTestAzCalls = @()
    $global:VmfTestAzdSets = @()
    [Environment]::SetEnvironmentVariable('VMF_CONSENT_LATER', $null)
}

Describe 'INSTALL-CONSENT-PUSH-1: the role it recommends' {

    It 'is Cloud Application Administrator, because the product asks for delegated permissions only' {
        # Microsoft, "Least privileged roles by task" (delegate-by-task, read
        # 2026-11-02): "Consent to any delegated permissions" - least privileged
        # role Cloud Application Administrator. Privileged Role Administrator is
        # the least role only for Microsoft Graph APPLICATION permissions.
        Get-VmfConsentLeastRole | Should -Be 'Cloud Application Administrator'
    }

    It 'and that rests on a fact read from the registration, not from memory' {
        # If the dashboard ever asks for a Microsoft Graph app role
        # (type 'Role'), Cloud Application Administrator can no longer approve
        # it, and the recommendation must change with it.
        $bicep = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'identity.bicep')
        $access = [regex]::Match($bicep, '(?s)requiredResourceAccess:\s*\[.*?\n  \]').Value
        $access | Should -Not -BeNullOrEmpty
        $asksAppRoles = $access -match "type:\s*'Role'"
        $script:VmfProductAsksGraphAppRoles | Should -Be $asksAppRoles
        $access | Should -Match "type:\s*'Scope'"
    }

    It 'would be Privileged Role Administrator if the product asked for a Graph app role' {
        $was = $script:VmfProductAsksGraphAppRoles
        try {
            $script:VmfProductAsksGraphAppRoles = $true
            Get-VmfConsentLeastRole | Should -Be 'Privileged Role Administrator'
        }
        finally { $script:VmfProductAsksGraphAppRoles = $was }
    }

    It 'is one of the roles the rights reader counts' {
        $script:allRoles | Should -Contain (Get-VmfConsentLeastRole)
    }

    It 'and the readiness check still counts the same roles' {
        # One list. tools/Test-VmfConsentReadiness.ps1 answers the same
        # question, and two lists would drift - so it reads this one
        # (CONSENT-TOOL-LINK-1) and holds no copy.
        $tool = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Test-VmfConsentReadiness.ps1')
        $tool | Should -Match 'Resolve-VmfInstallerRights\.ps1'
        $tool | Should -Match '\$anyPermission = \$script:VmfConsentAnyPermission'
        $tool | Should -Match '\$delegatedOnly = \$script:VmfConsentDelegatedOnly'
        foreach ($role in $script:allRoles) { $tool | Should -Not -Match ([regex]::Escape("'$role'")) }
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: what the install says before it creates anything' {

    It 'names every role that can give admin consent, from the reader''s own list' {
        foreach ($state in 'yes', 'no', 'unknown') {
            $text = (Get-VmfConsentNotice -Rights (New-Rights -CanConsent $state)) -join "`n"
            foreach ($role in $script:allRoles) { $text | Should -Match ([regex]::Escape($role)) }
        }
    }

    It 'says the Admin page needs admin consent, and recommends the least role' {
        $text = (Get-VmfConsentNotice -Rights (New-Rights -CanConsent 'no')) -join "`n"
        $text | Should -Match 'Admin page'
        $text | Should -Match 'admin consent in Microsoft Entra ID'
        $text | Should -Match 'Use Cloud Application Administrator'
    }

    It 'yes: says you can give it' {
        $text = (Get-VmfConsentNotice -Rights (New-Rights -CanConsent 'yes' -ConsentRoles 'Application Administrator')) -join "`n"
        $text | Should -Match 'You hold Application Administrator, so you can give admin consent'
        $text | Should -Not -Match 'no role that can give'
    }

    It 'no: says you hold none, and that an eligible role counts only when active' {
        $text = (Get-VmfConsentNotice -Rights (New-Rights -CanConsent 'no')) -join "`n"
        $text | Should -Match 'You hold no role that can give admin consent'
        $text | Should -Match 'Privileged Identity Management'
        $text | Should -Match 'activate it and run azd up again'
    }

    It 'unknown: says it could not read, and never guesses either way' {
        $text = (Get-VmfConsentNotice -Rights (New-Rights -CanConsent 'unknown')) -join "`n"
        $text | Should -Match 'could not read your Microsoft Entra roles'
        $text | Should -Match 'Privileged Identity Management'
        $text | Should -Not -Match 'You hold no role'
        $text | Should -Not -Match 'so you can give admin consent'
    }

    It 'a service principal: says a user gives it after the install, and guesses nothing' {
        $text = (Get-VmfConsentNotice -Rights (New-Rights -CanConsent 'unknown' -IsPerson $false)) -join "`n"
        $text | Should -Match 'A service principal runs this install'
        $text | Should -Not -Match 'could not read your Microsoft Entra roles'
        $text | Should -Not -Match 'Privileged Identity Management'
    }

    It 'every line is short enough to be one STE sentence or two' {
        foreach ($state in 'yes', 'no', 'unknown') {
            foreach ($line in (Get-VmfConsentNotice -Rights (New-Rights -CanConsent $state))) {
                foreach ($sentence in ($line -split '(?<=\.)\s+')) {
                    @($sentence.Trim() -split '\s+').Count | Should -BeLessOrEqual 25 -Because $sentence
                }
            }
        }
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: no consent role - Stop or Continue' {

    BeforeEach {
        Mock Test-VmfConsole { $true }
    }

    It 'Enter takes Stop, the default: the install stops before anything is created' {
        Mock Read-Host { '' }
        { Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'no') 6>$null } |
            Should -Throw '*stopped before it created anything*'
        Should -Invoke Read-Host -Times 1 -Exactly
    }

    It 'and Stop is NOT kept, so the next run asks again' {
        # Read-VmfChoice records every answer, and a recorded answer is never
        # asked again. A kept Stop would stop every later run with no question.
        Mock Read-Host { '' }
        try { Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'no') 6>$null } catch { $null = $_ }
        Get-AzdValue -Name 'VMF_CONSENT_LATER' | Should -BeNullOrEmpty
        $global:VmfTestAzdSets[-1] | Should -Be 'env set VMF_CONSENT_LATER '
    }

    It 'the Stop message names the role to come back with' {
        Mock Read-Host { '' }
        { Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'no') 6>$null } |
            Should -Throw '*Cloud Application Administrator*'
    }

    It 'Continue installs now, and says the install ends with what to send' {
        Mock Read-Host { '2' }
        $run = Invoke-Captured { Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'no') }
        $run.Out | Should -Be 'continue'
        $run.Text | Should -Match 'Stop now, or install without admin consent'
        $run.Text | Should -Match 'Stop\. .*\(default\)'
        Get-AzdValue -Name 'VMF_CONSENT_LATER' | Should -Be 'continue'
    }

    It 'an install with no console takes Continue, never Stop, and asks nothing' {
        Mock Test-VmfConsole { $false }
        Mock Read-Host { throw 'no console: nothing may be asked' }
        $run = Invoke-Captured { Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'no') }
        $run.Out | Should -Be 'continue'
        $run.Text | Should -Match 'no console'
        $run.Text | Should -Match 'ends with the link'
        Should -Invoke Read-Host -Times 0 -Exactly
        Get-AzdValue -Name 'VMF_CONSENT_LATER' | Should -Be 'continue'
    }

    It 'a Continue from an earlier install is used again, and said' {
        Mock Read-Host { throw 'a recorded answer is not asked again' }
        [Environment]::SetEnvironmentVariable('VMF_CONSENT_LATER', 'continue')
        $run = Invoke-Captured { Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'no') }
        $run.Out | Should -Be 'continue'
        $run.Text | Should -Match 'earlier install'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'a recorded value that is not Continue stops, and is cleared' {
        Mock Read-Host { throw 'a recorded answer is not asked again' }
        [Environment]::SetEnvironmentVariable('VMF_CONSENT_LATER', 'stop')
        { Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'no') 6>$null } | Should -Throw '*stopped*'
        Get-AzdValue -Name 'VMF_CONSENT_LATER' | Should -BeNullOrEmpty
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: nobody else is asked (FIRSTSCOPE-1: push, never block)' {

    BeforeEach {
        Mock Test-VmfConsole { $true }
        Mock Read-Host { throw 'this person must not be asked' }
    }

    It 'yes: no question' {
        (Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'yes' -ConsentRoles 'Global Administrator') 6>$null) |
            Should -Be 'not-asked'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'unknown: no question, because unknown is never read as no' {
        (Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'unknown') 6>$null) | Should -Be 'not-asked'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'a service principal: no question' {
        (Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'unknown' -IsPerson $false) 6>$null) |
            Should -Be 'not-asked'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'a service principal is not asked even if a reading ever said no' {
        # The reader returns unknown for a service principal today. The push
        # must not lean on that: nobody is at the console of a pipeline.
        (Invoke-VmfConsentPush -Rights (New-Rights -CanConsent 'no' -IsPerson $false) 6>$null) |
            Should -Be 'not-asked'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'and none of them records an answer' {
        foreach ($r in @((New-Rights -CanConsent 'yes'), (New-Rights -CanConsent 'unknown'),
                         (New-Rights -CanConsent 'unknown' -IsPerson $false))) {
            $null = Invoke-VmfConsentPush -Rights $r 6>$null
        }
        @($global:VmfTestAzdSets | Where-Object { $_ -match 'VMF_CONSENT_LATER' }).Count | Should -Be 0
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: Read-VmfChoice can take a different answer with no console' {

    BeforeEach { [Environment]::SetEnvironmentVariable('VMF_TEST_CHOICE', $null) }
    AfterAll { [Environment]::SetEnvironmentVariable('VMF_TEST_CHOICE', $null) }

    It 'with no console, -NoConsoleDefault wins over -Default' {
        Mock Test-VmfConsole { $false }
        $pick = Read-VmfChoice -Name 'VMF_TEST_CHOICE' -Question 'Q?' -Default 'a' -NoConsoleDefault 'b' `
            -Options @('a|A.', 'b|B.') 6>$null
        $pick | Should -Be 'b'
    }

    It 'with a console, Enter still takes -Default' {
        Mock Test-VmfConsole { $true }
        Mock Read-Host { '' }
        $pick = Read-VmfChoice -Name 'VMF_TEST_CHOICE' -Question 'Q?' -Default 'a' -NoConsoleDefault 'b' `
            -Options @('a|A.', 'b|B.') 6>$null
        $pick | Should -Be 'a'
    }

    It 'and without -NoConsoleDefault, no console takes -Default as before' {
        Mock Test-VmfConsole { $false }
        $run = Invoke-Captured { Read-VmfChoice -Name 'VMF_TEST_CHOICE' -Question 'Q?' -Default 'a' -Options @('a|A.', 'b|B.') }
        $run.Out | Should -Be 'a'
        $run.Text | Should -Match 'no console; the default is taken'
    }

    It 'Read-VmfChoice asks Test-VmfConsole, the one place that knows' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-VmfChoice' }, $true)
        "$($fn.Body)" | Should -Match 'Test-VmfConsole'
        "$($fn.Body)" | Should -Not -Match 'UserInteractive'
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: the request workflow is read, never guessed' {

    It 'on' {
        $script:answers['*adminConsentRequestPolicy*'] = '{"isEnabled":true}'
        Get-VmfConsentRequestWorkflow | Should -Be 'on'
    }

    It 'off' {
        $script:answers['*adminConsentRequestPolicy*'] = '{"isEnabled":false}'
        Get-VmfConsentRequestWorkflow | Should -Be 'off'
    }

    It 'a refused read is unknown, not off' {
        Get-VmfConsentRequestWorkflow | Should -Be 'unknown'
    }

    It 'an answer with no isEnabled is unknown, not off' {
        $script:answers['*adminConsentRequestPolicy*'] = '{"version":1}'
        Get-VmfConsentRequestWorkflow | Should -Be 'unknown'
    }

    It 'with one GET and no ampersand in the URL (CLAUDE.md: cmd eats it)' {
        $null = Get-VmfConsentRequestWorkflow
        $global:VmfTestAzCalls.Count | Should -Be 1
        $global:VmfTestAzCalls[0] | Should -Match '--method GET'
        $global:VmfTestAzCalls[0] | Should -Not -Match '&'
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: the admin consent link' {

    It 'is Microsoft''s tenant-wide admin consent URL for the dashboard registration' {
        # learn.microsoft.com/entra/identity/enterprise-apps/grant-admin-consent,
        # "Construct the URL for granting tenant-wide admin consent".
        Get-VmfAdminConsentUrl -TenantId $script:tenant -ClientId $script:client |
            Should -Be "https://login.microsoftonline.com/$($script:tenant)/adminconsent?client_id=$($script:client)"
    }

    It 'is made only from ids, so nothing else can reach the URL' {
        Get-VmfAdminConsentUrl -TenantId 'contoso.example.com' -ClientId $script:client | Should -BeNullOrEmpty
        Get-VmfAdminConsentUrl -TenantId $script:tenant -ClientId '' | Should -BeNullOrEmpty
        Get-VmfAdminConsentUrl -TenantId $script:tenant -ClientId "$($script:client)&prompt=x" | Should -BeNullOrEmpty
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: the hand-off at the end of the install' {

    BeforeAll {
        $script:handoff = {
            param($CanConsent, $Workflow, $Client = $script:client)
            (Get-VmfConsentHandoff -CanConsent $CanConsent -Workflow $Workflow -TenantId $script:tenant `
                -ClientId $Client -RegistrationName 'vmf-dashboard-example') -join "`n"
        }
        $script:url = "https://login.microsoftonline.com/$($script:tenant)/adminconsent?client_id=$($script:client)"
    }

    It 'workflow on: the request from the Admin page comes first, and the link is there too' {
        $text = & $script:handoff 'no' 'on'
        $text | Should -Match 'admin consent request workflow on'
        $text | Should -Match 'Request approval'
        $text | Should -Match 'Admin consent requests'
        $text | Should -Match ([regex]::Escape($script:url))
        $text.IndexOf('Request approval') | Should -BeLessThan $text.IndexOf($script:url)
    }

    It 'workflow off: the link, and no request it cannot make' {
        $text = & $script:handoff 'no' 'off'
        $text | Should -Match ([regex]::Escape($script:url))
        $text | Should -Not -Match 'Request approval'
        $text | Should -Match 'Send this link to a person who holds'
    }

    It 'workflow unknown: says it could not read it, and gives the link' {
        $text = & $script:handoff 'unknown' 'unknown'
        $text | Should -Match 'could not read if your directory has the admin consent request workflow on'
        $text | Should -Match ([regex]::Escape($script:url))
    }

    It 'names the role to send it to' {
        (& $script:handoff 'no' 'off') | Should -Match 'Cloud Application Administrator'
    }

    It 'yes: you give it yourself, with the link' {
        $text = & $script:handoff 'yes' 'off'
        $text | Should -Match 'You hold a role that can give admin consent'
        $text | Should -Match ([regex]::Escape($script:url))
        $text | Should -Not -Match 'Send this link'
    }

    It 'with no recorded id: no link, and the Microsoft Entra admin center route by name' {
        $text = & $script:handoff 'no' 'off' ''
        $text | Should -Not -Match 'adminconsent'
        $text | Should -Match 'could not make the link'
        $text | Should -Match 'vmf-dashboard-example'
        $text | Should -Match 'Grant admin consent'
    }

    It 'never hands anybody a command to run (rule 12)' {
        foreach ($c in 'yes', 'no', 'unknown') {
            foreach ($w in 'on', 'off', 'unknown') {
                foreach ($line in ((& $script:handoff $c $w) -split "`n")) {
                    $line.Trim() | Should -Not -Match '^(az|azd|Connect-MgGraph|pwsh)\b'
                }
            }
        }
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: the hooks use it' {

    BeforeAll {
        $script:preAst = [System.Management.Automation.Language.Parser]::ParseFile($script:prePath, [ref]$null, [ref]$null)
        $script:postCode = Get-VmfCodeOnly -Path $script:postPath
        function script:Get-FirstCallOffset {
            param($Ast, [string]$Pattern)
            $hit = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$n" -match $Pattern }, $true) |
                Sort-Object { $_.Extent.StartOffset })
            if ($hit.Count) { $hit[0].Extent.StartOffset } else { -1 }
        }
    }

    It 'preprovision says it and asks it BEFORE anything is created' {
        $notice = Get-FirstCallOffset $script:preAst '^Get-VmfConsentNotice'
        $push   = Get-FirstCallOffset $script:preAst '^Invoke-VmfConsentPush'
        $group  = Get-FirstCallOffset $script:preAst '^az group create'
        $plan   = Get-FirstCallOffset $script:preAst "^Read-VmfChoice -Name 'VMF_HOSTING_PLAN'"
        $notice | Should -BeGreaterThan 0
        $push | Should -BeGreaterThan $notice
        $group | Should -BeGreaterThan 0
        $push | Should -BeLessThan $group
        $push | Should -BeLessThan $plan -Because 'a Stop must not leave answers recorded for nothing'
    }

    It 'postprovision gives the hand-off, with the workflow and the tenant read, and no az command' {
        # CONSENT-DONE-CHECK-1: through Get-VmfConsentClosing, which gives the
        # hand-off unless admin consent is given (ConsentDoneCheck.Tests.ps1).
        $script:postCode | Should -Match 'Get-VmfConsentClosing'
        $script:postCode | Should -Match 'Get-VmfConsentRequestWorkflow'
        $script:postCode | Should -Match 'tenantId'
        $script:postCode | Should -Not -Match 'az ad app permission admin-consent'
    }

    It 'postprovision reads the directory only for a person (CD-1)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:postPath, [ref]$null, [ref]$null)
        $call = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$n" -match '^Get-VmfConsentRequestWorkflow' }, $true)
        $call | Should -Not -BeNullOrEmpty
        $node = $call.Parent; $guard = $null
        while ($node) {
            if ($node -is [System.Management.Automation.Language.IfStatementAst]) { $guard = $node; break }
            $node = $node.Parent
        }
        $guard | Should -Not -BeNullOrEmpty
        "$($guard.Clauses[0].Item1)" | Should -Match 'IsPerson|installerIsPerson'
    }
}

Describe 'INSTALL-CONSENT-PUSH-1: the manual says it first' {

    BeforeAll {
        $m = Join-Path $script:repoRoot 'docs' 'manual'
        $script:beforeYou = Get-Content (Join-Path $m 'install' 'before-you-install.md') -Raw
        $script:choicesMd = Get-Content (Join-Path $m 'install' 'choices.md') -Raw
        $script:signInMd  = Get-Content (Join-Path $m 'use' 'sign-in.md') -Raw
    }

    It 'before-you-install asks for the role as a requirement for the full product, and recommends the least one' {
        $script:beforeYou | Should -Match '(?i)For the full product, a directory role that can give admin consent'
        $script:beforeYou | Should -Match 'Use \*\*Cloud Application Administrator\*\*'
        $script:beforeYou | Should -Match '(?i)you can still install, assess and migrate'
        $script:beforeYou | Should -Match 'Privileged Identity Management'
    }

    It 'choices describes Stop and Continue, with Stop as the default and Continue with no console' {
        $script:choicesMd | Should -Match '(?i)stop now, or install without admin consent'
        $script:choicesMd | Should -Match '(?s)\*\*Stop\.\*\* This is the default'
        $script:choicesMd | Should -Match '(?i)with no console continues'
        $script:choicesMd | Should -Match '(?i)admin consent request workflow'
        $script:choicesMd | Should -Match '(?i)cannot read your roles.*does not guess'
    }

    It 'sign-in gives the request workflow and the link, and no command' {
        $script:signInMd | Should -Match 'Request approval'
        $script:signInMd | Should -Match '(?i)The install prints a link'
        $script:signInMd | Should -Not -Match '(?i)prints the command'
    }

    It 'every page names the same roles as the rights reader' {
        foreach ($page in $script:beforeYou, $script:choicesMd, $script:signInMd) {
            foreach ($role in $script:allRoles) { $page | Should -Match ([regex]::Escape($role)) }
        }
    }
}
}
