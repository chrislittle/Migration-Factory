#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# HEALTH-1 - one command that says whether a deployed install actually works.
#
# A day went into finding defects by clicking, on a subscription only one user
# can reach, because nothing in this repository can talk to Azure or Entra.
# Clicking through every page to find each defect does not scale.
#
# The two pieces with any logic in them are tested here. The rest of the script
# is `az` calls and a table, and pretending a unit test covers those would be
# the thing this project keeps catching itself doing.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:path = Join-Path $script:repoRoot 'tools' 'Test-VmfHealth.ps1'
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:code = Get-VmfCodeOnly -Path $script:path

    # The two functions, lifted out rather than run - the script itself needs a
    # resource group and a subscription.
    $text = Get-Content $script:path -Raw
    foreach ($name in @('ConvertFrom-VmfTokenPayload', 'Test-VmfRegistrationMatch', 'Get-VmfAuthPolicyVerdict', 'Get-VmfPerimeterVerdict', 'Get-VmfReachVerdict', 'Get-VmfCapabilityVerdict')) {
        $fn = [regex]::Match($text, "(?s)function $name \{.*?\n\}").Value
        if (-not $fn) { throw "could not lift $name" }
        . ([scriptblock]::Create($fn))
    }
}

Describe 'HEALTH-1: the registration comparison, which is the point of the script' {

    It 'two that agree is a match' {
        Test-VmfRegistrationMatch -DashboardAppId 'abc' -ServiceAppId 'abc' | Should -Be 'MATCH'
    }

    It 'two that differ is a MISMATCH - the HTTP 401 nobody could see' {
        Test-VmfRegistrationMatch -DashboardAppId 'abc' -ServiceAppId 'xyz' | Should -Be 'MISMATCH'
    }

    It 'a missing half is UNKNOWN, never a match' {
        # Two empty strings are equal. Reporting that as "they agree" would be
        # the check passing on the case where it read nothing.
        Test-VmfRegistrationMatch -DashboardAppId '' -ServiceAppId '' | Should -Be 'UNKNOWN'
        Test-VmfRegistrationMatch -DashboardAppId 'abc' -ServiceAppId '' | Should -Be 'UNKNOWN'
        Test-VmfRegistrationMatch -DashboardAppId '' -ServiceAppId 'abc' | Should -Be 'UNKNOWN'
    }
}

Describe 'HEALTH-1: reading the roles out of a real token' {

    BeforeAll {
        function New-TestToken {
            param($Payload)
            $json = $Payload | ConvertTo-Json -Compress
            $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
            # base64URL: the two swapped characters, and no padding.
            $b64url = $b64.Replace('+', '-').Replace('/', '_').TrimEnd('=')
            "header.$b64url.signature"
        }
    }

    It 'reads the roles claim' {
        $t = New-TestToken -Payload @{ roles = @('Vmf.Admin'); aud = 'api://abc' }
        $claims = ConvertFrom-VmfTokenPayload -Token $t
        @($claims.roles) | Should -Be @('Vmf.Admin')
    }

    It 'a token with no roles claim reads as no roles, not as a failure' {
        # @($claims.roles) is NOT the way to count this: an absent claim is
        # $null, and @($null) has ONE element. The script said OK for a token
        # carrying no role at all until this test failed.
        $claims = ConvertFrom-VmfTokenPayload -Token (New-TestToken -Payload @{ aud = 'api://abc' })
        $claims | Should -Not -BeNullOrEmpty
        @($claims.roles | Where-Object { $_ }).Count | Should -Be 0
        # And the script counts it the same way.
        $script:code | Should -Match 'Where-Object \{ \$_ \}\)'
    }

    It 'every padding length decodes' {
        # base64url drops the padding, so the length modulo 4 decides what has
        # to be put back. Getting this wrong fails on SOME tokens only, which
        # is the kind of fault that looks like an outage.
        foreach ($n in 1..12) {
            $payload = @{ roles = @('Vmf.Admin'); pad = ('x' * $n) }
            $claims = ConvertFrom-VmfTokenPayload -Token (New-TestToken -Payload $payload)
            $claims | Should -Not -BeNullOrEmpty -Because "a payload padded by $n characters must decode"
            [string]$claims.pad | Should -Be ('x' * $n)
        }
    }

    It 'rubbish is $null rather than an exception' {
        # It runs inside a check. A malformed token must produce a row, not a
        # stack trace that hides every row after it.
        ConvertFrom-VmfTokenPayload -Token 'not-a-token' | Should -BeNullOrEmpty
        ConvertFrom-VmfTokenPayload -Token 'a.!!!!.c' | Should -BeNullOrEmpty
    }
}

