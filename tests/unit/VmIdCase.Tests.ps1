#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VMID-CASE-1, from the TESTMATRIX-1 lab session, 2026-09-30.
#
# Azure resource IDs ignore letter case, and Azure does not always give one ID
# in one case: the lab's assessment read
# /resourceGroups/VMF-MATRIX-CORE/.../virtualMachines/MX-U6A for a machine
# made as mx-u6a in vmf-matrix-core. The product keeps the ID as the assessment
# read it, and it names store documents from that ID. Blob storage names ARE
# case sensitive, so the same machine in two letter cases is two names there.
#
# A Windows disk is not case sensitive, so a test on real files here cannot see
# any of this. These tests use a store that keeps names the way blob storage
# does: exactly as written.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:upper = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/VMF-MATRIX-CORE/providers/Microsoft.Compute/virtualMachines/MX-U6A'
    $script:lower = $script:upper.ToLowerInvariant()
    $script:runA = 'azblob://acct/vmf-runs/run-a'
    $script:runB = 'azblob://acct/vmf-runs/run-b'
    $script:claims = 'azblob://acct/vmf-runs/vmf-claims'

    # The store, as blob storage keeps it: one name, one document, and a name
    # in another letter case is another document.
    function Global:Use-VmfCaseSensitiveStore {
        $global:VmfCaseStore = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        Mock -ModuleName VmMigrationFactory Read-VmfStoreJson {
            $k = "$($RunPath.TrimEnd('/'))|$RelPath"
            if ($global:VmfCaseStore.ContainsKey($k)) { $global:VmfCaseStore[$k] | ConvertFrom-Json -Depth 30 } else { $null }
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreJson {
            $global:VmfCaseStore["$($RunPath.TrimEnd('/'))|$RelPath"] = ($Document | ConvertTo-Json -Depth 30)
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreJsonExclusive {
            $k = "$($RunPath.TrimEnd('/'))|$RelPath"
            if ($global:VmfCaseStore.ContainsKey($k)) { return $false }
            $global:VmfCaseStore[$k] = ($Document | ConvertTo-Json -Depth 30)
            $true
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItem {
            $null = $global:VmfCaseStore.Remove("$($RunPath.TrimEnd('/'))|$RelPath")
        }
        # CLAIM-TAKEOVER-RACE-1: a claim is read as text, written only if it
        # is still the text read, and removed only as read.
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText {
            $k = "$($RunPath.TrimEnd('/'))|$RelPath"
            if ($global:VmfCaseStore.ContainsKey($k)) { $global:VmfCaseStore[$k] } else { $null }
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextExclusive {
            $k = "$($RunPath.TrimEnd('/'))|$RelPath"
            if ($global:VmfCaseStore.ContainsKey($k)) { return $false }
            $global:VmfCaseStore[$k] = $Content
            $true
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextIfVersion {
            $k = "$($RunPath.TrimEnd('/'))|$RelPath"
            if (-not $global:VmfCaseStore.ContainsKey($k)) { return $false }
            $now = & (Get-Module VmMigrationFactory) { param($x) Get-VmfDocumentVersion -Text $x } $global:VmfCaseStore[$k]
            if ($now -ne $ExpectedVersion) { return $false }
            $global:VmfCaseStore[$k] = $Content
            $true
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion {
            $k = "$($RunPath.TrimEnd('/'))|$RelPath"
            if (-not $global:VmfCaseStore.ContainsKey($k)) { return $false }
            $now = & (Get-Module VmMigrationFactory) { param($x) Get-VmfDocumentVersion -Text $x } $global:VmfCaseStore[$k]
            if ($now -ne $ExpectedVersion) { return $false }
            $null = $global:VmfCaseStore.Remove($k)
            $true
        }
        Mock -ModuleName VmMigrationFactory Test-VmfStoreItem {
            $global:VmfCaseStore.ContainsKey("$($RunPath.TrimEnd('/'))|$RelPath")
        }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames {
            $prefix = "$($RunPath.TrimEnd('/'))|$(if ($Folder) { "$Folder/" })"
            @($global:VmfCaseStore.Keys | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) } |
                ForEach-Object { $_.Substring($prefix.Length) } |
                Where-Object { $_ -notmatch '/' -and (-not $Extension -or $_.EndsWith($Extension)) })
        }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent { }
    }
    function Global:Set-VmfCaseDoc {
        param([string]$RunPath, [string]$RelPath, $Document)
        $global:VmfCaseStore["$($RunPath.TrimEnd('/'))|$RelPath"] = ($Document | ConvertTo-Json -Depth 30)
    }
    function Global:Get-VmfCaseKeys { @($global:VmfCaseStore.Keys) }
}

AfterAll {
    Remove-Item -Path 'function:\Use-VmfCaseSensitiveStore', 'function:\Set-VmfCaseDoc', 'function:\Get-VmfCaseKeys' -ErrorAction SilentlyContinue
    Remove-Variable -Name VmfCaseStore -Scope Global -ErrorAction SilentlyContinue
}

Describe 'VMID-CASE-1: one machine is claimed once, whatever the letter case of its ID' {
    # RUN-CLAIM-1: the claim is what stops two migrations converting one
    # machine at once. It was named from the ID as each run's assessment read
    # it - so two runs whose assessments read the machine in two letter cases
    # held two claims, and both were granted.
    BeforeEach {
        Use-VmfCaseSensitiveStore
        Set-VmfCaseDoc $script:runA 'run.json' @{ runId = 'run-a' }
        Set-VmfCaseDoc $script:runB 'run.json' @{ runId = 'run-b' }
    }

    It 'a second run that read the ID in another letter case is refused' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; b = $script:runB; up = $script:upper; low = $script:lower } {
            (New-VmfVmClaim -RunPath $a -VmId $up -RunId 'run-a').Granted | Should -BeTrue
            $second = New-VmfVmClaim -RunPath $b -VmId $low -RunId 'run-b'
            $second.Granted | Should -BeFalse -Because 'the machine is already in run-a'
            $second.HeldBy | Should -Be 'run-a'
        }
    }

    It 'the holder asks again in the other letter case and still holds it' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; up = $script:upper; low = $script:lower } {
            (New-VmfVmClaim -RunPath $a -VmId $up -RunId 'run-a').Granted | Should -BeTrue
            (New-VmfVmClaim -RunPath $a -VmId $low -RunId 'run-a').Detail | Should -Be 'already held by this run'
        }
    }

    It 'a claim made before this change, under the letter case its run read, still fences the machine' {
        # An installation updated while a run holds machines has claims under
        # the old names. Missing them would let a second run take a machine
        # that the first is still moving.
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-a'; runPath = $script:runA }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            $asked = New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b'
            $asked.Granted | Should -BeFalse
            $asked.HeldBy | Should -Be 'run-a'
            (Get-VmfVmClaim -RunPath $b -VmId $up).runId | Should -Be 'run-a' -Because 'the older claim is read as well'
        }
    }

    It 'the run that holds an older claim keeps the machine, and a release lets both names go' {
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-a'; runPath = $script:runA }
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; up = $script:upper } {
            (New-VmfVmClaim -RunPath $a -VmId $up -RunId 'run-a').Granted | Should -BeTrue
            (Remove-VmfVmClaim -RunPath $a -VmId $up -RunId 'run-a').Released | Should -BeTrue
        }
        @(Get-VmfCaseKeys | Where-Object { $_ -like '*.claim' }) | Should -BeNullOrEmpty -Because 'nothing may go on holding the machine'
    }

    It 'a release by another run leaves a live older claim where it is, and does not fail' {
        # Review of VMID-CASE-1: an older claim is not this run's claim. It
        # must never make this run's release report a failure - Stop-VmfRun
        # and Remove-VmfRun count releases, and Skip-VmfVm reports one.
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-a'; runPath = $script:runA }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            (Remove-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Released | Should -BeTrue
        }
        @(Get-VmfCaseKeys | Where-Object { $_ -like '*.claim' }).Count | Should -Be 1 -Because 'run-a still holds the machine'
    }

    It 'a release of its own claim succeeds beside a live older claim of another run' {
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        $new = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { Get-VmfClaimRelPath -VmId $up }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-a'; runPath = $script:runA }
        Set-VmfCaseDoc $script:claims $new @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-b'; runPath = $script:runB }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            (Remove-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Released | Should -BeTrue
        }
        @(Get-VmfCaseKeys | Where-Object { $_ -like '*.claim' }) | Should -Be @("$($script:claims)|$old")
    }

    It 'an older claim of a run that is gone is taken over when another run is granted the machine' {
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-gone'; runPath = 'azblob://acct/vmf-runs/run-gone' }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            (New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Granted | Should -BeTrue
            (Get-VmfVmClaim -RunPath $b -VmId $up).runId | Should -Be 'run-b' -Because 'a run that is gone holds nothing'
        }
        # Third review: not removed but taken - the older name now holds this
        # run's claim, so a run on the old code is refused.
        ($global:VmfCaseStore["$($script:claims)|$old"] | ConvertFrom-Json).runId | Should -Be 'run-b'
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            (Remove-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Released | Should -BeTrue
        }
        @(Get-VmfCaseKeys | Where-Object { $_ -like '*.claim' }) | Should -BeNullOrEmpty
    }

    It 'a grant over a dead claim under each name takes the older name too' {
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        $new = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { Get-VmfClaimRelPath -VmId $up }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-gone'; runPath = 'azblob://acct/vmf-runs/run-gone' }
        Set-VmfCaseDoc $script:claims $new @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-gone-2'; runPath = 'azblob://acct/vmf-runs/run-gone-2' }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            (New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Detail | Should -Match 'no longer exists'
        }
        ($global:VmfCaseStore["$($script:claims)|$old"] | ConvertFrom-Json).runId | Should -Be 'run-b'
    }

    It 'a claim made by the new code holds the older name too, so a run on the old code is refused' {
        # Third review, blob storage only: a run on the new code wrote only
        # the lower-case name, and a run on the old code - which knows only
        # the name in its own letter case - created that one and was granted
        # the same machine. Before VMID-CASE-1 both were one name.
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper; oldName = $old } {
            (New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Granted | Should -BeTrue
            # What the old code does at its lease: an exclusive create of the older name.
            Write-VmfStoreJsonExclusive -RunPath (Get-VmfClaimScopePath -RunPath $b) -RelPath $oldName -Document @{ runId = 'run-a' } |
                Should -BeFalse -Because 'the old code must find the machine held'
            (Remove-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Released | Should -BeTrue
        }
        @(Get-VmfCaseKeys | Where-Object { $_ -like '*.claim' }) | Should -BeNullOrEmpty -Because 'the release removes both names'
    }

    It 'an older claim of a run that is gone is removed on release, and the release succeeds' {
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        $new = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { Get-VmfClaimRelPath -VmId $up }
        Set-VmfCaseDoc $script:claims $new @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-b'; runPath = $script:runB }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-gone'; runPath = 'azblob://acct/vmf-runs/run-gone' }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            (Remove-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Released | Should -BeTrue
        }
        @(Get-VmfCaseKeys | Where-Object { $_ -like '*.claim' }) | Should -BeNullOrEmpty
    }

    It 'a claim taken with -Force takes the older name too, so the older run cannot claim it back' {
        # Second review: deleting the older claim let a run still on the old
        # code write it again at its next lease. This run's claim under that
        # name refuses it, and this run's release removes it.
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-a'; runPath = $script:runA }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            $taken = New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b' -Force -TakenBy 'operator@example.com'
            $taken.Granted | Should -BeTrue
            $taken.Detail | Should -Match "taken from 'run-a'"
            (Get-VmfVmClaim -RunPath $b -VmId $up).runId | Should -Be 'run-b'
        }
        ($global:VmfCaseStore["$($script:claims)|$old"] | ConvertFrom-Json).runId | Should -Be 'run-b'
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            (Remove-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Released | Should -BeTrue
        }
        @(Get-VmfCaseKeys | Where-Object { $_ -like '*.claim' }) | Should -BeNullOrEmpty
    }

    It 'a live older claim is the holder, whatever the new name says' {
        # Second review: a run on the old code holds the older name, and the
        # new name holds a run that is gone. The live run holds the machine.
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        $new = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { Get-VmfClaimRelPath -VmId $up }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-a'; runPath = $script:runA }
        Set-VmfCaseDoc $script:claims $new @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-gone'; runPath = 'azblob://acct/vmf-runs/run-gone' }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            $asked = New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b'
            $asked.Granted | Should -BeFalse
            $asked.HeldBy | Should -Be 'run-a'
        }
        ($global:VmfCaseStore["$($script:claims)|$old"] | ConvertFrom-Json).runId | Should -Be 'run-a' -Because 'a live claim is never removed without -Force'
    }

    It 'an older claim written again by a live run while this run claims is not removed' {
        # The older claim was dead when first read; a run on the old code
        # wrote it again before this run finished. It is checked again at the
        # moment of removal.
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        $global:VmfCaseOldKey = "$($script:claims)|$old"
        $global:VmfCaseLive = (@{ schemaVersion = 1; vmId = $script:upper; runId = 'run-a'; runPath = $script:runA } | ConvertTo-Json)
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-gone'; runPath = 'azblob://acct/vmf-runs/run-gone' }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreJsonExclusive {
            $global:VmfCaseStore[$global:VmfCaseOldKey] = $global:VmfCaseLive
            $k = "$($RunPath.TrimEnd('/'))|$RelPath"
            if ($global:VmfCaseStore.ContainsKey($k)) { return $false }
            $global:VmfCaseStore[$k] = ($Document | ConvertTo-Json -Depth 30)
            $true
        }
        $new = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { Get-VmfClaimRelPath -VmId $up }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            $asked = New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b'
            # Third review: the old code took the machine first, so this run
            # is refused and holds neither name - never both runs at once.
            $asked.Granted | Should -BeFalse
            $asked.HeldBy | Should -Be 'run-a'
        }
        ($global:VmfCaseStore["$($script:claims)|$old"] | ConvertFrom-Json).runId | Should -Be 'run-a'
        $global:VmfCaseStore.ContainsKey("$($script:claims)|$new") | Should -BeFalse -Because 'the new name is given back'
        Remove-Variable -Name VmfCaseOldKey, VmfCaseLive -Scope Global
    }

    It 'a run holding the new name never removes a live older claim of another run' {
        $old = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { (Get-VmfVmKey -VmId $up) + '.claim' }
        $new = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { Get-VmfClaimRelPath -VmId $up }
        Set-VmfCaseDoc $script:claims $old @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-a'; runPath = $script:runA }
        Set-VmfCaseDoc $script:claims $new @{ schemaVersion = 1; vmId = $script:upper; runId = 'run-b'; runPath = $script:runB }
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; up = $script:upper } {
            (New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Granted | Should -BeFalse -Because 'run-a still holds it'
        }
        ($global:VmfCaseStore["$($script:claims)|$old"] | ConvertFrom-Json).runId | Should -Be 'run-a'
    }

}

