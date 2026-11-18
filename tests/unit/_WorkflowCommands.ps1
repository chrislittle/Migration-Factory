# RUNNER-TOOLS-1. Reads the workflow files the way a runner does: which job a
# step belongs to, which runner that job asks for, which shell the step uses,
# and which external commands the step's script actually calls.
#
# Written because a step that calls a command the runner does not have fails
# AFTER doing its work. MEASURED 2026-09-19, run 35438866553: upstream-drift
# found nine changed Microsoft pages and reported none of them - the step that
# writes the report called `gh`, and the repository's own runner has no GitHub
# CLI. The findings existed only in the log of a run whose error named a
# missing tool.
#
# There is no YAML parser in this repository and adding one would put a module
# on two CI runners to read six files. This reads the shape the files are
# written in, and every caller asserts it found work to do - an extractor that
# silently returns nothing is the failure mode to guard against.

# A command every POSIX shell or its core utilities provide. Nothing here has
# to be installed, so nothing here has to be declared by the runner build.
$script:VmfShellBuiltins = @(
    'awk', 'basename', 'break', 'cat', 'cd', 'chmod', 'chown', 'command', 'continue',
    'cp', 'cut', 'date', 'dd', 'df', 'dirname', 'do', 'done', 'du', 'echo', 'elif',
    'else', 'env', 'esac', 'eval', 'exec', 'exit', 'export', 'expr', 'false', 'fi',
    'find', 'for', 'grep', 'gzip', 'head', 'hostname', 'id', 'if', 'in', 'ln', 'local',
    'ls', 'mkdir', 'mv', 'printf', 'pwd', 'read', 'return', 'rm', 'rmdir', 'sed',
    'seq', 'set', 'shift', 'sleep', 'sort', 'source', 'tail', 'tar', 'tee', 'test',
    'then', 'touch', 'tr', 'true', 'uname', 'uniq', 'until', 'wc', 'which', 'while',
    'xargs'
)

# PowerShell's own lowercase aliases. These are the shell, not a tool on PATH.
$script:VmfPwshAliases = @(
    'cat', 'cd', 'copy', 'cp', 'del', 'dir', 'echo', 'foreach', 'group', 'gc', 'gci',
    'gcm', 'gi', 'gm', 'gp', 'irm', 'iwr', 'ls', 'measure', 'mkdir', 'move', 'mv',
    'ni', 'ogv', 'ps', 'pwd', 'rm', 'rmdir', 'select', 'sleep', 'sort', 'tee', 'type',
    'where', 'write'
)

function Get-VmfShellVocabulary {
    # One list, so a test does not write its own copy of it.
    @($script:VmfShellBuiltins + $script:VmfPwshAliases) | Sort-Object -Unique
}

function Get-VmfWorkflowSteps {
    <#
      .SYNOPSIS
      Every `run:` step in a workflow file, with the job's runner and the shell.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $lines = (Get-Content -LiteralPath $Path -Raw) -split "`r?`n"
    $steps = [System.Collections.Generic.List[object]]::new()
    $jobId = ''
    $runsOn = ''
    $stepName = ''
    $stepShell = ''
    $stepIf = ''
    $i = 0

    while ($i -lt $lines.Count) {
        $line = $lines[$i]

        if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') { $jobId = $matches[1]; $runsOn = '' }
        elseif ($line -match '^    runs-on:\s*(.+?)\s*$') { $runsOn = $matches[1] }
        elseif ($line -match '^      - ') { $stepName = ''; $stepShell = ''; $stepIf = '' }

        # A step's name sits either on the dash line or under it.
        if ($line -match '^\s{6,8}(?:- )?name:\s*(.+?)\s*$') { $stepName = $matches[1] }
        if ($line -match '^\s{6,8}(?:- )?shell:\s*(\S+)\s*$') { $stepShell = $matches[1] }
        # CI-RUNNER-SWITCH-1: a step's condition, so a step that runs only on a
        # GitHub-hosted runner is not held to what the self-hosted runner provides.
        if ($line -match '^\s{6,8}(?:- )?if:\s*(.+?)\s*$') { $stepIf = $matches[1] }

        if ($line -match '^(\s+)run: \|') {
            $indent = $matches[1].Length + 2
            $j = $i + 1
            $buf = [System.Collections.Generic.List[string]]::new()
            while ($j -lt $lines.Count) {
                $ln = $lines[$j]
                $isBlank = $ln.Trim() -eq ''
                $isInside = ($ln.Length -ge $indent) -and ($ln.Substring(0, $indent).Trim() -eq '')
                if (-not ($isBlank -or $isInside)) { break }
                $buf.Add($(if ($ln.Length -ge $indent) { $ln.Substring($indent) } else { '' }))
                $j++
            }
            $steps.Add([pscustomobject]@{
                Job      = $jobId
                RunsOn   = $runsOn
                Name     = $stepName
                # No `shell:` key means bash on Linux, PowerShell on Windows.
                Shell    = $(if ($stepShell) { $stepShell } else { 'default' })
                If       = $stepIf
                Line     = $i + 1
                Script   = ($buf -join "`n")
            })
            $i = $j
            continue
        }
        $i++
    }
    $steps
}

