#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERMISSIONS-WHY-1 (MANUAL-REVIEW-1, area B): a security reviewer reads the
# Azure actions that the two custom roles hold, on the manual's page
# reference/permissions.md. The page listed each action with no reason. The
# map, data/rbac-actions.json, had a reason per operation, but it was written
# for developers: cmdlet names and backlog items, and some of it out of date.
#
# So the map carries a second reason, operatorWhy: one sentence per action (two for a long list), in
# the words an operator reads - the step of the move or the page that uses the
# action, checked against the code that calls it. The generator writes it in a
# column of the page, and the STE gate reads it from the map.
#
# What is held here:
#   - every action in the map has a sentence, and every sentence an action;
#   - each is one sentence (two for a long list) of at most 25 words each, with
#     no developer names, and names a step or a page of the product;
#   - the page shows each action with its sentence, in each role's table;
#   - the STE gate reads every sentence from the map, and fails a bad one.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:mapPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json'
    $script:map = Get-Content $script:mapPath -Raw | ConvertFrom-Json
    $script:actions = @($script:map.operations | ForEach-Object { @($_.actions) } | Where-Object { $_ } | Sort-Object -Unique)
    $script:why = $script:map.PSObject.Properties['operatorWhy'] ? $script:map.operatorWhy : $null
    $script:whyKeys = @(if ($script:why) { $script:why.PSObject.Properties.Name })
    $script:pagePath = Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'permissions.md'
    $script:tool = Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1'
    # The nouns a sentence names its step or page with: the steps as the pages
    # show them (Get-VmfStepWord, UX_STATE in migrations.js), the rollback and
    # the restore, and the pages, buttons and jobs that use an action.
    $script:places = @(
        'Checking', 'Backing up', 'Preparing', 'Shutting down', 'Moving', 'Starting up', 'Verifying',
        'the rollback', 'a rollback', 'Restore this machine', 'An assessment', 'an assessment',
        'Where does the scan look\?', 'the targets step', 'Check the quota', 'Reserve capacity', 'Release',
        'Request an increase', 'the daily cleanup', 'Delete the copies as well', 'the wave editor', 'Start this wave',
        'Build the waves', 'Finish the rollback', 'Finish the restore', 'Delete these disks'
    )
    # The actions each Azure call holds, from the map: Update-AzVM (a write of
    # the whole machine) and Set-AzNetworkInterface (a write of an interface).
    $script:actionsOf = {
        param([string]$Cmdlet)
        @($script:map.operations | Where-Object { $_.cmdlet -eq $Cmdlet } | ForEach-Object { @($_.actions) } | Where-Object { $_ } | Sort-Object -Unique)
    }
}

Describe 'PERMISSIONS-WHY-1: every action has a sentence for the operator' {

    It 'the map reads real actions, or this file checks nothing' {
        $script:actions.Count | Should -BeGreaterThan 40
    }

    It 'every action in the map has a sentence' {
        $missing = @($script:actions | Where-Object {
            -not ($script:whyKeys -contains $_) -or [string]::IsNullOrWhiteSpace([string]$script:why.$_)
        })
        $missing | Should -BeNullOrEmpty -Because 'a security reviewer asks why the product holds each action'
    }

    It 'every sentence belongs to an action in the map, so a removed action takes its sentence with it' {
        @($script:whyKeys | Where-Object { $script:actions -notcontains $_ }) | Should -BeNullOrEmpty
    }

    It 'each is at most five short sentences (one fact each), of at most 25 words each, that end with a full stop' {
        foreach ($a in $script:whyKeys) {
            $s = [string]$script:why.$a
            $s | Should -Match '\.$' -Because $a
            # A step title that is a question (Where does the scan look?) ends no
            # sentence: the word after it starts lower case.
            $sentences = @($s -csplit '(?<=[.!?])\s+(?=[A-Z])' | Where-Object { $_.Trim() })
            $sentences.Count | Should -BeLessOrEqual 5 -Because "$a has at most five sentences, one fact each"
            $s | Should -Not -Match ';' -Because "$a has whole sentences, not two joined"
            foreach ($one in $sentences) {
                @($one -split '\s+' | Where-Object { $_ }).Count | Should -BeLessOrEqual 25 -Because "$a : $one"
            }
        }
    }

    It 'no sentence names a command, a backlog item or a role it does not mean' {
        foreach ($a in $script:whyKeys) {
            $s = [string]$script:why.$a
            $s | Should -Not -Match '\b[A-Z][a-z]+-(Vmf|Az)[A-Za-z]+\b' -Because "$a names no command"
            $s | Should -Not -Match '\b[A-Z][A-Z0-9]+(-[A-Z0-9]+)*-\d+\b' -Because "$a names no backlog item"
            $s | Should -Not -MatchExactly '\b(PRECHECK|GUEST_PREP|SAFETY_PRISTINE|SAFETY_COPY|CONVERTING|VALIDATING|STOPPED|STARTING)\b' -Because "$a names the step as the pages show it"
        }
    }

    It 'each sentence names the step of the move, or the page, that uses the action' {
        $pattern = '(' + ($script:places -join '|') + ')'
        foreach ($a in $script:whyKeys) {
            [string]$script:why.$a | Should -MatchExactly $pattern -Because "$a says where the product uses it"
        }
    }

    It 'the delete and quota actions say that they follow a person''s choice' {
        foreach ($a in 'Microsoft.Compute/disks/delete', 'Microsoft.Compute/snapshots/delete') {
            [string]$script:why.$a | Should -Match 'Delete the copies as well|chose|person' -Because "$a is said with the person's choice"
        }
        [string]$script:why.'Microsoft.Quota/quotas/write' | Should -Match 'Request an increase' -Because 'a quota request is only on a person''s choice'
    }
}