Describe 'VMID-CASE-1: on a file store that ignores letter case, the older name is the claim itself' {
    # A Windows disk keeps one file for both names. Removing "the older claim"
    # there would remove the claim just written, and leave the machine free
    # for any run. Real files, on purpose.
    It 'a run granted a machine over a dead claim still holds it afterwards' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-idcase-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $runB = Join-Path $root 'run-b'
            InModuleScope VmMigrationFactory -Parameters @{ b = $runB; up = $script:upper } {
                Initialize-VmfRun -RunPath $b -RunId 'run-b' | Out-Null
                $scope = Get-VmfClaimScopePath -RunPath $b
                Write-VmfStoreJson -RunPath $scope -RelPath ((Get-VmfVmKey -VmId $up) + '.claim') -Depth 6 -Document @{
                    schemaVersion = 1; vmId = $up; runId = 'run-gone'; runPath = (Join-Path (Split-Path $b -Parent) 'run-gone') }
                (New-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Granted | Should -BeTrue
                (Get-VmfVmClaim -RunPath $b -VmId $up).runId | Should -Be 'run-b' -Because 'the claim just written must survive'
            }
        }
        finally { if (Test-Path $root) { Remove-Item $root -Recurse -Force } }
    }

    It 'a release that removes a dead claim reports no failure' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-idcase-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $runB = Join-Path $root 'run-b'
            InModuleScope VmMigrationFactory -Parameters @{ b = $runB; up = $script:upper } {
                Initialize-VmfRun -RunPath $b -RunId 'run-b' | Out-Null
                $scope = Get-VmfClaimScopePath -RunPath $b
                Write-VmfStoreJson -RunPath $scope -RelPath ((Get-VmfVmKey -VmId $up) + '.claim') -Depth 6 -Document @{
                    schemaVersion = 1; vmId = $up; runId = 'run-gone'; runPath = (Join-Path (Split-Path $b -Parent) 'run-gone') }
                (Remove-VmfVmClaim -RunPath $b -VmId $up -RunId 'run-b').Released | Should -BeTrue
                Get-VmfVmClaim -RunPath $b -VmId $up | Should -BeNullOrEmpty
            }
        }
        finally { if (Test-Path $root) { Remove-Item $root -Recurse -Force } }
    }
}