Describe 'HEALTH-1: the script reads and never writes' {

    It 'calls no az verb that changes anything' {
        # A person runs this when they already do not trust what they are
        # seeing. It must not be able to make things worse.
        $writes = foreach ($line in ($script:code -split "`n")) {
            if ($line -match '\baz\b' -and $line -match '\b(create|delete|update|set|assign|purge|remove|restart|deploy)\b') {
                $line.Trim()
            }
        }
        @($writes) | Should -BeNullOrEmpty
    }

    It 'asks for the API token the browser asks for' {
        # The row no other check can do: the CLI is pre-authorised on the API
        # (infra/identity.bicep), so this gets the SAME token the dashboard
        # gets, and can tell "you have no role" apart from "the service refused
        # your token".
        $script:code | Should -Match 'get-access-token'
        # --scope, not --resource: --resource returns a v1.0 token whose issuer
        # the service refuses, with a message that reads like a role refusal.
        # Measured on a real install.
        $script:code | Should -Match "'--scope'"
        $script:code | Should -Match 'access_as_user'
        $script:code | Should -Not -Match "'--resource'" 
        $identity = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        $identity | Should -Match 'preAuthorizedApplications'
        $identity | Should -Match 'azCliClientId'
    }

    It 'a refused call shows what the service SAID, not just the code' {
        # The service's own 403 names the roles it required and the roles it
        # saw. Swallowing that cost an evening: the table said "your role does
        # not allow this" while Entra said Vmf.Admin.
        $script:code | Should -Match 'Get-VmfBodyText'
        $script:code | Should -Match 'function Get-VmfBodyText'
    }

    It 'names the mismatch as the cause of a 401, because that is the lesson' {
        $script:code | Should -Match '(?s)MISMATCH.*401'
    }

    It 'looks for the service in the FUNCTION app list' {
        # MEASURED on a real install: the first version used
        # `az webapp list`, which does not return function apps, and reported a
        # healthy platform as missing its service. Grant-VmfAccess.ps1 had it
        # right all along.
        $script:code | Should -Match "'functionapp', 'list'"
        # ID-ADDRESS-1 part 3: by the product's prefix, and two that match are refused.
        $script:code | Should -Match '''functionapp'', ''list'', ''-g'', \$ResourceGroup\)\) -Exact \$FacadeName `\s+-Prefix ''vmf-facade'''
        # And the dashboard IS a web app, so both lists are read.
        $script:code | Should -Match "'webapp', 'list'"
    }

    It 'and does not filter with a bracket query' {
        # CLAUDE.md: PowerShell hands `--query "[?...]"` to cmd, which eats the
        # bracket, and an error string comes back looking like an answer.
        $script:code | Should -Not -Match '--query\s+"\[\?'
    }
}

