#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-VERSION-READERS-REMOVE-2: no reader for a plan value, an approval, an
# acceptance or quota record name, or a classification that only an earlier
# version wrote.
#
# Nothing is public before 1.0, so no store holds such a record. Each reader
# goes with proof that no flow of this version writes what it read:
#   - the plan value 'park' for onDDataFound and onDriverBelowFloor (renamed to
#     'stop' long before 1.0; no writer or lever gives 'park');
#   - a wave approval with no waveVersion (WAVE-APPROVE-1 writes waveVersion
#     on every approval, and the wave-approval contract v5 requires it);
#   - a wave options acceptance under its name from before ACCEPT-NAME-1, and
#     a quota record under its name from before CLAIM-NAME-1 (every writer
#     uses Get-VmfWaveOptionsAcceptancePath and Get-VmfClaimFileName);
#   - the classification ReadyNow (assessment v11 and later write none, and
#     Assert-VmfSupportedAssessment takes version 16 only (DRIFT-12)).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:codeFiles = @(
        @(Get-ChildItem -Path $script:moduleRoot -Recurse -Include '*.ps1', '*.psm1') +
        @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'facade') -Recurse -Include '*.ps1', '*.psm1') +
        @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.js' | Where-Object { $_.Name -notlike '*.min.js' })
    )
    function Global:Ovr2CodeMatching([string]$Pattern) {
        foreach ($f in $script:codeFiles) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            if ($code -cmatch $Pattern) { $f.FullName.Substring($script:repoRoot.Length + 1) }
        }
    }
    $script:sub = '00000000-0000-0000-0000-000000000000'
}
AfterAll { Remove-Item function:Ovr2CodeMatching -ErrorAction SilentlyContinue }

Describe 'OLD-VERSION-READERS-REMOVE-2: the plan reader renames no value' {
    It 'a plan value an earlier version wrote is not changed on read, and no change is noted' {
        $plan = [pscustomobject]@{ entries = @([pscustomobject]@{ vmId = '/x/vm1'; schemaVersion = (Get-VmfTestPlanEntryVersion)
                    policy = [pscustomobject]@{ onDDataFound = 'park'; onDriverBelowFloor = 'park' } }) }
        $out = InModuleScope VmMigrationFactory -Parameters @{ p = $plan } { param($p) ConvertTo-VmfSupportedPlan -Plan $p }
        $out.entries[0].policy.onDDataFound | Should -Be 'park'
        $out.PSObject.Properties.Name | Should -Not -Contain 'vmfMigrations'
        InModuleScope VmMigrationFactory { Get-Variable -Name VmfPlanValueMigrations -Scope Script -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
    }
    It 'a plan from a later version is still refused by name' {
        $plan = [pscustomobject]@{ entries = @([pscustomobject]@{ vmId = '/x/vm1'; schemaVersion = 999; policy = [pscustomobject]@{} }) }
        { InModuleScope VmMigrationFactory -Parameters @{ p = $plan } { param($p) ConvertTo-VmfSupportedPlan -Plan $p } } | Should -Throw '*newer version*'
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-2: a wave approval is current only by its wave version' {
    It 'an approval with no waveVersion is not current, even when it signs the whole plan as it is' {
        $text = '{"entries":[]}'
        InModuleScope VmMigrationFactory -Parameters @{ t = $text } {
            param($t)
            $hash = Get-VmfDocumentVersion -Text $t
            Test-VmfWaveApprovalCurrent -Approval ([pscustomobject]@{ planHash = $hash }) -Wave 'w1' -PlanText $t | Should -BeFalse
            $wv = Get-VmfWaveVersion -PlanText $t -Wave 'w1'
            Test-VmfWaveApprovalCurrent -Approval ([pscustomobject]@{ planHash = $hash; waveVersion = $wv }) -Wave 'w1' -PlanText $t | Should -BeTrue
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-2: one name for an acceptance and for a quota record' {
    It 'no name of an earlier version is made or read' {
        InModuleScope VmMigrationFactory {
            (Get-Command Get-VmfWaveOptionsAcceptancePath).Parameters.Keys | Should -Not -Contain 'Legacy'
            (Get-Command Get-VmfClaimFileName).Parameters.Keys | Should -Not -Contain 'Legacy'
        }
        @(Ovr2CodeMatching '-Legacy\b|wave-options-\$readable\.json') | Should -BeNullOrEmpty
    }
    It 'an acceptance under the name of an earlier version is not this wave''s' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ovr2-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            New-Item -ItemType Directory -Path (Join-Path $rp 'acceptances') -Force | Out-Null
            '{"wave":"wave_1"}' | Set-Content (Join-Path $rp 'acceptances' 'wave-options-wave-1.json') -Encoding utf8NoBOM
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                param($rp)
                Resolve-VmfWaveOptionsAcceptancePath -Wave 'wave_1' | Should -BeExactly (Get-VmfWaveOptionsAcceptancePath -Wave 'wave_1')
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a quota record under the name of an earlier version is not this cell''s' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ovr2-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            New-Item -ItemType Directory -Path (Join-Path $rp 'capacity') -Force | Out-Null
            $cell = @{ Wave = 'w1'; SubscriptionId = $script:sub; Region = 'centralus'; Zone = ''; Size = 'Standard_D2s_v6' }
            $old = 'w1-00000000-centralus-regional-Standard-D2s-v6.json'
            (@{ schemaVersion = 15; wave = 'w1'; subscriptionId = $script:sub; region = 'centralus'; zone = ''; size = 'Standard_D2s_v6'; status = 'OK' } | ConvertTo-Json) |
                Set-Content (Join-Path $rp 'capacity' $old) -Encoding utf8NoBOM
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; c = $cell } {
                param($rp, $c)
                $r = Resolve-VmfClaimFile -RunPath $rp @c
                $r.Name | Should -BeExactly (Get-VmfClaimFileName @c)
                $r.Read | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-2: no classification ReadyNow' {
    It 'no code reads ReadyNow' {
        @(Ovr2CodeMatching "ReadyNow") | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory { Get-Command ConvertTo-VmfOwnClassification -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
    }
    It 'the assessment contract has no ReadyNow, in a record or in the summary' {
        $s = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'assessment.schema.json')) | ConvertFrom-Json -AsHashtable -Depth 40
        ($s | ConvertTo-Json -Depth 40) | Should -Not -Match 'ReadyNow'
    }
}
