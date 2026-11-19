#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ACCEPT-HASH-2: every page that accepts wave settings says WHICH plan it is
# agreeing to.
#
# WHY THIS FILE EXISTS. The service refuses an acceptance that is not bound to
# a plan version - "400: the plan version being accepted is required" - because
# an agreement that names no version proves nothing about what was chosen.
#
# TWO PAGES ACCEPT. The Migrations page computed the version. The WIZARD never
# did, so the Accept button in the flow answered 400 from the day it was
# written. Nobody noticed, because the page shows the refusal and a person
# takes the other route to the same thing.
#
# It was found on 2026-09-16 by the flow drill (TESTPLAN-2) on its first run
# against a real install, and only because the drill sends what the WIZARD
# sends. PROJECT-2 had already read that same 400 the day before and closed
# PLANVER-1 on it, deciding it was a symptom of a path defect. The path defect
# was real; this was a second cause with the same message.
#
# So the rule, not the instance: if a page calls accept-options, it must send a
# plan version with it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:pages = @(Get-ChildItem $script:dash -Filter '*.html' -File)
}

Describe 'ACCEPT-HASH-2: an acceptance names the plan it is accepting' {

    It 'there are pages to check, so this cannot pass by finding none' {
        $script:pages.Count | Should -BeGreaterThan 5
    }

    It 'THE DEFECT: every page that accepts sends a plan version' {
        $accepting = @()
        foreach ($page in $script:pages) {
            $code = Get-VmfCodeOnly -Path $page.FullName
            if ($code -notmatch 'accept-options') { continue }
            $accepting += $page.Name
            $code | Should -Match 'planHash' `
                -Because "$($page.Name) calls accept-options, and the service refuses one with no plan version"
        }
        # The wizard and the Migrations page both accept. If that ever drops to
        # one, this test is checking half of what it thinks it is.
        $accepting.Count | Should -BeGreaterOrEqual 2 -Because "only $($accepting -join ', ') accept"
    }

    It 'PLANVER-2: and it QUOTES the version the service issued, never derives one' {
        # THE MECHANISM CHANGED AND THE PROPERTY DID NOT.
        #
        # A page used to hash the plan text it had fetched. That is the right
        # property - name the plan you were shown - by a mechanism that quietly
        # required the document to travel BYTE FOR BYTE through a JSON service.
        # MEASURED 2026-09-17 against a real install: the same blob at the same
        # path produced one version in the service and another in the caller,
        # and no candidate reading of a byte-order mark or a newline closed it.
        # The acceptance was refused for ever, on both pages.
        #
        # The service issues the version now, over the bytes it read from the
        # store, beside the document in ONE response. A page quotes it.
        foreach ($page in $script:pages) {
            $code = Get-VmfCodeOnly -Path $page.FullName
            if ($code -notmatch 'planHash') { continue }
            $code | Should -Match 'asVersioned|readVersioned' `
                -Because "$($page.Name) must ask the service for the version"
        }
    }

    It 'PLANVER-2: NO page computes a plan version at all, anywhere' {
        # The strongest form of the rule, and the reason the old helper was
        # DELETED rather than left exported. A function that computes a value
        # callers must not compute is a trap: it keeps looking correct, and the
        # next person who needs a version will find it and use it.
        $help = Get-VmfCodeOnly -Path (Join-Path $script:dash 'help.js')
        $help | Should -Not -Match 'function planVersion' `
            -Because 'the browser does not compute this, so the means to must not be lying about'
        $help | Should -Not -Match 'crypto\.subtle\.digest'
        foreach ($page in $script:pages) {
            $code = Get-VmfCodeOnly -Path $page.FullName
            $code | Should -Not -Match 'crypto\.subtle\.digest' `
                -Because "$($page.Name) must not work out a document version in the browser"
        }
    }

    It 'and the SERVICE issues one, over the bytes it read from the store' {
        # The other half. Without this, the rule above is satisfied by nobody
        # computing a version anywhere and an acceptance could never be bound.
        # CORS-1 moved the header out of this file into one builder, so that the
        # PERMISSION a browser needs to read it is issued beside it and cannot
        # be added to one branch and forgotten on the other. The rule is
        # unchanged - both branches issue the version - so it is counted where
        # it now lives.
        $endpoint = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'GetStoreBlob' 'run.ps1')
        @([regex]::Matches($endpoint, 'Get-VmfDocumentVersionHeaders')).Count | Should -Be 2 `
            -Because 'both the blob-backed and the file-backed store must issue it'
        $core = Get-VmfCodeOnly -Path (
            Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Match 'x-vmf-document-version' `
            -Because 'the builder issues the version header'
        $core | Should -Match 'Get-VmfDocumentVersion ' `
            -Because 'and it is the same function the gates compare against'
    }

    It 'and the service still refuses an acceptance that names no plan' {
        # The gate this is all in service of. If this check ever goes, the
        # tests above are guarding a rule nothing enforces.
        $endpoint = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostAcceptWaveOptions' 'run.ps1')
        $endpoint | Should -Match "if \(-not \`$body\.planHash\) \{ throw '400"
    }
}
