#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# README-SCOPE-1: the README shows five pictures (docs/images/readme), each in
# a light and a dark file. A picture is text a test cannot read by accident:
# the word gate never saw it, and a fact drawn in it could drift from the code
# with nothing failing. These tests close both.
#
#   1. Every picture the README shows exists in light and dark, every file in
#      the folder is shown, and the two files of a pair hold the same words.
#   2. The word gate reads the words in each picture and each picture's alt
#      text, and a bad word or a long sentence in either is a finding.
#   3. The scope picture lists exactly what the scan leaves out and the
#      workloads it finds and does not move (assessment-reasons.json), and the
#      README's alt text names every item.
#   4. The route picture says what target-families.json, assessment-reasons.json
#      and the generated support matrix say about each route.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:imageDir = Join-Path $script:repoRoot 'docs' 'images' 'readme'
    $script:readme   = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'README.md'))
    $script:gate     = Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1'
    $data = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data'
    $script:reasons  = [System.IO.File]::ReadAllText((Join-Path $data 'assessment-reasons.json')) | ConvertFrom-Json
    $script:families = [System.IO.File]::ReadAllText((Join-Path $data 'target-families.json')) | ConvertFrom-Json
    $script:matrix   = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'support-matrix.md'))

    function Get-VmfSvg([string]$Name) {
        [xml][System.IO.File]::ReadAllText((Join-Path $script:imageDir $Name))
    }
    # The visible words of a node: each <text>, spaces made single.
    function Get-VmfSvgWords($Node) {
        @($Node.SelectNodes(".//*[local-name()='text']") | ForEach-Object { ($_.InnerText -replace '\s+', ' ').Trim() } | Where-Object { $_ })
    }
    function Get-VmfNormal([string]$Text) { ($Text -replace '\s+', ' ').Trim().ToLowerInvariant() }
    # The alt text of the README picture whose light file is $Name.
    function Get-VmfAlt([string]$Name) {
        $m = [regex]::Match($script:readme, '<img alt="([^"]*)" src="docs/images/readme/' + [regex]::Escape($Name) + '"')
        $m.Groups[1].Value
    }
    function Get-VmfRoute($Doc, [string]$Id) { $Doc.SelectSingleNode("//*[@data-route='$Id']") }
    function Get-VmfTarget($Route, [string]$Id) { $Route.SelectSingleNode(".//*[@data-target='$Id']") }

    # Run the word gate against a scratch root, for one source.
    function Invoke-VmfGateOn([string]$Root, [string]$Source) {
        & $script:gate -Path $Root -Source $Source 6>$null
    }
    function New-VmfGateRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force (Join-Path $root 'src' 'dashboard') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $root 'docs' 'images' 'readme') | Out-Null
        $root
    }
}

Describe 'README-SCOPE-1: every README picture has a light and a dark file' {

    It 'every <picture> names a dark source and a light image that exist' {
        $pictures = @([regex]::Matches($script:readme, '(?s)<picture>.*?</picture>'))
        $pictures.Count | Should -Be 5 -Because 'banner, phases, routes, scope and install'
        foreach ($p in $pictures) {
            $p.Value | Should -Match 'media="\(prefers-color-scheme: dark\)" srcset="docs/images/readme/[a-z]+-dark\.svg"'
            $dark  = [regex]::Match($p.Value, 'srcset="docs/images/readme/([a-z]+-dark\.svg)"').Groups[1].Value
            $light = [regex]::Match($p.Value, 'src="docs/images/readme/([a-z]+-light\.svg)"').Groups[1].Value
            $dark.Replace('-dark', '') | Should -Be $light.Replace('-light', '')
            Test-Path (Join-Path $script:imageDir $dark) | Should -BeTrue
            Test-Path (Join-Path $script:imageDir $light) | Should -BeTrue
            [regex]::Match($p.Value, '<img alt="([^"]+)"').Success | Should -BeTrue -Because 'a screen reader reads the alt text'
        }
    }

    It 'every file in the folder is a picture the README shows' {
        foreach ($f in Get-ChildItem $script:imageDir -File) {
            $script:readme | Should -BeLike "*docs/images/readme/$($f.Name)*"
        }
    }

    It 'the light and the dark file of a pair hold the same words' {
        foreach ($light in Get-ChildItem $script:imageDir -Filter '*-light.svg') {
            $a = Get-VmfSvg $light.Name
            $b = Get-VmfSvg ($light.Name -replace '-light\.svg$', '-dark.svg')
            (Get-VmfSvgWords $b.DocumentElement) -join '|' | Should -Be ((Get-VmfSvgWords $a.DocumentElement) -join '|')
            $b.DocumentElement.GetAttribute('aria-label') | Should -Be $a.DocumentElement.GetAttribute('aria-label')
        }
    }
}

