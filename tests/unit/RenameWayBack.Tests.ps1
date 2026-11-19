#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RENAME-WAY-BACK-1, 2026-11-12: the words "the way back" are bad wording,
# so they are fixed everywhere. The disks the product makes from the first safety
# copy before a move changes anything are ROLLBACK DISKS, and so are the disks a
# rollback makes itself when it cannot use them. Where "the way back"
# meant the act, the words say "rollback", or "a rollback or a restore" when
# both use it. Nothing is public before 1.0, so the names went too, and they say
# WHEN each disk was made (2026-11-12): safety.rollbackDisksBeforeMove and
# the top-level rollbackDisksDuringRollback (vm-state v46), the stop reason
# rollbackDisksBeforeMoveNotMade, *-VmfRollbackDisksBeforeMove*,
# New-VmfRollbackDisksDuringRollback, Add-VmfRollbackDiskDuringRollbackRecord,
# RollbackDisksBeforeMove.ps1, and the service's answer rollbackDisksBeforeMove.
#
# Two checks, so neither can come back:
#
#   1. The words. What an operator reads - the dashboard (markup, and script
#      code with the comments removed, Get-VmfCodeOnly), every page and picture
#      of the manual, the engine's data files, the schema descriptions, every
#      string literal of the module and the service (PowerShell tokenizer), and
#      the architecture document.
#   2. The names, in the code and the contracts: src/, schemas/, and the
#      screenshot fixtures - the whole text, comments too.
#
# "Put back" that means a restore (putBackJob, use/put-back.md) is a different
# word and stays.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))

    $script:badWords = '(?i)\bway[ -]back\b'
    # Case-sensitive on purpose: putBackJob (a restore) stays. PutBackDisk is
    # found inside a function name (New-VmfPutBackDisks); wayBack only as a
    # name of its own, never inside applicationGatewayBackend...
    # And the bare top-level field rollbackDisks: since v46 it says when its disks
    # were made (rollbackDisksDuringRollback), beside rollbackDisksBeforeMove.
    $script:badNames = 'PutBackDisk|(?<![A-Za-z])(putBackDisk|wayBack|WayBack)|(?<![\w$])rollbackDisks(?!BeforeMove|DuringRollback|\w)'

    function Find-VmfMatch {
        param([string]$Where, [string]$Text, [string]$Pattern)
        foreach ($m in [regex]::Matches($Text, $Pattern)) {
            $from = [Math]::Max(0, $m.Index - 40)
            $len  = [Math]::Min($Text.Length - $from, $m.Length + 80)
            "$Where : ...$(($Text.Substring($from, $len)) -replace '\s+', ' ')..."
        }
    }

    function Get-VmfJsonStrings {
        param($Node, [string[]]$Only)
        if ($null -eq $Node) { return }
        if ($Node -is [string]) { if (-not $Only) { $Node }; return }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [System.Collections.IDictionary]) {
            foreach ($item in $Node) { Get-VmfJsonStrings -Node $item -Only $Only }
            return
        }
        if ($Node -is [pscustomobject]) {
            foreach ($prop in $Node.PSObject.Properties) {
                if ($Only -and $prop.Name -in $Only -and $prop.Value -is [string]) { $prop.Value; continue }
                Get-VmfJsonStrings -Node $prop.Value -Only $Only
            }
        }
    }

    # ---- 1. the words ---------------------------------------------------------
    $script:dashboardFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Recurse -File -Include '*.html', '*.js')
    $script:dashboard = foreach ($file in $script:dashboardFiles) {
        if ($file.Extension -eq '.js') { $text = Get-VmfCodeOnly -Path $file.FullName }
        else {
            $text = [regex]::Replace((Get-VmfPageSource -Path $file.FullName), '(?s)<!--.*?-->', ' ')
            $text = [regex]::Replace($text, '(?is)(<script\b[^>]*>)(.*?)(</script>)', {
                    param($m) $m.Groups[1].Value + (Get-VmfCodeOnly -Text $m.Groups[2].Value -Language CStyle) + $m.Groups[3].Value
                })
        }
        [pscustomobject]@{ Where = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName); Text = $text }
    }
    $script:manualFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -File -Include '*.md', '*.svg')
    $script:manual = foreach ($file in $script:manualFiles) {
        [pscustomobject]@{ Where = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName); Text = (Get-Content -LiteralPath $file.FullName -Raw) }
    }
    $script:dataValues = foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data') -Filter '*.json' -File) {
        foreach ($s in (Get-VmfJsonStrings -Node (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json))) {
            [pscustomobject]@{ Where = "data/$($file.Name)"; Text = $s }
        }
    }
    $script:schemaText = foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'schemas') -Filter '*.json' -File) {
        foreach ($s in (Get-VmfJsonStrings -Node (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json) -Only 'description', 'title')) {
            [pscustomobject]@{ Where = "schemas/$($file.Name)"; Text = $s }
        }
    }
    $psFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory'), (Join-Path $script:repoRoot 'src' 'facade') -Recurse -File -Include '*.ps1', '*.psm1')
    $script:psStrings = foreach ($file in $psFiles) {
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errs)
        foreach ($tok in $tokens) {
            if ($tok -is [System.Management.Automation.Language.StringToken]) {
                [pscustomobject]@{ Where = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName); Text = $tok.Text }
            }
        }
    }
    $archPath = Join-Path $script:repoRoot 'docs' 'architecture' 'architecture.html'
    $script:architecture = [pscustomobject]@{ Where = 'docs/architecture/architecture.html'; Text = (Get-Content -LiteralPath $archPath -Raw) }

    # ---- 2. the names ---------------------------------------------------------
    $codeFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'src'), (Join-Path $script:repoRoot 'schemas') -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.js', '.html', '.json' -and $_.Name -notmatch '\.min\.js$' }) +
        @(Get-Item (Join-Path $script:repoRoot 'tools' 'manual-shots.js'), (Join-Path $script:repoRoot 'tools' 'New-VmfManualSampleRun.ps1'))
    $script:code = foreach ($file in $codeFiles) {
        [pscustomobject]@{ Where = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName); Text = (Get-Content -LiteralPath $file.FullName -Raw) }
    }
    $script:codeFileCount = $codeFiles.Count
}

