#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# QUOTA-NOT-CAPACITY-1 - a quota is not capacity, said in Microsoft's framing.
#
# Microsoft, capacity-reservation-overview: quota and capacity are separate
# checks; quota is the permission of the subscription to deploy, capacity is
# the infrastructure in a region or zone, and a capacity reservation is what
# guarantees capacity, with an SLA. quotas-overview: an assigned quota does not
# reserve or guarantee capacity.
#
# The product said "room" for capacity in several places (an invented softer
# word - CLAUDE.md rule 10), defined capacity in the glossary as partly a
# matter of quota, and called a quota increase a request for "more room". The
# wording was approved on 2026-10-07. This holds the approved sentences
# in place and keeps "room" out of operator text.
#
# No statement about the health of Azure capacity is made anywhere: the item
# says only what a quota is, what capacity is, and what a reservation gives.
#
# The independent review found the first version of this file too narrow: it
# read the pages WITH their comments (so a commented-out old string satisfied
# the tip check), it banned only a few shapes of "room", and it looked for
# capacity-health words on one page. All three are widened here.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual   = Join-Path $script:repoRoot 'docs' 'manual'
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:data     = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data'

    $script:capacityPage = Get-Content (Join-Path $script:manual 'use' 'capacity.md') -Raw
    $script:wavesCode    = Get-VmfCodeOnly -Path (Join-Path $script:dash 'waves.html')
    $script:stops        = Get-Content (Join-Path $script:data 'stop-reasons.json') -Raw | ConvertFrom-Json
    $script:stopsPage    = Get-Content (Join-Path $script:manual 'reference' 'stop-reasons.md') -Raw

    # Every word an operator reads: the manual, the pages and scripts of the
    # dashboard with their code comments removed (a comment is for whoever
    # edits the file, and the browser never shows it), and the data files the
    # dashboard shows.
    $script:operatorText = @()
    foreach ($file in @(Get-ChildItem $script:manual -Recurse -File -Filter '*.md')) {
        $script:operatorText += [pscustomobject]@{ Name = $file.FullName.Substring($script:repoRoot.Length + 1); Text = ((Get-VmfPageSource -Path $file.FullName)) }
    }
    foreach ($file in @(Get-ChildItem $script:dash -File | Where-Object { $_.Extension -in '.html', '.js' })) {
        $script:operatorText += [pscustomobject]@{ Name = $file.Name; Text = (Get-VmfCodeOnly -Path $file.FullName) }
    }
    foreach ($file in @(Get-ChildItem $script:data -File -Filter '*.json')) {
        $script:operatorText += [pscustomobject]@{ Name = $file.Name; Text = ((Get-VmfPageSource -Path $file.FullName)) }
    }
}

Describe 'QUOTA-NOT-CAPACITY-1: the manual says a quota is not capacity' {

    It 'reads every kind of operator text' {
        # A check over no files cannot fail.
        @($script:operatorText | Where-Object Name -match '\.md$').Count | Should -BeGreaterThan 40
        @($script:operatorText | Where-Object Name -match '\.html$').Count | Should -BeGreaterThan 5
        @($script:operatorText | Where-Object Name -match '\.js$').Count | Should -BeGreaterThan 0
        @($script:operatorText | Where-Object Name -eq 'stop-reasons.json').Count | Should -Be 1
    }

    It 'the capacity page opens with the approved statement, before its first section' {
        $intro = ($script:capacityPage -split '(?m)^## ')[0]
        foreach ($sentence in @(
                'Quota and capacity are separate checks.',
                'A quota is the permission of the subscription to deploy vCPUs of a size family in a region.',
                'Capacity is the infrastructure that Azure has in a region or zone.',
                'A quota does not reserve or guarantee capacity.',
                'A capacity reservation guarantees capacity for the wave, with a service-level agreement (SLA).'
            )) {
            $intro | Should -Match ([regex]::Escape($sentence)) -Because 'this wording was approved on 2026-10-07'
        }
    }

    It 'the glossary does not make capacity a matter of quota' {
        $words = Get-Content (Join-Path $script:manual 'understand' 'words.md') -Raw
        $row = ($words -split "`n") | Where-Object { $_ -match '^\| Capacity \|' }
        $row | Should -Not -BeNullOrEmpty
        $row | Should -Not -Match '(?i)quota' -Because 'quota and capacity are separate checks'
        $quotaRow = ($words -split "`n") | Where-Object { $_ -match '^\| Quota \|' }
        $quotaRow | Should -Match ([regex]::Escape('The permission of the subscription to deploy vCPUs'))
        $quotaRow | Should -Match ([regex]::Escape('A quota does not reserve or guarantee capacity.'))
        $reservationRow = ($words -split "`n") | Where-Object { $_ -match '^\| On-demand capacity reservation \|' }
        $reservationRow | Should -Match '\(SLA\)'
    }
}