Describe 'HEALTH-1: the sign-in layer, which is invisible from inside the app' {
    # Every caller on a real install got HTTP 403 - the browser and the
    # command line alike - with the right registration, the right audiences and
    # Vmf.Admin in the token. That refusal happens in App Service before any
    # product code runs, so nothing the product logs can show it. The check has
    # to read it from Azure.

    It 'reads the authorization policy from ARM, not through the CLI shape' {
        # MEASURED: an older CLI answers `az webapp auth show` with the v1
        # shape, whose every v2 field is null, and has no `auth v2` subcommand.
        $script:code | Should -Match 'authsettingsV2\?api-version='
        $script:code | Should -Match 'defaultAuthorizationPolicy'
    }

    It 'calls an empty allowedApplications the problem, because that is what was measured' {
        # Four states of one live site, one property changed at a time. The
        # empty array refuses every caller; removing it answers 200; putting it
        # back refuses again.
        $policy = [pscustomobject]@{ allowedApplications = @(); allowedPrincipals = [pscustomobject]@{} }
        $verdict = Get-VmfAuthPolicyVerdict -Policy $policy
        $verdict.Result | Should -Be 'PROBLEM'
        # 'HTTP 403', not '403' - the detail also names docs/backlog/easyauth-403-1,
        # so the looser pattern passed while the diagnosis was mutated away.
        $verdict.Detail | Should -Match 'HTTP 403'
        $verdict.Detail | Should -Match 'refuses EVERY caller'
    }

    It 'does not count an ABSENT list as one entry' {
        # @($null).Count is 1 in PowerShell, so the first version read an
        # absent list as a configured one and printed an empty allow-list as
        # though it named an application.
        $policy = [pscustomobject]@{ allowedPrincipals = [pscustomobject]@{} }
        $verdict = Get-VmfAuthPolicyVerdict -Policy $policy
        $verdict.Result | Should -Be 'OK'
        $verdict.Detail | Should -Not -Match 'only these'
    }

    It 'a list of one empty string is the same refusal by another route' {
        # What an empty dashboardAppId parameter would deploy: a list that
        # holds something and matches nobody.
        $verdict = Get-VmfAuthPolicyVerdict -Policy ([pscustomobject]@{ allowedApplications = @('') })
        $verdict.Result | Should -Be 'PROBLEM'
    }

    It 'does not call a list that names applications a fault' {
        # A check that flagged a correct allow-list would send somebody to
        # break a working install.
        $verdict = Get-VmfAuthPolicyVerdict -Policy ([pscustomobject]@{ allowedApplications = @('dash-id', 'cli-id') })
        $verdict.Result | Should -Be 'INFO'
        $verdict.Detail | Should -Match 'dash-id'
        $verdict.Detail | Should -Match 'cli-id'
    }

    It 'no policy at all is not a fault' {
        (Get-VmfAuthPolicyVerdict -Policy $null).Result | Should -Be 'OK'
    }

    It 'never blames an empty allowedPrincipals again' {
        # It was the suspect for a day and the measurement cleared it: an empty
        # allowedPrincipals object is present in BOTH states that answered 200.
        $policy = [pscustomobject]@{ allowedApplications = @('dash-id'); allowedPrincipals = [pscustomobject]@{} }
        (Get-VmfAuthPolicyVerdict -Policy $policy).Result | Should -Be 'INFO'
        $script:code | Should -Not -Match 'EMPTY allowedPrincipals'
        # And it must not state a suspect as a finding either way.
        $script:code | Should -Not -Match 'Not proven'
    }

    It 'reads the two app settings that refuse every caller when wrong' {
        $script:code | Should -Match "WEBSITE_AUTH\*"
    }

    It 'and asks ARM with one query parameter, never two' {
        # CLAUDE.md: an & in a URL given to `az rest` is a command separator to
        # cmd, and what comes back is every object in the tenant with exit 1.
        foreach ($line in ($script:code -split "`n")) {
            if ($line -notmatch 'management\.azure\.com') { continue }
            $line | Should -Not -Match '&'
        }
    }
}