Describe 'VMID-CASE-1: one availability set is one lock, whatever the letter case of its ID' {
    # Each machine records its availability set by its own reference, and the
    # worker's lock was named from that text - so two members naming one set in
    # two letter cases took two locks, and both converted at once.
    BeforeEach {
        Use-VmfCaseSensitiveStore
        Set-VmfCaseDoc $script:runA 'run.json' @{ runId = 'run-a' }
    }

    It 'the second member waits for the first' {
        $set = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/VMF-MATRIX-CORE/providers/Microsoft.Compute/availabilitySets/AS-1'
        $plan = [pscustomobject]@{ schemaVersion = 1; entries = @(
            foreach ($i in 1, 2) {
                [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
                    vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/vmf-matrix-core/providers/Microsoft.Compute/virtualMachines/mx-av$i"
                    wave = 'w1'; path = 'A'
                    assessment = [pscustomobject]@{ availabilitySetId = $(if ($i -eq 1) { $set } else { $set.ToLowerInvariant() }) }
                }
            }) }
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; plan = $plan } {
            $first = Get-VmfNextWaveVm -RunPath $a -Plan $plan -Wave 'w1' -WorkerId 'w1'
            $first | Should -Not -BeNullOrEmpty
            Get-VmfNextWaveVm -RunPath $a -Plan $plan -Wave 'w1' -WorkerId 'w2' |
                Should -BeNullOrEmpty -Because 'both machines are in one availability set'
        }
    }
}

