#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
OUTPUT-ESCAPE-1: no text from a customer machine or from Azure can run as
script in a page the product shows.

Two halves of that are here; the third is in the JavaScript harness.

  1. tests/js/_html-sinks.js reads every dashboard page and follows each value
     a page writes into HTML. It reads CODE ONLY, through its own scanner -
     there is no PowerShell in the browser tests. A reader that kept a comment,
     or lost code after a regular expression, would judge text that is not the
     page. So its scanner is held here to Get-VmfCodeOnly, the one every other
     test uses, on every script of every page: the same input gives the same
     code, character for character.

  2. The customer report is HTML the ENGINE writes, from the same machine and
     Azure text, and the Reports page shows it in a frame. A run whose every
     field a customer machine or Azure can fill holds a payload must give a
     report with no live markup from it.

  3. tests/js/output-escape.test.js runs the pages' own render functions with
     the same payloads.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:node = (Get-Command node -ErrorAction SilentlyContinue)?.Source

    # The payloads: a tag with a handler, a quote that ends an attribute, and a
    # script element.
    $script:tagPayload = '<img src=x onerror=alert(1)>'
    $script:quotePayload = '" onmouseover="alert(2)'
    $script:scriptPayload = '<script>alert(3)</script>'
}

Describe 'the reader of the dashboard reads code the way every other test does' {
    It 'node is here, so the reader runs' {
        $script:node | Should -Not -BeNullOrEmpty -Because 'a check that quietly does not run is the thing the inert-test detector exists to stop'
    }

    It 'keeps exactly the code Get-VmfCodeOnly keeps, in every script of every page' {
        $json = & $script:node (Join-Path $script:repo 'tests' 'js' '_html-sinks.js') --code-only
        $LASTEXITCODE | Should -Be 0
        $scripts = @($json | ConvertFrom-Json -Depth 4)
        $scripts.Count | Should -BeGreaterOrEqual 10 -Because 'eight pages and the two shared scripts'
        foreach ($s in $scripts) {
            $expected = Get-VmfCodeOnly -Text $s.text -Language CStyle
            if ($s.code -cne $expected) {
                $at = 0
                while ($at -lt [Math]::Min($s.code.Length, $expected.Length) -and $s.code[$at] -ceq $expected[$at]) { $at++ }
                $s.code | Should -BeExactly $expected -Because "$($s.file) differs at character $at"
            }
        }
    }
}

Describe 'the customer report shows text from machines and from Azure as text' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-outesc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        foreach ($d in 'state', 'logs', 'approvals', 'acceptances') { New-Item -ItemType Directory -Path (Join-Path $script:runPath $d) -Force | Out-Null }
        $tag = $script:tagPayload
        $quote = $script:quotePayload
        $scr = $script:scriptPayload
        $wave = "w1$quote"
        @{ schemaVersion = 9; kind = 'migration'; runId = 'r1'; createdUtc = '2026-09-23T19:00:00Z' } | ConvertTo-Json | Set-Content (Join-Path $script:runPath 'run.json')
        @{ schemaVersion = 1; generatedUtc = 'x'; assessmentRunId = 'r1'
           entries = @(
               @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/web$tag"; wave = $wave; path = 'A'
                  assessment = @{ sourceSize = "Standard_D2s_v4$tag"; tags = @{ "app$tag" = "billing$quote" } }
                  target = @{ size = 'Standard_D2s_v6' }; planNotes = @("note$scr") },
               @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/db$quote"; wave = $wave; path = 'A'
                  assessment = @{ sourceSize = 'Standard_D2s_v4' }; target = @{ size = "Standard_D2s_v6$tag" }; planNotes = @() })
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')
        # The machine moved, with what the guest said and what Azure said.
        @{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = "/s/rg/vm/web$tag"; state = 'MIGRATED'
           guestExecutions = @(@{ script = "prep$tag"; version = "1$quote"; result = "PASS$scr"; tsUtc = '2026-09-23T20:05:00Z'; evidenceRef = "evidence/x$tag.json" })
           history = @(@{ tsUtc = '2026-09-23T20:00:00Z'; state = 'PRECHECK'; outcome = 'ok'; detail = "Azure said: $tag" },
                       @{ tsUtc = '2026-09-23T20:20:00Z'; state = 'MIGRATED'; outcome = 'ok' }) } |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'state' 'web.json')
        # The machine put back, with a person's note and an Azure error.
        @{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = "/s/rg/vm/db$quote"; state = 'MIGRATED'; guestExecutions = @()
           history = @(@{ tsUtc = '2026-09-23T20:00:00Z'; state = 'PRECHECK'; outcome = 'fail'; detail = "(OperationNotAllowed) $scr" })
           restore = @{ restoredUtc = '2026-09-23T22:00:00Z'; restoredBy = "operator@example.com$tag"; note = "put back $scr"; sizeAfter = "Standard_D2s_v4$quote" } } |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'state' 'db.json')
        @{ schemaVersion = 2; wave = $wave; approvedBy = @{ identity = "approver@example.com$tag" }; approvedUtc = '2026-09-23T19:30:00Z'; note = "ok $scr" } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:runPath 'approvals' 'w1.json')
        @(@{ tsUtc = '2026-09-23T20:01:00Z'; step = 'precheck'; outcome = 'fail'; vmId = "/s/rg/vm/web$tag"; detail = "Azure: $scr"; note = "decided $tag" }) |
            ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 } | Set-Content (Join-Path $script:runPath 'logs' 'events.jsonl')
        @{ schemaVersion = 17; runId = 'r1'; vms = @(); notRead = @(@{ subject = "subscription$tag"; reason = "Forbidden $scr" }) } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:runPath 'assessment.json')
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'writes no payload as markup, anywhere in the report' {
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Not -BeNullOrEmpty
        $html.Contains($script:tagPayload) | Should -BeFalse -Because 'a machine name, a size or a note from a machine must not become an element'
        $html.Contains($script:scriptPayload) | Should -BeFalse -Because 'a note or an Azure error must not become a script'
        $html.Contains($script:quotePayload) | Should -BeFalse -Because 'a quote must not end an attribute'
        $html | Should -Not -Match '(?i)<script\b' -Because 'the report is a static document - it has no script of its own'
        $html | Should -Not -Match '(?i)<[a-z][^>]*\son\w+\s*=' -Because 'no element in the report has an event handler'
    }

    It 'still shows the text, escaped, so a person can read what the machine was called' {
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Match ([regex]::Escape('web&lt;img src=x onerror=alert(1)&gt;')) -Because 'the name is shown, as text'
    }
}
