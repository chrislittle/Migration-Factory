#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TERM-1 - Azure's own names, and the UI telling the truth about what we do.
#
# A review of the wave settings on 2026-09-02 found these faults. Azure
# on-demand capacity reservations were listed as "reserve and guarantee
# (needs reserving separately)", although the flow has made the ODCR from the
# first days, in a capacity reservation group in a decided subscription and
# resource group. "Regular capacity" is not an Azure term. "Fast networking"
# is not an Azure term: the term is accelerated networking. And "below the
# minimum" made no sense, because accelerated networking is on or off. So
# every word needed an audit for real Azure terms and ASD-STE100.
#
# Each finding was right, and there were TWO different faults behind them.
#
# THE FIRST IS A LIE, NOT A WORDING PROBLEM. The wave settings said reserving
# capacity was "a separate step, and this app cannot do it yet". The app has
# done it since CAPRG-1 shipped on 2026-08-30: New-VmfWaveReservation creates
# the reservation group AND the reservation, in the machines' own resource
# group and subscription. The UI was three days stale and telling operators the
# product could not do something it does. No wording rule catches that - only a
# test that reads the engine.
#
# THE SECOND IS THAT THE CHECKER PERMITTED THE RIGHT WORDS WITHOUT REQUIRING
# THEM. 'accelerated networking', 'temporary disk' and 'capacity reservation'
# were all on Test-SimplifiedEnglish's approved list, and 'fast networking',
# 'temporary drive' and 'regular capacity' shipped anyway. Permitting a word
# does not stop somebody inventing a different one.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:pages    = @(Get-ChildItem $script:dash -Filter '*.html')
    $script:data     = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data'
    $script:runway   = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfWaveReservation.ps1') -Raw
    $script:capOps   = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsCapacity.ps1') -Raw
    $script:ste      = Get-Content (Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Raw

    # Every operator-facing string in the product: the pages and the two data
    # files the engine ships for the dashboard to read.
    $script:allText = @()
    foreach ($p in $script:pages) { $script:allText += [pscustomobject]@{ Name = $p.Name; Text = ((Get-VmfPageSource -Path $p.FullName)) } }
    foreach ($j in 'stop-reasons.json', 'assessment-reasons.json', 'operator-guide.json', 'driver-floors.json') {
        $path = Join-Path $script:data $j
        if (Test-Path $path) { $script:allText += [pscustomobject]@{ Name = $j; Text = ((Get-VmfPageSource -Path $path)) } }
    }
}

Describe 'TERM-1: the engine really does create the capacity reservation' {

    It 'New-VmfWaveReservation creates the group and the reservation' {
        $script:capOps | Should -Match 'New-AzCapacityReservationGroup'
        $script:capOps | Should -Match 'New-AzCapacityReservation\b'
        $script:runway | Should -Match 'New-VmfCapacityReservation'
    }

    It 'and it lands in the machines OWN resource group and subscription' {
        # CAPRG-1 and ODCR-SUB-1. A reservation group is subscription-scoped,
        # so one made anywhere else is unusable by the machines it is for.
        $script:runway | Should -Match '\$claimRg\s*=\s*\[string\]\$claim\.resourceGroup'
        $script:runway | Should -Match '\$claimSub\s*=\s*\[string\]\$claim\.subscriptionId'
        # RESERVING-STUCK-1: the names and ids come from one rule over the claim.
        $script:runway | Should -Match 'New-VmfCapacityReservation -ResourceGroupName \$names\.ResourceGroup'
        $script:capOps | Should -Match '\[Parameter\(Mandatory\)\]\[string\]\$SubscriptionId'
    }
}

