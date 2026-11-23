#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SUPPORT-MATRIX-1 (filed for v1.0 on 2026-10-25): ONE page in the manual says which machines the product moves and
# which it does not.
#
# Before it, the facts were on three pages that overlapped and did not agree:
# limits.md (a long paragraph of source sizes and a list "What the product
# will not do"), what-it-does.md (its own list "What it does not do"), and the
# assessment findings. Two of those lists were written by hand.
#
# THE PAGE IS GENERATED from the data the product itself reads -
# data/target-families.json, data/supported-images.json,
# data/driver-floors.json and data/assessment-reasons.json - and from the
# planner's own functions (Test-VmfShapeChoiceSource, Get-VmfSizeReplacement,
# Get-VmfDefaultSizeCandidates, Get-VmfSizeLifecycleStage,
# Get-VmfSizeRetirement), by tools/Update-VmfManualReference.ps1. So the page
# cannot say one thing while the planner does another.
#
# What is held here:
#   - the page exists, is generated, and is first under Reference;
#   - every data row the page is built from reaches the page, so a row added
#     to the data later is a row on the page, or this file fails;
#   - the facts it states are the facts the data and the planner give;
#   - limits.md and what-it-does.md no longer keep a second scope list.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'
    $script:pagePath = Join-Path $script:manual 'reference' 'support-matrix.md'
    $script:page = if (Test-Path $script:pagePath) { Get-Content $script:pagePath -Raw } else { '' }
    $script:data = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data'
    $script:families = Get-Content (Join-Path $script:data 'target-families.json') -Raw | ConvertFrom-Json
    $script:reasons = Get-Content (Join-Path $script:data 'assessment-reasons.json') -Raw | ConvertFrom-Json
    $script:images = Get-Content (Join-Path $script:data 'supported-images.json') -Raw | ConvertFrom-Json
    $script:floors = Get-Content (Join-Path $script:data 'driver-floors.json') -Raw | ConvertFrom-Json
    $script:tool = Join-Path $script:repoRoot 'tools' 'Update-VmfManualReference.ps1'

    # One section of the page: from its "## " heading to the next one.
    function script:Get-Section([string]$Heading) {
        [regex]::Match($script:page, '(?ms)^## ' + [regex]::Escape($Heading) + '\s*$(.*?)(?=^## |\z)').Groups[1].Value
    }
    # The table rows of a section, header and separator left out, each as its cells.
    function script:Get-Rows([string]$Heading) {
        $lines = @((Get-Section $Heading) -split "`r?`n" | Where-Object { $_ -match '^\|' })
        @($lines | Select-Object -Skip 2 | ForEach-Object {
                , @($_.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            })
    }
}

Describe 'SUPPORT-MATRIX-1: the page exists and a person can reach it' {
    It 'the page exists' {
        Test-Path $script:pagePath | Should -BeTrue
    }

    It 'is the first page under Reference in the sidebar' {
        $sidebar = Get-Content (Join-Path $script:manual '_sidebar.md') -Raw
        $reference = [regex]::Match($sidebar, '(?ms)^- Reference\s*\r?\n(?<items>(?:\s+- .*\r?\n?)+)').Groups['items'].Value
        $first = @($reference -split "`r?`n" | Where-Object { $_.Trim() })[0]
        $first | Should -Match '\[Support matrix\]\(/reference/support-matrix\.md\)'
    }

    It 'is generated: the reference tool writes it, and says so on the page' {
        Get-VmfCodeOnly -Path $script:tool | Should -Match "Write-Page -Name 'support-matrix\.md'"
        $script:page | Should -Match '(?i)generated from the data the product reads'
    }

    It 'is not stale: the tool in check mode finds nothing to write' {
        { & $script:tool -Check } | Should -Not -Throw
    }

    It 'says Supported or Not supported, and nothing else, in every status cell' {
        # SUPPORT-MATRIX-2: "Experimental" went with the Generation 1 to
        # Generation 2 row (2026-10-31: the product does not support a move
        # from Generation 1 to Generation 2). The product labels nothing Experimental.
        $cells = @(
            foreach ($h in 'Source sizes', 'Machines the product does not move') {
                foreach ($row in (Get-Rows $h)) { $row[-2] }
            }
            foreach ($h in 'Windows', 'Machine generation') {
                foreach ($row in (Get-Rows $h)) { $row[1]; $row[2] }
            }
        )
        @($cells).Count | Should -BeGreaterThan 20 -Because 'the check must read real rows'
        foreach ($c in $cells) { $c | Should -BeIn @('Supported', 'Not supported') }
    }
}

