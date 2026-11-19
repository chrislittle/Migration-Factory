#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CONSENT-1, part two (2026-09-10): how does a user check, in another Azure
# environment such as a corporate tenant, whether they can consent to the app?
# They may be able to create applications and still not know about its roles.
#
# tools/Test-VmfConsentReadiness.ps1 answers that, and these tests hold the two
# properties that make it safe to hand somebody for a corporate tenant:
# it only READS, and it never reports a clean result it did not measure.
#
# It also carries the third variant of a hazard already in CLAUDE.md. MEASURED
# 2026-09-10: `applications?$filter=...&$select=...` returned EVERY application
# in the tenant, with exit code 1. az.cmd passes its arguments through cmd,
# which treats '&' as a command separator - so the second query parameter is
# cut off AND the first one is lost with it. The same family as the
# `az --query "[?...]"` mangling. One query parameter per call.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:toolPath = Join-Path $script:repoRoot 'tools' 'Test-VmfConsentReadiness.ps1'
    $script:tool     = Get-Content $script:toolPath -Raw

    # Lift Read-Graph out of the script so its guard can be exercised without
    # running the script or reaching Azure.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:toolPath, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-Graph'
    }, $true))
    if ($fn.Count -ne 1) { throw "expected one Read-Graph, found $($fn.Count)" }
    $script:readGraph = & ([scriptblock]::Create("function Read-Graph $($fn[0].Body.Extent.Text)`n`${function:Read-Graph}"))
}

Describe 'CONSENT-1: the readiness check only reads' {

    It 'the script exists and parses' {
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:toolPath, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
    }

    It 'every Graph call is a GET' {
        # Handing somebody a diagnostic for their CORPORATE directory means it
        # must be provably incapable of changing anything there.
        $script:tool | Should -Not -Match "--method\s+(POST|PATCH|PUT|DELETE)"
        $script:tool | Should -Match 'az rest --method GET'
    }

    It 'and it grants no consent, however tempting' {
        # CONSENT-TOOL-LINK-1: it no longer even PRINTS the command for
        # somebody else to run (rule 12). The person with the role approves in
        # the browser, from the install's own hand-off.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path $script:toolPath
        $code | Should -Not -Match 'admin-consent'
        $code | Should -Match 'Get-VmfConsentHandoff'
    }

    It 'it says so itself, where a reader will see it' {
        $script:tool | Should -Match '(?i)This script changed nothing'
    }
}

Describe 'CONSENT-1: it never reports a result it did not measure' {

    It 'a failed read is Ok=false with a reason, not an empty answer' {
        # The whole lesson of 2026-09-09: a guard that cannot measure must say
        # so rather than return a benign-looking nothing.
        $script:tool | Should -Match 'Ok = \$false'
        $script:tool | Should -Match '(?i)COULD NOT BE READ'
        $script:tool | Should -Match '(?i)UNKNOWN, not "no"|UNKNOWN. Your roles could not be read'
    }

    It 'and it digs the message out of a JSON refusal' {
        # Graph answers a refusal with a JSON body whose first line is '{',
        # which tells a reader nothing. Seen, and fixed.
        $script:tool | Should -Match '\.error\.message'
    }

    It 'and it parses from the first brace, because az prefixes the body' {
        # MEASURED 2026-09-10: a refusal arrives as `ERROR: Forbidden({...})`,
        # which ConvertFrom-Json rejects outright. Without this the reason falls
        # back to the raw line and the reader gets 200 characters of noise.
        $script:tool | Should -Match "IndexOf\('\{'\)"
        $script:tool | Should -Match "LastIndexOf\('\}'\)" -Because 'the trailing bracket breaks the parse too'
    }
}

