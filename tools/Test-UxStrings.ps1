<#
.SYNOPSIS
    STRING-SWEEP-1: every UX string a page reads exists, and every one it
    declares is read.

.DESCRIPTION
    TWO RULES, AND THE FIRST IS THE ONE THAT MATTERS.

    (1) UNDEFINED READ. `UX_ACT.startNeedsAccept` where UX_ACT has no such key
        is `undefined`, and JavaScript says nothing. On migrations.html three
        keys were declared in UX_MISC while every read of them said UX_ACT:

          - the refusal watcher called .replace() on undefined and THREW, so
            the refusal it exists to report was never reported - the exact
            fault its own comment says it was written to fix;
          - `startBlockedBy` went undefined, which is falsy, so the Start
            button rendered on an UNACCEPTED wave with no reason beside it.
            That is EVAL-H9, whose fix sits three lines above it.

        Neither is visible by reading the page: both look like correct code.
        This rule has no judgement in it - a name is defined or it is not.

    (2) UNUSED DECLARATION. A string nothing renders is the same defect as an
        unused CSS token: the product looks like it says something it does not.
        Sixty were found and removed - a create-run dialog that moved to
        wizard.html, labels superseded by other labels, and four ring names
        left over from a concept WAVE-2 deleted from the engine, the schema and
        every page.

    WHY THIS VERSION GATES WHEN THE FIRST ONE DID NOT. The first attempt was
    dropped for noise: it flattened nested objects, so UX.stateWords' inner
    keys read as UX's own and three live, dynamically-indexed state labels were
    reported dead. It also swept objects that are never read by name at all.
    Both are fixed by understanding the SHAPE - depth-1 keys only, and an
    object read by index, enumeration or spread is exempt whole - rather than
    by accumulating exemptions. A check that cries wolf is the thing this
    project keeps having to diagnose.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$DashboardPath = (Join-Path $PSScriptRoot '..' 'src' 'dashboard'),
    [Parameter()][switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Blank out // and /* */ so a comment naming a string is never read as a use.
# Quotes are skipped first, or a // inside a URL would eat the rest of a line.
. (Join-Path $PSScriptRoot '..' 'tests' 'unit' '_CodeOnly.ps1')

function Remove-JsComments {
    <#
    .SYNOPSIS
        The page with its comments blanked, using the ONE hardened scanner.
    .DESCRIPTION
        This used to carry its own scanner, and that scanner did not know what
        a REGULAR EXPRESSION LITERAL is. Every page opens with

            const esc = (v) => String(v ?? '').replace(/[&<>"']/g, ...)

        and the `"` inside that character class read as the start of a string.
        From there the scanner was one quote out of step with the file for
        thousands of characters, so whether it could see a given key depended
        on how many quotes happened to appear downstream.

        NOTHING ANNOUNCED THAT. The gate kept reporting on the keys it could
        still see, and an ordinary comment edit that changed quote parity made
        three real, declared keys vanish from its view and be reported as
        undefined reads. A checker that silently misreads its input is the
        defect class this repository already names elsewhere; here the checker
        was doing it to itself.

        Get-VmfCodeOnly learned regex literals in CODEONLY-2 and is tested.
        Two scanners meant two behaviours, so there is now one.
    #>
    param([string]$Text)
    Get-VmfCodeOnly -Text $Text -Language CStyle
}

# Brace-match from the object's opening '{'.
function Get-ObjectBody {
    param([string]$Text, [int]$From)
    $i = $Text.IndexOf('{', $From)
    if ($i -lt 0) { return $null }
    $depth = 0
    for ($j = $i; $j -lt $Text.Length; $j++) {
        if ($Text[$j] -eq '{') { $depth++ }
        elseif ($Text[$j] -eq '}') {
            $depth--
            if ($depth -eq 0) { return [pscustomobject]@{ Body = $Text.Substring($i, $j - $i + 1); End = $j } }
        }
    }
    $null
}

# Keys at depth 1 ONLY. A nested object is itself one key; whatever is inside it
# is reached by a read that does not name it, so it is out of scope.
function Get-TopLevelKeys {
    param([string]$Body)
    $keys = [System.Collections.Generic.List[string]]::new()
    $depth = 0; $i = 0
    while ($i -lt $Body.Length) {
        $c = $Body[$i]
        if ($c -eq '"' -or $c -eq "'" -or $c -eq '`') {
            $quote = $c; $i++
            while ($i -lt $Body.Length) {
                if ($Body[$i] -eq '\') { $i += 2; continue }
                if ($Body[$i] -eq $quote) { break }
                # a ${ } inside a template literal carries its own braces
                if ($quote -eq '`' -and $Body[$i] -eq '$' -and $i + 1 -lt $Body.Length -and $Body[$i + 1] -eq '{') {
                    $d2 = 0; $i++
                    while ($i -lt $Body.Length) {
                        if ($Body[$i] -eq '{') { $d2++ }
                        elseif ($Body[$i] -eq '}') { $d2--; if ($d2 -eq 0) { break } }
                        $i++
                    }
                }
                $i++
            }
            $i++
            continue
        }
        if ($c -eq '{' -or $c -eq '(' -or $c -eq '[') { $depth++; $i++; continue }
        if ($c -eq '}' -or $c -eq ')' -or $c -eq ']') { $depth--; $i++; continue }
        if ($depth -eq 1) {
            $m = [regex]::Match($Body.Substring($i), '^([A-Za-z_][A-Za-z0-9_]*)\s*:')
            $prevOk = ($i -eq 0) -or ($Body[$i - 1] -notmatch '[A-Za-z0-9_.]')
            if ($m.Success -and $prevOk) {
                $keys.Add($m.Groups[1].Value)
                $i += $m.Length
                continue
            }
        }
        $i++
    }
    $keys
}

$findings = [System.Collections.Generic.List[object]]::new()
# STRINGS-GATE-1: which keys does a CALLEE read, when a page hands it the whole
# string table?
#
# WHY THIS EXISTS. Rule 2 below used to give up on the entire object the moment
# it was passed whole to anything: `waveEstimate(machines, value, UX)` matched
# "an object between a comma and a bracket", and the page's key checking was
# switched off. The wizard has exactly one such call, so ALL of its strings
# went unchecked - and when WAVE-FLOW-1 deleted two screens on 2026-09-16, the
# 34 strings they owned were reported as fine.
#
# Giving up was the safe-looking choice, because the callee names the parameter
# whatever it likes - `waveEstimate` calls it `T`, not `UX`. So resolve it:
# find the argument's POSITION, take the parameter at that position in the
# callee, and read the keys off that name inside the callee's body.
function Get-VmfKeysReadByCallee {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PageCode,
        [Parameter(Mandatory)][string]$ObjectName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SharedCode
    )
    $found = [System.Collections.Generic.HashSet[string]]::new()
    $n = [regex]::Escape($ObjectName)
    # `something.fn(a, b, UX)` or `fn(a, UX)`. The argument list is taken up to
    # the closing bracket; a nested call inside it would confuse the position,
    # so a call containing one is skipped rather than guessed at.
    foreach ($m in [regex]::Matches($PageCode, "(?<fn>[A-Za-z_][\w]*)\s*\(")) {
        # The argument list is SCANNED, not matched: `waveEstimate(machines,
        # $('#f-thr').value, UX)` has a call inside it, and a pattern that
        # stopped at the first bracket missed the wizard entirely - which is
        # the one page the blind gate was found on.
        $depth = 0; $start = $m.Index + $m.Length; $at = -1; $slot = 0
        $piece = [System.Text.StringBuilder]::new()
        for ($j = $start; $j -lt $PageCode.Length; $j++) {
            $c = $PageCode[$j]
            if ($c -eq '(') { $depth++ }
            elseif ($c -eq ')' -and $depth -gt 0) { $depth-- }
            elseif ($c -eq ')' -or ($c -eq ',' -and $depth -eq 0)) {
                if ($piece.ToString().Trim() -eq $ObjectName) { $at = $slot }
                if ($c -eq ')') { break }
                $slot++; [void]$piece.Clear(); continue
            }
            [void]$piece.Append($c)
            if ($j - $start -gt 2000) { break }   # not an argument list
        }
        if ($at -lt 0) { continue }   # named a key, not the object itself
        $fn = [regex]::Escape($m.Groups['fn'].Value)
        $sig = [regex]::Match($SharedCode, "function\s+$fn\s*\((?<p>[^)]*)\)")
        if (-not $sig.Success) { continue }
        $params = @($sig.Groups['p'].Value -split ',' | ForEach-Object { ($_ -split '=')[0].Trim() })
        if ($at -ge $params.Count -or -not $params[$at]) { continue }
        $body = Get-ObjectBody -Text $SharedCode -From $sig.Index
        if (-not $body) { continue }
        $param = [regex]::Escape($params[$at])
        foreach ($r in [regex]::Matches($body.Body, "\b$param\.(?<k>[A-Za-z_][\w]*)")) { [void]$found.Add($r.Groups['k'].Value) }
        foreach ($r in [regex]::Matches($body.Body, "\b$param\[['`"](?<k>[^'`"]+)['`"]\]")) { [void]$found.Add($r.Groups['k'].Value) }
    }
    # NO leading comma: the caller wraps this in @(), and a comma here would
    # hand it ONE element that is itself an array - so -contains compares a
    # string to an array and is false for every key. Measured, not reasoned:
    # the first version of this fix reported the same 15 strings dead as the
    # blind gate did, for a completely different reason.
    [string[]]@($found)
}
# The shared helpers a page hands its strings to. Read once, and comment-free,
# so a callee named in a comment cannot be mistaken for one that exists.
$sharedHelp = Join-Path $DashboardPath 'help.js'
$sharedCode = if (Test-Path -LiteralPath $sharedHelp) { Remove-JsComments -Text (Get-Content -LiteralPath $sharedHelp -Raw) } else { '' }

$pages = @(Get-ChildItem -LiteralPath $DashboardPath -Filter '*.html' -File)

foreach ($page in $pages) {
    # CSP-INLINE-1: the page's strings and code are in its own script file;
    # the page is read with that script put back inline.
    $raw = Get-VmfPageSource -Path $page.FullName
    $code = Remove-JsComments -Text $raw

    $declared = @{}      # object name -> keys
    $spans = @{}         # object name -> [start,end] in $code
    foreach ($m in [regex]::Matches($code, '(?m)^const (UX[A-Za-z_]*|TEXT[A-Za-z_]*) = \{')) {
        $name = $m.Groups[1].Value
        $obj = Get-ObjectBody -Text $code -From $m.Index
        if (-not $obj) { continue }
        $declared[$name] = Get-TopLevelKeys -Body $obj.Body
        $spans[$name] = @($m.Index, $obj.End)
    }
    if (-not $declared.Count) { continue }

    # ---- rule 0: a key is declared once --------------------------------
    # JavaScript keeps the LAST of two same-named keys and says nothing. A
    # second colMachine written for a new step changed the column heading of
    # an older table on the same page, and every other rule here was satisfied:
    # the key was declared, and it was read.
    foreach ($name in $declared.Keys) {
        foreach ($g in @($declared[$name] | Group-Object -CaseSensitive | Where-Object Count -gt 1)) {
            $findings.Add([pscustomobject]@{
                    Rule = 'duplicate-key'; Page = $page.Name; Line = 0
                    Detail = "$name.$($g.Name) is declared $($g.Count) times - only the last is used, so the earlier words never show"
                })
        }
    }

    # ---- rule 1: every dotted read resolves ----------------------------
    foreach ($m in [regex]::Matches($code, '\b(UX[A-Za-z_]*|TEXT[A-Za-z_]*)\.([A-Za-z_][A-Za-z0-9_]*)')) {
        $name = $m.Groups[1].Value
        $key = $m.Groups[2].Value
        if (-not $declared.ContainsKey($name)) { continue }   # not one of this page's objects
        if ($declared[$name] -contains $key) { continue }
        $line = ($code.Substring(0, $m.Index) -split "`n").Count
        $findings.Add([pscustomobject]@{
                Rule = 'undefined-read'; Page = $page.Name; Line = $line
                Detail = "$name.$key is read but $name has no such key - it is undefined at runtime"
            })
    }

    # ---- rule 2: every declared key is read ----------------------------
    foreach ($name in $declared.Keys) {
        $span = $spans[$name]
        $outside = $code.Substring(0, $span[0]) + $code.Substring($span[1] + 1)
        $n = [regex]::Escape($name)
        # Read without naming a key? Then key-level analysis says nothing.
        if ($outside -match "$n\s*\[") { continue }
        # STRING-SWEEP-2: the object ITSELF, not something reached through it.
        # This used to end at \b, so `Object.keys(UX.roleWords)` - which names a
        # key and therefore says nothing about the other forty - excused the
        # WHOLE object. One such line on access.html switched dead-string
        # detection off for that page from the day this gate was written, and
        # the summary still reported "nothing is declared unread".
        if ($outside -match "Object\.(keys|values|entries)\s*\(\s*$n\s*\)") { continue }
        if ($outside -match "\.\.\.\s*$n\b") { continue }
        # STRINGS-GATE-1: passing the object WHOLE no longer excuses the page.
        # It used to `continue` here, and one such call switched key checking
        # off for every string the page declares. Resolve what the callee reads
        # instead - and only give up if the call cannot be followed, which is
        # the assignment below rather than a skip of everything.
        $viaCallee = @(Get-VmfKeysReadByCallee -PageCode $outside -ObjectName $name -SharedCode $sharedCode)
        if ($outside -match "=\s*$n\s*[;,]") { continue }   # aliased whole: nothing can be said
        foreach ($key in $declared[$name]) {
            if ($viaCallee -contains $key) { continue }
            $k = [regex]::Escape($key)
            if ($outside -match "$n\.$k\b") { continue }
            if ($outside -match "$n\[['`"]$k['`"]\]") { continue }
            $findings.Add([pscustomobject]@{
                    Rule = 'unused-string'; Page = $page.Name; Line = 0
                    Detail = "$name.$key is declared and never read"
                })
        }
    }
}

if (-not $findings.Count) {
    Write-Host 'UX strings: every read resolves, and nothing is declared unread.' -ForegroundColor Green
    return [pscustomobject]@{ Findings = @(); Count = 0 }
}

Write-Host "UX string findings: $($findings.Count)" -ForegroundColor Yellow
foreach ($g in $findings | Group-Object Rule) {
    Write-Host ("`n{0} ({1})" -f $g.Name, $g.Count) -ForegroundColor Cyan
    $show = if ($Detailed) { $g.Group } else { $g.Group | Select-Object -First 10 }
    foreach ($f in $show) {
        Write-Host ("  {0}{1}  {2}" -f $f.Page, $(if ($f.Line) { ":$($f.Line)" } else { '' }), $f.Detail)
    }
    if (-not $Detailed -and $g.Count -gt 10) { Write-Host "  ... $($g.Count - 10) more (use -Detailed)" }
}
[pscustomobject]@{ Findings = $findings; Count = $findings.Count }