Describe 'PERMISSIONS-WHY-1: the sentences say what the code does (after SCAN-SCOPE-READS-1 and CPU-BASELINE-REMOVE-1)' {

    It 'no sentence names "a finish", which is no page name: the buttons are Finish the rollback and Finish the restore' {
        foreach ($a in $script:whyKeys) { [string]$script:why.$a | Should -Not -Match '\ba finish\b' -Because $a }
    }

    It 'every action Azure checks on a write of the whole machine names both finishes, which swap data disks with that write' {
        # Complete-VmfDataDiskSwap -> Set-VmfVmDataDisks -> Update-AzVM. Not the
        # group join: a finish does not put the machine in a group.
        $writes = @(& $script:actionsOf 'Update-AzVM' | Where-Object { $_ -ne 'Microsoft.Compute/capacityReservationGroups/deploy/action' })
        $writes.Count | Should -BeGreaterThan 2
        foreach ($a in $writes) {
            [string]$script:why.$a | Should -MatchExactly 'Finish the rollback' -Because $a
            [string]$script:why.$a | Should -MatchExactly 'Finish the restore' -Because $a
        }
    }

    It 'every action of a write of a network interface names Restore this machine, which sets accelerated networking back' {
        # Restore-VmfVm -> Restore-VmfCapturedAcceleratedNetworking -> Set-AzNetworkInterface.
        $writes = @(& $script:actionsOf 'Set-AzNetworkInterface')
        $writes.Count | Should -BeGreaterThan 6
        foreach ($a in $writes) { [string]$script:why.$a | Should -MatchExactly 'Restore this machine' -Because $a }
    }

    It 'the quota and size reads name Build the waves, whose plan operation checks the quota' {
        $entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        [regex]::Match($entry, "(?s)'plan'\s*\{.*?(?=\n\s{4}'wave'\s*\{)").Value | Should -Match 'Test-VmfQuota' -Because 'the plan operation reads the quota'
        foreach ($a in 'Microsoft.Compute/locations/usages/read', 'Microsoft.Compute/skus/read') {
            [string]$script:why.$a | Should -MatchExactly 'Build the waves' -Because $a
        }
    }

    It 'the subscription read does not say that an assessment reads outside its scope' {
        # SCAN-SCOPE-READS-1 removed GET /subscriptions from the assessment. The
        # read that is left lists the subscriptions under a management group.
        $s = [string]$script:why.'Microsoft.Resources/subscriptions/read'
        $s | Should -Match 'management group'
        $s | Should -Not -Match 'every subscription that it can see|each subscription that it scans'
    }

    It 'the quota read says that no step calls it, and the usage read says it is the quota read' {
        [string]$script:why.'Microsoft.Quota/quotas/read' | Should -Match '^No step of the product calls this action\.'
        [string]$script:why.'Microsoft.Compute/locations/usages/read' | Should -Match 'not with Microsoft\.Quota/quotas/read'
    }

    It 'the image read says that it reads only a Marketplace image, and its latest version' {
        $s = [string]$script:why.'Microsoft.Compute/locations/publishers/read'
        $s | Should -Match 'Marketplace'
        $s | Should -Match 'latest version'
    }
}

Describe 'PERMISSIONS-WHY-1: the permissions page shows the sentence' {

    It 'each role section is a table with a column for the sentence' {
        $page = Get-Content $script:pagePath -Raw
        ([regex]::Matches($page, '\| Operation \| When the product uses it \|')).Count | Should -Be 2
    }

    It 'every action of each role is a row with its sentence' {
        $page = Get-Content $script:pagePath -Raw
        foreach ($role in 'assess', 'execute') {
            $name = $script:map.roles.$role.roleName
            $section = [regex]::Match($page, "(?s)## $([regex]::Escape($name))\s.*?(?=\n## )").Value
            $section | Should -Not -BeNullOrEmpty -Because $name
            $mine = @($script:map.operations | Where-Object { $_.role -eq $role } | ForEach-Object { @($_.actions) } | Where-Object { $_ } | Sort-Object -Unique)
            foreach ($a in $mine) {
                $row = [regex]::Match($section, "(?m)^\| ``$([regex]::Escape($a))`` \| (.+) \|$")
                $row.Success | Should -BeTrue -Because "$a is a row under $name"
                $row.Groups[1].Value | Should -BeLike "$([string]$script:why.$a)*" -Because "$a shows its sentence"
            }
        }
    }
}

Describe 'PERMISSIONS-WHY-1: the STE gate reads the sentences from the map' {

    It 'the gate lists the map as a source, with one string for each action' {
        $line = @(& $script:tool -ListSources 6>$null) -match '^rbac-actions\s'
        $line | Should -Match "\b$($script:actions.Count) string"
    }

    It 'a sentence that breaks a rule is a finding of the map' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-permwhy-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $data = Join-Path $fake 'src' 'VmMigrationFactory' 'data'
            New-Item -ItemType Directory -Path $data -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $fake 'src' 'dashboard') -Force | Out-Null
            $doc = Get-Content $script:mapPath -Raw | ConvertFrom-Json
            $doc.operatorWhy.'Microsoft.Compute/virtualMachines/read' = 'Checking reads the machine, and it is read by the engine every time that a wave runs and a machine is moved by the product to its new size in Azure today.'
            $doc | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $data 'rbac-actions.json') -Encoding utf8NoBOM
            $r = & $script:tool -Path $fake -Source 'rbac-actions' 6>$null
            $ids = @($r.Findings | ForEach-Object { $_.Id })
            $ids | Should -Contain 'rbac-actions.json:Microsoft.Compute/virtualMachines/read'
        }
        finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
    }
}