Describe 'VMID-CASE-1: a machine named in another letter case finds its record' {
    # Every page sends the ID its record holds. A person or a tool that copies
    # the ID from Azure can send it in another case, and on blob storage that
    # missed the record - and a write under that ID started a second record for
    # the same machine.
    BeforeEach {
        Use-VmfCaseSensitiveStore
        Set-VmfCaseDoc $script:runA 'run.json' @{ runId = 'run-a' }
    }

    It 'Resolve-VmfRecordedVmId gives the ID as the record spells it' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; up = $script:upper; low = $script:lower } {
            New-VmfStateDoc -RunPath $a -RunId 'run-a' -VmId $up | Out-Null
            Resolve-VmfRecordedVmId -RunPath $a -VmId $low | Should -BeExactly $up
            Resolve-VmfRecordedVmId -RunPath $a -VmId $up | Should -BeExactly $up
            $other = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/NEW-01'
            Resolve-VmfRecordedVmId -RunPath $a -VmId $other | Should -BeExactly $other -Because 'no record: the ID as given'
        }
    }

    It 'Skip-VmfVm leaves out the machine the plan holds, and starts no second record' {
        Mock -ModuleName VmMigrationFactory Read-VmfPlanDocument {
            [pscustomobject]@{ schemaVersion = 1; entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:upper; wave = 'w1'; path = 'A' }) }
        }
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; up = $script:upper; low = $script:lower } {
            Skip-VmfVm -RunPath $a -VmId $low -Reason 'test' -SkippedBy 'operator@example.com' -Confirm:$false | Out-Null
            (Read-VmfStateDoc -RunPath $a -VmId $up).state | Should -Be 'SKIPPED' -Because 'the worker reads the record by the plan spelling'
        }
        @(Get-VmfCaseKeys | Where-Object { $_ -like '*|state/*' }).Count | Should -Be 1
    }

    It '<Name> reads the record by the spelling it holds' -ForEach @(
        @{ Name = 'Restore-VmfVm'; State = 'MIGRATED'; Extra = @{ retention = @{ deletedUtc = '2026-09-30T00:00:00Z'; deletedBy = 'retention'; keepDays = 7 } }; Past = 'were deleted' }
        @{ Name = 'Resolve-VmfDecision'; State = 'MIGRATED'; Extra = @{}; Past = 'is not waiting for a person' }
    ) {
        # Each refusal below comes from reading the record: past the "no record"
        # message means the record was found.
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        $doc = @{ schemaVersion = (Get-VmfTestStateVersion); runId = 'run-a'; vmId = $script:upper; state = $State; history = @() } + $Extra
        $key = InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } { Get-VmfVmKey -VmId $up }
        Set-VmfCaseDoc $script:runA "state/$key.json" $doc
        $callArgs = @{ RunPath = $script:runA; VmId = $script:lower }
        if ($Name -eq 'Resolve-VmfDecision') { $callArgs.PlanPath = 'plan.json'; $callArgs.Note = 'test' }
        $thrown = $null
        try { & $Name @callArgs | Out-Null } catch { $thrown = $_.Exception.Message }
        $thrown | Should -Match $Past
    }
}

