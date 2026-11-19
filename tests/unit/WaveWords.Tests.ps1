#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-WORDS-3: the manual names each wave setting and each value as the
# wave editor does. tests/js/wave-words.test.js holds the three pages to one
# name; this holds the manual to the same names.
#
# The manual used to list the other names a screen gave a setting ("In that
# dialog, the sign-off setting is called ..."). The screens now agree, so the
# manual says one name, and the reference page lists the editor's values.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'
    $script:pages = Get-ChildItem $script:manual -Recurse -Filter '*.md' |
        ForEach-Object { [pscustomobject]@{ Name = $_.FullName.Substring($script:manual.Length + 1); Text = (Get-VmfPageSource -Path $_.FullName) } }
    $waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
    # The editor's own words, read from its string table.
    $script:editor = @{}
    foreach ($key in 'capLabel', 'capOnDemand', 'capReserved', 'approvalOn', 'dataLabel', 'dataStop', 'dataProceed',
                     'keepLabel', 'atOnceLabel') {
        $m = [regex]::Match($waves, "(?m)^  $key\s*:\s*'([^']*)',")
        $m.Success | Should -BeTrue -Because "the wave editor declares $key"
        $script:editor[$key] = $m.Groups[1].Value
    }
    $script:reference = [System.IO.File]::ReadAllText((Join-Path $script:manual 'reference' 'wave-settings.md'))
    $script:refRow = {
        param([string]$Label)
        $line = ($script:reference -split "`n") | Where-Object { $_.StartsWith("| $Label |") } | Select-Object -First 1
        if (-not $line) { return $null }
        ($line.Trim().Trim('|') -split '\|')[1].Trim()
    }
}

Describe 'WAVE-WORDS-3: the manual uses one name for each wave setting' {

    It 'no manual page names a setting or a value by a name the screens no longer show' {
        $gone = 'Pay as you go', 'standard allocation', 'How this wave gets its hardware',
                'must approve before this wave runs', '**Reserved capacity**'
        $bad = foreach ($page in $script:pages) {
            foreach ($g in $gone) { if ($page.Text.Contains($g)) { "$($page.Name): $g" } }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty
    }

    It 'WAVE-WORDS-4: no operator text says "reserved capacity" or "None requested"' {
        # Azure names the thing a Reserved wave makes an on-demand capacity
        # reservation, and the editor names the other value None. The card,
        # the step words, the report, the manual and the engine messages said
        # "reserved capacity" and "None requested" for them. The code of each
        # page and each engine file is read without its comments
        # (COMMENT-TRAP-1): a comment is not operator text, and the history in
        # one would otherwise fail this. Azure's "Reserved VM Instances" is
        # another thing, and neither phrase is in its name.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $gone = 'reserved capacity', 'None requested'
        $files = @(
            Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -File -Include '*.html', '*.js' -Recurse |
                Where-Object Name -ne 'msal-browser.min.js'
            Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -File -Include '*.ps1', '*.psm1' -Recurse
            Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade') -File -Include '*.ps1', '*.psm1', '*.js' -Recurse
        )
        $files.Count | Should -BeGreaterThan 50 -Because 'the scan reads the pages and the engine, not nothing'
        $bad = foreach ($file in $files) {
            $code = Get-VmfCodeOnly -Path $file.FullName
            foreach ($g in $gone) {
                if ($code.IndexOf($g, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { "$($file.Name): $g" }
            }
        }
        $bad += foreach ($page in $script:pages) {
            foreach ($g in $gone) {
                if ($page.Text.IndexOf($g, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { "$($page.Name): $g" }
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty
    }

    It 'the reference page lists each setting by the editor name, with the editor values' {
        $e = $script:editor
        & $script:refRow $e.capLabel      | Should -Be "$($e.capOnDemand), $($e.capReserved)"
        & $script:refRow $e.approvalOn    | Should -Be 'Yes, No'
        & $script:refRow $e.dataLabel     | Should -Be "$($e.dataStop), $($e.dataProceed)"
        # WAVE-KERNEL-LINE-1: no wave has a kernel setting, so the page lists none.
        & $script:refRow 'If the kernel is below the minimum version that Microsoft lists for MANA' | Should -BeNullOrEmpty
        # REBUILD-REMOVE-ACCEPT-1: the identity setting is gone from the editor and the page.
        & $script:refRow 'If a machine would get a new system-assigned identity' | Should -BeNullOrEmpty
        & $script:refRow $e.keepLabel     | Should -Not -BeNullOrEmpty
        & $script:refRow $e.atOnceLabel   | Should -Not -BeNullOrEmpty
    }

    It 'the retention range on the reference page is the range the plan contract allows' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $days = $schema.properties.policy.properties.keepSnapshotDays
        $days | Should -Not -BeNullOrEmpty -Because 'the contract states the range'
        & $script:refRow $script:editor.keepLabel | Should -Be "$($days.minimum) to $($days.maximum) days"
    }

    It 'the guide page names the capacity values as the editor does' {
        $use = ($script:pages | Where-Object Name -eq (Join-Path 'use' 'wave-settings.md')).Text
        $use | Should -Match ([regex]::Escape("**$($script:editor.capOnDemand)**, or **$($script:editor.capReserved)**"))
    }
}