Describe 'QUOTA-NOT-CAPACITY-1: the wave editor and the stop reason say it too' {

    It 'the quota row tip says a quota does not reserve or guarantee capacity' {
        # Read from the code, not the file: a commented-out old string must not
        # satisfy this.
        $m = [regex]::Match($script:wavesCode, "quotaRowTip:\s*'([^']*)'")
        $m.Success | Should -BeTrue -Because 'the quota row needs its tip'
        $m.Groups[1].Value | Should -Be 'The permission of the subscription to deploy vCPUs of these size families in this region. A quota does not reserve or guarantee capacity. An on-demand capacity reservation does. It is the row above.'
    }

    # CAPACITY-WORDS-2: this sentence was approved with "an SLA" on
    # 2026-10-07, and on 2026-10-12 spelled out, as the capacity
    # page and the glossary already do.
    It 'capacityUnavailable names the capacity reservation and its SLA' {
        $reason = @($script:stops.reasons | Where-Object code -eq 'capacityUnavailable')
        $reason.Count | Should -Be 1
        $reason[0].whatToDo | Should -Match ([regex]::Escape('An on-demand capacity reservation guarantees capacity for a wave, with a service-level agreement (SLA).'))
        $reason[0].whatToDo | Should -Not -Match '(?i)avoids this entirely'
    }

    It 'and the generated stop-reasons page carries the same words' {
        $script:stopsPage | Should -Match ([regex]::Escape('An on-demand capacity reservation guarantees capacity for a wave, with a service-level agreement (SLA).'))
    }
}

Describe 'CAPACITY-WORDS-2: capacity is not a count of interfaces or disks' {

    It 'the stop reasons for too few interfaces or data disks name the count, not capacity' {
        foreach ($code in 'targetTooFewNics', 'targetTooFewDataDisks') {
            $reason = @($script:stops.reasons | Where-Object code -eq $code)
            $reason.Count | Should -Be 1 -Because "$code is a stop reason"
            "$($reason[0].title) $($reason[0].meaning) $($reason[0].whatToDo)" | Should -Not -Match '(?i)capacity' -Because 'capacity is the infrastructure of Azure in a region or zone (glossary)'
        }
        @($script:stops.reasons | Where-Object code -eq 'targetTooFewNics')[0].meaning | Should -Match 'fewer network interfaces'
        @($script:stops.reasons | Where-Object code -eq 'targetTooFewDataDisks')[0].meaning | Should -Match 'fewer data disks'
    }

    It 'the generated stop-reasons page has no capacity of a count left' {
        $script:stopsPage | Should -Not -Match '(?i)(network|data disk) capacity'
    }

    It 'the PRECHECK row names what the step checks' {
        $page = Get-Content (Join-Path $script:manual 'technical' 'machine-state-machine.md') -Raw
        $row = ($page -split "`n") | Where-Object { $_ -match '^\| PRECHECK \| Checking \|' }
        @($row).Count | Should -Be 1
        $row | Should -Not -Match '(?i)capacity'
        $row | Should -Match ([regex]::Escape("the target size in the machine's zone, and the number of network interfaces and data disks that the target size holds."))
    }

    It 'a quota increase can take days, in one wording everywhere (QUOTA-CHECK-SPINNER-1: Azure accepts or refuses)' {
        $m = [regex]::Match($script:wavesCode, "quotaBody:\s*'([^']*)'")
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match 'Azure accepts or refuses each request\. The answer can come after some days\.'
        $bad = foreach ($item in $script:operatorText) {
            if ($item.Text -match '(?i)a day or two') { $item.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'the capacity page and the glossary say a quota increase can take days'
    }
}

Describe 'QUOTA-NOT-CAPACITY-1: what operator text may not say' {

    It 'no operator text says room - Azure says capacity, quota, or cores' {
        # One sentence uses "room" for something that is not capacity, and it
        # is named here whole, so a new use anywhere else fails: a target size
        # holds a number of disks and network interfaces.
        # RESTORE-DIALOG-WORDS-1: the second one, "a move needs room for two"
        # type changes of a disk, now says "a move needs both of them", as the
        # Safety copies page has since HDD-OS-1.
        $allowed = @(
            'the target size has room for every disk and network interface'
        )
        $bad = foreach ($item in $script:operatorText) {
            $text = $item.Text
            foreach ($sentence in $allowed) { $text = $text.Replace($sentence, '') }
            foreach ($m in [regex]::Matches($text, '(?i)\brooms?\b')) {
                $from = [math]::Max(0, $m.Index - 40)
                "$($item.Name): '...$($text.Substring($from, [math]::Min(80, $text.Length - $from)) -replace '\s+', ' ')...'"
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'room is an invented word for capacity, quota or cores (CLAUDE.md rule 10)'
    }

    It 'no operator text says how healthy Azure capacity is' {
        # The item makes no statement about shortages, constrained regions, or
        # how often capacity runs out. One quoted Azure error is allowed: the
        # install page quotes it so an operator can recognise it.
        $allowed = @('ManagedEnvironmentCapacityHeavyUsageError: AKS is experiencing heavy usage')
        $patterns = 'busy day', 'heavy usage', 'high demand', 'shortages?\b', 'often short', 'region is short', 'is short of', 'short of (a|the) size', 'constrained region', 'runs? out of capacity'
        $bad = foreach ($item in $script:operatorText) {
            $text = $item.Text
            foreach ($sentence in $allowed) { $text = $text.Replace($sentence, '') }
            foreach ($pattern in $patterns) {
                foreach ($m in [regex]::Matches($text, "(?i)\b$pattern")) { "$($item.Name): '$($m.Value)'" }
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'this product says what a quota and a reservation are, not how Azure capacity is doing'
    }
}
