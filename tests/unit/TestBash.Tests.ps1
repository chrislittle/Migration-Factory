#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEST-BASH-WSL-1 (2026-11-15): the tests for the helper every shell
# test runs bash through (tests/unit/_TestBash.ps1). On a Windows PC a start
# of Git's bash takes up to 2.4 s, so the helper takes WSL bash there - and a
# wrong path or a variable that does not cross into WSL would make every shell
# test test nothing, or fail for a reason that is not the script's.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    $script:testBash = Get-VmfTestBash
}

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    $script:testBash = Get-VmfTestBash
}

Describe 'TEST-BASH-WSL-1: a Windows path in the form that bash reads' {

    It 'WSL reads a drive path under its mount root, with the drive letter in lower case' {
        ConvertTo-VmfTestBashPath -Path 'C:\dev-work\wt\tests' -Kind wsl -MountRoot '/mnt/' | Should -BeExactly '/mnt/c/dev-work/wt/tests'
        ConvertTo-VmfTestBashPath -Path 'D:/x y/z.sh' -Kind wsl -MountRoot '/mnt/' | Should -BeExactly '/mnt/d/x y/z.sh'
        ConvertTo-VmfTestBashPath -Path 'C:\' -Kind wsl -MountRoot '/mnt/' | Should -BeExactly '/mnt/c/'
        ConvertTo-VmfTestBashPath -Path 'C:' -Kind wsl -MountRoot '/mnt/' | Should -BeExactly '/mnt/c/'
    }

    It 'WSL uses the mount root the probe found, not a fixed one' {
        ConvertTo-VmfTestBashPath -Path 'C:\a\b' -Kind wsl -MountRoot '/' | Should -BeExactly '/c/a/b'
        ConvertTo-VmfTestBashPath -Path 'C:\a\b' -Kind wsl -MountRoot '/win' | Should -BeExactly '/win/c/a/b'
    }

    It 'Git''s bash reads /c/x/y, as cygpath -u gives it' {
        ConvertTo-VmfTestBashPath -Path 'C:\Users\x\AppData\Local\Temp\vmf-1\bin' -Kind git | Should -BeExactly '/c/Users/x/AppData/Local/Temp/vmf-1/bin'
    }

    It 'a native bash gets the path unchanged' {
        ConvertTo-VmfTestBashPath -Path '/tmp/vmf-1/bin' -Kind native | Should -BeExactly '/tmp/vmf-1/bin'
    }

    It 'a path that is already a bash path, or relative, keeps its words and gets forward slashes' {
        ConvertTo-VmfTestBashPath -Path '/mnt/c/x' -Kind wsl -MountRoot '/mnt/' | Should -BeExactly '/mnt/c/x'
        ConvertTo-VmfTestBashPath -Path 'linux\neutral-mark.sh' -Kind git | Should -BeExactly 'linux/neutral-mark.sh'
    }

    It 'a UNC path is refused: no bash form reads it the same way' {
        { ConvertTo-VmfTestBashPath -Path '\\server\share\x' -Kind wsl -MountRoot '/mnt/' } | Should -Throw '*UNC*'
    }
}

Describe 'TEST-BASH-WSL-1: the probe of WSL' {

    It 'reads the mount root from a probe of a user that is not root' {
        ConvertFrom-VmfWslProbe -Text "5.3.9(1)-release|1000|/mnt/c/`n" | Should -BeExactly '/mnt/'
        ConvertFrom-VmfWslProbe -Text "5.1.16(1)-release|1000|/c/" | Should -BeExactly '/'
    }

    It 'refuses root: the guest scripts would change the distribution' {
        ConvertFrom-VmfWslProbe -Text '5.3.9(1)-release|0|/mnt/c/' | Should -BeNullOrEmpty
    }

    It 'refuses an answer that is not the probe line (no distribution, no bash, no wslpath)' {
        ConvertFrom-VmfWslProbe -Text '' | Should -BeNullOrEmpty
        ConvertFrom-VmfWslProbe -Text $null | Should -BeNullOrEmpty
        ConvertFrom-VmfWslProbe -Text 'Windows Subsystem for Linux has no installed distributions.' | Should -BeNullOrEmpty
        ConvertFrom-VmfWslProbe -Text '|1000|/mnt/c/' | Should -BeNullOrEmpty
        ConvertFrom-VmfWslProbe -Text '5.3.9(1)-release|1000|' | Should -BeNullOrEmpty
    }
}