Describe 'TERM-1: and the UI does not say otherwise' {

    It 'no page claims the app cannot reserve capacity' {
        # THE ACTUAL BUG. This is not a wording rule - it is the UI describing
        # a product we stopped being three days earlier.
        # Scoped to sentences that are ABOUT capacity: "Planning is a separate
        # step" is a true statement about the assess-then-plan flow and has
        # nothing to do with this. A rule that cannot tell those apart trains
        # people to ignore it.
        $lies = @(
            'needs reserving separately',
            'cannot do it yet',
            'is a separate step',
            'waits until somebody reserves',
            'nothing to reserve'
        )
        # A window around the phrase decides whether the sentence is about
        # capacity at all - no quote characters in the pattern, because a
        # backslash is not an escape in a PowerShell double-quoted string and
        # \" ends it, which is how this check silently stopped parsing once.
        $bad = foreach ($item in $script:allText) {
            foreach ($l in $lies) {
                foreach ($m in [regex]::Matches($item.Text, "(?i)" + [regex]::Escape($l))) {
                    $from = [math]::Max(0, $m.Index - 90)
                    $len  = [math]::Min(180, $item.Text.Length - $from)
                    $window = $item.Text.Substring($from, $len)
                    if ($window -match '(?i)(reserv|capacity)') { "$($item.Name): '$l'" }
                }
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'New-VmfWaveReservation has created reservations since CAPRG-1'
    }

    It 'and it names where the reservation goes, because somebody has to find it' {
        $waves = ($script:allText | Where-Object Name -eq 'waves.html').Text
        $waves | Should -Match 'resource group and subscription' `
            -Because 'an operator looking for the reservation must be told where it is'
    }
}

Describe 'TERM-1: Azure names, not invented ones' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        # The four the review found, plus the ones the sweep turned up with
        # them. Checked here as well as in Test-SimplifiedEnglish so that a
        # failure names the Azure term rather than only the rule.
        $script:invented = [ordered]@{
            'fast networking'         = 'accelerated networking'
            'fast network path'       = 'accelerated networking'
            'fast path'               = 'accelerated networking, MANA, or the SR-IOV virtual function'
            'temporary drive'         = 'temporary disk'
            'temp drive'              = 'temporary disk'
            'regular capacity'        = 'None, the value with no on-demand capacity reservation (there is no "regular capacity" in Azure)'
            'reserved and guaranteed' = 'on-demand capacity reservation'
            'guaranteed capacity'     = 'on-demand capacity reservation'
            'hardware generation'     = 'machine size series ("generation" is Gen1/Gen2 in Azure)'
        }
    }

    It 'no operator-facing text invents a term Azure already has' {
        $invented = $script:invented
        $bad = foreach ($item in $script:allText) {
            foreach ($k in $invented.Keys) {
                if ($item.Text -match "(?i)\b$([regex]::Escape($k))\b") {
                    "$($item.Name) says '$k' - Azure says '$($invented[$k])'"
                }
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty
    }

    It 'nor does the engine, the guest scripts, the service or the contracts - comments included' {
        # AN-KEEP-1, 2026-09-25: the words "fast networking" are not an Azure term, and it
        # was still in the code. The check
        # above read only the pages and the data files, so the term already
        # ruled out on 2026-09-02 lived on in the ENGINE - seven places,
        # two of them messages that reach the activity log - and six more were
        # added the day this was written. An engine message IS operator-facing:
        # the dashboard shows it. And a comment is where the next message is
        # copied from, so comments are held to it too.
        $roots = @(
            (Join-Path $script:repoRoot 'src' 'VmMigrationFactory'),
            (Join-Path $script:repoRoot 'src' 'guest'),
            (Join-Path $script:repoRoot 'src' 'facade'),
            (Join-Path $script:repoRoot 'schemas')
        ) | Where-Object { Test-Path $_ }
        $files = @($roots | ForEach-Object {
                Get-ChildItem $_ -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.sh', '*.json', '*.js', '*.cs'
            })
        $files.Count | Should -BeGreaterThan 50 -Because 'a check that finds no files cannot fail'
        $bad = foreach ($file in $files) {
            $text = (Get-VmfPageSource -Path $file.FullName)
            foreach ($k in $script:invented.Keys) {
                if ($text -match "(?i)\b$([regex]::Escape($k))\b") {
                    "$($file.FullName.Substring($script:repoRoot.Length + 1)) says '$k' - Azure says '$($script:invented[$k])'"
                }
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty
    }

    It 'the driver floor is described as a DRIVER floor, not as a switch' {
        # "Below the minimum" made no sense for a setting that is on or off -
        # accelerated networking IS on or off. The setting is about something
        # else entirely: whether the guest kernel meets the published minimum
        # for the MANA driver on its distribution. The old label put those two
        # different things behind one sentence, so the question read as
        # nonsense. It is the same fault as calling a size series a generation.
        # WAVE-KERNEL-LINE-1: the wave setting is gone; the one row left on
        # each page names the MANA driver, never accelerated networking.
        foreach ($p in 'waves.html', 'wizard.html', 'migrations.html') {
            $text = ($script:allText | Where-Object Name -eq $p).Text
            $text | Should -Match 'Machines whose kernel the product updates if it has no MANA driver' `
                -Because "$p must say what the row is really about"
            $text | Should -Not -Match 'below the (published )?minimum for accelerated networking' `
                -Because "$p must not describe an on/off feature as having a minimum"
        }
    }

    It 'and the checker REQUIRES those terms, not merely permits them' {
        # The gap that let all of this ship. TechnicalNames is an allow-list;
        # an allow-list cannot notice a word that is not on it.
        # 'quota increase': QUOTA-PREVIEW-1, 2026-10-26, "you don't 'ask azure'".
        foreach ($concept in 'accelerated networking', 'temporary disk', 'capacity reservation', 'size series', 'quota increase') {
            $script:ste | Should -Match "Concept = '$concept'" -Because "'$concept' needs a substitution rule"
        }
        $script:ste | Should -Match "fast networking"
        $script:ste | Should -Match "regular capacity"
        $script:ste | Should -Match "hardware generation"
        $script:ste | Should -Match ([regex]::Escape('\bask Azure\b'))
    }

    It 'one word, one concept: "generation" is Gen1/Gen2 and nothing else' {
        # Both meanings were on the same screens - "Generation 2" for the
        # hypervisor generation and "Hardware generation" for the v6/v7 size
        # series. Two concepts behind one word is the fault, whichever word
        # wins, and Azure had already spent this one.
        foreach ($item in $script:allText) {
            $gens = [regex]::Matches($item.Text, '(?i)generation') | ForEach-Object { $_.Index }
            foreach ($i in $gens) {
                $window = $item.Text.Substring([math]::Max(0, $i - 30), [math]::Min(45, $item.Text.Length - [math]::Max(0, $i - 30)))
                $window | Should -Not -Match '(?i)(hardware|size|series|target)\s+generation' `
                    -Because "$($item.Name): generation means Gen1/Gen2 in Azure"
            }
        }
    }
}
