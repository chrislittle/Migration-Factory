#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PUBLIC-READY-GATE-1: nothing private reaches the public tree.
#
# The 1.0 release goes to a NEW public repository as one export of this one
# (PUBLIC-SYNC-1). tools/Test-VmfPublicReady.ps1 is the check: the export tool
# runs it on the exported folder, and this file runs it here, on every tracked
# file for the identifier kinds (CLAUDE.md rule 13 covers every tracked file)
# and on the files that SHIP for every kind.
#
# THIS FILE CARRIES NO VALUE THE GATE HUNTS FOR. The fixtures below use
# invented values, and each one is built from two pieces, so the gate's own
# run over this repository does not find this file.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:gate = Join-Path $script:repoRoot 'tools' 'Test-VmfPublicReady.ps1'
    $script:dataPath = Join-Path $script:repoRoot 'tools' 'public-ready.json'
    $script:data = Get-Content -LiteralPath $script:dataPath -Raw | ConvertFrom-Json -AsHashtable

    function Get-PrTestHash([string]$Text) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())
        -join ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') })
    }

    # Invented values, each in two pieces.
    $script:fx = @{
        labGuid     = 'f0e1d2c3' + '-b4a5-4697-8879-6a5b4c3d2e1f'
        otherGuid   = 'd3b07384' + '-d9a0-4c9b-8f3e-2a1b5c6d7e8f'
        subGuid     = '9f8e7d6c' + '-5b4a-4392-8170-fedcba987654'
        subShort    = '9f8e7d6c' + '...'
        suffix      = 'vmfstate' + 'q7w2e9r4t'
        token       = 'k3j9x2m8' + 'p0q1z'
        employer    = 'Fabrikam ' + 'Widgetcorp'
        profile     = 'C:\Users\' + 'jdoe7\AppData'
        email       = 'jdoe' + '@fabrikam-mail.org'
        link        = 'https://claude' + '.ai/code/artifact/x'
        ownerDate   = 'Own' + 'er, 2026-01-02, on the screen: it reads wrong.'
        ownerSpeech = 'The own' + 'er, on the screen: "this reads wrong"'
        ownerActed  = 'own' + 'er-approved design: the stop names the role'
        ownerHis    = 'on the own' + 'er''s PC the suite took 25 seconds'
        ownerLater  = 'Own' + 'er decision of the lab walk, 2026-01-02: no safety block'
        ownerHtml   = 'the own' + 'er&rsquo;s design for the check'
        dateQuote   = 'ITEM-1, 2026-01-02' + ': "never do this"'
    }

    # A data file for the fixtures: the real allow-lists, with the invented
    # lab id and employer name as the known values.
    $script:fxData = Join-Path $TestDrive 'fixture-data.json'
    $d = Get-Content -LiteralPath $script:dataPath -Raw | ConvertFrom-Json -AsHashtable
    $d.labIdHashes = @(Get-PrTestHash $script:fx.labGuid)
    $d.employerNames = @(@{ words = 2; word = (Get-PrTestHash 'widgetcorp'); name = (Get-PrTestHash 'fabrikam widgetcorp') })
    $d | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:fxData -Encoding utf8NoBOM

    function Invoke-PrFixture([string]$Text, [string]$Name = 'page.md') {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        Set-Content -LiteralPath (Join-Path $folder $Name) -Value $Text -Encoding utf8NoBOM
        $gateArgs = @{ Root = $folder; DataPath = $script:fxData; PassThru = $true }
        @(& $script:gate @gateArgs)
    }

    # Every tracked file, and the ones that ship. ONE SHIP LIST (PUBLIC-SYNC-1):
    # what ships is what tools/public-export.json says - its include and
    # exclude rules, read the way tools/Export-VmfPublicRelease.ps1 reads them.
    # public/ never ships as a folder.
    # In the public repository the list is not there: that tree IS what ships.
    $script:tracked = @(& git -C $script:repoRoot ls-files)
    $exportJson = Join-Path $script:repoRoot 'tools' 'public-export.json'
    $script:hasExportList = Test-Path -LiteralPath $exportJson
    $script:exportConfig = if ($script:hasExportList) { Get-Content -LiteralPath $exportJson -Raw | ConvertFrom-Json } else { $null }
    $matchRule = { param($File, $Rule) if ($Rule.EndsWith('/')) { $File.StartsWith($Rule, [System.StringComparison]::Ordinal) } else { $File -ceq $Rule } }
    $script:shipped = if (-not $script:hasExportList) { $script:tracked } else { @($script:tracked | Where-Object {
        $rel = $_
        -not $rel.StartsWith('public/') -and
        @($script:exportConfig.include | Where-Object { & $matchRule $rel $_ }).Count -and
        -not @($script:exportConfig.exclude | Where-Object { & $matchRule $rel $_.path }).Count
    }) }
}

