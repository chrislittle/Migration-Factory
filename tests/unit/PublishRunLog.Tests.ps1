#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PUBLISH-RUN-LOG-1: a failed publish run shows what the run itself wrote.
#
# MEASURED in the lab on 2026-11-05: one `azd up` failed with "did not put the
# code package in the store. It ended as Failed", and the next one passed with
# no change. The execution record said Failed and nothing else, the replica was
# gone when somebody looked, and Log Analytics did not have the run. The
# console of the run was the one place the cause was, and nothing kept it.
#
# So the install now reads the console WHILE the run lives, keeps it in a file,
# and puts the end of it in the error. These tests RUN the wait with Azure
# stubbed out, because every rule here is about what the operator is told.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $script:repoRoot 'infra' 'Wait-VmfJobRun.ps1')
    $script:deployCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1') -Language PowerShell
    $script:helperCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'Wait-VmfJobRun.ps1') -Language PowerShell
    $script:pwshPath = (Get-Process -Id $PID).Path
}

Describe 'PUBLISH-RUN-LOG-1: the console read asks Azure for the right thing' {

    It 'follows one execution, by name, as text, with the most lines Azure gives' {
        $a = Get-VmfJobConsoleArguments -ResourceGroup 'rg-x' -JobName 'vmf-publish-x' -Execution 'vmf-publish-x-abc' -Container 'publish' -Follow
        ($a -join ' ') | Should -BeLike 'containerapp job logs show *'
        $a[([array]::IndexOf($a, '--execution')) + 1] | Should -Be 'vmf-publish-x-abc'
        $a[([array]::IndexOf($a, '--container')) + 1] | Should -Be 'publish'
        $a[([array]::IndexOf($a, '-g')) + 1] | Should -Be 'rg-x'
        $a[([array]::IndexOf($a, '-n')) + 1] | Should -Be 'vmf-publish-x'
        $a[([array]::IndexOf($a, '--tail')) + 1] | Should -Be '300' -Because '300 is the most the command accepts (az containerapp job logs show --help)'
        $a[([array]::IndexOf($a, '--format')) + 1] | Should -Be 'text'
        $a | Should -Contain '--follow'
        $a | Should -Contain '--only-show-errors' -Because 'the preview warning is not the run''s output'
        $a | Should -Not -Contain '--query'
    }

    It 'a read after the run does not follow' {
        $a = Get-VmfJobConsoleArguments -ResourceGroup 'rg-x' -JobName 'j' -Execution 'e' -Container 'publish'
        $a | Should -Not -Contain '--follow'
        $a | Should -Contain '--execution'
    }

    It 'the container named is the publish job''s container in the template' {
        $template = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $name = [regex]::Match($template, "(?s)vmf-publish-job-deploy.*?containers: \[\s*\{\s*name: '([^']+)'").Groups[1].Value
        $name | Should -Not -BeNullOrEmpty
        $script:deployCode | Should -Match ("Wait-VmfJobRun\b[^\r\n]*-Container '" + [regex]::Escape($name) + "'")
    }
}