Describe 'RENAME-WAY-BACK-1: the check itself' {

    It 'catches the words and the names it removed' {
        foreach ($s in 'the disks for the way back', 'Safety copies and the way back', 'The Way Back', 'a way-back disk') {
            @(Find-VmfMatch -Where 'probe' -Text $s -Pattern $script:badWords).Count | Should -BeGreaterThan 0 -Because "'$s' is the wording this item removed"
        }
        foreach ($s in 'safety.putBackDisks', 'New-VmfPutBackDisks', '$wayBack = 1', 'r.wayBackDisks', "'putBackDiskNotMade'", '$doc.rollbackDisks', "-List 'rollbackDisks'") {
            @(Find-VmfMatch -Where 'probe' -Text $s -Pattern $script:badNames).Count | Should -BeGreaterThan 0 -Because "'$s' is a name this item removed"
        }
    }

    It 'leaves alone a restore, and words that only contain the letters' {
        foreach ($s in 'putBackJob', 'Get-VmfPutBackCapture', 'applicationGatewayBackendAddressPools', 'the gateway backend pool', 'safety.rollbackDisksBeforeMove', '$doc.rollbackDisksDuringRollback', '$rollbackDisksBeforeMove = 1', 'the rollback disks') {
            @(Find-VmfMatch -Where 'probe' -Text $s -Pattern $script:badNames).Count | Should -Be 0 -Because "'$s' is not one of the removed names"
            @(Find-VmfMatch -Where 'probe' -Text $s -Pattern $script:badWords).Count | Should -Be 0 -Because "'$s' is not the removed wording"
        }
    }

    It 'read a meaningful amount of every source, so it cannot pass by reading nothing' {
        $script:dashboardFiles.Count | Should -BeGreaterThan 10
        $script:manualFiles.Count | Should -BeGreaterThan 40
        @($script:dataValues).Count | Should -BeGreaterThan 500
        @($script:schemaText).Count | Should -BeGreaterThan 100
        @($script:psStrings).Count | Should -BeGreaterThan 5000
        $script:architecture.Text.Length | Should -BeGreaterThan 100000
        $script:codeFileCount | Should -BeGreaterThan 300
        # The code-only reading keeps the strings a page shows.
        (@($script:dashboard | Where-Object Where -match 'migrations\.js$')[0].Text) | Should -Match 'A rollback or a restore of a machine uses these copies'
    }
}