Describe 'PUBLIC-READY-GATE-1: the gate finds each kind in any folder' {

    It 'a page of placeholders and published ids gives no finding' {
        $clean = @(
            '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app'
            'store vmfstateexamplesuffix, facade vmf-facade-contoso'
            'Contributor b24988ac-6180-42a0-ab88-20f7382dd24c and 11111111-2222-3333-4444-555555555555'
            'C:\Users\<user>\.azure and C:\Users\vmfrunner'
            'operator@example.com'
            'Storage Blob Data Owner: "read and write"'
            'The owner of the resource group gives the role.'
            'The application owner asked for more testing, and the database owner''s login stays.'
            'The application owner signed off on 2026-01-02.'
            'The application owner: "ship it"'
            '/subscriptions/aaaa0a0a.../resourceGroups/rg'
            'OWNER-QUESTIONS-1 row 19, decided 2026-10-05, made Bsv2 the default'
            'OWNER-QUESTIONS-1: "Bsv2 is the default"'
            'Microsoft (sizes page, read 2026-01-02): "Accelerated networking is required"'
            '{ "2026-10-05": "a date as a key", "at": "2026-10-05" }'
        ) -join "`n"
        Invoke-PrFixture $clean | Should -BeNullOrEmpty
    }

    It 'finds <Kind>' -ForEach @(
        @{ Kind = 'subscriptionId'; Key = 'subGuid'; Wrap = '/subscriptions/{0}/resourceGroups/rg' }
        @{ Kind = 'subscriptionId'; Key = 'subShort'; Wrap = 'both reach /subscriptions/{0}, twice' }
        @{ Kind = 'labId';          Key = 'labGuid'; Wrap = 'the application {0} signs in' }
        @{ Kind = 'unknownGuid';    Key = 'otherGuid'; Wrap = 'object {0}' }
        @{ Kind = 'installSuffix';  Key = 'suffix'; Wrap = 'the store {0} holds runs' }
        @{ Kind = 'installToken';   Key = 'token'; Wrap = 'suffix {0} here' }
        @{ Kind = 'employerName';   Key = 'employer'; Wrap = 'in the {0} tenant' }
        @{ Kind = 'profileFolder';  Key = 'profile'; Wrap = 'path {0}\Local' }
        @{ Kind = 'personalEmail';  Key = 'email'; Wrap = 'mail {0} now' }
        @{ Kind = 'claudeLink';     Key = 'link'; Wrap = 'read {0} first' }
        @{ Kind = 'ownerQuote';     Key = 'ownerDate'; Wrap = '# {0}' }
        @{ Kind = 'ownerQuote';     Key = 'ownerSpeech'; Wrap = '# {0}' }
        @{ Kind = 'ownerQuote';     Key = 'ownerActed'; Wrap = '# {0}' }
        @{ Kind = 'ownerQuote';     Key = 'ownerHis'; Wrap = '# {0}' }
        @{ Kind = 'ownerQuote';     Key = 'ownerLater'; Wrap = '# {0}' }
        @{ Kind = 'ownerQuote';     Key = 'ownerHtml'; Wrap = '<p>{0}</p>' }
        @{ Kind = 'ownerQuote';     Key = 'dateQuote'; Wrap = '# ({0})' }
    ) {
        $found = Invoke-PrFixture ($Wrap -f $script:fx[$Key])
        @($found | Where-Object Kind -EQ $Kind).Count | Should -BeGreaterThan 0 -Because "a planted $Kind must be found"
        $found[0].Path | Should -Be 'page.md'
    }

    It 'gives the line of a finding' {
        $found = Invoke-PrFixture ("one`ntwo`nread " + $script:fx.link)
        $found[0].Line | Should -Be 3
    }

    It 'does not read a file it cannot judge: a minified library or a binary file' {
        Invoke-PrFixture ('x=' + $script:fx.email) -Name 'library.min.js' | Should -BeNullOrEmpty
        $folder = Join-Path $TestDrive 'binary'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $bytes = [byte[]](@(0, 1, 2) + [System.Text.Encoding]::UTF8.GetBytes($script:fx.email))
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'image.png'), $bytes)
        @(& $script:gate -Root $folder -DataPath $script:fxData -PassThru) | Should -BeNullOrEmpty
    }


    It 'run as a script, it exits 1 on a finding and 0 on none, so an export stops' {
        $bad = Join-Path $TestDrive 'exit-bad'; $good = Join-Path $TestDrive 'exit-good'
        New-Item -ItemType Directory -Path $bad, $good | Out-Null
        Set-Content -LiteralPath (Join-Path $bad 'a.md') -Value ('read ' + $script:fx.link)
        Set-Content -LiteralPath (Join-Path $good 'a.md') -Value 'nothing here'
        & pwsh -NoProfile -File $script:gate -Root $bad -DataPath $script:fxData *> $null
        $LASTEXITCODE | Should -Be 1
        & pwsh -NoProfile -File $script:gate -Root $good -DataPath $script:fxData *> $null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'PUBLIC-READY-GATE-1: this repository' {

    It 'finds files to check, so this cannot pass by scanning nothing' {
        $script:tracked.Count | Should -BeGreaterThan 1000
        $script:shipped.Count | Should -BeGreaterThan 1000
        if ($script:hasExportList) { $script:shipped.Count | Should -BeLessThan $script:tracked.Count }
    }

    # PUBLIC-SYNC-1: the list does not ship; in the public repository the tree is what ships.
    It 'what ships is read from one list, tools/public-export.json' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'public-export.json'))) {
        $script:shipped | Where-Object { $_ -like 'docs/backlog/*' -or $_ -eq 'CLAUDE.md' -or $_ -eq 'AGENTS.md' -or
            $_ -like '.claude/*' -or $_ -like 'lab/*' -or $_ -like 'tests/lab/*' -or $_ -like 'public/*' } | Should -BeNullOrEmpty
        $script:shipped | Should -Contain 'src/VmMigrationFactory/VmMigrationFactory.psd1'
    }

    It 'and no second ship list returns: not in the gate''s data, and not in the gate' {
        # PUBLIC-READY-GATE-1 first kept its own list (shipExclude) until
        # PUBLIC-SYNC-1 landed. Two lists drift: a path one leaves out and the
        # other ships is a path nothing checks.
        @($script:data.Keys | Where-Object { $_ -match '(?i)ship|exclude|include' }) | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $script:gate -Raw) | Should -Not -Match '(?i)shipExclude|shipInclude'
    }

    It 'no tracked file carries a lab id, a subscription id, an install suffix, an employer name, a profile folder or a personal email' {
        $kinds = 'subscriptionId', 'labId', 'unknownGuid', 'installSuffix', 'installToken', 'employerName', 'profileFolder', 'personalEmail'
        $found = @(& $script:gate -Root $script:repoRoot -Path $script:tracked -Kind $kinds -PassThru)
        ($found | ForEach-Object { "$($_.Kind) $($_.Path):$($_.Line) $($_.Value)" }) -join '; ' |
            Should -BeNullOrEmpty -Because 'rule 13 covers every tracked file, not only the ones that ship'
    }

    It 'no file that ships carries a claude.ai link or an owner quote' {
        # OWNER-QUOTES-OUT-1 took out the last one; there is no allow-list for a quote.
        $found = @(& $script:gate -Root $script:repoRoot -Path $script:shipped -Kind 'claudeLink', 'ownerQuote' -PassThru)
        ($found | ForEach-Object { "$($_.Kind) $($_.Path):$($_.Line) $($_.Value)" }) -join '; ' |
            Should -BeNullOrEmpty -Because 'a new owner quote stays in the backlog item, not in a file that ships'
    }

}