Describe 'VMID-CASE-1: the engine names a machine as Azure spells it on the machine' {
    BeforeAll {
        $script:cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'machine-names.json') -Raw | ConvertFrom-Json).cases
    }

    It 'every shared case gives the name the dashboard gives' {
        $script:cases.Count | Should -BeGreaterOrEqual 5
        foreach ($c in $script:cases) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
                Get-VmfMachineName -VmId $c.vmId -Names @($c.captured, $c.assessed) | Should -BeExactly $c.want -Because $c.case
            }
        }
    }

    It 'the migration record names each machine from its capture' {
        InModuleScope VmMigrationFactory -Parameters @{ up = $script:upper } {
            $record = ConvertTo-VmfMigrationRecord -Manifest ([pscustomobject]@{ runId = 'run-a' }) `
                -Plan ([pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $up; wave = 'w1'; path = 'A' }) }) `
                -StateDocs @((Complete-VmfTestCapture ([pscustomobject]@{ vmId = $up; state = 'MIGRATED'; history = @()
                    captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{ name = 'mx-u6a'; size = 'Standard_D2s_v4' } } }))) `
                -GeneratedBy 'operator@example.com' -Reason 'downloaded'
            @($record.machines)[0].name | Should -BeExactly 'mx-u6a'
        }
    }
}