Describe 'CONSENT-2: it does not claim an administrator is the only way' {
    # The need (2026-09-10): a user can consent, OR an admin can consent for
    # the organisation. Either is fine; an administrator is not the only way
    # to make this app work.
    #
    # The first version of this script assumed the opposite, twice. These hold the
    # corrected shape: the ADMIN PAGE always needs an administrator, and whether
    # a USER can approve the rest is read from the directory.

    It 'the two questions are separated' {
        $script:tool | Should -Match '(?i)TWO CONSENT QUESTIONS'
        $script:tool | Should -Match '(?i)Can an ordinary user approve the product here'
    }

    It 'and neither overstatement survives' {
        $script:tool | Should -Not -Match '(?i)reserved for an administrator whatever'
        $script:tool | Should -Not -Match '(?i)Nobody can sign in to the dashboard until'
    }

    It 'it reads what a policy INCLUDES, never the policy name' {
        # A directory can assign a custom policy. Reading the answer off a
        # built-in name would report a confident wrong result there.
        $script:tool | Should -Match 'permissionGrantPolicies/\$id/includes'
        $script:tool | Should -Match 'permissionClassification'
    }

    It 'and only the ForSelf policies are read' {
        # ManagePermissionGrantsForOwnedResource.* governs Teams and chat
        # resources. Counting those would turn "user consent is off" into "on".
        $script:tool | Should -Match "ManagePermissionGrantsForSelf\.\*"
    }

    It 'a failed request-workflow read says so rather than printing nothing' {
        # MEASURED 2026-09-10 in a corporate tenant: the read failed
        # and the section printed NOTHING, which reads as "nothing to say".
        $script:tool | Should -Match '(?i)could not be read - \$\(\$req\.Why\)'
    }

    It 'and a guest account is named as one' {
        $script:tool | Should -Match "#EXT#"
        $script:tool | Should -Match '(?i)You are a GUEST in this directory'
    }
}

Describe 'CONSENT-1: the az/cmd ampersand hazard' {

    It 'no Graph URL in the script carries an ampersand' {
        $bad = @(Get-Content $script:toolPath | Where-Object { $_ -match 'graph\.microsoft\.com' -and $_ -match '&' })
        $bad -join ' ' | Should -BeNullOrEmpty -Because 'cmd eats & and the query silently returns everything'
    }

    It 'and Read-Graph REFUSES one rather than issuing it' {
        # Behavioural, not a source match: the guard runs before any az call,
        # so this reaches no network.
        { & $script:readGraph -Url 'https://graph.microsoft.com/v1.0/applications?$filter=a&$select=b' } |
            Should -Throw '*eaten by cmd*'
    }
}

Describe 'CONSENT-1: the roles it names are the ones Microsoft names' {

    BeforeAll {
        # CONSENT-TOOL-LINK-1: the role lists and the consent read live in the
        # install's rights reader, which the tool dot-sources - one copy.
        $script:rightsText = Get-Content (Join-Path $script:repoRoot 'infra' 'Resolve-VmfInstallerRights.ps1') -Raw
    }

    It 'the any-permission roles' {
        $script:tool | Should -Match 'Resolve-VmfInstallerRights\.ps1'
        $script:rightsText | Should -Match "'Global Administrator'"
        $script:rightsText | Should -Match "'Privileged Role Administrator'"
    }

    It 'and the ones limited to everything EXCEPT Graph app roles' {
        # Which is enough here, and that is the point worth getting right: this
        # product asks for delegated permissions only, so Application
        # Administrator - common in a corporate directory - is sufficient.
        $script:rightsText | Should -Match "'Cloud Application Administrator'"
        $script:rightsText | Should -Match "'Application Administrator'"
        $script:tool | Should -Match '(?i)every permission it wants is delegated, so it is enough'
    }

    It 'it warns that PIM-eligible roles do not show' {
        # A role held but not activated is invisible here, and reading "NO"
        # when the answer is "not right now" would send somebody to ask for a
        # role they already have.
        $script:tool | Should -Match '(?i)ELIGIBLE and not activated'
    }

    It 'and it separates person-level consent from organisation-wide' {
        # The trap, measured on a lab install: three grants, all
        # consentType 'Principal'. It worked for the installer and for nobody else.
        # Run, with az stubbed, in ConsentDoneCheck.Tests.ps1.
        $script:tool | Should -Match 'Get-VmfAdminConsentState'
        $script:rightsText | Should -Match "consentType -eq 'AllPrincipals'"
        $script:rightsText | Should -Match "consentType -eq 'Principal'"
        $script:rightsText | Should -Match '(?i)nobody else'
    }
}