Describe 'RENAME-WAY-BACK-1: an operator reads "rollback disk" and "rollback", never "the way back"' {

    It 'the dashboard' {
        @($script:dashboard | ForEach-Object { Find-VmfMatch -Where $_.Where -Text $_.Text -Pattern $script:badWords }) | Should -BeNullOrEmpty
    }

    It 'the manual, its pages and its pictures' {
        @($script:manual | ForEach-Object { Find-VmfMatch -Where $_.Where -Text $_.Text -Pattern $script:badWords }) | Should -BeNullOrEmpty
    }

    It 'the data files the engine and the manual read (stop reasons, roles)' {
        @($script:dataValues | ForEach-Object { Find-VmfMatch -Where $_.Where -Text $_.Text -Pattern $script:badWords }) | Should -BeNullOrEmpty
    }

    It 'the schema descriptions' {
        @($script:schemaText | ForEach-Object { Find-VmfMatch -Where $_.Where -Text $_.Text -Pattern $script:badWords }) | Should -BeNullOrEmpty
    }

    It 'the messages the module and the service write' {
        @($script:psStrings | ForEach-Object { Find-VmfMatch -Where $_.Where -Text $_.Text -Pattern $script:badWords }) | Should -BeNullOrEmpty
    }

    It 'the architecture document' {
        @(Find-VmfMatch -Where $script:architecture.Where -Text $script:architecture.Text -Pattern $script:badWords) | Should -BeNullOrEmpty
    }
}

Describe 'RENAME-WAY-BACK-1: the names say rollback disk too' {

    It 'no field, function, variable, reason code or response key in src, schemas or the screenshot fixtures carries the old name' {
        @($script:code | ForEach-Object { Find-VmfMatch -Where $_.Where -Text $_.Text -Pattern $script:badNames }) | Should -BeNullOrEmpty
    }

    It 'the new names are there' {
        $all = ($script:code | ForEach-Object Text) -join "`n"
        foreach ($n in 'rollbackDisksBeforeMove', 'rollbackDisksDuringRollback', 'rollbackDisksBeforeMoveNotMade', 'New-VmfRollbackDisksBeforeMove', 'New-VmfRollbackDisksDuringRollback', 'Add-VmfRollbackDiskDuringRollbackRecord', 'Get-VmfDueRollbackDisksBeforeMove') {
            $all | Should -Match ([regex]::Escape($n)) -Because "$n is the new name"
        }
        Test-Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RollbackDisksBeforeMove.ps1') | Should -BeTrue
        Test-Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RollbackDisks.ps1') | Should -BeFalse
        Test-Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PutBackDisks.ps1') | Should -BeFalse
    }
}

Describe 'RENAME-WAY-BACK-1: the lock note says what removing the lock allows' {
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
        . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
        Block-VmfAzureCalls -TestFile $PSCommandPath
    }

    It 'the note on the lock of each safety copy, word for word (2026-11-12)' {
        $note = InModuleScope VmMigrationFactory { Get-VmfSafetyCopyLockNotes -VmName 'vm1' -RunId 'run1' }
        $note | Should -BeExactly ("VMF safety copy of vm1 for migration run run1. The product removes this lock and deletes the copy when the wave's accepted retention ends. " +
            'If you remove this lock by hand, a user can delete this copy. Then a rollback or a restore of this machine cannot use it.')
    }
}