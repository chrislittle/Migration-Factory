#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SEC-CONTEXT-1, 2026-09-09. An install log raised the question: does
# anything land in this container that should not?
#
# The IMAGE was always clean - the Dockerfile copies three paths. The UPLOAD
# was not. There was no .dockerignore, so `az acr build ... .` tarred the whole
# repository and sent it to the registry. Its "default ignore rules" skip .git
# and .gitignore and NOTHING ELSE, so every path .gitignore names went up:
#
#   runs/                     1.4 MB of real migration output - machine names,
#                             resource ids, guest command output
#   .azure/<env>/.env         subscription id, app ids, principal ids
#   CLAUDE-SECURITY-*/        a security scan's findings
#
# .gitignore is the file that records "this must not leave the machine". The
# build honoured the file and ignored its contents.
#
# MEASURED with a real ACR build, before and after:
#   upload  3.713 MiB -> 259.192 KiB
#   context 12.03 MB  -> 1.012 MB, against 0.879 MB of files plus tar overhead
#   the image still builds; all three COPY steps resolve
BeforeAll {
    $script:repoRoot   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:ignorePath = Join-Path $script:repoRoot '.dockerignore'
    # EVERY Dockerfile, found rather than listed.
    #
    # PUBLISH-IN-1 nearly shipped past this test. It read ONE Dockerfile by
    # name, so a SECOND one - copying three paths the allow-list denies - was
    # invisible to it, and every install would have failed at COPY. The test's
    # own comment said "a new COPY cannot quietly go unallowed"; it was a new
    # DOCKERFILE that went unallowed. `az acr build` reads the .dockerignore
    # beside the context, so one list governs both builds and this test has to
    # see both.
    $script:dockerfiles = @(Get-ChildItem (Join-Path $script:repoRoot 'docker') -Filter 'Dockerfile' -Recurse -File)
    $script:dockerfile  = ($script:dockerfiles | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"

    $lines = @(Get-Content $script:ignorePath | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    $script:firstRule = $lines | Select-Object -First 1
    $script:allowed = @($lines | Where-Object { $_.StartsWith('!') } | ForEach-Object { $_.Substring(1) })

    # What the image actually needs, read from the Dockerfile rather than
    # restated - so a new COPY cannot quietly go unallowed.
    $script:copied = @([regex]::Matches($script:dockerfile, '(?m)^\s*COPY\s+(?<src>\S+)\s+\S+') |
        ForEach-Object { $_.Groups['src'].Value })
}

Describe 'SEC-CONTEXT-1: only what the image needs is uploaded' {

    It 'a .dockerignore exists at all' {
        # Its absence is the whole defect. Nothing warns about it.
        Test-Path $script:ignorePath | Should -BeTrue
    }

    It 'and its first rule denies everything' {
        # An allow-list. A deny-list must be updated every time the repository
        # gains a directory, and the failure is silent.
        $script:firstRule | Should -Be '*'
    }

    It 'the Dockerfile copies the paths this test reads' {
        $script:copied.Count | Should -BeGreaterThan 0
    }

    It 'and it reads EVERY Dockerfile, not one by name' {
        # The hole PUBLISH-IN-1 found. Two images share one allow-list; a test
        # that reads one of them proves nothing about the other.
        $script:dockerfiles.Count | Should -BeGreaterOrEqual 2
        @($script:dockerfiles | ForEach-Object { $_.FullName }) |
            Should -Contain (Join-Path $script:repoRoot 'docker' 'publish' 'Dockerfile')
    }

    It 'EVERY path the Dockerfile copies is allowed' {
        # Otherwise the build fails, loudly, at COPY.
        foreach ($path in $script:copied) {
            $script:allowed | Should -Contain $path -Because "the Dockerfile copies $path"
        }
    }

    It 'and NOTHING is allowed that the Dockerfile does not copy' {
        # This is the half that matters. An allow line nobody needs is a path
        # going to the registry for no reason.
        foreach ($path in $script:allowed) {
            $script:copied | Should -Contain $path -Because ".dockerignore allows $path"
        }
    }
}

Describe 'SEC-CONTEXT-1: the paths that must never be uploaded' {

    # Named one by one, because "the allow-list covers it" is an argument and
    # these are the ones that would matter if the argument were ever wrong.
    It 'the run store output is not allowed' {
        $script:allowed | Should -Not -Contain 'runs'
        $script:copied  | Should -Not -Contain 'runs'
    }

    It 'the azd environment is not allowed' {
        $script:allowed | Should -Not -Contain '.azure'
    }

    It 'and no allow line reaches outside src or docker' {
        foreach ($path in $script:allowed) {
            $path | Should -Match '^(src/|docker/)'
        }
    }
}
