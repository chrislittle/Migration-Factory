#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SUBID-1: no live Azure subscription id in the repository.
#
# A real subscription id sat in 14 tracked files - drill evidence, four lab
# scripts, a unit test, a page comment and the ledger - because the drills that
# produced them ran in a real subscription and the ids came along with
# the records.
#
# It is not a credential. Nothing is unlocked by knowing it. It is an
# identifier: it names a real resource container, and it is the kind of thing
# that turns "here is our tool" into "here is where our machines live" the
# moment a repository goes public. PUBLIC-1 is the event this is a blocker for.
#
# THIS TEST DELIBERATELY DOES NOT CONTAIN THE ID IT IS GUARDING AGAINST. Writing
# it here to assert its absence would put it straight back. So the rule is
# inverted: every id in a SUBSCRIPTION POSITION must be one of a short list of
# known placeholders, and anything else fails - including an id nobody has seen
# yet, from a subscription nobody has used yet.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

    # The only ids allowed to sit where a subscription id goes.
    $script:allowedSubscriptionIds = @(
        # The lab subscription, redacted. Microsoft's own documentation
        # placeholder style: valid hex, obviously not real.
        'aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e',
        # A subscription invented by a unit test or a schema sample.
        '00000000-0000-0000-0000-000000000000',
        '11111111-2222-3333-4444-555555555555',
        # CLAIM-NAME-1: a second invented subscription with the SAME first eight
        # characters as the first, because names carry only those eight.
        '00000000-1111-1111-1111-111111111111'
    )

    # A SECOND subscription appears in the ledger - the one the CI runner lives
    # in - and it was only ever written truncated, so no whole-GUID search
    # would ever have found it. It has its own placeholder so the two stay
    # distinguishable in prose that contrasts them.
    $script:allowedPrefixes = @(
        'aaaa0a0a',   # the lab subscription
        'bbbb0b0b',   # the CI runner's subscription
        '00000000', '11111111'
    )

    # Everything git tracks, minus the vendored library and this file's own
    # neighbour that explains the placeholders in prose.
    $script:tracked = @(
        & git -C $script:repoRoot ls-files |
            Where-Object { $_ -notmatch 'msal-browser\.min\.js' } |
            Where-Object { $_ -ne 'docs/evidence/README.md' } |
            Where-Object { $_ -ne 'tests/unit/NoLiveIdentifiers.Tests.ps1' }
    )
}