Describe 'PUBLISH-RUN-LOG-1: the file goes in the azd environment''s folder' {

    It 'is in .azure/<environment> when azd runs the install' {
        $root = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $root '.azure' 'lab1') -Force | Out-Null
        $path = Get-VmfJobConsolePath -Execution 'vmf-publish-x-abc' -RepoRoot $root -EnvironmentName 'lab1'
        (Split-Path $path -Parent) | Should -Be (Join-Path $root '.azure' 'lab1')
        (Split-Path $path -Leaf) | Should -BeLike 'vmf-publish-x-abc*.log'
    }

    It 'is in the temporary folder when no azd environment is there' {
        $root = Join-Path $TestDrive 'bare'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        # The parent folder is compared whole: the test drive is itself in the
        # temporary folder.
        $temp = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
        $path = Get-VmfJobConsolePath -Execution 'e1' -RepoRoot $root -EnvironmentName ''
        (Split-Path $path -Parent).TrimEnd('\', '/') | Should -Be $temp
        $path = Get-VmfJobConsolePath -Execution 'e1' -RepoRoot $root -EnvironmentName 'absent'
        (Split-Path $path -Parent).TrimEnd('\', '/') | Should -Be $temp -Because 'a folder azd did not make is not its environment'
    }

    It 'an environment name with a path in it is not followed' {
        $root = Join-Path $TestDrive 'repo2'
        # Both folders exist, so only the name check keeps the path out.
        New-Item -ItemType Directory -Path (Join-Path $root '.azure') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'x') -Force | Out-Null
        $temp = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
        $path = Get-VmfJobConsolePath -Execution 'e1' -RepoRoot $root -EnvironmentName '../x'
        (Split-Path $path -Parent).TrimEnd('\', '/') | Should -Be $temp
    }

    It 'the publisher gives it the repository root and the environment azd set' {
        $script:deployCode | Should -Match 'Get-VmfJobConsolePath\b[^\r\n]*-RepoRoot'
        $script:deployCode | Should -Match 'Get-VmfJobConsolePath\b[^\r\n]*\$env:AZURE_ENV_NAME'
    }
}

Describe 'PUBLISH-RUN-LOG-1: the background read, run as a real process' {
    # The read is a separate process, so a Pester mock of az cannot reach it.
    # pwsh stands in for az: what matters here is that the output lands in the
    # file, and that a read which does not end is ended.

    It 'writes what the process prints into the file' {
        $out = Join-Path $TestDrive 'out1.log'; $err = Join-Path $TestDrive 'err1.log'
        $proc = Start-VmfJobConsoleFollow -AzPath $script:pwshPath -OutPath $out -ErrPath $err `
            -Arguments @('-NoProfile', '-Command', 'Write-Output first-line; Write-Output second-line')
        Stop-VmfJobConsoleFollow -Process $proc -WaitSeconds 60 | Should -BeTrue
        (Get-Content $out) | Should -Be @('first-line', 'second-line')
    }

    It 'ends a read that does not end, and says so' {
        $out = Join-Path $TestDrive 'out2.log'; $err = Join-Path $TestDrive 'err2.log'
        $proc = Start-VmfJobConsoleFollow -AzPath $script:pwshPath -OutPath $out -ErrPath $err `
            -Arguments @('-NoProfile', '-Command', '[System.Threading.Thread]::Sleep(120000)')
        Stop-VmfJobConsoleFollow -Process $proc -WaitSeconds 1 | Should -BeFalse
        $proc.HasExited | Should -BeTrue -Because 'no read is left running after the install'
    }

    It 'ends the whole process tree, not only the first process' {
        # az on Windows is az.cmd starting Python: the read that matters is a
        # CHILD of the process this tool started. A parent pwsh starts a child
        # pwsh that sleeps and writes its id; after the stop, both are gone.
        # The shell's path is quoted: Start-Process joins arguments with spaces.
        $idFile = Join-Path $TestDrive 'child.id'
        $parentScript = Join-Path $TestDrive 'parent.ps1'
        Set-Content -LiteralPath $parentScript -Value @(
            'param($IdFile, $Shell)'
            '$c = Start-Process -FilePath $Shell -ArgumentList @(''-NoProfile'', ''-Command'', ''[System.Threading.Thread]::Sleep(120000)'') -NoNewWindow -PassThru'
            # Written to a side file, then moved: the test never reads a file
            # that exists but is still empty (PUBLISH-LOG-TEST-RACE-1).
            'Set-Content -LiteralPath ($IdFile + ''.tmp'') -Value $c.Id'
            'Move-Item -LiteralPath ($IdFile + ''.tmp'') -Destination $IdFile -Force'
            '[System.Threading.Thread]::Sleep(120000)'
        )
        $out = Join-Path $TestDrive 'out3.log'; $err = Join-Path $TestDrive 'err3.log'
        $proc = Start-VmfJobConsoleFollow -AzPath $script:pwshPath -OutPath $out -ErrPath $err `
            -Arguments @('-NoProfile', '-File', $parentScript, $idFile, ('"' + $script:pwshPath + '"'))
        $childId = 0
        try {
            # Wait for an id that parses, not only for the file: on a busy
            # 2-core CI runner the parent can be slow to start its child.
            $deadline = [DateTime]::UtcNow.AddSeconds(90)
            while ([DateTime]::UtcNow -lt $deadline -and $childId -le 0) {
                $text = $null
                try { $text = [System.IO.File]::ReadAllText($idFile) } catch { $null = $_ }
                $parsed = 0
                if ($text -and [int]::TryParse($text.Trim(), [ref]$parsed)) { $childId = $parsed }
                else { [System.Threading.Thread]::Sleep(250) }
            }
            $childId | Should -BeGreaterThan 0 -Because ('the parent writes its child id; error output: ' + [string](Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue))
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'the child must be running before the stop'
            Stop-VmfJobConsoleFollow -Process $proc -WaitSeconds 1 | Should -BeFalse
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while ([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id $childId -ErrorAction SilentlyContinue)) { [System.Threading.Thread]::Sleep(250) }
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the child of the read must end with it'
        }
        finally {
            if ($childId) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
            if ($proc -and -not $proc.HasExited) { $proc.Kill($true) }
        }
    }

    It 'nothing to stop is not a cut read' {
        Stop-VmfJobConsoleFollow -Process $null | Should -BeTrue
    }
}

Describe 'PUBLISH-RUN-LOG-1: the wait keeps what the run wrote' {

    BeforeAll {
        function global:az {
            $joined = $args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -like '*job execution show*') {
                $global:PrlStatusCalls++
                $i = [math]::Min($global:PrlStatusCalls, $global:PrlStatuses.Count) - 1
                return ('{"properties":{"status":"' + $global:PrlStatuses[$i] + '"}}')
            }
            if ($joined -like '*job logs show*') {
                $global:PrlLateReads++
                $global:LASTEXITCODE = $global:PrlLateExit
                return $global:PrlLateText
            }
            $global:LASTEXITCODE = 1
            "unexpected az call: $joined"
        }
    }
    AfterAll {
        # TEST-STUB-1: the function:global: form removes nothing.
        Remove-Item 'function:\az' -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name PrlStatuses, PrlStatusCalls, PrlLateReads, PrlLateExit, PrlLateText -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:PrlStatuses = @('Running', 'Failed')
        $global:PrlStatusCalls = 0
        $global:PrlLateReads = 0
        $global:PrlLateExit = 0
        $global:PrlLateText = $null
        $script:attempts = [System.Collections.Generic.List[object]]::new()
        # One entry per follow the wait starts. The last one repeats.
        $script:followPlan = @(@{ Out = "Publishing facade.zip`nConnect-AzAccount: ManagedIdentityCredential authentication failed"; Err = ''; ExitCode = 0 })
        $script:stopEndedItself = $true
        $script:consolePath = Join-Path $TestDrive ("run-{0}.log" -f [guid]::NewGuid())

        Mock Start-VmfJobConsoleFollow {
            $n = [math]::Min($script:attempts.Count, $script:followPlan.Count - 1)
            $plan = $script:followPlan[$n]
            [System.IO.File]::WriteAllText($OutPath, [string]$plan.Out)
            [System.IO.File]::WriteAllText($ErrPath, [string]$plan.Err)
            $fake = [pscustomobject]@{ HasExited = (-not $plan.Running); ExitCode = $plan.ExitCode; Arguments = $Arguments }
            $script:attempts.Add($fake)
            $fake
        }
        Mock Stop-VmfJobConsoleFollow { $script:stopEndedItself }
        Mock Start-Sleep { }
        # Start-Sleep is mocked, so a run that never ends would spin for the
        # whole default wait. A short limit makes a broken rule fail fast.
        $PSDefaultParameterValues['Wait-VmfJobRun:TimeoutMinutes'] = 0.05
    }

    It 'a failed run comes back with what it wrote, in the file' {
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Status | Should -Be 'Failed'
        $r.Read | Should -Be 'lines'
        $r.Lines | Should -Contain 'Connect-AzAccount: ManagedIdentityCredential authentication failed'
        (Get-Content $script:consolePath) | Should -Contain 'Publishing facade.zip'
        $r.ConsolePath | Should -Be $script:consolePath
    }

    It 'the read is started for the execution being waited on' {
        Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath | Out-Null
        $a = $script:attempts[0].Arguments
        $a[([array]::IndexOf($a, '--execution')) + 1] | Should -Be 'job-1'
        $a | Should -Contain '--follow'
    }

    It 'leaves no part files beside the console file' {
        $script:followPlan = @(@{ Out = ''; Err = 'No replicas found for execution'; ExitCode = 1 },
                               @{ Out = 'one'; Err = ''; ExitCode = 0 })
        $global:PrlStatuses = @('Running', 'Running', 'Running', 'Failed')
        Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath | Out-Null
        # -like, not -Filter: a Windows filter 'x.log.*' also matches 'x.log'.
        $leaf = Split-Path $script:consolePath -Leaf
        @(Get-ChildItem (Split-Path $script:consolePath) -File | Where-Object { $_.Name -like "$leaf.*" }).Count | Should -Be 0
        Test-Path -LiteralPath $script:consolePath | Should -BeTrue
    }

    It 'leaves no read files when the wait is stopped by a throw (or Ctrl+C)' {
        $script:followPlan = @(@{ Out = 'one'; Err = 'two'; ExitCode = 0 })
        Mock Stop-VmfJobConsoleFollow { throw 'stopped by the operator' }
        { Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath } |
            Should -Throw '*stopped by the operator*'
        $leaf = Split-Path $script:consolePath -Leaf
        @(Get-ChildItem (Split-Path $script:consolePath) -File | Where-Object { $_.Name -like "$leaf.*" }).Count | Should -Be 0
    }

    It 'starts the read again while the run lives, when Azure had no replica yet' {
        $script:followPlan = @(@{ Out = ''; Err = 'ERROR: No replicas found for execution'; ExitCode = 1 },
                               @{ Out = "Publishing facade.zip`nboom"; Err = ''; ExitCode = 0 })
        $global:PrlStatuses = @('Running', 'Running', 'Failed')
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $script:attempts.Count | Should -BeGreaterThan 1
        $r.Read | Should -Be 'lines'
        $r.Lines | Should -Contain 'boom'
    }

    It 'keeps the longest read when a later read gives less' {
        $script:followPlan = @(@{ Out = "a`nb`nc`nthe cause"; Err = ''; ExitCode = 0 },
                               @{ Out = ''; Err = 'ERROR: No replicas found for execution'; ExitCode = 1 })
        $global:PrlStatuses = @('Running', 'Running', 'Running', 'Failed')
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Lines | Should -Contain 'the cause' -Because 'a replica that is gone must not erase what was read while it lived'
    }

    It 'does not start the read again while one is running' {
        $script:followPlan = @(@{ Out = 'x'; Err = ''; ExitCode = 0; Running = $true })
        $global:PrlStatuses = @('Running', 'Running', 'Running', 'Running', 'Failed')
        Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath | Out-Null
        $script:attempts.Count | Should -Be 1
    }

    It 'stops the read when the wait ends' {
        Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath | Out-Null
        Should -Invoke Stop-VmfJobConsoleFollow -Times 1 -Exactly
    }

    It 'a read that had to be ended says the output can be cut' {
        $script:followPlan = @(@{ Out = 'partial'; Err = ''; ExitCode = 0; Running = $true })
        $script:stopEndedItself = $false
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Cut | Should -BeTrue
        $script:stopEndedItself = $true
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Cut | Should -BeFalse
    }

    It 'a read that connected and got nothing means the run wrote nothing' {
        $script:followPlan = @(@{ Out = ''; Err = ''; ExitCode = 0 })
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Read | Should -Be 'empty'
        @($r.Lines).Count | Should -Be 0
    }

    It 'a read that was ended with nothing is not proof the run wrote nothing' {
        $script:followPlan = @(@{ Out = ''; Err = ''; ExitCode = 0; Running = $true })
        $script:stopEndedItself = $false
        $global:PrlLateExit = 1
        $global:PrlLateText = 'ERROR: No replicas found for execution'
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Read | Should -Be 'unread'
    }

    It 'a read after the run that connects and gets nothing means the run wrote nothing' {
        $script:followPlan = @(@{ Out = ''; Err = 'ERROR: No replicas found for execution'; ExitCode = 1 })
        $global:PrlLateExit = 0
        $global:PrlLateText = $null
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Read | Should -Be 'empty'
    }

    It 'a read that ended with an error code and no words did not connect' {
        $script:followPlan = @(@{ Out = ''; Err = ''; ExitCode = 1 })
        $global:PrlLateExit = 1
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Read | Should -Be 'unread'
    }

    It 'a read that ended with an error message did not connect' {
        $script:followPlan = @(@{ Out = ''; Err = 'ERROR: Got bad status from the logstream API: 403'; ExitCode = 0 })
        $global:PrlLateExit = 1
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Read | Should -Be 'unread'
        $r.ReadError | Should -Match '403'
    }

    It 'a read Azure refused every time is unread, with Azure''s words' {
        $script:followPlan = @(@{ Out = ''; Err = "WARNING: x`nERROR: No replicas found for execution"; ExitCode = 1 })
        $global:PrlLateExit = 1
        $global:PrlLateText = $null
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $r.Read | Should -Be 'unread'
        $r.ReadError | Should -Match 'No replicas found'
    }

    It 'reads once more after the run when the follow got nothing, and keeps that' {
        $script:followPlan = @(@{ Out = ''; Err = 'ERROR: No replicas found for execution'; ExitCode = 1 })
        $global:PrlLateText = @('Publishing facade.zip', 'the late cause')
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
        $global:PrlLateReads | Should -Be 1
        $r.Read | Should -Be 'lines'
        $r.Lines | Should -Contain 'the late cause'
        (Get-Content $script:consolePath) | Should -Contain 'the late cause'
    }

    It 'does not read again when the follow already has the output' {
        Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath | Out-Null
        $global:PrlLateReads | Should -Be 0
    }

    It 'Stopped ends the wait, as Failed, Degraded and Succeeded do' {
        foreach ($end in 'Stopped', 'Degraded', 'Succeeded') {
            $global:PrlStatuses = @('Running', $end, 'Running')
            $global:PrlStatusCalls = 0
            $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath
            $r.Status | Should -Be $end
            $global:PrlStatusCalls | Should -Be 2
        }
    }

    It 'a run that does not end in time comes back with no status' {
        $global:PrlStatuses = @('Running')
        $r = Wait-VmfJobRun -ResourceGroup 'rg' -JobName 'job' -Execution 'job-1' -Container 'publish' -ConsolePath $script:consolePath -TimeoutMinutes 0.002
        $global:PrlStatusCalls | Should -BeGreaterThan 0 -Because 'the run must have been asked, and said Running'
        $r.Status | Should -Be '' -Because 'Running is not how a run ended'
    }
}

Describe 'PUBLISH-RUN-LOG-1: the message says what is known' {

    BeforeAll {
        $script:base = @{ What = 'The publish job'; JobName = 'vmf-publish-x'; ResourceGroup = 'rg-x'; Execution = 'vmf-publish-x-abc'; ConsolePath = 'C:\work\.azure\lab1\vmf-publish-x-abc.console.log' }
    }

    It 'a failed run: its status, the end of what it wrote, and the file' {
        $lines = @(1..50 | ForEach-Object { "line $_" })
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'lines' -Lines $lines
        $m | Should -Match 'vmf-publish-x ended as Failed'
        $m | Should -Match 'line 50'
        $m | Should -Match 'line 11'
        $m | Should -Not -Match 'line 10\b' -Because 'only the end goes in the message; the file has all of it'
        $m | Should -Match ([regex]::Escape($script:base.ConsolePath))
    }

    It 'a run that wrote nothing: says so, and where that puts the cause' {
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'empty'
        $m | Should -Match '(?i)connected and got no lines'
        $m | Should -Not -Match '(?i)wrote nothing' -Because 'a run that started also gives nothing once its replica is gone'
        $m | Should -Match '(?i)most likely stopped before its script started'
        $m | Should -Match '(?i)image pull'
        $m | Should -Match '(?i)identity'
    }

    It 'a console that could not be read: says that, with Azure''s words, and never claims the run wrote nothing' {
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'unread' -ReadError 'ERROR: No replicas found for execution'
        $m | Should -Match '(?i)could not read'
        $m | Should -Match 'No replicas found for execution'
        $m | Should -Not -Match '(?i)wrote nothing'
    }

    It 'no replica: says the run most likely stopped before its script started' {
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'unread' -ReadError 'ERROR: No replicas found for execution'
        $m | Should -Match '(?i)no replica'
        $m | Should -Match '(?i)before its script started'
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'unread' -ReadError 'ERROR: Got bad status from the logstream API: 403'
        $m | Should -Not -Match '(?i)before its script started' -Because 'a refused read says nothing about the run'
    }

    It 'never gives the cause as a fact, in any branch' {
        # Review finding, 2026-11-05: nothing measured proves where an empty or
        # unread run stopped, so every sentence that names the cause says
        # "most likely".
        foreach ($case in @(
                @{ Read = 'empty' },
                @{ Read = 'unread'; ReadError = 'ERROR: No replicas found for execution' },
                @{ Read = 'lines'; Lines = @('a') })) {
            $m = Format-VmfJobRunFailure @script:base -Status 'Failed' @case
            $m | Should -Not -Match '(?i)(?<!most likely )stopped before its script started' -Because "the $($case.Read) message"
            $m | Should -Not -Match '(?i)So it stopped' -Because "the $($case.Read) message"
        }
    }

    It 'a cut read says the output can be incomplete' {
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'lines' -Lines @('a') -Cut
        $m | Should -Match '(?i)incomplete'
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'lines' -Lines @('a')
        $m | Should -Not -Match '(?i)incomplete'
    }

    It 'a run that did not end says that' {
        $m = Format-VmfJobRunFailure @script:base -Status '' -Read 'lines' -Lines @('a') -TimeoutMinutes 18
        $m | Should -Match '(?i)had not ended after 18 minutes'
    }

    It 'names Azure''s record of the run, and not Log Analytics' {
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'empty'
        $m | Should -Match 'az containerapp job execution show -g rg-x -n vmf-publish-x --job-execution-name vmf-publish-x-abc'
        $m | Should -Not -Match '(?i)Log Analytics'
    }

    It 'no longer blames the upload it never reached' {
        $m = Format-VmfJobRunFailure @script:base -Status 'Failed' -Read 'empty'
        $m | Should -Not -Match '(?i)about the upload'
    }
}

Describe 'PUBLISH-RUN-LOG-1: the publisher uses it' {

    It 'reads the helper, waits through it, and throws its message' {
        $script:deployCode | Should -Match "Wait-VmfJobRun\.ps1"
        $script:deployCode | Should -Match 'Wait-VmfJobRun\b'
        $script:deployCode | Should -Match "Status -ne 'Succeeded'"
        $script:deployCode | Should -Match 'throw \(Format-VmfJobRunFailure\b'
    }

    It 'a run that succeeded leaves no console file behind' {
        $m = [regex]::Match($script:deployCode, "(?s)if \(\`$run\.Status -ne 'Succeeded'\) \{.*?\n\}\s*\n([^\n]+)")
        $m.Groups[1].Value | Should -Match 'Remove-Item -LiteralPath \$run\.ConsolePath'
    }

    It 'no longer sends the operator to Log Analytics' {
        $script:deployCode | Should -Not -Match '(?i)Log Analytics'
    }

    It 'the helper waits longer than the job can run' {
        $template = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $timeout = [int]([regex]::Match($template, '(?s)vmf-publish-job-deploy.*?replicaTimeout: (\d+)').Groups[1].Value)
        $m = [regex]::Match($script:deployCode, 'Wait-VmfJobRun\b[^\r\n]*-TimeoutMinutes (\d+)')
        $m.Success | Should -BeTrue
        ([int]$m.Groups[1].Value * 60) | Should -BeGreaterThan $timeout
    }

    It 'the helper ends every read it starts' {
        $script:helperCode | Should -Match '(?s)finally\s*\{[^}]*Stop-VmfJobConsoleFollow'
        $script:helperCode | Should -Match '\.Kill\(\$true\)' -Because 'az on Windows is a cmd file over python, so the whole tree must end'
    }
}
