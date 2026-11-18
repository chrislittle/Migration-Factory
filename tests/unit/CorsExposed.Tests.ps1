# CORS-1: a response header the dashboard READS must be one the facade EXPOSES.
#
# THE DEFECT, measured against a live install on 2026-09-18. PLANVER-2 returns a
# document's version in `x-vmf-document-version`, beside the document, so a page
# can name the plan it was shown. The page read it like this:
#
#     version: r.headers.get('x-vmf-document-version') || ''
#
# and got NULL. Every time. The dashboard and the facade are different origins,
# and a browser hands JavaScript only the CORS-safelisted response headers
# unless the server names the rest in `Access-Control-Expose-Headers`. Nothing
# named it.
#
# So the page approved a wave with an EMPTY version and the gate refused it:
#
#     400: the plan version being approved is required
#
# The approval could not be given at all - on the one install where somebody
# was trying to run a migration.
#
# WHY NOTHING SAW IT. The header was always sent. Nothing dropped it, nothing
# logged a problem, and the service was behaving exactly as written. The browser
# declined to hand it over, which is the specified behaviour.
#
# AND THE ONE TEST BUILT TO PROVE THIS PATH END TO END COULD NOT SEE IT: the
# flow drill reads the header with Invoke-WebRequest. PowerShell is not a
# browser and has no CORS, so the drill saw the header the whole time. A test
# that runs somewhere the defect cannot occur proves nothing about the place it
# does.
#
# This check is the closest a test here can get to the browser's rule. It is
# static on purpose: no test in this repository can make a cross-origin request.

. (Join-Path $PSScriptRoot '_CodeOnly.ps1')

# The seven headers a browser hands over without being asked. Everything else
# needs naming. https://fetch.spec.whatwg.org/#cors-safelisted-response-header-name
$script:vmfSafelisted = @(
    'cache-control', 'content-language', 'content-length',
    'content-type', 'expires', 'last-modified', 'pragma'
)

$script:vmfRepo = Join-Path $PSScriptRoot '..' '..'

# Every response header the dashboard reads, from its CODE, not its comments -
# the fix's own write-up names the header several times over.
$script:vmfHeadersRead = @(
    Get-ChildItem -LiteralPath (Join-Path $script:vmfRepo 'src' 'dashboard') -Recurse -File |
        Where-Object { $_.Extension -in '.js', '.html' } |
        ForEach-Object {
            $code = Get-VmfCodeOnly -Path $_.FullName
            foreach ($m in [regex]::Matches($code, 'headers\s*\.\s*get\s*\(\s*[''"]([^''"]+)[''"]')) {
                [pscustomobject]@{ File = $_.Name; Header = $m.Groups[1].Value }
            }
        }
)

# Every header the facade says a browser may read.
$script:vmfExposed = @(
    Get-ChildItem -LiteralPath (Join-Path $script:vmfRepo 'src' 'facade') -Recurse -File -Filter '*.ps*1' |
        ForEach-Object { Get-VmfCodeOnly -Path $_.FullName } |
        ForEach-Object {
            foreach ($m in [regex]::Matches($_, "Access-Control-Expose-Headers'?\s*=\s*'([^']+)'")) {
                $m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() }
            }
        }
) | Where-Object { $_ }

Describe 'CORS-1: the browser can read what the page reads' -ForEach @(
    @{ Read = $script:vmfHeadersRead; Exposed = $script:vmfExposed; Safe = $script:vmfSafelisted; Repo = $script:vmfRepo }
) {

    # Dot-sourced again: Pester discovers and RUNS in separate scopes, so the
    # helper loaded at the top of this file is not in reach from an It body.
    BeforeAll { . (Join-Path $PSScriptRoot '_CodeOnly.ps1') }
    It 'found the header the defect was about, so this cannot pass on nothing' {
        # THE VACUITY GUARD. A scan that finds no reader reports every rule
        # satisfied. Named explicitly: if PLANVER-2's header stops being read,
        # somebody re-points this check rather than it quietly covering nothing.
        $Read.Count | Should -BeGreaterThan 0 -Because 'the dashboard reads at least one response header'
        @($Read | Where-Object { $_.Header -eq 'x-vmf-document-version' }).Count |
            Should -BeGreaterThan 0 -Because 'the page names the plan version it was shown'
    }

    It 'the facade exposes at least one header, so the expose list is real' {
        $Exposed.Count | Should -BeGreaterThan 0 -Because 'a list nobody writes cannot be checked'
        $Exposed | Should -Contain 'x-vmf-document-version'
    }

    It 'every non-safelisted header the dashboard reads is exposed by the facade' {
        $missing = @()
        $checked = 0
        foreach ($use in $Read) {
            if ($Safe -contains $use.Header.ToLowerInvariant()) { continue }
            $checked++
            # THE RULE. A browser returns null for a header nobody exposed, and
            # null is indistinguishable from "the service did not send one".
            if ($Exposed -notcontains $use.Header) {
                $missing += "$($use.File) reads '$($use.Header)' and no facade response exposes it"
            }
        }
        $checked | Should -BeGreaterThan 0 -Because 'a rule applied to nothing is not a rule'
        ($missing -join '; ') | Should -BeNullOrEmpty -Because (
            'the dashboard and the facade are different origins, so a custom ' +
            'response header is invisible to JavaScript until the service names ' +
            'it in Access-Control-Expose-Headers. It reads as null, which looks ' +
            'exactly like a service that sent nothing.')
    }

    It 'the version header and its permission are issued together, by one builder' {
        # Two branches of the blob read used to build the header each. Two
        # places to add the permission to is one place to forget it.
        $core = Get-VmfCodeOnly -Path (Join-Path $Repo 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Match 'function Get-VmfDocumentVersionHeaders'
        $blob = Get-VmfCodeOnly -Path (
            Join-Path $Repo 'src' 'facade' 'app' 'GetStoreBlob' 'run.ps1')
        $blob | Should -Not -Match "Headers\s*=\s*@\{\s*'x-vmf-document-version'" `
            -Because 'the header is built in one place, with the permission beside it'
        @([regex]::Matches($blob, 'Get-VmfDocumentVersionHeaders')).Count |
            Should -Be 2 -Because 'both the local-store branch and the blob branch return it'
    }
}