Describe 'SUBID-1: the repository carries no live subscription id' {

    It 'finds files to check, so this cannot pass by scanning nothing' {
        # The failure mode of every repository-wide test: the file list comes
        # back empty and the whole thing reports success.
        $script:tracked.Count | Should -BeGreaterThan 100
    }

    It 'every id in a subscription position is a known placeholder' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:tracked) {
            $full = Join-Path $script:repoRoot $file
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $text = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            # `/subscriptions/<id>`, `subscriptionId: "<id>"`, `-SubscriptionId '<id>'`
            foreach ($m in [regex]::Matches($text, "(?i)subscriptions?[/`"':= ]{1,4}(?<g>$script:guidPattern)")) {
                $id = $m.Groups['g'].Value.ToLower()
                if ($script:allowedSubscriptionIds -notcontains $id) {
                    $offenders.Add("$file : $id")
                }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'a live subscription id names where a customer''s machines really are'
    }

    # FOUND BY HAND, after the first pass reported "none left". The id
    # also lived TRUNCATED, in prose: "in subscription <first two blocks>-...". A
    # whole-GUID search does not match that, and neither did the check above -
    # so three fragments survived a redaction that reported itself complete.
    #
    # A fragment is a weaker identifier than the whole id, not a harmless one:
    # the leading block is the part a search engine matches on.
    It 'and no TRUNCATED id survives in prose either' {
        # Same rule, applied to the first block alone, so it catches
        # `<prefix>-...` and `<prefix>-<next>-...` as well as the full form.
        $allowedPrefixes = $script:allowedPrefixes
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:tracked) {
            $full = Join-Path $script:repoRoot $file
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $text = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            foreach ($m in [regex]::Matches($text, "(?i)subscriptions?[/`"':= ]{1,4}(?<p>[0-9a-f]{8})(?:-|\.\.\.)")) {
                $prefix = $m.Groups['p'].Value.ToLower()
                if ($allowedPrefixes -notcontains $prefix) {
                    $offenders.Add("$file : $prefix-...")
                }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'half an id still names the subscription'
    }

    # SUBID-2, 2026-09-15. The rule above only looks where the word
    # "subscription" sits immediately BEFORE the id. A live work
    # subscription sat in three tracked files as an Azure error quote -
    # `Property id '<prefix>-...' at path 'properties.subscriptions[0].id'` -
    # where the word subscriptions is in the path AFTER it. So the check passed
    # while the id was there: a check reporting what it matched rather than
    # what is true, which is the defect class this repository keeps finding.
    #
    # THE RULE IS INVERTED, for the same reason as the one above. A shortened
    # id ANYWHERE must be one of a short list, and anything else fails -
    # including an id from a subscription nobody has used yet. Somebody pasting
    # their own tenant's id into a quoted error is exactly what this catches.
    It 'and no shortened id anywhere, whatever word sits before it' {
        # Every entry is either a placeholder or an identifier Microsoft
        # publishes. A NEW one fails until somebody says which it is.
        $allowed = @{
            'aaaa0a0a' = 'placeholder: the lab subscription'
            'bbbb0b0b' = "placeholder: the CI runner's subscription"
            'cccc0c0c' = 'placeholder: any other id inside a quoted error'
            '00000000' = 'placeholder'
            '11111111' = 'placeholder'
            'b24988ac' = 'Azure built-in role: Contributor'
            'ba92f5b4' = 'Azure built-in role: Storage Blob Data Contributor'
            'f58310d9' = 'Azure built-in role: Role Based Access Control Administrator'
            'fb382eab' = 'Azure built-in role: Container Registry Tasks Contributor'
            '84bccea3' = 'Microsoft Graph permission: AppRoleAssignment.ReadWrite.All'
            'c79f8feb' = 'Microsoft Graph permission: Application.Read.All'
            'e87a87f5' = 'Azure built-in policy definition: the MANA NVA list'
        }
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:tracked) {
            $full = Join-Path $script:repoRoot $file
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $text = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            # `<prefix>-...` and `<prefix>-<block>-...`, which is how a real id
            # gets written when somebody shortens one by hand.
            foreach ($m in [regex]::Matches($text, '(?i)(?<p>[0-9a-f]{8})-(?:[0-9a-f]{4}-)*\.\.\.')) {
                $prefix = $m.Groups['p'].Value.ToLower()
                if (-not $allowed.ContainsKey($prefix)) {
                    $offenders.Add("$file : $prefix-...")
                }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'half an id still names the thing, and a search engine matches on the first block'
    }

    # PUBLIC-SYNC-1: tests/lab and docs/evidence do not ship to the public
    # repository. The three tests about them run where they are.
    It 'the lab drills take the subscription from whoever is signed in' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' 'lab'))) {
        # Four drills carried a real subscription as a PARAMETER DEFAULT,
        # so the id was not incidental to a record - it was the thing the script
        # would use if nobody said otherwise. Several other drills already read
        # the signed-in context; these now do the same. REBUILD-REMOVE-LEDGER-1
        # deleted the fourth, Invoke-WindowsSeedRedo: it drove only the rebuild.
        $drills = @('Invoke-AssessPlanDrill', 'Invoke-PilotRehearsal',
                    'Invoke-WaveRehearsal')
        foreach ($name in $drills) {
            $file = Join-Path $script:repoRoot 'tests' 'lab' "$name.ps1"
            Test-Path $file | Should -BeTrue -Because "$name should exist"
            $text = Get-Content $file -Raw
            # PILOT-DECIDE-LAB-1: a drill may read it in the body, in the
            # phases that use Azure, so a plan-only phase reads nothing.
            $text | Should -Match '\[string\]\$SubscriptionId = \(Get-AzContext\)\.Subscription\.Id' `
                -Because "$name must not carry anybody's subscription as its default"
            # And it must still refuse to run without a context, or the default
            # is an empty string and the drill acts on nothing while looking fine.
            $text | Should -Match 'No Az context' -Because "$name must refuse rather than run with an empty subscription"
        }
    }

    It 'the install suffix from a real deployment is not in the evidence' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'docs' 'evidence'))) {
        # A derived, environment-specific name. Not secret, but it identifies
        # one real installation, and it travelled in two drill records.
        $evidence = @($script:tracked | Where-Object { $_ -like 'docs/evidence/*' })
        $evidence.Count | Should -BeGreaterThan 5
        foreach ($file in $evidence) {
            $text = Get-Content -LiteralPath (Join-Path $script:repoRoot $file) -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            $text | Should -Match '(?s).*' # keep the loop honest if a file is empty
            $text | Should -Not -Match 'VMF Assessment \(n[0-9a-z]{12}\)' -Because "$file must not name a real installation"
        }
    }

    It 'and the evidence says its ids were redacted, so nobody reads them as real' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'docs' 'evidence'))) {
        # Evidence that has been edited must say so, or the next person treats a
        # placeholder as a measurement.
        $readme = Get-Content (Join-Path $script:repoRoot 'docs' 'evidence' 'README.md') -Raw
        $readme | Should -Match '(?i)placeholder'
        $readme | Should -Match 'aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e'
        $readme | Should -Match '(?i)nothing else was changed'
    }
}

Describe 'PII-1: the repository carries nobody real name, address or tenant' {

    # PII-1, 2026-09-18. The same lesson as SUBID-1, one identifier along, and
    # it had to be learned twice.
    #
    # Found when notes about an employer's tenant were to be kept out of the
    # repository. A wider look found, already merged:
    #
    #   * a real PERSONAL EMAIL ADDRESS, in a test written HOURS EARLIER as sample
    #     data for a record of who put a machine back. It looked harmless
    #     because the test was about an audit trail, which is exactly where a
    #     real name feels natural;
    #   * an employer's environment name in seven files - an example command in
    #     a tool's help, three test comments, two write-ups and a quoted Azure
    #     error;
    #   * a corporate subscription's DISPLAY NAME, which carries an internal
    #     request number and a surname, quoted from a product message.
    #
    # None of it is a credential. All of it is the kind of thing that turns
    # "here is our tool" into "here is who runs it and where" the moment a
    # repository goes public. PUBLIC-1 is the event this blocks.
    #
    # THE RULE IS INVERTED, like SUBID-1 above, and for the same reason: a check
    # that listed the addresses to ban would have to contain them. So every
    # email-shaped string must be at a DOCUMENTATION domain, and anything else
    # fails - including an address nobody has written yet.
    #
    # WHAT THIS CANNOT CATCH. A person's name, or a customer's tenant name, has
    # no shape to test for. There is no check for those; there is a hard rule in
    # CLAUDE.md and there is review. Saying so plainly is better than implying
    # this gate covers more than it does.

    BeforeAll {
        # Domains that exist to be written down. RFC 2606 reserves example.*
        # and .invalid; contoso is Microsoft's own documentation company.
        $script:docDomains = @(
            'example.com', 'example.org', 'example.net', 'example.local',
            'contoso.com', 'contoso.local', 'localhost', 'invalid', 'test'
        )
        $script:emailPattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
        # Schema files describe an email FORMAT without carrying one, and the
        # manual's own front matter names the project, not a person.
        $script:piiSkip = @('package-lock.json')
    }

    It 'finds files to check, so this cannot pass by scanning nothing' {
        $script:tracked.Count | Should -BeGreaterThan 100
    }

    It 'the pattern really does find an address, or every check below is empty' {
        # A vacuity guard with teeth: prove the matcher works on a made-up
        # address before trusting it to report none.
        ('somebody@' + 'a-real-company.co.uk') | Should -Match $script:emailPattern
        'operator@example.com' | Should -Match $script:emailPattern
    }

    It 'every email address in the repository is at a documentation domain' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        $checked = 0
        foreach ($rel in $script:tracked) {
            if ($script:piiSkip -contains (Split-Path $rel -Leaf)) { continue }
            $path = Join-Path $script:repoRoot $rel
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            foreach ($m in [regex]::Matches($text, $script:emailPattern)) {
                $checked++
                $domain = ($m.Value -split '@')[1].TrimEnd('.').ToLowerInvariant()
                $ok = $script:docDomains | Where-Object { $domain -eq $_ -or $domain.EndsWith(".$_") }
                if (-not $ok) { $offenders.Add("$rel -> $($m.Value)") }
            }
        }
        $checked | Should -BeGreaterThan 0 -Because 'a rule applied to no address is not a rule'
        ($offenders -join '; ') | Should -BeNullOrEmpty -Because (
            'a real address names a real person. Use one of the documentation ' +
            'domains - example.com and the rest exist for this.')
    }
}
Describe 'CONFIG-HOST-1: nothing the dashboard ships names a host somebody else could own' {
    <#
        The sample configuration that ships beside the pages pre-filled the
        service address with an example name on azurewebsites.net - while every
        other field in it was an obvious row of zeroes. It was the one field
        that looked already done, and the file told the reader to rename it and
        deploy.

        App Service names are handed out first-come across the whole of Azure,
        and that name was NOT REGISTERED. Anybody could take it. A deployment
        that kept the sample value would have obtained a real access token for
        the customer's own service and posted it to whoever answered.

        The rule is therefore the same shape as the subscription-id rule above:
        nothing we ship may name a real address. A wildcard in the browser's
        security policy has no name at all: since CSP-AZUREWEBSITES-1 it
        holds a marker the publish replaces with the exact service origin.
    #>

    BeforeAll {
        $script:dashboardFiles = @($script:tracked | Where-Object { $_ -like 'src/dashboard/*' })
        # One specific name, and any sibling: a host under azurewebsites.net
        # written out in full. The CSP marker names no host, so it does not
        # match.
        $script:namedHost = '[a-z0-9][a-z0-9-]*\.azurewebsites\.net'
    }

    It 'finds dashboard files to check, so this cannot pass by scanning nothing' {
        $script:dashboardFiles.Count | Should -BeGreaterThan 10
    }

    It 'the shipped sample configuration carries no address at all' {
        $sample = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'dashboard.sample.config.json') -Raw |
            ConvertFrom-Json
        # Empty is the documented state for "no service is deployed", and the
        # pages already draw no action controls in it. A blank to fill in is
        # safe; a plausible value is not.
        $sample.apiUrl | Should -BeNullOrEmpty
    }

    It 'no dashboard file names an azurewebsites host in full' {
        $found = @()
        foreach ($file in $script:dashboardFiles) {
            $text = Get-Content -LiteralPath (Join-Path $script:repoRoot $file) -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            if ($text -match $script:namedHost) { $found += "$file names $($Matches[0])" }
        }
        $found | Should -BeNullOrEmpty -Because 'a name we ship is a name somebody else can register'
    }

    It 'the security policy still has a place for the service, so a real facade still works' {
        # The guard above must not be satisfied by removing the permission the
        # product needs - that would pass while breaking every deployment.
        # CSP-AZUREWEBSITES-1: the place is a marker the publish replaces with
        # the exact origin (CspServiceHost.Tests.ps1), not a wildcard.
        $webConfig = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'web.config') -Raw
        $webConfig | Should -Match 'connect-src[^";]*\{vmf-service-origin\}'
    }
}

Describe 'CONFIG-HOST-1: every page runs its configuration through the check' {
    <#
        The check is worth nothing on a page that skips it, and the next page
        somebody adds will copy an existing one. Eight pages read the
        configuration with the same line; this is what makes the ninth fail
        rather than quietly send a token wherever the file says.

        Read as CODE, not as text: a page that mentions the file in a comment
        explaining any of this must not satisfy the check by talking about it.
    #>

    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html' -File)
    }

    It 'finds pages to check' {
        $script:pages.Count | Should -BeGreaterThan 5
    }

    It 'a page that reads the configuration also checks it' {
        $readers = @()
        $checked = @()
        foreach ($page in $script:pages) {
            $code = Get-VmfCodeOnly -Path $page.FullName -Language CStyle
            if ($code -notmatch "fetch\('dashboard\.config\.json'\)") { continue }
            $readers += $page.Name
            if ($code -match 'VmfHelp\.checkedConfig\(') { $checked += $page.Name }
        }
        $readers.Count | Should -BeGreaterThan 5 -Because 'the pages do read a configuration file'
        @($readers | Where-Object { $_ -notin $checked }) | Should -BeNullOrEmpty -Because 'a page that reads the address must check it'
    }
}

# HEAD-SCRUB-1's checks (a known lab id by hash, an install suffix, an employer
# tenant name, a profile folder) moved to tools/Test-VmfPublicReady.ps1 with
# PUBLIC-READY-GATE-1; tests/unit/PublicReady.Tests.ps1 runs them over every
# tracked file.
