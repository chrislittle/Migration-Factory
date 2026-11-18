#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# TERM-ROLLBACK-1, 2026-09-26. The product said "put back" on about 180 lines
# for the act Microsoft's v6/v7 pages call a ROLLBACK - and the engine's own
# state was already FAILED_ROLLED_BACK. "Put back" is not a good term, and it
# is not an Azure term. It is CLAUDE.md rule 10's failure: a softer word
# invented for something that already has a name.
#
# This check is what stops it coming back. It reads what an operator READS:
#
#   * the dashboard - page markup, and the strings and code of its scripts with
#     the comments removed (Get-VmfCodeOnly), so a comment about PUTBACK-TILE-1
#     is not a finding and an identifier such as putBack or putBackDone never
#     matches (the words need a space or a hyphen between them);
#   * every page of the operator's manual, less its link targets - the page
#     file is still use/put-back.md, because links and bookmarks depend on it;
#   * every string value in src/VmMigrationFactory/data/*.json;
#   * every description and title in schemas/*.json;
#   * every string literal in the module and the service - event details,
#     warnings, refusals - read with the PowerShell tokenizer, so comment-based
#     help and comments stay out.
#
# THE ALLOWED PHRASES are the uses that do NOT mean a rollback: a machine that
# goes back into the queue, and the settings a Path B rebuild applies again.
# Each one must still be present, so the list cannot rot into a hole.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:bad = @(
        '(?i)\bput(s|ting)?[- ]back\b'
        '(?i)\bput(s|ting)?\s+(it|them|the machine|a machine|this machine|that machine|machines|its disk)\s+back\b'
        # Case-sensitive on purpose: putBack is an identifier and an enum value
        # stored in documents, and it stays.
        '\b(Putback|putback|PUTBACK)\b'
    )

    # Uses that mean something other than a rollback. Matched without case.
    $script:allowed = @(
        # REBUILD-REMOVE-ENGINE-1: the two RebuildFidelity phrases went with the rebuild refusal.
        # REBUILD-REMOVE-ROLE-1: 'the rebuild cannot put it back' went with Get-VmfRebuildConfigExtras.
        # ROLLBACK-ORIGINALS-LEFT-1: words approved on 2026-11-08 for the
        # panel part Original disks, not in use. They say that the rollback did not
        # attach the original disks again - the disks, not the act of a rollback.
        'The rollback did not put them back'
        # RESERVATION-RESULT-WORDS-1: words approved on 2026-11-14 for
        # the line after a rollback reads the capacity reservation group. They
        # say which group the machine goes into - the group, not the act of a
        # rollback, which the same sentence names.
        'has no group to put it back in'
        'puts it back in that group'
    )

    function Find-VmfPutBack {
        param([string]$Where, [string]$Text)
        $clean = $Text
        foreach ($a in $script:allowed) {
            $clean = [regex]::Replace($clean, [regex]::Escape($a), ' ', 'IgnoreCase')
        }
        foreach ($pattern in $script:bad) {
            foreach ($m in [regex]::Matches($clean, $pattern)) {
                $from = [Math]::Max(0, $m.Index - 40)
                $len  = [Math]::Min($clean.Length - $from, $m.Length + 80)
                "$Where : ...$(($clean.Substring($from, $len)) -replace '\s+', ' ')..."
            }
        }
    }

    function Get-VmfJsonStrings {
        # Every string VALUE in a parsed JSON document; property names are keys
        # and are not read. With -Only, just the values of those property names.
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

    # ---- the dashboard: markup, and script code with comments removed ------
    $script:dashboardFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Recurse -File -Include '*.html', '*.js')
    $script:dashboard = foreach ($file in $script:dashboardFiles) {
        $raw = (Get-VmfPageSource -Path $file.FullName)
        if ($file.Extension -eq '.js') {
            $text = Get-VmfCodeOnly -Path $file.FullName
        }
        else {
            $text = [regex]::Replace($raw, '(?s)<!--.*?-->', ' ')
            $text = [regex]::Replace($text, '(?is)<style\b.*?</style>', ' ')
            $text = [regex]::Replace($text, '(?is)(<script\b[^>]*>)(.*?)(</script>)', {
                    param($m) $m.Groups[1].Value + (Get-VmfCodeOnly -Text $m.Groups[2].Value -Language CStyle) + $m.Groups[3].Value
                })
        }
        [pscustomobject]@{ Where = "src/dashboard/$([System.IO.Path]::GetRelativePath((Join-Path $script:repoRoot 'src' 'dashboard'), $file.FullName) -replace '\\', '/')"; Text = $text }
    }

    # ---- the manual, less link targets -------------------------------------
    $script:manualFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -File -Include '*.md', '*.svg')
    $script:manual = foreach ($file in $script:manualFiles) {
        $text = (Get-VmfPageSource -Path $file.FullName)
        $text = [regex]::Replace($text, '(?s)<!--.*?-->', ' ')
        $text = [regex]::Replace($text, '\]\([^)]*\)', ']()')
        [pscustomobject]@{ Where = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName); Text = $text }
    }

    # ---- the engine's data files: every string value ------------------------
    $script:dataValues = foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data') -Filter '*.json' -File) {
        $doc = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        foreach ($s in (Get-VmfJsonStrings -Node $doc)) {
            [pscustomobject]@{ Where = "data/$($file.Name)"; Text = $s }
        }
    }

    # ---- the schemas: descriptions and titles --------------------------------
    $script:schemaText = foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'schemas') -Filter '*.json' -File) {
        $doc = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        foreach ($s in (Get-VmfJsonStrings -Node $doc -Only 'description', 'title')) {
            [pscustomobject]@{ Where = "schemas/$($file.Name)"; Text = $s }
        }
    }

    # ---- the module and the service: string literals only -------------------
    $psFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory'), (Join-Path $script:repoRoot 'src' 'facade') -Recurse -File -Include '*.ps1', '*.psm1')
    $script:psStringCount = 0
    $script:psStrings = foreach ($file in $psFiles) {
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errs)
        foreach ($tok in $tokens) {
            if ($tok -is [System.Management.Automation.Language.StringToken]) {
                $script:psStringCount++
                [pscustomobject]@{ Where = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName); Text = $tok.Text }
            }
        }
    }
    $script:psFileCount = $psFiles.Count

    $script:everything = @($script:dashboard) + @($script:manual) + @($script:dataValues) + @($script:schemaText) + @($script:psStrings)
}

