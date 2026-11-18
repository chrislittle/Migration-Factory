#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANUAL-REVIEW-1, area A: the use and install pages, the manual's opening
# page, What this product does, and the README where it repeats the manual.
#
# The review checked each sentence against the code. These are the findings
# that have a shape a machine can check, so that they cannot come back:
#
#   * The README said a Windows machine "must be deleted and created again" on
#     a move to v6 or v7. No move deletes a machine (REBUILD-REMOVE-1).
#     RebuildRemoveDocs.Tests.ps1 looks for "rebuil" and "recreat", and this
#     sentence used neither word.
#   * The install pages said the product "can do nothing yet" after the
#     install. The default answer of the install is scan and migrate
#     (preprovision.ps1), and postprovision.ps1 prints that it may SCAN AND
#     MIGRATE.
#   * The sample readiness table named two rows that the check does not have,
#     a region, and lab counts.
#   * "Reservation" alone, where Azure's name is on-demand capacity
#     reservation, or Azure Reservations for the billing product.
#   * Sentences about records from an earlier version, which no 1.0 install
#     holds (2026-11-11).
#   * Lab words and lab measurements shown to an operator.
#   * A command-line grant in place of the Admin page (hard rule 12).
#   * finish.md said each next wave needs a sign-off. A signed-off plan
#     starts the next wave by itself (Approve-VmfPlan.ps1).
#   * sign-in.md said the page tries again on its own when the service is
#     starting. Only the wizard says it, and it asks the person to try again.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'

    $script:areaFiles = @(
        @(Get-ChildItem -Path (Join-Path $script:manual 'use') -Filter '*.md' -File)
        @(Get-ChildItem -Path (Join-Path $script:manual 'install') -Filter '*.md' -File)
        Get-Item (Join-Path $script:manual 'README.md')
        Get-Item (Join-Path $script:manual 'understand' 'what-it-does.md')
        Get-Item (Join-Path $script:repoRoot 'README.md')
    )

    # The prose of a page: code blocks dropped, each line split into
    # sentences. A table row stays one unit.
    function Get-AreaSentences {
        param([System.IO.FileInfo]$File)
        $inCode = $false
        foreach ($line in ([System.IO.File]::ReadAllText($File.FullName) -split "`n")) {
            if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
            if ($inCode) { continue }
            $pieces = if ($line.TrimStart().StartsWith('|')) { @($line) } else { $line -split '(?<=[.!?])\s+' }
            foreach ($piece in $pieces) { $t = $piece.Trim(); if ($t) { [pscustomobject]@{ File = $File.Name; Text = $t } } }
        }
    }
    $script:sentences = @(foreach ($f in $script:areaFiles) { Get-AreaSentences -File $f })

    function Read-ManualPage { param([string[]]$Parts) [System.IO.File]::ReadAllText((Join-Path $script:manual ($Parts -join [System.IO.Path]::DirectorySeparatorChar))) }
}

