#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LITTER-1 - the test suite must not write into the repository.
#
# A folder named `x` appeared at the root of a working tree.
#
# `x/logs/events.jsonl` was test litter: four tests built an
# engine context with `RunPath = 'x'` - a RELATIVE path - so the event writer
# created `./x/logs/` in whatever directory the runner started in, which is the
# repository root. Then it was committed (99da035) along with real work, and sat
# there looking like a deliberate part of the product.
#
# The cost is not the disk space. It is that a stray directory in a repository
# is indistinguishable from something that matters until somebody reads it, and
# the one thing a person cannot do with a file called `x` is guess.
#
# Two guards here, because the cause and the symptom are different problems:
#   1. no test may pass a relative run path (the cause)
#   2. the repository root holds only directories that belong there (anything
#      else that leaks, whatever it gets called)
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
}

Describe 'LITTER-1: nothing writes into the repository' {

    It 'no test passes a relative run path' {
        # A relative RunPath is the whole mechanism. The engine joins it with
        # 'logs' and writes - correctly, to somewhere nobody asked for.
        $hits = foreach ($f in Get-ChildItem (Join-Path $script:repoRoot 'tests') -Filter '*.Tests.ps1' -Recurse) {
            if ($f.Name -eq 'NoRepoLitter.Tests.ps1') { continue }   # this file quotes the pattern it hunts
            # A run path ASSIGNED as a bare quoted word, on one line: no drive,
            # no variable, no Join-Path. `RunPath = $x` and
            # `-RunPath (Join-Path ...)` are the correct forms.
            # `Join-Path $RunPath 'capacity'` READS a run path - the quoted word
            # there is the child - so the match is anchored to RunPath being
            # assigned or passed, never merely mentioned.
            foreach ($line in (Get-Content $f.FullName)) {
                # Comments describe the trap; they are not the trap. Without
                # this the guard flags the note explaining why the fix exists.
                if ($line -match '^\s*#') { continue }
                $m = [regex]::Match($line, "RunPath\s*=\s*'([^']*)'|-RunPath\s+'([^']*)'")
                if (-not $m.Success) { continue }
                $v = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                if ($v -notmatch '^[A-Za-z]:[\\/]' -and $v -notmatch '^[\\/]' -and $v -notmatch '^azblob://') {
                    "$($f.Name): RunPath '$v'"
                }
            }
        }
        $hits -join '; ' | Should -BeNullOrEmpty -Because 'a relative run path writes into the working directory, which is this repository'
    }

    It 'the repository root holds only directories that belong to the product' {
        # Deliberately an ALLOW list. A deny list only catches the litter you
        # have already seen, and this one was called 'x'.
        $allowed = @(
            '.git', '.github', '.claude', '.vscode',
            'docker', 'docs', 'infra', 'lab', 'samples', 'schemas', 'src', 'tests', 'tools',
            # PUBLIC-PIPELINE-1: the public repository's own files, which the
            # public export copies over their private twins.
            'public'
        )
        # Anything git IGNORES is declared local state - `runs/` is the lab
        # store, named in .gitignore with a reason beside it. The litter this
        # catches is the other kind: a directory nobody declared, which is
        # therefore a candidate for being committed by accident, as `x/` was.
        $stray = @(Get-ChildItem $script:repoRoot -Directory -Force |
            Where-Object { $_.Name -notin $allowed } |
            Where-Object {
                git -C $script:repoRoot check-ignore -q $_.Name 2>$null
                $LASTEXITCODE -ne 0
            } |
            ForEach-Object { $_.Name })
        $stray -join ', ' | Should -BeNullOrEmpty -Because 'a directory nobody declared is one that gets committed by accident'
    }

    It 'and the run-log shape that leaked is not tracked anywhere outside a run store' {
        # `logs/events.jsonl` is a RUN artefact. One inside the repository means
        # a run wrote here.
        $tracked = @(git -C $script:repoRoot ls-files '*logs/events.jsonl' 2>$null)
        $tracked -join ', ' | Should -BeNullOrEmpty -Because 'run logs belong in the state store, not in git'
    }
}
