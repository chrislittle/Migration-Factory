# QUOTA-CHECK-WORDS-PLAN-1: Check the quota is on the card Request a quota increase at the top of the wave
# editor, for the whole plan (QUOTA-CHECK-SPINNER-1). No instruction may send the operator to a wave for it.
BeforeAll {
    $script:dataDir = Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'data'
    $script:words = foreach ($name in 'start-gates.json', 'stop-reasons.json', 'operator-guide.json') {
        [System.IO.File]::ReadAllText((Join-Path $script:dataDir $name)) | ConvertFrom-Json -Depth 50 |
            ConvertTo-Json -Depth 50 -Compress | ForEach-Object { [regex]::Matches($_, '"([^"\\]|\\.)*"') } |
            ForEach-Object { [pscustomobject]@{ File = $name; Text = $_.Value } }
    }
}
Describe 'QUOTA-CHECK-WORDS-PLAN-1: no instruction puts Check the quota on a wave' {
    It 'reads the strings of the three data files' { @($script:words).Count | Should -BeGreaterThan 50 }
    It 'no string says Check the quota on wave, or Check the quota and Reserve capacity for the wave' {
        $bad = @($script:words | Where-Object { $_.Text -match 'Check the quota (on|for) (the )?wave' -or $_.Text -match 'Check the quota and Reserve capacity (on|for) (the )?wave' -or $_.Text -match 'Check the quota shows the quota of each wave' })
        $bad | ForEach-Object { "$($_.File): $($_.Text)" } | Should -BeNullOrEmpty
    }
}