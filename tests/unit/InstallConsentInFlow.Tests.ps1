#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-CONSENT-IN-FLOW-1: a person who CAN give admin consent is asked once,
# during azd up, and the install gives it as that person.
#
# Found 2026-11-16, before the final lab: a Global Administrator should give
# the admin consent during azd up, as part of the flow, and the install did
# not. CONSENT-1 (2026-09-09) had decided the opposite: the
# install granted nothing and ended with a link, also for a Global
# Administrator who could have approved it there and then.
#
# The functions are CALLED here with az and azd stubbed out, never only read.
# The az stub is a small directory: it keeps the grants, a POST adds one and a
# PATCH changes one, so the read back sees what the grant wrote - or, when a
# test says so, does not.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:rightsPath = Join-Path $script:repoRoot 'infra' 'Resolve-VmfInstallerRights.ps1'
    $script:postPath   = Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1'
    . (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1')
    . $script:rightsPath

    # Placeholder ids only (rule 13): no real tenant, application or person.
    $script:client   = '11111111-2222-3333-4444-555555555555'
    $script:clientSp = '22222222-0000-0000-0000-000000000001'
    $script:graphSp  = '22222222-0000-0000-0000-000000000002'
    $script:armSp    = '22222222-0000-0000-0000-000000000003'
    $script:graphApp = '00000003-0000-0000-c000-000000000000'
    $script:armApp   = '797f4846-ba00-4fd7-ba43-dac1f8f63013'
    $script:graphAll = @('AppRoleAssignment.ReadWrite.All', 'Application.Read.All', 'User.ReadBasic.All', 'Group.Read.All')

    function global:az {
        $joined = $args -join ' '
        $global:VmfTestAzCalls += , $joined
        $global:LASTEXITCODE = 0
        if ($joined -like 'rest --method POST *' -or $joined -like 'rest --method PATCH *') {
            $bodyArg = @($args | Where-Object { "$_" -like '@*' }) | Select-Object -First 1
            $body = $null
            if ($bodyArg) { $body = Get-Content -LiteralPath ([string]$bodyArg).Substring(1) -Raw | ConvertFrom-Json }
            $global:VmfTestWrites += , [pscustomobject]@{ Call = $joined; Body = $body }
            if ($global:VmfTestWriteFails) {
                $global:LASTEXITCODE = 1
                return 'ERROR: Insufficient privileges to complete the operation.'
            }
            if ($global:VmfTestWritesLost) { return $null }
            if ($body -and $global:VmfTestLoseResource -and $body.resourceId -eq $global:VmfTestLoseResource) { return $null }
            if ($joined -like 'rest --method POST --url https://graph.microsoft.com/v1.0/oauth2PermissionGrants *') {
                $global:VmfTestGrantCount++
                $global:VmfTestGrants += , @{ id = "grant-new-$($global:VmfTestGrantCount)"; clientId = $body.clientId
                    consentType = $body.consentType; resourceId = $body.resourceId; scope = $body.scope; principalId = $null }
            }
            elseif ($joined -match 'oauth2PermissionGrants/(\S+) ') {
                $id = $Matches[1]
                foreach ($g in $global:VmfTestGrants) { if ($g.id -eq $id) { $g.scope = $body.scope } }
            }
            return $null
        }
        if ($joined -like "ad app permission list-grants --id $($script:client)*") {
            if ($global:VmfTestGrantReadFails) { $global:LASTEXITCODE = 1; return $null }
            if ($global:VmfTestLateReads -gt 0 -and $global:VmfTestWrites.Count -gt 0) { $global:VmfTestLateReads--; return '[]' }
            return (ConvertTo-Json -Compress -Depth 4 -InputObject @($global:VmfTestGrants))
        }
        if ($joined -match "^ad sp list --filter appId eq '([0-9a-f-]+)'") {
            $sp = $global:VmfTestSps[$Matches[1]]
            if ($sp -eq 'FAIL') { $global:LASTEXITCODE = 1; return $null }
            if (-not $sp) { return '[]' }
            return (ConvertTo-Json -Compress -InputObject @(@{ id = $sp; appId = $Matches[1] }))
        }
        $global:LASTEXITCODE = 1
        $null
    }
    function global:azd {
        $global:VmfTestAzdSets += , ($args -join ' ')
        $global:LASTEXITCODE = 0
    }

    function script:New-Rights {
        param([string]$CanConsent, [bool]$IsPerson = $true, [string[]]$ConsentRoles = @('Global Administrator'))
        [pscustomobject]@{ IsPerson = $IsPerson; CanGrant = 'yes'; CanConsent = $CanConsent
                           GrantRoles = @('Owner'); ConsentRoles = $ConsentRoles }
    }
    function script:New-Grant {
        param([string]$Id, [string]$ResourceId, [string]$Scope, [string]$ConsentType = 'AllPrincipals', [string]$Principal = $null)
        @{ id = $Id; clientId = $script:clientSp; consentType = $ConsentType; resourceId = $ResourceId; scope = $Scope; principalId = $Principal }
    }
    function script:Read-State { Get-VmfAdminConsentState -ClientId $script:client }
    # Runs the step and splits what it RETURNED from what it PRINTED.
    function script:Invoke-Step {
        param($Rights, $Consent = (Read-State), [string]$ClientId = $script:client)
        $all = @(Invoke-VmfAdminConsentInFlow -Rights $Rights -Consent $Consent -ClientId $ClientId 6>&1)
        [pscustomobject]@{
            Out  = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }) | Select-Object -First 1
            Text = (@($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                    ForEach-Object { [string]$_.MessageData }) -join "`n")
        }
    }
    function script:Get-PostWrites { @($global:VmfTestWrites | Where-Object { $_.Call -like 'rest --method POST *' }) }
    function script:Get-PatchWrites { @($global:VmfTestWrites | Where-Object { $_.Call -like 'rest --method PATCH *' }) }
}