Describe 'TERM-ROLLBACK-1: the check itself' {

    It 'catches every form the product used' {
        foreach ($s in 'Put this machine back', 'a put-back of a machine', 'Putting back', 'Putting the machine back now',
                       'The tool put the machine back as it was.', 'it puts it back', '{n} put back', 'the PUTBACK step') {
            @(Find-VmfPutBack -Where 'probe' -Text $s).Count | Should -BeGreaterThan 0 -Because "'$s' is the wording this item removed"
        }
    }

    It 'never matches an identifier, a state name or an allowed use' {
        foreach ($s in 'putBackDone', 'isPutBack(doc)', "=== 'putBack'", 'PUT_BACK:', 'const putBack = 1;',
                       'Restore this machine') {
            @(Find-VmfPutBack -Where 'probe' -Text $s).Count | Should -Be 0 -Because "'$s' is not the operator wording"
        }
    }

    It 'read a meaningful amount of every source, so it cannot pass by reading nothing' {
        $script:dashboardFiles.Count | Should -BeGreaterThan 10
        (@($script:dashboard | Where-Object Where -eq 'src/dashboard/migrations.html')[0].Text.Length) | Should -BeGreaterThan 100000
        $script:manualFiles.Count | Should -BeGreaterThan 40
        @($script:dataValues).Count | Should -BeGreaterThan 500
        @($script:schemaText).Count | Should -BeGreaterThan 100
        $script:psFileCount | Should -BeGreaterThan 100
        $script:psStringCount | Should -BeGreaterThan 5000
    }

    It 'the code-only reading keeps the UX strings a page shows' {
        # A stripper that ate the strings would make every other test here pass.
        $page = @($script:dashboard | Where-Object Where -eq 'src/dashboard/migrations.html')[0].Text
        $page | Should -Match 'Restore this machine'
        $page | Should -Not -Match 'PUTBACK-TILE-1' -Because 'comments are removed'
    }

    It 'every allowed phrase is still in use, so the list cannot hide a new one' {
        $all = ($script:everything | ForEach-Object Text) -join "`n"
        foreach ($a in $script:allowed) {
            $all | Should -Match ([regex]::Escape($a)) -Because "'$a' is on the allowed list and must still exist"
        }
    }
}

Describe 'TERM-ROLLBACK-1: an operator reads "rollback", never "put back"' {

    It 'the dashboard' {
        @($script:dashboard | ForEach-Object { Find-VmfPutBack -Where $_.Where -Text $_.Text }) | Should -BeNullOrEmpty
    }

    It 'the manual (the page file use/put-back.md keeps its name; its links are not read)' {
        @($script:manual | ForEach-Object { Find-VmfPutBack -Where $_.Where -Text $_.Text }) | Should -BeNullOrEmpty
    }

    It 'the data files the engine and the manual read' {
        @($script:dataValues | ForEach-Object { Find-VmfPutBack -Where $_.Where -Text $_.Text }) | Should -BeNullOrEmpty
    }

    It 'the schema descriptions' {
        @($script:schemaText | ForEach-Object { Find-VmfPutBack -Where $_.Where -Text $_.Text }) | Should -BeNullOrEmpty
    }

    It 'the messages the module and the service write' {
        @($script:psStrings | ForEach-Object { Find-VmfPutBack -Where $_.Where -Text $_.Text }) | Should -BeNullOrEmpty
    }
}