Describe 'SUPPORT-MATRIX-1: the source sizes are the ones the data names' {
    BeforeAll {
        $script:sourceRows = @(Get-Rows 'Source sizes')
        # The example size of each row, in backticks in the second cell.
        $script:examples = @($script:sourceRows | ForEach-Object { [regex]::Match($_[1], '`(Standard_[A-Za-z0-9_]+)`').Groups[1].Value } | Where-Object { $_ })
    }

    It 'every source row names its size series' {
        foreach ($row in $script:sourceRows) { $row[0] | Should -Match '\w' }
    }

    It 'says that a size series not in the table is outside the scope of this tool' {
        # The engine gives no target to a family with no size on the target
        # series (Get-VmfTargetSize, family-not-in-region), so the table is
        # the whole list - and the page has to say so (review).
        (Get-Section 'Source sizes') | Should -Match 'A size series that is not in this table is outside the scope of this tool\.'
        Get-VmfCodeOnly -Path $script:tool | Should -Match 'A size series that is not in this table is outside the scope of this tool\.'
    }

    It 'a series Microsoft lists no v7 size for says so, from the data' {
        $eb = @($script:sourceRows | Where-Object { $_[1] -match '`Standard_E2bds_v5`' })
        $eb.Count | Should -Be 1
        $eb[0][5] | Should -Match 'v7: none, because Microsoft lists no size of this name'
    }

    It 'every source row has an example size' {
        @($script:examples).Count | Should -Be @($script:sourceRows).Count
        @($script:examples).Count | Should -BeGreaterThan 15
    }

    It 'every lifecycle row that is not Current has a source row for each of its versions' {
        foreach ($row in @($script:families.lifecycle.bySeries | Where-Object { $_.stage -ne 'Current' })) {
            foreach ($g in @($row.generations)) {
                $hit = @($script:examples | Where-Object {
                        $ex = $_
                        InModuleScope VmMigrationFactory -Parameters @{ s = $ex; f = [string]$row.family; g = [string]$g } {
                            param($s, $f, $g)
                            $name = $s -replace '^Basic_', 'Standard_'
                            $gen = Get-VmfSizeGeneration -SizeName $name
                            if (-not $gen -and $name -cmatch '^Standard_[A-Z]+\d+[a-z]*$') { $gen = 'v1' }
                            (Get-VmfSizeFamilyPrefix -SizeName $name) -ceq $f -and $gen -eq $g
                        }
                    })
                $hit.Count | Should -BeGreaterThan 0 -Because "the lifecycle data names the $($row.family) family at $g, so the page must show it"
            }
        }
    }

    It 'every retirement row has a source row, with its date' {
        foreach ($row in @($script:families.lifecycle.retirements)) {
            $day = if ($row.retiresUtc -is [datetime]) { $row.retiresUtc.ToString('yyyy-MM-dd') } else { [string]$row.retiresUtc }
            $hits = @($script:sourceRows | Where-Object {
                    $ex = [regex]::Match($_[1], '`(Standard_[A-Za-z0-9_]+)`').Groups[1].Value
                    $read = InModuleScope VmMigrationFactory -Parameters @{ s = $ex } { param($s) Get-VmfSizeSeriesReading -SizeName $s }
                    @($row.sizeSeries) -contains $read
                })
            $hits.Count | Should -BeGreaterThan 0 -Because "the retirement of $(@($row.series) -join ', ') must be on the page"
            foreach ($h in $hits) { $h[3] | Should -Match ([regex]::Escape($day)) }
        }
    }

    It 'each row gives the stage the lifecycle data gives for its example' {
        foreach ($row in $script:sourceRows) {
            $ex = [regex]::Match($row[1], '`(Standard_[A-Za-z0-9_]+)`').Groups[1].Value
            $stage = InModuleScope VmMigrationFactory -Parameters @{ s = $ex } { param($s) (Get-VmfSizeLifecycleStage -SizeName $s).Stage }
            $row[2] | Should -Be $stage -Because "$ex is $stage in the lifecycle data"
        }
    }

    It 'a retired size is Not supported and every other size is Supported' {
        foreach ($row in $script:sourceRows) {
            if ($row[2] -eq 'Retired') { $row[-2] | Should -Be 'Not supported' }
            else { $row[-2] | Should -Be 'Supported' }
        }
    }

    It 'an F, Fs or Fsv2 machine gets a Dl, D or E size by its vCPUs and memory, never an F size' {
        # The question the item asked to settle from the engine: the page said
        # Dl, D or E, and the data lists F as a v7 target family. The engine
        # sizes an F machine by shape (Test-VmfShapeChoiceSource), and the
        # shape choices are Dl, D and E only (Get-VmfShapeSizeChoices).
        $fRows = @($script:sourceRows | Where-Object { $_[1] -match '`Standard_F\d' })
        $fRows.Count | Should -Be 3
        foreach ($row in $fRows) {
            $row[4] | Should -Match 'Dl, D or E'
            $row[5] | Should -Match 'Dl, D or E'
            ($row[4] + $row[5]) | Should -Not -Match 'F[a-z]*v[67]'
        }
    }

    It 'the page says why: the F v7 family Microsoft lists has another processor maker' {
        $fv7 = @($script:families.targetFamilyExamples | Where-Object { $_.generation -eq 'v7' } | ForEach-Object {
                $row = $_; @($row.examples | Where-Object { $_ -match '^F' }) | ForEach-Object { @{ Name = $_; Platform = [string]$row.platform } } })
        $fv7.Count | Should -BeGreaterThan 0
        $note = Get-Section 'Target series'
        foreach ($x in $fv7) { $note | Should -Match "$([regex]::Escape($x.Name)), an $($x.Platform) family" }
        $note | Should -Match 'keeps its processor maker'
    }

    It 'the engine agrees: an F machine is sized by shape, and its choices hold no F size' {
        $sku = {
            param([string]$Name, [int]$Vcpus, [int]$MemoryGB)
            [pscustomobject]@{ Name = $Name; Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
                    [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$MemoryGB }
                    [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' }
                    [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                    [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '32' }) }
        }
        $catalog = @{}
        foreach ($s in @((& $sku 'Standard_F2s_v2' 2 4), (& $sku 'Standard_F2as_v7' 2 8), (& $sku 'Standard_F2als_v7' 2 4),
                (& $sku 'Standard_F2s_v7' 2 4), (& $sku 'Standard_D2s_v7' 2 8), (& $sku 'Standard_D2ls_v7' 2 4), (& $sku 'Standard_E2s_v7' 2 16))) {
            $catalog[$s.Name] = $s
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = $catalog } {
            param($c)
            foreach ($s in 'Standard_F2', 'Standard_F2s', 'Standard_F2s_v2') { Test-VmfShapeChoiceSource -SourceSize $s | Should -BeTrue }
            $choices = @(Get-VmfShapeSizeChoices -SourceSize 'Standard_F2s_v2' -CatalogBySize $c -HyperVGeneration 'V2' -TargetGeneration 'v7')
            $choices.Count | Should -BeGreaterThan 0
            @($choices | Where-Object { [string]$_.size -match '^Standard_F' }).Count | Should -Be 0
            @($choices | ForEach-Object { [string]$_.family } | Sort-Object -Unique) | Should -Be @('D', 'Dl', 'E')
        }
    }

    It 'a B v1 machine is offered Bsv2 on v5, from the Bsv2 row of the data' {
        $bRow = @($script:sourceRows | Where-Object { $_[1] -match '`Standard_B\d' })
        $bRow.Count | Should -BeGreaterThan 0
        foreach ($row in $bRow) { $row[4] | Should -Match ([regex]::Escape([string]$script:families.burstableTargets.series[0].series)) }
    }

    It 'a size the planner sizes by name shows the sizes the planner tries, in its order' {
        $named = @($script:sourceRows | Where-Object { $_[2] -ne 'Retired' -and $_[4] -notmatch 'Dl, D or E' })
        $named.Count | Should -BeGreaterThan 10
        foreach ($row in $named) {
            $ex = [regex]::Match($row[1], '`(Standard_[A-Za-z0-9_]+)`').Groups[1].Value
            $tries = InModuleScope VmMigrationFactory -Parameters @{ s = $ex } {
                param($s)
                # A size Microsoft does not list is never a target (V5-SUCCESSOR-1).
                $keep = { param($n) @($n | Where-Object { (Get-VmfMicrosoftSizeListing -SizeName $_).Listed -ne $false }) }
                @{ v5 = @(& $keep @(Get-VmfDefaultSizeCandidates -SourceSize $s -TargetGeneration 'v5'))
                   v6 = @(& $keep @(Get-VmfDefaultSizeCandidates -SourceSize $s -TargetGeneration 'v6'))
                   v7 = @(& $keep @(Get-VmfDefaultSizeCandidates -SourceSize $s -TargetGeneration 'v7')) }
            }
            foreach ($g in 'v6', 'v7') {
                if (-not $tries[$g].Count) { $row[5] | Should -Match "$($g): none, because Microsoft lists no size of this name"; continue }
                $row[5] | Should -Match ("$($g): " + (($tries[$g] | ForEach-Object { [regex]::Escape($_) }) -join '(, | or )') + '\.') -Because "$ex tries $($tries[$g] -join ', ') on $g"
            }
            if ($ex -match '_v5$') { $row[4] | Should -Match 'already on v5' }
            # SUPPORT-MATRIX-2: after the generation words the cell starts with.
            else { $row[4] | Should -Match ('^Generation 1 and Generation 2\. ' + (($tries.v5 | ForEach-Object { [regex]::Escape($_) }) -join '(, | or )') + '\.$') }
        }
    }

    It 'every v3 and v4 replacement row has a source row of its own' {
        foreach ($rep in @($script:families.replacements.bySeries | Where-Object { @($_.sourceSeries | Where-Object { $_ -match 'v[34]$' }).Count })) {
            $hits = @($script:examples | Where-Object {
                    $ex = $_
                    $series = InModuleScope VmMigrationFactory -Parameters @{ s = $ex } { param($s) Get-VmfSizeSeriesName -SizeName $s }
                    @($rep.sourceSeries) -contains $series
                })
            $hits.Count | Should -BeGreaterThan 0 -Because "$(@($rep.sourceSeries) -join ', ') has a replacement row"
        }
    }

    It 'an Intel machine on a v3 size is shown Intel sizes only, as the planner gives' {
        $v3 = @($script:sourceRows | Where-Object { $_[1] -match '_v3`' })
        $v3.Count | Should -Be 2
        foreach ($row in $v3) { ($row[4] + $row[5]) | Should -Not -Match '_[A-Z]\d+a' }
    }
}
Describe 'SUPPORT-MATRIX-1: the target series are the ones the data names' {
    BeforeAll { $script:targetSection = Get-Section 'Target series' }

    It 'has a column for each target series in the data, and no other' {
        # SUPPORT-MATRIX-2: Bsv2 is one series of the B family, not a peer of
        # v5, v6 and v7. It has a table of its own (tested below).
        $header = @($script:targetSection -split "`r?`n" | Where-Object { $_ -match '^\|' })[0]
        $cells = @($header.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        @($cells | Select-Object -Skip 1) | Should -Be @($script:families.generations.PSObject.Properties.Name)
    }

    It 'the disk controller and the Generations are the data''s' {
        $controller = @($script:targetSection -split "`r?`n" | Where-Object { $_ -match '^\| Disk controller' })[0]
        $gens = @($script:targetSection -split "`r?`n" | Where-Object { $_ -match '^\| Machine generation' })[0]
        $cells = @($controller.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        $gcells = @($gens.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        $i = 1
        foreach ($g in @($script:families.generations.PSObject.Properties.Name)) {
            $cells[$i] | Should -Match ([string]$script:families.generations.$g.controller)
            if (@($script:families.generations.$g.hyperVGenerations) -contains 'V1') { $gcells[$i] | Should -Match 'Generation 1' }
            else { $gcells[$i] | Should -Not -Match 'Generation 1' }
            $i++
        }
    }

    It 'accelerated networking is Required exactly where the data requires it' {
        $an = @($script:targetSection -split "`r?`n" | Where-Object { $_ -match '^\| Accelerated networking' })[0]
        $cells = @($an.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        $i = 1
        foreach ($g in @($script:families.generations.PSObject.Properties.Name)) {
            $required = @($script:families.generations.$g.acceleratedNetworkingRequired)
            # DRIFT-11: where it covers every series and processor (v6), the
            # cell says every size, and names no "other sizes".
            $have = @($required | ForEach-Object { "$($_.series)/$($_.processor)" })
            $all = @(foreach ($s in @($script:families.seriesByGeneration.$g)) { foreach ($pr in @($script:families.approvedProcessors)) { "$s/$pr" } })
            if ($required.Count -and -not @($all | Where-Object { $have -notcontains $_ }).Count) {
                $cells[$i] | Should -Be 'Required on every size.'
            }
            elseif ($required.Count) {
                foreach ($r in $required) { $cells[$i] | Should -Match "$($r.processor) $($r.series)" }
                $cells[$i] | Should -Match 'Required'
                $cells[$i] | Should -Match 'Supported on the other sizes'
            }
            else { $cells[$i] | Should -Not -Match 'Required' }
            $i++
        }
    }

    It 'names the families each series takes, from the data' {
        $fam = @($script:targetSection -split "`r?`n" | Where-Object { $_ -match '^\| Families' })[0]
        $cells = @($fam.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        $i = 1
        foreach ($g in @($script:families.generations.PSObject.Properties.Name)) {
            foreach ($f in @($script:families.seriesByGeneration.$g)) { $cells[$i] | Should -Match "\b$f\b" }
            $i++
        }
    }
}

Describe 'SUPPORT-MATRIX-1: the operating systems are the ones the data names' {
    It 'every Linux publisher on the supported list has a row, with its status' {
        $rows = @(Get-Rows 'Linux images')
        $linux = @($script:images.publishers | Where-Object { $_.os -eq 'Linux' })
        # IMAGE-SCRIPT-MATCH-1: one row per entry - an entry for some offers of
        # a publisher (openSUSE Leap of SUSE) has a row of its own, by its name.
        $rows.Count | Should -Be ($linux.Count + 1) -Because 'one row per entry, and the row for any other image'
        foreach ($p in $linux) {
            $named = $p.PSObject.Properties['name'] -and [string]$p.name
            $row = @($rows | Where-Object { $_[1] -eq [string]$p.publisher -and (-not $named -or $_[0] -eq [string]$p.name) })
            if (-not $named) {
                $others = @($linux | Where-Object { [string]$_.publisher -eq [string]$p.publisher -and $_.PSObject.Properties['name'] -and [string]$_.name } | ForEach-Object { [string]$_.name })
                $row = @($row | Where-Object { $others -notcontains $_[0] })
            }
            $row.Count | Should -Be 1 -Because "$($p.publisher) $(if ($named) { $p.name }) is on the supported list"
            $want = if ($p.support -eq 'unsupported') { 'Not supported' } else { 'Supported' }
            $row[0][2] | Should -Be $want
        }
    }

    It 'every distribution in the MANA kernel table has a row, with its kernel' {
        $rows = @(Get-Rows 'Linux kernel for MANA')
        # One row per data row: three distributions share version 9.6 and one
        # kernel, so a match alone cannot see a row left out (found by mutation).
        $rows.Count | Should -Be @($script:floors.mana.linux.distros).Count
        foreach ($d in @($script:floors.mana.linux.distros)) {
            $kernel = if ($d.minKernel) { [string]$d.minKernel } else { "Any $($d.kernelSeries)" }
            $version = if ([string]$d.versionId -eq '*') { 'Any' } else { [string]$d.versionId }
            @($rows | Where-Object { $_[1] -eq $version -and $_[2] -match [regex]::Escape($kernel) }).Count |
                Should -BeGreaterThan 0 -Because "$($d.id) $($d.versionId) is in the MANA table"
        }
        (Get-Section 'Linux kernel for MANA') | Should -Match ([regex]::Escape([string]$script:floors.mana.linux.fallbackForUnlistedDistros.minKernel))
    }

    It 'the Windows rows follow which series each Windows rule closes' {
        $rows = @(Get-Rows 'Windows')
        $ws2016 = @($rows | Where-Object { $_[0] -eq 'Windows Server 2016' })[0]
        $ws2019 = @($rows | Where-Object { $_[0] -eq 'Windows Server 2019 and later' })[0]
        $older = @($rows | Where-Object { $_[0] -eq 'Windows Server older than 2016' })[0]
        $ws2019[1] | Should -Be 'Supported'; $ws2019[2] | Should -Be 'Supported'
        # windows-version-below-2019 closes the series in its appliesTo.
        $below2019 = @($script:reasons.blockers.'windows-version-below-2019'.appliesTo)
        $ws2016[1] | Should -Be $(if ($below2019 -contains 'v5') { 'Not supported' } else { 'Supported' })
        $ws2016[2] | Should -Be $(if ($below2019 -contains 'v6') { 'Not supported' } else { 'Supported' })
        $older[1] | Should -Be 'Not supported'; $older[2] | Should -Be 'Not supported'
        # The reason covers both columns: each rule that closes a series for
        # this row gives its words (review).
        foreach ($code in 'windows-version-not-proven', 'windows-version-below-2019') {
            $first = ([string]$script:reasons.blockers.$code.meaning -split '(?<=\.)\s')[0]
            $older[3] | Should -Match ([regex]::Escape($first))
        }
        $client = @($rows | Where-Object { $_[0] -match 'client' })
        $client.Count | Should -Be 1
        $client[0][1] | Should -Be 'Not supported'
    }

    It 'the Windows Server years the tool writes are the years the assessment rules test' {
        # The two years are numbers in Rules.ps1, not data, so the generator
        # holds them too. This reads both, so they cannot come apart.
        $rules = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1')
        $toolCode = Get-VmfCodeOnly -Path $script:tool
        foreach ($pair in @(@{ Code = 'windows-version-below-2019'; Year = 2019 }, @{ Code = 'windows-version-not-proven'; Year = 2016 })) {
            $rules | Should -Match ("-lt $($pair.Year)\) \{ \`$blockers\.Add\('$($pair.Code)'\)")
            $toolCode | Should -Match ("Code = '$($pair.Code)'; Year = $($pair.Year) ")
        }
    }

    It 'Generation 1 goes to v5 only, and the table offers no route from Generation 1 to Generation 2' {
        # SUPPORT-MATRIX-2 (2026-10-31: no move from Generation 1 to
        # Generation 2 is supported; GEN1-UPGRADE-1 was decided 2026-10-05 as outside the
        # scope of this tool). The row "Generation 1, changed to Generation 2
        # by Microsoft's Trusted Launch upgrade | Experimental" is gone.
        $rows = @(Get-Rows 'Machine generation')
        @($rows | ForEach-Object { $_[0] }) | Should -Be @('Generation 2', 'Generation 1')
        $gen1 = @($rows | Where-Object { $_[0] -eq 'Generation 1' })[0]
        $gen1[1] | Should -Be $(if (@($script:families.generations.v5.hyperVGenerations) -contains 'V1') { 'Supported' } else { 'Not supported' })
        $gen1[2] | Should -Be 'Not supported'
        $gen1[3] | Should -Match 'outside the scope of this tool'
    }
}

Describe 'SUPPORT-MATRIX-1: the machines the product does not move are the data''s' {
    BeforeAll { $script:outRows = @(Get-Rows 'Machines the product does not move') }

    It 'every machine the assessment leaves alone has a row, with its Microsoft page' {
        foreach ($p in $script:reasons.excluded.PSObject.Properties) {
            $row = @($script:outRows | Where-Object { $_[0] -eq [string]$p.Value.title })
            $row.Count | Should -Be 1 -Because "$($p.Name) is a machine the assessment leaves alone"
            $row[0][-1] | Should -Match ([regex]::Escape([string]$p.Value.docs.url))
        }
    }

    It 'SCAN-PARTIAL-SUBS-1: a scan that could not read the sizes is not a row - it is no limit of the product' {
        @($script:outRows | Where-Object { $_[0] -eq [string]$script:reasons.blockers.'sizes-not-read'.title }).Count | Should -Be 0
    }
    It 'LINUX-VERSION-OVERFLOW-1: a machine whose facts were not read is not a row - it is no limit of the product' {
        @($script:outRows | Where-Object { $_[0] -eq [string]$script:reasons.blockers.'machine-not-read'.title }).Count | Should -Be 0
    }
    It 'every finding that closes every size series has a row, with its route and page' {
        $all = @('v5', 'v6', 'v7')
        $codes = @($script:reasons.blockers.PSObject.Properties | Where-Object {
                $applies = @($_.Value.appliesTo)
                # SCAN-PARTIAL-SUBS-1: sizes-not-read is a scan that could not read, not a limit of the product.
                # LINUX-VERSION-OVERFLOW-1: and machine-not-read is a machine the scan could not read.
                $_.Name -notin @('image-not-supported', 'sizes-not-read', 'machine-not-read') -and @($all | Where-Object { $applies -notcontains $_ }).Count -eq 0
            })
        $codes.Count | Should -BeGreaterThan 10
        foreach ($p in $codes) {
            $title = ([string]$p.Value.title) -replace '\s*\(not in scope\)$', ''
            $row = @($script:outRows | Where-Object { $_[0] -eq $title })
            $row.Count | Should -Be 1 -Because "$($p.Name) closes every series"
            $row[0][-1] | Should -Match ([regex]::Escape([string]$p.Value.docs.url))
            $row[0][2] | Should -Be ([string]$p.Value.whatToDo)
            $row[0][-2] | Should -Be 'Not supported'
        }
    }

    It 'an Arm64 machine has a row, and the processors the data approves are named' {
        $arm = @($script:outRows | Where-Object { $_[0] -match 'Arm64' })
        $arm.Count | Should -Be 1
        foreach ($p in @($script:families.approvedProcessors)) { $arm[0][1] | Should -Match $p }
    }

    It 'the out-of-scope list is all there' {
        foreach ($t in 'scale set', 'Virtual Desktop', 'platform manages', 'Confidential', 'Arm64', 'GPU', 'HPC', 'FPGA',
            'Ls or Lsv2', 'G or GS', 'More than 32 data disks', 'SAP', 'Network virtual appliance', 'Storage or backup appliance',
            'managed application', 'Failover cluster', 'Always On') {
            @($script:outRows | Where-Object { $_[0] -match [regex]::Escape($t) }).Count | Should -BeGreaterThan 0 -Because "the item names $t"
        }
    }
}

Describe 'SUPPORT-MATRIX-1: the two older pages keep no second scope list' {
    BeforeAll {
        $script:limits = Get-Content (Join-Path $script:manual 'reference' 'limits.md') -Raw
        $script:what = Get-Content (Join-Path $script:manual 'understand' 'what-it-does.md') -Raw
    }

    It 'limits.md links to the matrix' {
        $script:limits | Should -Match '\]\(support-matrix\.md\)'
    }

    It 'limits.md no longer lists the machines outside the scope of this tool' {
        foreach ($t in 'HPC', 'FPGA', 'GPU', 'SAP', 'Arm64', 'confidential', 'failover cluster', 'managed application',
            'scale set', 'Kubernetes', 'virtual desktop', 'network virtual appliance', 'G or GS', 'Lsv2') {
            $script:limits | Should -Not -Match "(?i)$([regex]::Escape($t))" -Because "the matrix says $t; limits.md must not say it a second time"
        }
    }

    It 'limits.md keeps the facts that are not about scope' {
        foreach ($h in '## A wave', '## Capacity', '## The product') { $script:limits | Should -Match ([regex]::Escape($h)) }
        $script:limits | Should -Match '(?i)two type changes for each disk in 24 hours'
    }

    It 'what-it-does.md links to the matrix' {
        $script:what | Should -Match '\]\(\.\./reference/support-matrix\.md\)'
    }

    It 'what-it-does.md no longer lists the machines outside the scope of this tool' {
        $section = [regex]::Match($script:what, '(?ms)^## What it does not do\s*$(.*?)(?=^## |\z)').Groups[1].Value
        $section | Should -Not -BeNullOrEmpty
        foreach ($t in 'SAP', 'confidential', 'Kubernetes', 'virtual desktop', 'scale set', 'failover cluster',
            'Always On', 'network virtual appliance', 'managed application', 'Generation 1') {
            $section | Should -Not -Match "(?i)$([regex]::Escape($t))" -Because "the matrix says $t"
        }
    }
}

Describe 'SUPPORT-MATRIX-2: a reader of one row cannot get the generation, the series or a family name wrong' {
    # Found 2026-10-31: a row read as if a v4 D could take any route, though
    # the route depends on the generation; Bsv2 sat as a table header beside
    # v5, v6 and v7, though it is a family; and "A DI" read as a family name.
    BeforeAll {
        $script:sourceRows = @(Get-Rows 'Source sizes')
        $script:burst = $script:families.burstableTargets.series[0]
        # The words for the generations a series takes, from the data, as the
        # tool writes them.
        $words = { param($Gens) if (@($Gens) -contains 'V1') { 'Generation 1 and Generation 2' } else { 'Generation 2 only' } }
        $v67 = @(@($script:families.generations.v6.hyperVGenerations) | Where-Object { @($script:families.generations.v7.hyperVGenerations) -contains $_ })
        $script:v5Words = & $words $script:families.generations.v5.hyperVGenerations
        $script:v67Words = & $words $v67
        $script:headerOf = {
            param([string]$Heading)
            $line = @((Get-Section $Heading) -split "`r?`n" | Where-Object { $_ -match '^\|' })[0]
            @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        }
    }

    It 'reads real rows, so a pass means something' {
        @($script:sourceRows).Count | Should -BeGreaterThan 30
        $script:v67Words | Should -Be 'Generation 2 only'
    }

    It 'every row that can move says the generation in its v6 and v7 cell' {
        # Before: only the rows sized by shape said "Generation 2 only", so a
        # Generation 1 Dv4 machine read as able to go to v6.
        foreach ($row in @($script:sourceRows | Where-Object { $_[2] -ne 'Retired' })) {
            $row[5] | Should -Match ('^' + [regex]::Escape($script:v67Words) + '\. ') -Because "the $($row[0]) row must say which machines can go to v6 and v7"
        }
    }

    It 'every row that names a v5 size says the generation in its v5 cell' {
        $named = @($script:sourceRows | Where-Object { $_[2] -ne 'Retired' -and $_[4] -notmatch 'already on v5' })
        $named.Count | Should -BeGreaterThan 20
        foreach ($row in $named) {
            $row[4] | Should -Match ('^' + [regex]::Escape($script:v5Words) + '\. ') -Because "the $($row[0]) row must say which machines can go to v5"
        }
    }

    It 'the column headers of the source table say the generation too' {
        $h = & $script:headerOf 'Source sizes'
        $h[4] | Should -Be "On v5 ($script:v5Words)"
        $h[5] | Should -Be "On v6 and v7 ($script:v67Words)"
    }

    It 'never writes "a Dl" or "A Dl", which reads as a family named ADl' {
        foreach ($text in @($script:page,
                (Get-Content (Join-Path $script:manual 'reference' 'limits.md') -Raw),
                (Get-Content (Join-Path $script:manual 'use' 'plan.md') -Raw))) {
            $text | Should -Not -Match '(?i)\ban? Dl\b'
        }
        Get-VmfCodeOnly -Path $script:tool | Should -Not -Match '(?i)\ban? Dl\b'
    }

    It 'says what Dl is, once, before the first table' {
        $intro = [regex]::Match($script:page, '(?ms)\A(.*?)(?=^## )').Groups[1].Value
        $intro | Should -Match 'Dl is Microsoft''s name for the D sizes with less memory'
        $intro | Should -Match 'D2ls_v5'
    }

    It 'a row sized by shape says the smallest size of the Dl, D or E family' {
        $shape = @($script:sourceRows | Where-Object { $_[4] -match 'Dl, D or E' })
        $shape.Count | Should -BeGreaterThan 8
        foreach ($row in $shape) {
            $row[4] | Should -Match 'a size in the Dl, D or E family: the smallest with at least the machine''s vCPUs and memory\.$'
            $row[5] | Should -Match 'A size in the Dl, D or E family: the smallest with at least the machine''s vCPUs and memory\.$'
        }
    }

    It 'Bsv2 is not a column of the target series table, and it has a table of its own' {
        $h = & $script:headerOf 'Target series'
        $h | Should -Not -Contain ([string]$script:burst.series)
        $section = Get-Section 'Target series'
        $own = @($section -split "`r?`n" | Where-Object { $_ -match '^\| Item \| ' })
        $own.Count | Should -Be 1
        $own[0] | Should -Match ([regex]::Escape("$($script:burst.series), for a machine on a B v1 size"))
        $section | Should -Match ([regex]::Escape("$($script:burst.series) is one series of the B family. It is not a generation"))
    }

    It 'the Bsv2 table gives the Bsv2 facts from the data' {
        $section = Get-Section 'Target series'
        $lines = @($section -split "`r?`n")
        $at = [array]::IndexOf($lines, @($lines | Where-Object { $_ -match '^\| Item \| ' })[0])
        $rows = @{}
        foreach ($l in @($lines | Select-Object -Skip ($at + 2))) {
            if ($l -notmatch '^\|') { break }
            $c = @($l.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            $rows[$c[0]] = $c[1]
        }
        $t = $script:burst.traits
        $rows['Disk controller'] | Should -Be ([string]$t.controller)
        $rows['Machine generation'] | Should -Be $(if (@($t.hyperVGenerations) -contains 'V1') { 'Generation 1 and Generation 2' } else { 'Generation 2 only' })
        $rows['Accelerated networking'] | Should -Be $(if (@($t.acceleratedNetworkingRequired).Count) { 'Required' } else { 'Supported' })
        $rows['Choose it as'] | Should -Match ([regex]::Escape([string]$script:burst.option))
        # Before: "Sizes with an AMD processor do not give MANA", for a series
        # that has no AMD size at all.
        $rows['Microsoft Azure Network Adapter (MANA)'] | Should -Not -Match 'AMD'
        $rows['Microsoft Azure Network Adapter (MANA)'] | Should -Be 'Every size can give MANA.'
    }

    It 'the Windows and Machine generation tables never put Bsv2 beside v5 as a peer' {
        foreach ($heading in 'Windows', 'Machine generation') {
            $h = & $script:headerOf $heading
            $h[1] | Should -Be "v5 (and $($script:burst.series) for a B v1 machine)"
            $h[2] | Should -Be 'v6 and v7'
        }
        $script:page | Should -Not -Match ([regex]::Escape("v5 and $($script:burst.series)"))
        $script:page | Should -Not -Match ([regex]::Escape("v5 or $($script:burst.series)"))
    }

    It 'the NVMe table says what an image needs, not what a finding says about one machine' {
        $row = @(Get-Rows 'What a move to NVMe needs' | Where-Object { $_[0] -eq 'Image' })
        $row.Count | Should -Be 1
        $row[0][1] | Should -Not -Match '(?i)this image|this machine'
        $row[0][1] | Should -Match 'NVMe'
        $row[0][1] | Should -Match 'v5'
    }

    It 'says that a Generation 1 machine can also choose its v5 size by shape, as the planner offers' {
        InModuleScope VmMigrationFactory { Test-VmfShapeChoiceSource -Generation 'V1' -SourceSize 'Standard_D2_v4' } | Should -BeTrue
        (Get-Section 'Source sizes') | Should -Match 'On v5, a Generation 1 machine can also choose a size in the Dl, D or E family'
    }

    It 'the confidential row names no scope the tool does not have' {
        # Before: "This tool migrates the D and E series." It moves A, B, D, E
        # and F sizes, to D, E and Bsv2 sizes.
        $script:reasons.blockers.'confidential-vm-requires-manual'.meaning | Should -Not -Match 'D and E series'
        $row = @(Get-Rows 'Machines the product does not move' | Where-Object { $_[0] -eq 'Confidential machine' })
        $row.Count | Should -Be 1
        $row[0][1] | Should -Not -Match 'D and E series'
    }

    It 'the out-of-scope table has no invented "scope row"' {
        $intro = Get-Section 'Machines the product does not move'
        $intro | Should -Not -Match '(?i)scope row'
        $intro | Should -Match 'The product does not migrate these machines to any size series\.'
    }
}

Describe 'SUPPORT-MATRIX-2: the product offers, describes and recommends no route from Generation 1 to Generation 2' {
    # Since 2026-10-31 the route is ruled out completely: no move from
    # Generation 1 to Generation 2 is supported. GEN1-UPGRADE-1: decided
    # 2026-10-05, not built, outside the scope of this tool.
    BeforeAll {
        $script:readmeText = Get-Content (Join-Path $script:repoRoot 'README.md') -Raw
        $script:manualPages = @(Get-ChildItem $script:manual -Recurse -Filter '*.md')
        $script:gen1Reason = $script:reasons.blockers.'gen1-requires-redeploy'
    }

    It 'reads the manual at all, so the checks below mean something' {
        $script:manualPages.Count | Should -BeGreaterThan 30
    }

    It 'no manual page and not the README names the Trusted Launch upgrade' {
        foreach ($page in $script:manualPages) {
            (Get-Content $page.FullName -Raw) | Should -Not -Match '(?i)Trusted Launch upgrade' -Because "$($page.Name) must not describe a Generation 1 to Generation 2 route"
        }
        $script:readmeText | Should -Not -Match '(?i)Trusted Launch upgrade'
    }

    It 'no manual page and not the README labels anything Experimental' {
        foreach ($page in $script:manualPages) {
            (Get-Content $page.FullName -Raw) | Should -Not -Match '\bExperimental\b' -Because "$($page.Name)"
        }
        $script:readmeText | Should -Not -Match '\bExperimental\b'
        Get-VmfCodeOnly -Path $script:tool | Should -Not -Match '\bExperimental\b'
    }

    It 'the Generation 1 finding sends the machine to v5, and says the rest is outside the scope of this tool' {
        ($script:gen1Reason.meaning + ' ' + $script:gen1Reason.whatToDo) | Should -Not -Match '(?i)trusted launch|upgrade|backup'
        $script:gen1Reason.docs.url | Should -Not -Match 'trusted-launch'
        $script:gen1Reason.whatToDo | Should -Match 'outside the scope of this tool'
    }
}