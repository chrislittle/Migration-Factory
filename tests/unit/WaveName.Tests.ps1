#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-NAME-1 - the editor's rule and the service's rule are ONE rule.
#
# A wave name becomes a file name (approvals/<wave>.json) and it keys the
# quota record and the schedule, so Set-VmfWavePlan refuses anything outside
# [A-Za-z0-9._-] that does not start with a letter or a number.
#
# That refusal used to arrive at SAVE, after the arranging was done, and a
# tester could not see it at all: the names edited fine in the demo view,
# because demo mode never calls the service, so the rule fired for nobody who
# was looking.
#
# waves.html now makes the name usable as it is typed. That is a SECOND copy of
# the rule, and two copies of a rule is how they drift - so these tests read
# both and fail if they stop agreeing. The behaviour of the client rule is
# held by tests/js/wave-name.test.js; this file only holds that the two are
# the same rule.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:server = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Set-VmfWavePlan.ps1') -Raw
    $script:client = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
}

Describe 'WAVE-NAME-1: one rule, written in two places' {

    It 'the service still states a rule, or there is nothing to agree with' {
        $script:server | Should -Match '\$name -notmatch'
    }

    It 'the editor allows exactly the characters the service allows' {
        # Server: ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$
        # Client: .replace(/[^A-Za-z0-9._-]+/g, '-')
        $serverClass = [regex]::Match($script:server, "notmatch '\^\[[^\]]+\]\[(?<c>[^\]]+)\]").Groups['c'].Value
        $clientClass = [regex]::Match($script:client, "replace\(/\[\^(?<c>[^\]]+)\]\+/g").Groups['c'].Value
        $serverClass | Should -Not -BeNullOrEmpty -Because 'the service pattern must be readable, or this test proves nothing'
        $clientClass | Should -Not -BeNullOrEmpty -Because 'the editor pattern must be readable, or this test proves nothing'
        $clientClass | Should -Be $serverClass -Because 'a name the editor produces must be one the service accepts'
    }

    It 'and stops at the same length' {
        # The service counts the characters AFTER the first one, so its 62 is
        # the editor's 63.
        $serverMax = [int][regex]::Match($script:server, '\{0,(?<n>\d+)\}').Groups['n'].Value
        $clientMax = [int][regex]::Match($script:client, 'slice\(0, (?<n>\d+)\)').Groups['n'].Value
        $serverMax | Should -BeGreaterThan 0
        $clientMax | Should -Be ($serverMax + 1) -Because 'the service pattern counts the first character separately'
    }

    It 'the editor requires the same first character the service does' {
        $serverFirst = [regex]::Match($script:server, "notmatch '\^\[(?<c>[^\]]+)\]").Groups['c'].Value
        $script:client | Should -Match ([regex]::Escape("replace(/^[^$serverFirst]+/, '')")) -Because 'the service demands the name starts with one of these'
    }

    It 'and the person is told when their text was changed' {
        # Doing it silently would trade one surprise for another.
        $script:client | Should -Match 'nameChanged'
        $ux = [regex]::Match($script:client, "nameChanged: '(?<t>[^']*)'").Groups['t'].Value
        $ux | Should -Match '\{typed\}'
        $ux | Should -Match '\{used\}'
    }
}
