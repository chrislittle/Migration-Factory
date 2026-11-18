# OPT-DROP-1: a page helper must FORWARD every option its own callers pass.
#
# THE DEFECT, measured in a browser on 2026-09-18. PLANVER-2 added `asVersioned`
# to VmfHelp.storeBlob and a caller for it on the Migrations page. The page's
# own helper in between read one option and passed one option:
#
#     async function blobFetch(path, { asText = false } = {}) {
#       return VmfHelp.storeBlob(getToken, cfg.apiUrl, path, { asText });
#     }
#
# `asVersioned` was dropped in the middle, silently. storeBlob returned the
# parsed document, the caller read `.text` and got undefined, and Approve died
# with `"undefined" is not valid JSON`. The approval gate could not be opened.
#
# JavaScript has no complaint to make here: an unknown property on an object
# literal is legal, and a dropped one leaves no trace. So the rule is checked.
#
# WHY IT IS THE CALLER SIDE THAT IS CHECKED. The broken helper was INTERNALLY
# CONSISTENT - it destructured `asText` and forwarded `asText`. A rule reading
# only the helper passes it. The mismatch was between the caller and the
# helper, so that is the pair this reads.
#
# The BEHAVIOUR is covered by tests/js/blob-options.test.js, which runs the real
# helper against the real storeBlob with only the network faked. THIS covers the
# class: any option, any page, including ones added later.
#
# COMMENT-TRAP-1 applies with force: the fix's own comment names both options.
# Everything below reads Get-VmfCodeOnly output, never the raw file.

. (Join-Path $PSScriptRoot '_CodeOnly.ps1')

# The option names in an object literal. `{ asText, asVersioned: true }` gives
# asText, asVersioned. A spread is skipped - it carries names this cannot know.
function Get-VmfOptionNames {
    param([string]$Literal)
    @($Literal -split ',' | ForEach-Object { ($_ -split ':|=')[0].Trim() } |
        Where-Object { $_ -and $_ -notmatch '^\.\.\.' })
}

# Every page helper that delegates to VmfHelp.storeBlob, with the options it
# forwards and the options its own callers ask it for.
function Get-VmfBlobWrappers {
    param([string]$Path)

    $code = Get-VmfCodeOnly -Path $Path
    # A template placeholder holds BRACES: `${run}/${rel}` reads to a pattern
    # looking for an object literal as one, and the first scan duly reported
    # that a page passed an option called 'run'. Blank them before scanning.
    $scan = [regex]::Replace($code, '\$\{[^{}]*\}', 'X')
    $lines = $scan -split "`n"
    $found = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch 'VmfHelp\.storeBlob\s*\(') { continue }

        # What this delegate call forwards. No literal forwards nothing, which
        # is right only if no caller asks for anything.
        $forwards = @()
        if ($lines[$i] -match 'VmfHelp\.storeBlob\s*\([^{]*\{([^{}]*)\}') {
            $forwards = Get-VmfOptionNames -Literal $matches[1]
        }

        # The enclosing function, by walking back to the nearest declaration.
        $name = $null
        for ($j = $i; $j -ge 0; $j--) {
            if ($lines[$j] -match 'function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(') { $name = $matches[1]; break }
        }
        if (-not $name) { continue }

        # Every CALL of that helper. The lookbehind drops the declaration - its
        # parameter list is an object literal too, and matching it made the
        # helper look like a caller of itself asking for 'asText = false'.
        $asked = @()
        $callPattern = '(?<![.\w])(?<!function\s)' + [regex]::Escape($name) + '\s*\(([^()]*)\)'
        foreach ($call in [regex]::Matches($scan, $callPattern)) {
            if ($call.Groups[1].Value -match '\{([^{}]*)\}') {
                $asked += Get-VmfOptionNames -Literal $matches[1]
            }
        }

        $found += [pscustomobject]@{
            Page     = Split-Path $Path -Leaf
            Helper   = $name
            Forwards = @($forwards | Sort-Object -Unique)
            Asked    = @($asked | Sort-Object -Unique)
        }
    }
    , $found
}

# Scanned once, at discovery, so the cases and the checks read the same result.
$script:vmfWrappers = @(
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'src' 'dashboard') -Filter '*.html' -File |
        ForEach-Object { Get-VmfBlobWrappers -Path $_.FullName }
)

# Pester discovers and RUNS in separate scopes, so a variable set here is gone
# by the time an It body reads it - it read as empty and the guard below fired.
# The data travels on the Describe instead, which is the one channel that
# crosses that line.
Describe 'OPT-DROP-1: a store-blob helper forwards what its callers pass' -ForEach @(
    @{ Wrappers = $script:vmfWrappers }
) {

    It 'found the helpers to check, so this file cannot pass on nothing' {
        # THE VACUITY GUARD. A scan that matches no wrapper reports every rule
        # satisfied, and two checks shipped that way here in one week.
        $Wrappers.Count | Should -BeGreaterThan 0 `
            -Because 'pages delegate to VmfHelp.storeBlob'
        @($Wrappers | Where-Object { $_.Asked.Count -gt 0 }).Count |
            Should -BeGreaterThan 0 -Because 'at least one caller passes an option'
    }

    It 'reads the Migrations page helper that broke, with both of its options' {
        # Named on purpose. If the page is renamed or the helper rewritten, this
        # fails and somebody re-points the check, rather than the check quietly
        # ceasing to cover the thing it was written for.
        $mig = $Wrappers |
            Where-Object { $_.Page -eq 'migrations.html' -and $_.Helper -eq 'blobFetch' } |
            Select-Object -First 1
        $mig | Should -Not -BeNullOrEmpty
        $mig.Asked | Should -Contain 'asVersioned' `
            -Because 'PLANVER-2 asks this page for the version the service issued'
        $mig.Asked | Should -Contain 'asText'
        $mig.Forwards | Should -Contain 'asVersioned'
    }

    It 'forwards every option its callers pass, on every page' {
        # ONE LOOP, NOT A CASE PER WRAPPER. The first version made each wrapper
        # a Pester case with -ForEach and read $Page / $Asked in the body. Those
        # never bound - the case data did not cross into an It nested inside a
        # Describe that also has -ForEach - so $Asked was $null, the loop ran
        # ZERO times, and every case passed. The test NAME still expanded, so it
        # read as eight checks doing their job.
        #
        # Mutation found it: the rule survived the exact defect it was written
        # for. A check that cannot fail is worse than no check, because it is
        # counted. Hence $checked below - it says how many rules were really
        # applied, and nothing here can pass on an empty collection again.
        $checked = 0
        $dropped = @()
        foreach ($wrapper in $Wrappers) {
            foreach ($option in $wrapper.Asked) {
                $checked++
                if ($wrapper.Forwards -notcontains $option) {
                    $dropped += "$($wrapper.Page): $($wrapper.Helper) is asked for " +
                                "'$option' and does not pass it on"
                }
            }
        }

        $checked | Should -BeGreaterThan 0 `
            -Because 'a rule applied to nothing is not a rule'

        # THE RULE. An option a caller passes and the helper does not hand on is
        # dropped in silence, and the next line reads undefined.
        ($dropped -join '; ') | Should -BeNullOrEmpty -Because (
            'a page helper must forward every option its callers pass to ' +
            'VmfHelp.storeBlob. A dropped option throws nothing and makes the ' +
            'next line lie - that is how Approve broke with ' +
            '"undefined" is not valid JSON.')
    }
}