Describe 'NSP-5: what Azure says about the perimeter around the run store' {
    # Found in the portal by accident, on an ENFORCED perimeter: one
    # unresolved issue, MissingIdentityConfiguration, and the install said
    # nothing about it anywhere. The row exists so nobody has to find it there
    # a second time.

    BeforeAll {
        function New-TestConfig {
            param([string]$Mode = 'Enforced', [string]$State = 'Succeeded', $Issues = @())
            [pscustomobject]@{
                properties = [pscustomobject]@{
                    resourceAssociation = [pscustomobject]@{ name = 'run-store'; accessMode = $Mode }
                    provisioningState   = $State
                    provisioningIssues  = $Issues
                }
            }
        }
        function New-TestIssue {
            param([string]$Name, [string]$Severity, [string]$Description = 'what Azure said')
            [pscustomobject]@{ name = $Name; properties = [pscustomobject]@{ severity = $Severity; issueType = 'Unknown'; description = $Description } }
        }
    }

    It 'a warning is reported, and named' {
        $c = New-TestConfig -Issues @(New-TestIssue -Name 'MissingIdentityConfiguration' -Severity 'Warning')
        $v = Get-VmfPerimeterVerdict -Configurations @($c)
        $v.Result | Should -Be 'INFO'
        $v.Detail | Should -Match 'MissingIdentityConfiguration'
        $v.Detail | Should -Match 'Enforced'
    }

    It 'an error is a PROBLEM, and carries what Azure said about it' {
        $c = New-TestConfig -Issues @(New-TestIssue -Name 'ConfigurationPropagationFailure' -Severity 'Error' -Description 'the rule did not reach the store')
        $v = Get-VmfPerimeterVerdict -Configurations @($c)
        $v.Result | Should -Be 'PROBLEM'
        $v.Detail | Should -Match 'the rule did not reach the store'
    }

    It 'reports an issue name Microsoft does not declare' {
        # Their schema for this response declares two issue types, and Azure
        # answers with names in neither. A check written against the declared
        # list would say nothing about the one issue anybody has seen.
        $c = New-TestConfig -Issues @(New-TestIssue -Name 'SomethingAzureInventedToday' -Severity 'Warning')
        (Get-VmfPerimeterVerdict -Configurations @($c)).Detail | Should -Match 'SomethingAzureInventedToday'
    }

    It 'a configuration Azure has not applied is a PROBLEM' {
        $v = Get-VmfPerimeterVerdict -Configurations @(New-TestConfig -State 'Failed')
        $v.Result | Should -Be 'PROBLEM'
        $v.Detail | Should -Match 'Failed'
    }

    It 'a clean association is OK, and says which mode it is in' {
        $v = Get-VmfPerimeterVerdict -Configurations @(New-TestConfig -Mode 'Transition')
        $v.Result | Should -Be 'OK'
        $v.Detail | Should -Match 'Transition'
        $v.Detail | Should -Match 'no issue'
    }

    It 'no perimeter at all is not a fault' {
        # A store outside a perimeter is a supported shape. The row must not
        # send somebody to build one.
        (Get-VmfPerimeterVerdict -Configurations @()).Result | Should -Be 'OK'
        (Get-VmfPerimeterVerdict -Configurations $null).Result | Should -Be 'OK'
    }

    It 'an empty answer is not counted as one configuration' {
        # @($null).Count is 1. The same trap this file already carries twice.
        (Get-VmfPerimeterVerdict -Configurations $null).Detail | Should -Match 'no perimeter'
    }

    It 'the worst of several associations decides the row' {
        $configs = @(
            New-TestConfig -Issues @(New-TestIssue -Name 'MissingIdentityConfiguration' -Severity 'Warning')
            New-TestConfig -Issues @(New-TestIssue -Name 'ConfigurationPropagationFailure' -Severity 'Error')
        )
        (Get-VmfPerimeterVerdict -Configurations $configs).Result | Should -Be 'PROBLEM'
    }

    It 'asks the STORE for the effective configuration, with one query parameter' {
        $script:code | Should -Match 'networkSecurityPerimeterConfigurations\?api-version='
        foreach ($line in ($script:code -split "`n")) {
            if ($line -notmatch 'networkSecurityPerimeterConfigurations') { continue }
            $line | Should -Not -Match '&'
        }
    }

    It 'and the store carries the identity the perimeter asks for' {
        # Microsoft: a managed identity has to be assigned on a resource for
        # perimeter access. Without one, Azure raises the issue above against
        # the association, and it stays there.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $bicep = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Language CStyle
        $store = [regex]::Match($bicep, "(?s)module store .*?\n\}").Value
        $store | Should -Not -BeNullOrEmpty
        $store | Should -Match 'systemAssigned: true'
    }
}