function Remove-VmfShellText {
    <#
      .SYNOPSIS
      Blank out one shell line's quoted text and trailing comment, and hand
      back each command substitution separately so it can be read as code.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Substitutions
    )

    $out = [System.Text.StringBuilder]::new()
    $i = 0
    $n = $Line.Length
    $quote = ''
    while ($i -lt $n) {
        $c = $Line[$i]

        # A command substitution is code wherever it appears, including inside
        # double quotes. Take its body out and keep reading around it.
        if ($c -eq '$' -and ($i + 1) -lt $n -and $Line[$i + 1] -eq '(' -and $quote -ne "'") {
            $depth = 1
            $j = $i + 2
            $start = $j
            while ($j -lt $n -and $depth -gt 0) {
                if ($Line[$j] -eq '(') { $depth++ }
                elseif ($Line[$j] -eq ')') { $depth-- }
                $j++
            }
            $Substitutions.Add($Line.Substring($start, [Math]::Max(0, $j - $start - 1)))
            $null = $out.Append(' ')
            $i = $j
            continue
        }

        if ($quote) {
            if ($c -eq $quote) { $quote = '' }
            $null = $out.Append(' ')
            $i++
            continue
        }

        if ($c -eq '"' -or $c -eq "'") { $quote = $c; $null = $out.Append(' '); $i++; continue }

        # Outside quotes a hash starts a comment for the rest of the line.
        if ($c -eq '#' -and ($i -eq 0 -or $Line[$i - 1] -match '\s')) { break }

        $null = $out.Append($c)
        $i++
    }
    $out.ToString()
}

function Get-VmfStepCommands {
    <#
      .SYNOPSIS
      The external commands a step's script calls, lower-cased and de-duplicated.
      .DESCRIPTION
      A pwsh step goes to the PowerShell parser, so what comes back is what
      PowerShell would really invoke - not a word that looked like a command.
      A shell step is read line by line, because there is no shell parser here.
    #>
    param([Parameter(Mandatory)][object]$Step)

    $found = [System.Collections.Generic.HashSet[string]]::new()

    if ($Step.Shell -eq 'pwsh' -or $Step.Shell -eq 'powershell') {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $Step.Script, [ref]$null, [ref]$errors)
        $commands = $ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $commands) {
            $name = $c.GetCommandName()
            if (-not $name) { continue }
            # A cmdlet or a function is Verb-Noun and is part of PowerShell. An
            # external tool is a bare lower-case name - `az`, `git`, `gh`.
            if ($name -cmatch '^[a-z][a-z0-9_.+-]*$') { $null = $found.Add($name) }
        }
        return @($found)
    }

    foreach ($raw in ($Step.Script -split "`n")) {
        # QUOTES FIRST, or the scan reads English as shell. `echo "...; this
        # job does not install tools."` gave a command called `this`, because
        # the semicolon inside the sentence looked like a separator. What is
        # inside quotes is text - except a command substitution, which is code
        # and is lifted out to be read on its own.
        $substitutions = [System.Collections.Generic.List[string]]::new()
        $line = Remove-VmfShellText -Line $raw -Substitutions $substitutions

        foreach ($fragment in (@($line) + $substitutions)) {
            $text = $fragment.Trim()
            if ($text -eq '') { continue }
            # Anywhere a command can start: the fragment itself, or after a
            # pipe or a separator.
            foreach ($segment in ($text -split '\|\||&&|\||;|&')) {
                $seg = $segment.Trim()
                if ($seg -eq '') { continue }
                # An assignment is not a call. `name=$(basename ...)` reaches
                # here as two fragments, and the substitution is the call.
                if ($seg -match '^[A-Za-z_][A-Za-z0-9_]*=') { continue }
                if ($seg -match '^([a-z][a-z0-9_.+-]*)(\s|$)') { $null = $found.Add($matches[1]) }
            }
        }
    }
    @($found)
}

function Get-VmfRunnerProvides {
    <#
      .SYNOPSIS
      The commands the Linux runner build script promises a job it will find.
      .DESCRIPTION
      Read from the script's own declaration, which that script then PROVES by
      running `command -v` over it at the end of a build. A list nobody proves
      is a list that goes stale, and the cost of this one going stale is a job
      that fails after it has done its work.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -notmatch '(?m)^VMF_RUNNER_PROVIDES="([^"]+)"') {
        throw "No VMF_RUNNER_PROVIDES declaration in $Path"
    }
    @($matches[1] -split '\s+' | Where-Object { $_ })
}
