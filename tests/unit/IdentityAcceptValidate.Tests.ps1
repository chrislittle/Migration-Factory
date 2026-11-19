#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# IDENTITY-ACCEPT-VALIDATE-1, after REBUILD-REMOVE-ENGINE-1.
#
# MEASURED 2026-11-01 in the lab: an accepted identity loss on a rebuild (path
# B) rolled the machine back at VALIDATING, and this item taught the
# comparison to know an accepted loss. The owner removed the rebuild on
# 2026-11-07, and with it the acceptance: no move deletes a system-assigned
# identity now, so a new object ID is always a failure. What stays from this
# item is the comparison itself - and that a machine with both kinds of
# identity has its user-assigned identities compared too.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:old = '11111111-2222-3333-4444-555555555555'
    $script:new = '99999999-8888-7777-6666-555555555555'
    $script:uami = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-app'

    function Global:IavCaptured([string]$Type = 'SystemAssigned', [string]$Principal = $script:old, [string[]]$Uami = @()) {
        [pscustomobject]@{ name = 'app-01'; ultraSsdEnabled = $false
            identity = [pscustomobject]@{ type = $Type; principalId = $Principal; userAssignedIds = @($Uami) } }
    }
    function Global:IavLive([string]$Type = 'SystemAssigned', [string]$Principal = $script:new, [string[]]$Uami = @()) {
        [pscustomobject]@{ identityType = $Type; identityPrincipalId = $Principal; userAssignedIds = @($Uami); ultraSsdEnabled = $false }
    }
    function Global:IavFidelity($Captured, $Live) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $Captured; l = $Live } {
            param($c, $l) Test-VmfRebuildFidelity -Captured $c -Live $l
        }
    }
}
AfterAll {
    Remove-Item 'function:\IavCaptured', 'function:\IavLive', 'function:\IavFidelity' -ErrorAction SilentlyContinue
}

Describe 'IDENTITY-ACCEPT-VALIDATE-1: the comparison holds every machine to its identity' {
    It 'a new object ID is a failure: nothing excuses it' {
        $r = IavFidelity (IavCaptured) (IavLive)
        $r.Ok | Should -BeFalse
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Detail | Should -Match 'NEW one'
    }

    It 'the same account back is a match' {
        (IavFidelity (IavCaptured) (IavLive -Principal $script:old)).Verdict | Should -Be 'MATCH'
    }

    It 'another type of identity is a failure: <Live>' -ForEach @(
        @{ Live = '' }, @{ Live = 'UserAssigned' }, @{ Live = 'None' }
    ) {
        $r = IavFidelity (IavCaptured) (IavLive -Type $Live)
        $r.Ok | Should -BeFalse
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Detail | Should -Match "was 'SystemAssigned' before the move"
    }

    It 'lost Ultra Disk capability is a failure' {
        $cap = IavCaptured -Principal $script:old; $cap.ultraSsdEnabled = $true
        $r = IavFidelity $cap (IavLive -Principal $script:old)
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match '(?i)ultra'
    }

    It 'a live read with no account stays unknown' {
        (IavFidelity (IavCaptured) (IavLive -Principal '')).Verdict | Should -Be 'UNKNOWN'
    }
}

Describe 'IDENTITY-ACCEPT-VALIDATE-1: a machine with both kinds has its user-assigned identities compared' {
    It 'a lost user-assigned identity fails, with the type written as <Type>' -ForEach @(
        @{ Type = 'SystemAssigned, UserAssigned' }, @{ Type = 'SystemAssignedUserAssigned' }
    ) {
        $r = IavFidelity (IavCaptured -Type $Type -Uami @($script:uami)) (IavLive -Type $Type -Principal $script:old)
        $r.Ok | Should -BeFalse
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Detail | Should -Match 'mi-app'
    }

    It 'both kinds back as they were: a match' {
        $t = 'SystemAssigned, UserAssigned'
        (IavFidelity (IavCaptured -Type $t -Uami @($script:uami)) (IavLive -Type $t -Principal $script:old -Uami @($script:uami))).Verdict | Should -Be 'MATCH'
    }
}