Describe 'REACH-1: the engine and the service are two identities' {
    # MEASURED on a real install, 2026-09-15. The engine held a role on the
    # subscription; the web service held nothing outside the product's own
    # resource group. The wizard offered the subscription and then listed no
    # resource groups in it, because the service answers that question with its
    # OWN identity - and this check said "The engine can reach ...", which was
    # true, about the wrong identity.

    It 'says so plainly when the service reaches nothing' {
        $v = Get-VmfReachVerdict -EngineScopes @('/subscriptions/abc') -ServiceScopes @()
        $v.Result | Should -Be 'PROBLEM'
        $v.Detail | Should -Match 'the web service reaches nothing'
        $v.Detail | Should -Match 'resource groups'
    }

    It 'and is OK when both reach the same place' {
        $v = Get-VmfReachVerdict -EngineScopes @('/subscriptions/abc') -ServiceScopes @('/subscriptions/abc')
        $v.Result | Should -Be 'OK'
        $v.Detail | Should -Match '/subscriptions/abc'
    }

    It 'reports a place the engine reaches and the service does not' {
        $v = Get-VmfReachVerdict -EngineScopes @('/subscriptions/abc', '/subscriptions/def') -ServiceScopes @('/subscriptions/abc')
        $v.Result | Should -Be 'INFO'
        $v.Detail | Should -Match 'cannot list resource groups'
    }

    It 'an engine that reaches nothing is still the first thing to say' {
        (Get-VmfReachVerdict -EngineScopes @() -ServiceScopes @()).Result | Should -Be 'PROBLEM'
        (Get-VmfReachVerdict -EngineScopes $null -ServiceScopes $null).Detail | Should -Match 'an assessment finds no machines'
    }

    It 'does not count an empty answer as a grant' {
        # @($null).Count is 1. Three times in this file now - and the first
        # version of this test passed an empty list for BOTH, so the engine
        # branch answered and the service branch was never reached.
        $v = Get-VmfReachVerdict -EngineScopes @('/subscriptions/abc') -ServiceScopes @($null)
        $v.Result | Should -Be 'PROBLEM'
        $v.Detail | Should -Match 'the web service reaches nothing'
        (Get-VmfReachVerdict -EngineScopes @($null) -ServiceScopes @($null)).Result | Should -Be 'PROBLEM'
    }

    It 'and the check reads the SERVICE identity, not only the engine' {
        # The ASSIGNMENT, not a mention. A version of this test matched the
        # variable name and passed while the read had been replaced with an
        # empty list beside it.
        $script:code | Should -Match '\$serviceGrants = @\(Get-VmfJson'
        $script:code | Should -Match "'--assignee', \`$facade\.identity\.principalId"
        $script:code | Should -Match 'ServiceScopes @\(\$serviceGrants'
    }
}

Describe 'REACH-1: the grant gives both identities what they need' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:grant = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1')
    }

    It 'a migrate scope reaches the service too' {
        # The migration role CONTAINS the assessment role, which is true of the
        # actions and says nothing about who holds them. This is what left the
        # dashboard's lists empty on a real install.
        $block = [regex]::Match($script:grant, '(?s)if \(\$MigrateScope\) \{.*?\n\}').Value
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Match "Grant-Role -PrincipalId \`$facadeMi -RoleName 'VMF Assessment'"
    }

    It 'and only the engine may change a machine' {
        $block = [regex]::Match($script:grant, '(?s)if \(\$MigrateScope\) \{.*?\n\}').Value
        $migration = @(($block -split "`n") | Where-Object { $_ -match "'VMF Migration'" })
        $migration.Count | Should -Be 1
        $migration[0] | Should -Match 'engineMi'
    }

    It 'an assess scope still reaches both' {
        $block = [regex]::Match($script:grant, '(?s)if \(\$AssessScope\) \{.*?\n\}').Value
        $block | Should -Match 'engineMi'
        $block | Should -Match 'facadeMi'
    }
}