Describe 'INSTALL-CONSENT-IN-FLOW-1' {

AfterAll {
    Remove-Item 'function:\az' -ErrorAction SilentlyContinue
    Remove-Item 'function:\azd' -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('VMF_ADMIN_CONSENT', $null)
    Remove-Variable -Scope Global -Name VmfTestAzCalls, VmfTestAzdSets, VmfTestWrites, VmfTestGrants, VmfTestSps,
        VmfTestWriteFails, VmfTestWritesLost, VmfTestGrantReadFails, VmfTestGrantCount, VmfTestLoseResource, VmfTestLateReads -ErrorAction SilentlyContinue
}

BeforeEach {
    $global:VmfTestAzCalls = @()
    $global:VmfTestAzdSets = @()
    $global:VmfTestWrites = @()
    $global:VmfTestGrants = @()
    $global:VmfTestGrantCount = 0
    $global:VmfTestWriteFails = $false
    $global:VmfTestWritesLost = $false
    $global:VmfTestGrantReadFails = $false
    $global:VmfTestLoseResource = $null
    $global:VmfTestLateReads = 0
    $global:VmfTestSps = @{ $script:client = $script:clientSp; $script:graphApp = $script:graphSp; $script:armApp = $script:armSp }
    [Environment]::SetEnvironmentVariable('VMF_ADMIN_CONSENT', $null)
    Mock Start-Sleep { }
    Mock Test-VmfConsole { $true }
    Mock Read-Host { '' }
}

Describe 'INSTALL-CONSENT-IN-FLOW-1: a person who can give admin consent' {

    It 'not given: asks once, gives admin consent, and the read back is given' {
        $run = Invoke-Step (New-Rights 'yes')
        Should -Invoke Read-Host -Times 1 -Exactly
        $run.Text | Should -Match 'Give admin consent for your organization now\?'
        $run.Text | Should -Match 'Yes\. .*\(default\)'
        $run.Out.State | Should -Be 'given'
        (Read-State).State | Should -Be 'given'
        Get-AzdValue -Name 'VMF_ADMIN_CONSENT' | Should -Be 'yes'
    }

    It 'the closing then says the organization has admin consent, with no link' {
        $run = Invoke-Step (New-Rights 'yes')
        $text = (Get-VmfConsentClosing -Consent $run.Out -CanConsent 'yes' -Workflow 'off' `
            -TenantId '00000000-0000-0000-0000-000000000000' -ClientId $script:client) -join "`n"
        $text | Should -Match 'Your organization has admin consent for the product'
        $text | Should -Not -Match 'adminconsent'
    }

    It 'grants every delegated permission the dashboard registration asks, organization-wide, one grant per API' {
        $null = Invoke-Step (New-Rights 'yes')
        $posts = @(Get-PostWrites)
        $posts.Count | Should -Be 2
        foreach ($w in $posts) {
            $w.Body.clientId | Should -Be $script:clientSp
            $w.Body.consentType | Should -Be 'AllPrincipals'
        }
        $graph = @($posts | Where-Object { $_.Body.resourceId -eq $script:graphSp })
        @(([string]$graph[0].Body.scope) -split ' ' | Sort-Object) | Should -Be @($script:graphAll | Sort-Object)
        $arm = @($posts | Where-Object { $_.Body.resourceId -eq $script:armSp })
        $arm[0].Body.scope | Should -Be 'user_impersonation'
    }

    It 'partial before: adds only what is missing to the grant that is there, and keeps its other scopes' {
        $global:VmfTestGrants = @(
            (New-Grant 'g-graph' $script:graphSp 'AppRoleAssignment.ReadWrite.All Application.Read.All User.ReadBasic.All openid'),
            (New-Grant 'g-arm' $script:armSp 'user_impersonation'))
        $run = Invoke-Step (New-Rights 'yes')
        @(Get-PostWrites).Count | Should -Be 0
        $patch = @(Get-PatchWrites)
        $patch.Count | Should -Be 1
        $patch[0].Call | Should -Match 'oauth2PermissionGrants/g-graph '
        @(([string]$patch[0].Body.scope) -split ' ' | Sort-Object) |
            Should -Be @(($script:graphAll + 'openid') | Sort-Object)
        $run.Out.State | Should -Be 'given'
    }

    It 'a grant a user gave for themselves is never changed: an organization-wide one is added' {
        $global:VmfTestGrants = @((New-Grant 'g-me' $script:graphSp ($script:graphAll -join ' ') 'Principal' '33333333-0000-0000-0000-00000000000a'))
        $null = Invoke-Step (New-Rights 'yes')
        @(Get-PatchWrites).Count | Should -Be 0
        @(Get-PostWrites).Count | Should -Be 2
    }

    It 'no console: takes yes, the default, and gives admin consent' {
        Mock Test-VmfConsole { $false }
        Mock Read-Host { throw 'no console: nothing may be asked' }
        $run = Invoke-Step (New-Rights 'yes')
        Should -Invoke Read-Host -Times 0 -Exactly
        $run.Text | Should -Match 'no console'
        $run.Out.State | Should -Be 'given'
    }

    It 'a recorded yes is not asked again, and still gives admin consent when it is not given' {
        [Environment]::SetEnvironmentVariable('VMF_ADMIN_CONSENT', 'yes')
        $run = Invoke-Step (New-Rights 'yes')
        Should -Invoke Read-Host -Times 0 -Exactly
        $run.Out.State | Should -Be 'given'
    }

    It 'no: gives nothing, and the closing keeps the link' {
        Mock Read-Host { '2' }
        $run = Invoke-Step (New-Rights 'yes')
        $global:VmfTestWrites.Count | Should -Be 0
        $run.Out.State | Should -Be 'none'
        Get-AzdValue -Name 'VMF_ADMIN_CONSENT' | Should -Be 'no'
        $text = (Get-VmfConsentClosing -Consent $run.Out -CanConsent 'yes' -Workflow 'off' `
            -TenantId '00000000-0000-0000-0000-000000000000' -ClientId $script:client) -join "`n"
        $text | Should -Match 'adminconsent'
    }
}

Describe 'INSTALL-CONSENT-IN-FLOW-1: only given is given (the read back)' {

    It 'the grant is sent but the directory shows only part: partial, and the hand-off' {
        # The Microsoft Graph grant is written; the Azure Service Management one is lost.
        $global:VmfTestLoseResource = $script:armSp
        $run = Invoke-Step (New-Rights 'yes')
        $run.Out.State | Should -Be 'partial'
        $run.Text | Should -Match 'does not show it for every permission'
        $text = (Get-VmfConsentClosing -Consent $run.Out -CanConsent 'yes' -Workflow 'off' `
            -TenantId '00000000-0000-0000-0000-000000000000' -ClientId $script:client) -join "`n"
        $text | Should -Match 'One directory action is left'
        $text | Should -Match 'adminconsent'
        $text | Should -Not -Match 'Your organization has admin consent'
    }

    It 'the directory shows nothing after the grant: reads again a fixed number of times, then hands off' {
        $global:VmfTestWritesLost = $true
        $run = Invoke-Step (New-Rights 'yes')
        $run.Out.State | Should -Be 'none'
        $reads = @($global:VmfTestAzCalls | Where-Object { $_ -like 'ad app permission list-grants*' }).Count
        $reads | Should -BeGreaterThan 2
        $reads | Should -BeLessOrEqual 10
    }

    It 'the directory shows it on a later read: given' {
        # Microsoft Entra ID can show a new grant a few seconds late.
        $global:VmfTestLateReads = 2
        $run = Invoke-Step (New-Rights 'yes')
        $run.Out.State | Should -Be 'given'
        $global:VmfTestLateReads | Should -Be 0
    }
    It 'the grant command fails: the install continues, says why, and the closing keeps the hand-off' {
        $global:VmfTestWriteFails = $true
        $run = $null
        { $script:run = Invoke-Step (New-Rights 'yes') } | Should -Not -Throw
        $script:run.Out.State | Should -Not -Be 'given'
        $script:run.Text | Should -Match 'The install could not give admin consent'
        $script:run.Text | Should -Match 'Insufficient privileges'
        $text = (Get-VmfConsentClosing -Consent $script:run.Out -CanConsent 'yes' -Workflow 'off' `
            -TenantId '00000000-0000-0000-0000-000000000000' -ClientId $script:client) -join "`n"
        $text | Should -Match 'adminconsent'
    }

    It 'the grants cannot be read: the install continues, and nothing is called given' {
        $global:VmfTestGrantReadFails = $true
        $consent = Read-State
        $consent.State | Should -Be 'unknown'
        $run = Invoke-Step (New-Rights 'yes') $consent
        $run.Out.State | Should -Be 'unknown'
        $global:VmfTestWrites.Count | Should -Be 0
        $run.Text | Should -Match 'The install could not give admin consent'
    }

    It 'the dashboard has no service principal: the install continues and gives nothing' {
        $global:VmfTestSps.Remove($script:client)
        $run = Invoke-Step (New-Rights 'yes')
        $global:VmfTestWrites.Count | Should -Be 0
        $run.Out.State | Should -Not -Be 'given'
        $run.Text | Should -Match 'The install could not give admin consent'
    }
}

Describe 'INSTALL-CONSENT-IN-FLOW-1: who is not asked' {

    It 'already given: no question and no write' {
        $global:VmfTestGrants = @(
            (New-Grant 'g-graph' $script:graphSp ($script:graphAll -join ' ')),
            (New-Grant 'g-arm' $script:armSp 'user_impersonation'))
        $run = Invoke-Step (New-Rights 'yes')
        Should -Invoke Read-Host -Times 0 -Exactly
        $global:VmfTestWrites.Count | Should -Be 0
        $global:VmfTestAzdSets.Count | Should -Be 0
        $run.Out.State | Should -Be 'given'
        $run.Text | Should -BeNullOrEmpty
    }

    It '<CanConsent>, a person: no question, no write, and the consent it read is passed on' -ForEach @(
        @{ CanConsent = 'no' }, @{ CanConsent = 'unknown' }) {
        $consent = Read-State
        $run = Invoke-Step (New-Rights $CanConsent) $consent
        Should -Invoke Read-Host -Times 0 -Exactly
        $global:VmfTestWrites.Count | Should -Be 0
        $global:VmfTestAzdSets.Count | Should -Be 0
        $run.Out | Should -Be $consent
    }

    It 'a service principal: no question and no write, also when its rights read yes' {
        Mock Test-VmfConsole { $false }
        $run = Invoke-Step (New-Rights 'yes' -IsPerson $false) $null
        $global:VmfTestWrites.Count | Should -Be 0
        $global:VmfTestAzdSets.Count | Should -Be 0
        $run.Out | Should -BeNullOrEmpty
    }

    It 'no recorded dashboard application id: no question it cannot act on' {
        foreach ($id in '', 'vmf-dashboard-example') {
            $run = Invoke-Step (New-Rights 'yes') ([pscustomobject]@{ State = 'unknown'; Missing = @(); People = 0 }) $id
            $run.Out.State | Should -Be 'unknown'
        }
        Should -Invoke Read-Host -Times 0 -Exactly
        $global:VmfTestWrites.Count | Should -Be 0
    }
}

Describe 'INSTALL-CONSENT-IN-FLOW-1: how it writes' {

    It 'as the signed-in user through Microsoft Graph, one URL with no query string (no ampersand through cmd)' {
        $global:VmfTestGrants = @((New-Grant 'g-graph' $script:graphSp 'Application.Read.All'))
        $null = Invoke-Step (New-Rights 'yes')
        $global:VmfTestWrites.Count | Should -BeGreaterThan 1
        foreach ($w in $global:VmfTestWrites) {
            $w.Call | Should -Match '^rest --method (POST|PATCH) --url https://graph\.microsoft\.com/v1\.0/oauth2PermissionGrants(/[A-Za-z0-9_-]+)? '
            $w.Call | Should -Not -Match '[?&]'
        }
    }

    It 'never the portal admin-consent command, never a secret, never a service principal sign-in' {
        $code = Get-VmfCodeOnly -Path $script:rightsPath
        $code | Should -Not -Match 'admin-consent'
        $code | Should -Not -Match 'main\.iam\.ad\.ext\.azure\.com'
        $code | Should -Not -Match '(?i)--service-principal|client[-_]?secret|--password'
    }

    It 'a grant id that is not a plain Microsoft Graph id is never put in a URL' {
        $global:VmfTestGrants = @((New-Grant 'g&x=1' $script:graphSp 'Application.Read.All'))
        $run = Invoke-Step (New-Rights 'yes')
        @(Get-PatchWrites).Count | Should -Be 0
        $run.Text | Should -Match 'The install could not give admin consent'
    }

    It 'the body file is removed after each write' {
        $null = Invoke-Step (New-Rights 'yes')
        foreach ($w in $global:VmfTestWrites) {
            $file = ([regex]::Match($w.Call, '@(\S+)')).Groups[1].Value
            $file | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $file | Should -BeFalse
        }
    }

    It 'grants only delegated permissions, because the registration asks for no application permission' {
        # INSTALL-CONSENT-PUSH-1's test holds this flag to identity.bicep. If
        # the dashboard ever asks for a Microsoft Graph app role, this grant
        # does not cover it, and the step refuses rather than claim it did.
        $was = $script:VmfProductAsksGraphAppRoles
        try {
            $script:VmfProductAsksGraphAppRoles = $true
            $run = Invoke-Step (New-Rights 'yes')
            $global:VmfTestWrites.Count | Should -Be 0
            $run.Text | Should -Match 'The install could not give admin consent'
        }
        finally { $script:VmfProductAsksGraphAppRoles = $was }
    }
}

Describe 'INSTALL-CONSENT-IN-FLOW-1: the words' {

    It 'the question lists every permission it approves, by API, from the one list' {
        $run = Invoke-Step (New-Rights 'yes' -ConsentRoles 'Global Administrator')
        $run.Text | Should -Match 'You hold Global Administrator, so you can give admin consent'
        $run.Text | Should -Match 'Microsoft Graph: AppRoleAssignment\.ReadWrite\.All, Application\.Read\.All, User\.ReadBasic\.All, Group\.Read\.All'
        $run.Text | Should -Match 'Azure Service Management: user_impersonation'
    }

    It 'every sentence it prints is short enough for STE' {
        $global:VmfTestWriteFails = $true
        $texts = @((Invoke-Step (New-Rights 'yes')).Text)
        $global:VmfTestWriteFails = $false
        [Environment]::SetEnvironmentVariable('VMF_ADMIN_CONSENT', $null)
        $global:VmfTestWritesLost = $true
        $texts += (Invoke-Step (New-Rights 'yes')).Text
        foreach ($line in ($texts -join "`n") -split "`n") {
            if ($line -match 'Insufficient privileges|: AppRole|: user_imp') { continue }
            foreach ($sentence in ($line -split '(?<=\.)\s+')) {
                @($sentence.Trim() -split '\s+').Count | Should -BeLessOrEqual 25 -Because $sentence
            }
        }
    }

    It 'preprovision''s notice says the install asks to give it' {
        $text = (Get-VmfConsentNotice -Rights (New-Rights 'yes' -ConsentRoles 'Global Administrator')) -join "`n"
        $text | Should -Match 'it asks to give admin consent for your organization'
        $text | Should -Not -Match 'The end of the install shows how'
    }
}

Describe 'INSTALL-CONSENT-IN-FLOW-1: the manual says it' {

    BeforeAll {
        $m = Join-Path $script:repoRoot 'docs' 'manual'
        $script:choicesMd = Get-Content (Join-Path $m 'install' 'choices.md') -Raw
        $script:updateMd  = Get-Content (Join-Path $m 'install' 'update.md') -Raw
        $script:stepsMd   = Get-Content (Join-Path $m 'install' 'step-by-step.md') -Raw
    }

    It 'choices gives the question, Yes as the default also with no console, the read back, and the recorded value' {
        $script:choicesMd | Should -Match 'Give admin consent for your organization now\?'
        $script:choicesMd | Should -Match '\*\*Yes\.\*\* This is the default'
        $script:choicesMd | Should -Match '(?i)no console takes Yes'
        $script:choicesMd | Should -Match '(?i)reads the admin consent again'
        $script:choicesMd | Should -Match 'VMF_ADMIN_CONSENT'
        $script:choicesMd | Should -Not -Match 'admin consent, if you cannot give it'
    }

    It 'update lists the recorded value, and step by step lists the step' {
        $script:updateMd | Should -Match '\| `VMF_ADMIN_CONSENT` \|'
        $script:stepsMd | Should -Match '(?i)asks to give it\. If you answer Yes, it gives admin consent as you'
    }
}
Describe 'INSTALL-CONSENT-IN-FLOW-1: postprovision runs it' {

    BeforeAll {
        $script:postAst = [System.Management.Automation.Language.Parser]::ParseFile($script:postPath, [ref]$null, [ref]$null)
        function script:Find-Call {
            param([string]$Pattern)
            $script:postAst.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$n" -match $Pattern }, $true)
        }
    }

    It 'for a person only, after the consent read and before the closing, and the closing gets what it read back' {
        $step = Find-Call '^Invoke-VmfAdminConsentInFlow'
        $step | Should -Not -BeNullOrEmpty
        "$step" | Should -Match '-Rights \$rights\b'
        "$step" | Should -Match '-Consent \$consent\b'
        "$step" | Should -Match '-ClientId \$dashboardAppId\b'
        "$($step.Parent.Parent)" | Should -Match '^\$consent = '
        $node = $step.Parent; $guard = $null
        while ($node) {
            if ($node -is [System.Management.Automation.Language.IfStatementAst]) { $guard = $node; break }
            $node = $node.Parent
        }
        "$($guard.Clauses[0].Item1)" | Should -Match 'installerIsPerson'
        $read = Find-Call '^Get-VmfAdminConsentState'
        $closing = Find-Call '^Get-VmfConsentClosing'
        $step.Extent.StartOffset | Should -BeGreaterThan $read.Extent.StartOffset
        $step.Extent.StartOffset | Should -BeLessThan $closing.Extent.StartOffset
    }

    It 'the rights it passes are the ones the consent role was read from' {
        $rightsCall = Find-Call '^Get-VmfInstallerRights'
        "$($rightsCall.Parent.Parent)" | Should -Match '^\$rights = '
    }
}
}