Describe 'TEST-BASH-WSL-1: which bash' {

    BeforeAll {
        $script:sel = @{ GitBash = 'C:\Program Files\Git\bin\bash.exe'; WslExe = 'C:\Windows\System32\wsl.exe'; WslMountRoot = '/mnt/' }
    }

    It 'Linux uses its own bash, as before, whatever else is set' {
        $b = Select-VmfTestBash -OnWindows $false -NativeBash '/usr/bin/bash' -Want 'wsl' -InCi $true
        $b.Kind | Should -Be 'native'
        $b.Exe | Should -Be '/usr/bin/bash'
        @($b.Prefix).Count | Should -Be 0
        Select-VmfTestBash -OnWindows $false -NativeBash '' | Should -BeNullOrEmpty
    }

    It 'Windows with WSL bash, on a PC: WSL, started as wsl.exe -e bash' {
        $b = Select-VmfTestBash -OnWindows $true -InCi $false @script:sel
        $b.Kind | Should -Be 'wsl'
        $b.Exe | Should -Be 'C:\Windows\System32\wsl.exe'
        @($b.Prefix) | Should -Be @('-e', 'bash')
        $b.MountRoot | Should -Be '/mnt/'
    }

    It 'Windows with no usable WSL: Git''s bash, as before' {
        $b = Select-VmfTestBash -OnWindows $true -InCi $false -GitBash $script:sel.GitBash -WslExe $script:sel.WslExe -WslMountRoot ''
        $b.Kind | Should -Be 'git'
        $b.Exe | Should -Be $script:sel.GitBash
        @($b.Prefix).Count | Should -Be 0
    }

    It 'GitHub Actions on Windows: Git''s bash, as before, even with WSL there' {
        (Select-VmfTestBash -OnWindows $true -InCi $true @script:sel).Kind | Should -Be 'git'
    }

    It 'VMF_TEST_BASH forces one, and a forced one that is absent is no bash (the test skips)' {
        (Select-VmfTestBash -OnWindows $true -InCi $false -Want 'git' @script:sel).Kind | Should -Be 'git'
        (Select-VmfTestBash -OnWindows $true -InCi $true -Want 'WSL' @script:sel).Kind | Should -Be 'wsl'
        Select-VmfTestBash -OnWindows $true -InCi $false -Want 'wsl' -GitBash $script:sel.GitBash | Should -BeNullOrEmpty
    }

    It 'no bash at all is $null' {
        Select-VmfTestBash -OnWindows $true -InCi $false | Should -BeNullOrEmpty
    }

    It 'Get-VmfTestBash asks the probe once a session, and asks again when VMF_TEST_BASH changes' {
        $saved = $global:VmfTestBashChoice
        $savedWant = $env:VMF_TEST_BASH
        try {
            $global:VmfTestBashChoice = @{ Key = "|$("$env:GITHUB_ACTIONS" -eq 'true')"; Value = 'cached' }
            $env:VMF_TEST_BASH = ''
            Get-VmfTestBash | Should -Be 'cached'
            $env:VMF_TEST_BASH = 'none-such'
            Get-VmfTestBash | Should -Not -Be 'cached'
        }
        finally { $global:VmfTestBashChoice = $saved; $env:VMF_TEST_BASH = $savedWant }
    }
}

Describe 'TEST-BASH-WSL-1: a script run through the helper' -Skip:(-not $script:testBash) {

    It 'gets the variables the test sets, and the test''s own variables are put back after it' {
        $env:VMF_TBW_KEEP = 'before'
        try {
            $out = Invoke-VmfTestBash -ArgumentList @('-c', 'printf "%s|%s|%s" "$VMF_TBW_ONE" "$VMF_TBW_TWO" "$VMF_TBW_KEEP"') -Environment @{ VMF_TBW_ONE = 'a b'; VMF_TBW_TWO = "x'y"; VMF_TBW_KEEP = 'during' }
            ($out -join "`n") | Should -BeExactly "a b|x'y|during"
            $env:VMF_TBW_KEEP | Should -Be 'before'
            $env:VMF_TBW_ONE | Should -BeNullOrEmpty
        }
        finally { Remove-Item env:VMF_TBW_KEEP -ErrorAction SilentlyContinue }
    }

    It 'WSLENV is as it was after the call' {
        $saved = $env:WSLENV
        $null = Invoke-VmfTestBash -ArgumentList @('-c', 'true') -Environment @{ VMF_TBW_ONE = '1' }
        $env:WSLENV | Should -Be $saved
    }

    It 'gives back the script''s exit code, and its stderr apart from stdout' {
        $out = Invoke-VmfTestBash -ArgumentList @('-c', 'echo out; echo err >&2; exit 7') 2>$null
        $LASTEXITCODE | Should -Be 7
        @($out) | Should -Be @('out')
    }

    It 'runs a script at a converted path, with an argument that holds a space' {
        $dir = Join-Path $TestDrive 'a b'
        $null = New-Item -ItemType Directory -Path $dir
        $file = Join-Path $dir 's.sh'
        [System.IO.File]::WriteAllText($file, "#!/bin/bash`nprintf '%s' `"`$1`"`n")
        $out = Invoke-VmfTestBash -ArgumentList @((ConvertTo-VmfTestBashPath -Path $file), 'one two')
        ($out -join '') | Should -BeExactly 'one two'
        $LASTEXITCODE | Should -Be 0
    }

    It 'a file the test writes is read back by bash at the converted path, and bash writes where the test reads' {
        $in = Join-Path $TestDrive 'in.txt'
        [System.IO.File]::WriteAllText($in, "line`n")
        $outFile = Join-Path $TestDrive 'out.txt'
        $null = Invoke-VmfTestBash -ArgumentList @('-c', 'cat "$IN" > "$OUT"') -Environment @{ IN = (ConvertTo-VmfTestBashPath -Path $in); OUT = (ConvertTo-VmfTestBashPath -Path $outFile) }
        [System.IO.File]::ReadAllText($outFile) | Should -BeExactly "line`n"
    }
}