Describe 'FIRSTSCOPE-1: the health check says what the product may DO, not only what it reaches' {

    # MEASURED on a corporate install, 2026-09-22: both identities on
    # VMF Assessment at the subscription, no migration role anywhere, and this
    # tool printed "Every check passed". Every row was true. The install could
    # not stop a machine, resize one, take a safety copy or run anything in a
    # guest, and the check run before had reported it fine.
    #
    # Reach and capability are different questions and it only ever asked one.

    It 'a migration role anywhere means it may scan and migrate' {
        $v = Get-VmfCapabilityVerdict -EngineGrants @(
            [pscustomobject]@{ roleDefinitionName = 'VMF Migration (abc)'; scope = '/subscriptions/s' })
        $v.Result | Should -Be 'OK'
        $v.Detail | Should -Match 'scan and migrate'
        $v.Detail | Should -Match '/subscriptions/s'
    }

    It 'assessment alone is SCAN ONLY, and says what it cannot do' {
        # THE DEFECT. This state reported nothing at all before.
        $v = Get-VmfCapabilityVerdict -EngineGrants @(
            [pscustomobject]@{ roleDefinitionName = 'VMF Assessment (abc)'; scope = '/subscriptions/s' })
        $v.Detail | Should -Match '^SCAN ONLY'
        $v.Detail | Should -Match '(?i)cannot stop a machine'
        $v.Detail | Should -Match '(?i)safety copy'
    }

    It 'and scan only is not a FAILURE, because it is a choice somebody made' {
        # A legitimate install. Reporting it as broken would teach people to
        # ignore the row, which is how the original defect survived.
        $v = Get-VmfCapabilityVerdict -EngineGrants @(
            [pscustomobject]@{ roleDefinitionName = 'VMF Assessment (abc)'; scope = '/subscriptions/s' })
        $v.Result | Should -Be 'INFO'
    }

    It 'neither role is a PROBLEM - it can do nothing at all' {
        $v = Get-VmfCapabilityVerdict -EngineGrants @()
        $v.Result | Should -Be 'PROBLEM'
        $v.Detail | Should -Match '(?i)neither scan nor migrate'
    }

    It 'a migration role wins even when an assessment role sits beside it' {
        # Both is the normal shape of an install that was granted assess first
        # and migrate later. It may migrate.
        $v = Get-VmfCapabilityVerdict -EngineGrants @(
            [pscustomobject]@{ roleDefinitionName = 'VMF Assessment (abc)'; scope = '/subscriptions/s' },
            [pscustomobject]@{ roleDefinitionName = 'VMF Migration (abc)'; scope = '/subscriptions/s/resourceGroups/rg' })
        $v.Result | Should -Be 'OK'
        $v.Detail | Should -Match 'resourceGroups/rg'
    }

    It 'the tool really adds the row, and says it after the reach rows' {
        $tool = Get-Content (Join-Path $script:repoRoot 'tools' 'Test-VmfHealth.ps1') -Raw
        $tool | Should -Match "Add-Row 'What it may DO with them'"
        $reachAt = $tool.IndexOf("Add-Row 'The service can reach'")
        $doAt = $tool.IndexOf("Add-Row 'What it may DO with them'")
        $doAt | Should -BeGreaterThan $reachAt -Because 'capability is the answer a person came for, so it is said last'
    }

    It 'and "Every check passed" no longer stands alone on a scan-only install' {
        # The line people actually read.
        $tool = Get-Content (Join-Path $script:repoRoot 'tools' 'Test-VmfHealth.ps1') -Raw
        $tool | Should -Match 'It may NOT migrate a machine'
        $closing = [regex]::Match($tool, "(?s)Every check passed\.'.*$").Value
        $closing | Should -Match '\$scanOnly'
    }
}


Describe 'REACH-2: a scope is named once, however many roles reach it' {

    # Seen on a corporate install the moment it gained a second role:
    #
    #   both reach /subscriptions/aaaa0a0a..., /subscriptions/aaaa0a0a...
    #
    # The engine held VMF Assessment AND VMF Migration at the same subscription,
    # and the caller passes one scope per GRANT. Harmless, and it reads like the
    # tool cannot count - which is the last thing a health check should look
    # like when somebody is deciding whether to trust it.

    It 'says a subscription once when two roles reach it' {
        $v = Get-VmfReachVerdict -EngineScopes @('/subscriptions/s', '/subscriptions/s') `
                                 -ServiceScopes @('/subscriptions/s')
        $v.Result | Should -Be 'OK'
        @([regex]::Matches($v.Detail, '/subscriptions/s')).Count | Should -Be 1
    }

    It 'and still names two DIFFERENT places' {
        $v = Get-VmfReachVerdict -EngineScopes @('/subscriptions/s', '/subscriptions/s/resourceGroups/rg') `
                                 -ServiceScopes @('/subscriptions/s', '/subscriptions/s/resourceGroups/rg')
        $v.Detail | Should -Match 'resourceGroups/rg'
        $v.Detail | Should -Match '/subscriptions/s,'
    }

    It 'and a place the service cannot reach is still reported' {
        # The check REACH-1 exists for must survive the de-duplication.
        $v = Get-VmfReachVerdict -EngineScopes @('/subscriptions/s', '/subscriptions/s') `
                                 -ServiceScopes @('/subscriptions/other')
        $v.Result | Should -Be 'INFO'
        $v.Detail | Should -Match '(?i)cannot list resource groups'
    }
}