Describe 'MANUAL-REVIEW-1 area A: the use and install pages match the product' {

    It 'reads every page of the area' {
        $script:areaFiles.Count | Should -BeGreaterThan 25
        $script:sentences.Count | Should -BeGreaterThan 500
    }

    It 'never says that a move deletes a machine and creates it again' {
        $hits = @($script:sentences | Where-Object { $_.Text -match '(?i)\bcreated again\b|\bdeleted and (re-?)?created\b|\bdelete[sd]? (the|a) machine and\b' } |
            ForEach-Object { "$($_.File): $($_.Text)" })
        $hits | Should -BeNullOrEmpty -Because 'no move deletes a machine (REBUILD-REMOVE-1)'
    }

    It 'says what the install gives with its default answer, as postprovision prints it' {
        $post = Get-VmfCodeOnly -Language PowerShell -Text ([System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')))
        $pre = Get-VmfCodeOnly -Language PowerShell -Text ([System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')))
        $pre | Should -Match "\`$default = 'migrate'" -Because 'the default answer is scan and migrate'
        $line = [regex]::Match($post, 'Write-Host "   (This install may SCAN AND MIGRATE machines in subscription) \$subId\."')
        $line.Success | Should -BeTrue -Because 'postprovision prints what a default install may do'
        $steps = Read-ManualPage 'install', 'step-by-step.md'
        $steps | Should -Match ([regex]::Escape($line.Groups[1].Value + ' <subscription id>.'))
        foreach ($rel in @(@('install', 'after-install.md'), @('install', 'step-by-step.md'), @('install', 'before-you-install.md'))) {
            $text = Read-ManualPage $rel
            $text | Should -Not -Match '(?i)can do nothing yet' -Because "$($rel -join '/') must not say the install gives no permission"
            $text | Should -Not -Match '(?i)That is deliberate' -Because 'postprovision prints no such line'
            $text | Should -Not -Match '(?i)starts with no permission over any machine'
        }
        $readme = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'README.md'))
        $readme | Should -Not -Match '(?i)can do nothing yet|starts with no permission over any machine'
    }

    It 'shows only readiness rows that the check writes, with no region and no lab count' {
        $check = Get-VmfCodeOnly -Language PowerShell -Text ([System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'infra' 'hooks' 'Test-VmfReadiness.ps1')))
        $names = @([regex]::Matches($check, "Add-Check '([^']+)'") | ForEach-Object { $_.Groups[1].Value }) + @('Provider Microsoft.App', 'Hosting plan: Free', 'Hosting plan: Basic')
        $check | Should -Match 'Add-Check "Provider \$p"'
        $check | Should -Match 'Add-Check "Hosting plan: \$\(\$room\.Choice\)"'
        $steps = Read-ManualPage 'install', 'step-by-step.md'
        $table = [regex]::Match($steps, '(?s)```\nCheck\s+Result\s+Detail\n(.*?)```')
        $table.Success | Should -BeTrue -Because 'step-by-step.md shows a sample readiness table'
        $rows = @($table.Groups[1].Value -split "`n" | Where-Object { $_.Trim() -and $_.Trim() -ne '...' })
        $rows.Count | Should -BeGreaterThan 8
        foreach ($row in $rows) {
            $label = ($row -split '\s{2,}| (?=(ok|warn|unknown|blocker)\s)')[0].Trim()
            $names | Should -Contain $label -Because "the sample row '$label' must be a row that Test-VmfReadiness.ps1 writes"
        }
        $table.Value | Should -Not -Match '(?i)\b(central|east|west|north|south)\s?(us|europe|asia)\d?\b|\b(centralus|eastus2?|westus\d?|westeurope|northeurope|uksouth)\b' -Because 'a sample names no region'
        $table.Value | Should -Not -Match '\b\d+ of \d+ used' -Because 'a sample gives no lab count'
        $steps | Should -Match '(?m)^Each line says \*\*ok\*\*, \*\*warn\*\*, \*\*unknown\*\* or \*\*blocker\*\*\.' -Because 'a row can say warn (Test-VmfReadiness.ps1, Get-VmfHostingPlanRoom)'
    }

    It 'gives Azure''s name every time: on-demand capacity reservation, or Azure Reservations' {
        $hits = foreach ($s in $script:sentences) {
            foreach ($m in [regex]::Matches($s.Text, '(?i)\breservations?\b')) {
                $before = $s.Text.Substring(0, $m.Index)
                $after = $s.Text.Substring($m.Index + $m.Length)
                if ($before -match '(?i)capacity $') { continue }
                if ($before -match 'Azure $') { continue }
                if ($m.Value -ceq 'Reservation' -and $after -match '^ failed') { continue }   # the label Reservation failed
                "$($s.File): $($s.Text)"
            }
        }
        @($hits) | Should -BeNullOrEmpty
    }

    It 'has no sentence about a record that an earlier version wrote' {
        $hits = @($script:sentences | Where-Object {
                $_.Text -match '(?i)\b(an? )?(earlier|older) version of the product\b|before projects existed|before this version|Outside a project|Not in a project'
            } | ForEach-Object { "$($_.File): $($_.Text)" })
        $hits | Should -BeNullOrEmpty -Because 'no 1.0 install holds such a record (2026-11-11)'
    }

    It 'shows no lab word and no lab measurement to an operator' {
        $hits = @($script:sentences | Where-Object {
                $_.Text -match '(?i)\blab run\b|\bno lab\b|measured, not estimated|measured on 20\d\d|measured on a corporate'
            } | ForEach-Object { "$($_.File): $($_.Text)" })
        $hits | Should -BeNullOrEmpty
    }

    It 'gives the Admin page, never a command, for a grant (hard rule 12)' {
        $hits = @(foreach ($f in $script:areaFiles) {
                if ([System.IO.File]::ReadAllText($f.FullName) -match 'Grant-VmfAccess') { $f.Name }
            })
        $hits | Should -BeNullOrEmpty -Because 'a person gives the product access on the Admin page'
        $post = Get-VmfCodeOnly -Language PowerShell -Text ([System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')))
        $said = @([regex]::Matches($post, 'Write-Host\s+(''[^'']*''|"[^"]*")') | ForEach-Object { $_.Groups[1].Value })
        $said.Count | Should -BeGreaterThan 10
        @($said | Where-Object { $_ -match 'Grant-VmfAccess' }) | Should -BeNullOrEmpty -Because 'the install output names the Admin page, never a command (2026-11-13)'
    }

    It 'says that a signed-off plan starts the next wave, as Approve-VmfPlan does' {
        $approve = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Approve-VmfPlan.ps1'))
        $approve | Should -Match 'approvals/\$w\.json' -Because 'the plan sign-off writes one approval for each wave'
        $finish = Read-ManualPage 'use', 'finish.md'
        $finish | Should -Not -Match 'starts only after the wave before it is reviewed and signed off'
        $finish | Should -Match 'A signed-off plan starts the next wave when this wave finishes\. It does not when a machine waits for a person or the run is paused\.'
    }

    It 'gives the wizard''s own words when the service is starting, and promises no retry' {
        $wizard = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js'))
        $slow = [regex]::Match($wizard, "slow: '([^']+)'")
        $slow.Success | Should -BeTrue
        $signIn = Read-ManualPage 'use', 'sign-in.md'
        $quoted = [regex]::Match($signIn, '\*\*(The service did not answer\. Try again\.)\*\*')
        $quoted.Success | Should -BeTrue
        $slow.Groups[1].Value | Should -Be $quoted.Groups[1].Value
        $signIn | Should -Not -Match '(?i)tries again on its own'
    }

    It 'never says that a move keeps accelerated networking off on the primary network interface' {
        $hits = @($script:sentences | Where-Object { $_.Text -match '(?i)keeps accelerated networking off' } |
            ForEach-Object { "$($_.File): $($_.Text)" })
        $hits | Should -BeNullOrEmpty -Because 'every move turns it on for the primary network interface (AN-MANA-DRIVER-RULE-1)'
    }

    It 'gives no time per machine for a wave (2026-11-13)' {
        $hits = @($script:sentences | Where-Object { $_.Text -match '(?i)each machine takes about \d+|\d+ minutes (per|for each|a|each) machine' } |
            ForEach-Object { "$($_.File): $($_.Text)" })
        $hits | Should -BeNullOrEmpty
    }

    It 'makes no cost or speed claim with no source (2026-11-13)' {
        $hits = @($script:sentences | Where-Object {
                $_.Text -match '(?i)per dollar|for the same money|costs? less per hour|performance for the price|price-performance|cheaper and safer|an engineer an hour|\|\s*(Moderate|Low|Very low)\s*\|'
            } | ForEach-Object { "$($_.File): $($_.Text)" })
        $hits | Should -BeNullOrEmpty
    }

    It 'says when an on-demand capacity reservation stops billing, in the owner''s words, and quotes the labels of the pages' {
        $rule = 'It bills until every machine of the wave has ended and the product releases it, or until you select **Release**.'
        foreach ($rel in @(@('use', 'capacity.md'), @('use', 'wave-settings.md'))) {
            $text = Read-ManualPage $rel
            $text | Should -Match ([regex]::Escape($rule)) -Because "$($rel -join '/') says when it stops billing"
            $text | Should -Not -Match '(?i)until the wave finishes'
        }
        $settings = Read-ManualPage 'use', 'wave-settings.md'
        $settings | Should -Match '\*\*On-demand capacity reservation for this wave\.\*\*'
        @($script:sentences | Where-Object { $_.Text -cmatch '\*\*Capacity reservation for this wave' }) | Should -BeNullOrEmpty
        (Read-ManualPage 'use', 'assess.md') | Should -Match '\*\*What the scan found\*\*'
        @($script:sentences | Where-Object { $_.Text -match '\*\*What we found\*\*' }) | Should -BeNullOrEmpty
        (Read-ManualPage 'use', 'when-a-machine-stops.md') | Should -Not -Match 'engineer should look at'
    }
}