Describe 'README-SCOPE-1: the word gate reads the pictures and their alt text' {

    It 'the gate has a source for the pictures, and it reads every picture' {
        $list = & $script:gate -Path $script:repoRoot -ListSources 6>$null
        $line = @($list | Where-Object { $_ -match '^README-images\s' })
        $line.Count | Should -Be 1
        [int]([regex]::Match($line[0], '(\d+) string').Groups[1].Value) | Should -BeGreaterThan 60
    }

    It 'the pictures of this repository have no finding' {
        (Invoke-VmfGateOn $script:repoRoot 'README-images').Count | Should -Be 0
    }

    It 'a word the gate refuses, in a picture, is a finding' {
        $root = New-VmfGateRoot
        $svg = [System.IO.File]::ReadAllText((Join-Path $script:imageDir 'banner-light.svg'))
        $svg = $svg.Replace('</svg>', '<text x="1" y="1">Use this lever to start the wave.</text></svg>')
        [System.IO.File]::WriteAllText((Join-Path $root 'docs' 'images' 'readme' 'banner-light.svg'), $svg)
        $r = Invoke-VmfGateOn $root 'README-images'
        @($r.Findings | Where-Object { $_.Rule -eq 'jargon' -and $_.Text -match 'lever' }).Count | Should -Be 1
    }

    It 'a sentence spread over several lines of a picture is read as one sentence' {
        $root = New-VmfGateRoot
        $lines = 'It checks each machine on its new size', 'and then it checks each disk of the machine', 'and then it checks each network interface', 'and then it writes the result to the report.'
        $texts = ($lines | ForEach-Object { "<text x=`"1`" y=`"1`">$_</text>" }) -join ''
        $svg = "<svg xmlns=`"http://www.w3.org/2000/svg`" viewBox=`"0 0 10 10`" aria-label=`"A picture.`">$texts</svg>"
        [System.IO.File]::WriteAllText((Join-Path $root 'docs' 'images' 'readme' 'test-light.svg'), $svg)
        $r = Invoke-VmfGateOn $root 'README-images'
        @($r.Findings | Where-Object { $_.Rule -eq 'long-sentence' }).Count | Should -Be 1 -Because 'the four lines are one sentence of 33 words'
    }

    It 'a long sentence in the alt text of a README picture is a finding' {
        $root = New-VmfGateRoot
        $alt = 'This picture shows the dashboard and the web service and the engine and the run store and the registry and the logs and the identities of the product.'
        $md = "# Title`n`n<picture>`n  <img alt=`"$alt`" src=`"docs/images/readme/x-light.svg`">`n</picture>`n"
        [System.IO.File]::WriteAllText((Join-Path $root 'README.md'), $md)
        $r = Invoke-VmfGateOn $root 'README'
        @($r.Findings | Where-Object { $_.Rule -eq 'long-sentence' -and $_.Text -match 'This picture shows' }).Count | Should -Be 1
        @($r.Findings | Where-Object { $_.Text -match 'srcset|<img' }).Count | Should -Be 0 -Because 'the markup is not a sentence'
    }
}

Describe 'README-SCOPE-1: the scope picture is held to assessment-reasons.json' {

    BeforeAll {
        $script:scope = Get-VmfSvg 'scope-light.svg'
        function Get-VmfPanelCodes([string]$Panel) {
            @($script:scope.SelectNodes("//*[@data-panel='$Panel']/*[@data-reason]") | ForEach-Object { $_.GetAttribute('data-reason') -split ' ' })
        }
        # Blockers about the SIZE, the generation, the operating system or a
        # read that failed. Since 2026-11-17 those belong to the support
        # matrix, not to Scope. A new blocker must be put in one list or the
        # other, or the last test fails.
        $script:matrixBlockers = @(
            'gen1-requires-redeploy', 'image-not-supported', 'image-cannot-boot-nvme',
            'windows-version-below-2019', 'linux-release-not-on-nvme-list', 'windows-version-not-proven',
            'disk-encryption-present', 'hpc-or-fpga-size', 'local-nvme-storage-size',
            'l-series-replacement', 'gpu-size', 'size-retired', 'sizes-not-read', 'machine-not-read')
    }

    It 'the "leaves out" panel shows every excluded code, and no other' {
        $shown = @(Get-VmfPanelCodes 'excluded' | Sort-Object)
        $data  = @($script:reasons.excluded.PSObject.Properties.Name | Sort-Object)
        $shown -join ',' | Should -Be ($data -join ',')
    }

    It 'the "finds and does not move" panel shows every blocker that is not a size or system fact' {
        $shown = @(Get-VmfPanelCodes 'blocked')
        $shown.Count | Should -BeGreaterThan 8
        foreach ($code in $shown) {
            $script:reasons.blockers.PSObject.Properties.Name | Should -Contain $code
            $script:matrixBlockers | Should -Not -Contain $code
        }
        foreach ($code in $script:reasons.blockers.PSObject.Properties.Name) {
            ($code -in $shown) -or ($code -in $script:matrixBlockers) |
                Should -BeTrue -Because "blocker '$code' must be drawn in the scope picture or named as a support matrix fact"
        }
    }

    It 'the README alt text names every item the panels show' {
        $alt = Get-VmfNormal (Get-VmfAlt 'scope-light.svg')
        $alt | Should -Not -BeNullOrEmpty
        foreach ($item in $script:scope.SelectNodes("//*[@data-panel]/*[@data-reason]")) {
            $words = Get-VmfNormal ((Get-VmfSvgWords $item) -join ' ')
            $alt | Should -BeLike "*$words*" -Because "the alt text must name '$words'"
        }
    }
}

Describe 'README-SCOPE-1: the route picture is held to target-families.json' {

    BeforeAll {
        $script:routes = Get-VmfSvg 'routes-light.svg'
        $script:gen = $script:families.generations
        function Get-VmfTargets($Route) { @($Route.SelectNodes(".//*[@data-target]") | ForEach-Object { $_.GetAttribute('data-target') }) }
        function Get-VmfTargetText($Route, $Id) { (Get-VmfSvgWords (Get-VmfTarget $Route $Id)) -join ' ' }
        $script:allRoutes = @($script:routes.SelectNodes("//*[@data-route]"))
    }

    It 'draws three routes' {
        @($script:allRoutes | ForEach-Object { $_.GetAttribute('data-route') }) -join ',' | Should -Be 'older,b-v1,on-v5'
    }

    It 'names the kind of change from the disk controller of each generation' {
        $kind = { param($c) if ($c -eq 'SCSI') { 'RESIZE ON SCSI' } else { 'SCSI TO NVMe' } }
        $gen.v6.controller | Should -Be $gen.v7.controller -Because 'one picture block stands for v6 and v7'
        foreach ($r in $script:allRoutes) {
            foreach ($t in Get-VmfTargets $r) {
                $controller = if ($t -eq 'v5') { $gen.v5.controller } else { $gen.v6.controller }
                Get-VmfTargetText $r $t | Should -BeLike "*$(& $kind $controller)*"
            }
        }
    }

    It 'names the machine generations each target takes' {
        $words = { param($g) if (@($g) -contains 'V1') { 'Generation 1 and Generation 2' } else { 'Generation 2 only' } }
        (@($gen.v6.hyperVGenerations) -join ',') | Should -Be (@($gen.v7.hyperVGenerations) -join ',')
        foreach ($r in $script:allRoutes) {
            foreach ($t in Get-VmfTargets $r) {
                $g = if ($t -eq 'v5') { $gen.v5.hyperVGenerations } else { $gen.v6.hyperVGenerations }
                Get-VmfTargetText $r $t | Should -BeLike "*$(& $words $g)*"
            }
        }
    }

    It 'names the lowest Windows version each target takes, from the scan''s own reasons' {
        @($script:reasons.blockers.'windows-version-below-2019'.appliesTo) -join ',' | Should -Be 'v6,v7'
        @($script:reasons.blockers.'windows-version-not-proven'.appliesTo) -join ',' | Should -Be 'v5'
        foreach ($r in $script:allRoutes) {
            foreach ($t in Get-VmfTargets $r) {
                $min = if ($t -eq 'v5') { 'Windows Server 2016 and later' } else { 'Windows Server 2019 and later' }
                Get-VmfTargetText $r $t | Should -BeLike "*$min*"
            }
        }
    }

    It 'offers the D and E families on v5, v6 and v7, as the picture says' {
        foreach ($g in 'v5', 'v6', 'v7') { @($script:families.seriesByGeneration.$g) | Should -Contain 'D'; @($script:families.seriesByGeneration.$g) | Should -Contain 'E' }
        foreach ($r in $script:allRoutes) {
            Get-VmfTargetText $r 'v6v7' | Should -BeLike '*D, Dl or E*'
        }
    }

    It 'the B v1 route names the B v1 series and offers Bsv2 first, as burstableTargets says' {
        $bsv2 = @($script:families.burstableTargets.series | Where-Object { $_.option -eq 'v5' })
        $bsv2.Count | Should -Be 1
        $route = Get-VmfRoute $script:routes 'b-v1'
        Get-VmfTargetText $route 'v5' | Should -BeLike "*$($bsv2[0].series) first*"
        # The line under the name lists the source series, and only those.
        $own = @($route.SelectNodes("./*[local-name()='text']") | ForEach-Object { $_.InnerText.Trim() })
        $listed = @(($own[1] -split ', | and ') | Sort-Object)
        $listed -join ',' | Should -Be (@($bsv2[0].sourceSizeSeries | Sort-Object) -join ',')
    }

    It 'a machine already on v5 gets no v5 target, as the generated support matrix says' {
        $rows = @($script:matrix -split "`n" | Where-Object { $_ -match '^\| [^|]+ \| `Standard_[^`]+` \|' })
        $v5Rows = @($rows | Where-Object { $_ -match '`Standard_[^`]+_v5`' })
        $v5Rows.Count | Should -BeGreaterThan 5
        foreach ($row in $v5Rows) { ($row -split '\|')[5].Trim() | Should -Be 'None. The machine is already on v5.' }
        $older = @($rows | Where-Object { $_ -match '`Standard_[^`]+_v[34]`' -and $_ -match '\| Supported \|' })
        $older.Count | Should -BeGreaterThan 5
        foreach ($row in $older) { ($row -split '\|')[5].Trim() | Should -Not -Match '^None' }

        (Get-VmfTargets (Get-VmfRoute $script:routes 'on-v5')) -join ',' | Should -Be 'v6v7'
        ((Get-VmfSvgWords (Get-VmfRoute $script:routes 'on-v5')) -join ' ') | Should -BeLike '*No v5 target*'
        (Get-VmfTargets (Get-VmfRoute $script:routes 'older')) -join ',' | Should -Be 'v5,v6v7'
        (Get-VmfTargets (Get-VmfRoute $script:routes 'b-v1')) -join ',' | Should -Be 'v5,v6v7'
    }

    It 'the README alt text names every route' {
        $alt = Get-VmfAlt 'routes-light.svg'
        $alt | Should -Match 'A machine on A v2, D, E or F, v1 to v4, moves to v5, or to v6 or v7\.'
        $alt | Should -Match 'A machine on B v1 moves to Bsv2 first, or to v5, or to v6 or v7\.'
        $alt | Should -Match 'A machine on D, Dl or E v5 has no v5 target, and moves to v6 or v7\.'
    }
}
