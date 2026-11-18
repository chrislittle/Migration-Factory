<#
.SYNOPSIS
    PUBLIC-READY-GATE-1: find what must never reach the public repository - a
    lab identifier, an install suffix, an employer name, a claude.ai link, an
    owner quote, a personal email - in any folder.

.DESCRIPTION
    The release goes to a new public repository as one export of this one
    (PUBLIC-SYNC-1). The export tool runs this script on the EXPORTED folder,
    and this repository's own suite runs it on the files that ship
    (tests/unit/PublicReady.Tests.ps1). So it takes any folder, and it reads
    nothing from git.

    THIS SCRIPT AND ITS DATA FILE CARRY NONE OF THE VALUES THEY HUNT FOR, or
    the gate would be the leak. Each rule is one of three kinds:

    - an INVERTED rule: every value of a shape must be on an allow-list of
      placeholders and published ids, so a value nobody has seen yet fails
      too (a GUID, a subscription id, an install suffix, an email domain, a
      profile folder);
    - a HASH: a known lab id is kept as the SHA-256 of its lower-case text,
      and a known employer name as the hash of its words. A GUID has 122
      random bits, so its hash cannot be turned back;
    - a SHAPE: a claude.ai link, an owner quote.

    The data is tools/public-ready.json. A new known value goes in as its
    hash, never as its text.

.PARAMETER Root
    The folder to check.

.PARAMETER Path
    The files to check, relative to Root with forward slashes. Default: every
    file under Root.

.PARAMETER Kind
    Check only these kinds. Default: all of them.


.PARAMETER PassThru
    Return the findings as objects and do not exit.

.EXAMPLE
    ./tools/Test-VmfPublicReady.ps1 -Root C:\dev-work\export-1.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string[]]$Path,
    [ValidateSet('subscriptionId', 'labId', 'unknownGuid', 'installSuffix', 'installToken',
                 'employerName', 'profileFolder', 'personalEmail', 'claudeLink', 'ownerQuote')]
    [string[]]$Kind,
    [string]$DataPath = (Join-Path $PSScriptRoot 'public-ready.json'),
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$allKinds = @('subscriptionId', 'labId', 'unknownGuid', 'installSuffix', 'installToken',
              'employerName', 'profileFolder', 'personalEmail', 'claudeLink', 'ownerQuote')
if (-not $Kind) { $Kind = $allKinds }
$want = @{}; foreach ($k in $Kind) { $want[$k] = $true }

$rootFull = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { throw "Root is not a folder: $rootFull" }
$data = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json -AsHashtable

function Get-VmfPrHash([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())
    -join ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') })
}

# A GUID with six or fewer different hex digits is a placeholder somebody
# typed (eight ones, then eight twos and so on). A random
# GUID has about fourteen.
function Test-VmfPrPlaceholderGuid([string]$Guid) {
    $set = [System.Collections.Generic.HashSet[char]]::new([char[]]($Guid.ToLowerInvariant() -replace '-', ''))
    $set.Count -le 6
}

if (-not $Path) {
    $Path = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        ForEach-Object { [System.IO.Path]::GetRelativePath($rootFull, $_.FullName).Replace('\', '/') })
}

$guidPattern = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'
$rx = @{
    guid          = [regex]::new($guidPattern)
    subscription  = [regex]::new("(?i)subscriptions?[/`"':= ]{1,4}(?<g>$guidPattern)")
    subPrefix     = [regex]::new("(?i)subscriptions?[/`"':= ]{1,4}(?<p>[0-9a-f]{8})(?:-|\.\.\.)")
    shortId       = [regex]::new('(?i)\b(?<p>[0-9a-f]{8})-(?:[0-9a-f]{4}-)*\.\.\.')
    # The names platform.bicep builds from baseSuffix, longest first.
    suffix        = [regex]::new('\b(?:vmfstate|vmfacr|vmf-(?:facade-plan|facade-b1|plan-b1|dash-plan|engine-mi|publish-mi|facade|dash|logs|aca-env|engine|publish|nsp)-)(?<s>[a-z0-9]{4,})\b')
    # uniqueString() gives 13 lower-case letters and digits.
    token13       = [regex]::new('(?<![A-Za-z0-9])(?=[a-z0-9]{13}(?![A-Za-z0-9]))(?=[a-z0-9]*[0-9])(?=[a-z0-9]*[a-z])[a-z0-9]{13}')
    profile       = [regex]::new('(?i)\b[a-z]:[\\/]+users[\\/]+(?<u>[^\\/\s''"`<>|*?]+)')
    email         = [regex]::new('[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
    claude        = [regex]::new('(?i)\bclaude\.ai/[^\s)''"<>\]]*')
    # A role or a thing that has an owner is not the person: a word before
    # "owner" that makes a role name (Storage Blob Data, resource, app) is
    # refused, and so is an item ID such as OWNER-QUESTIONS-1.
    # The word owner, then a date in the same line within 40 characters.
    ownerDate     = [regex]::new('(?i)(?<!data |account |subscription |group |resource |app |application |workload |service |database |product )\bowner(?:''s)?\b(?-i:(?!-[A-Z]))[^\n.]{0,40}?\b20\d\d-\d\d-\d\d')
    # The word owner, up to 60 characters with no colon or full stop, a colon,
    # then a quotation mark.
    ownerSpeech   = [regex]::new('(?i)(?<!data |account |subscription |group |resource |app |application |workload |service |database |product )\bowner\b(?-i:(?!-[A-Z]))[^\n:."]{0,60}:\s*[*_]*["\u201C]')
    # The word owner as the one who acted: followed by a verb or a noun from
    # the list (asked, decided, ruling and the rest), with a space or a hyphen,
    # or as a possessive with an apostrophe and s.
    ownerActed    = [regex]::new('(?i)(?<!data |account |subscription |group |resource |app |application |workload |service |database |product )\bowner(?:(?:''|&rsquo;|\u2019)s\b|(?:\s+|-)(?:asked|said|wrote|ruled|decided|chose|chosen|found|saw|wants|wanted|approved|rejected|declined|confirmed|agreed|noted|caught|spotted|raised|directed|requested|ruling|rulings|decision|decisions|rule|words|choice|call|question|request|design|order|example|case|list|text)\b)')
    # A date, a colon, then a quotation: what is left when only the name was
    # taken out of a quote. A date as a JSON key or a code string has a quote
    # mark straight after it, so it does not match. A source and the date it
    # was read, in brackets before a quotation of Microsoft, does not match.
    dateQuote     = [regex]::new('\b20\d\d-\d\d-\d\d:\s*[*_]*(?:"|\u201C|&ldquo;)')
}

$skipName = @($data.skipFiles)
$findings = [System.Collections.Generic.List[object]]::new()
$texts = [System.Collections.Generic.List[object]]::new()

foreach ($rel in $Path) {
    $leaf = Split-Path $rel -Leaf
    if ($skipName | Where-Object { $leaf -like $_ }) { continue }
    $full = Join-Path $rootFull $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $probe = [Math]::Min($bytes.Length, 8000)
    if ([Array]::IndexOf($bytes, [byte]0, 0, $probe) -ge 0) { continue }   # binary
    $texts.Add([pscustomobject]@{ Path = $rel; Text = [System.Text.Encoding]::UTF8.GetString($bytes) })
}

$lineStarts = @{}
function Add-VmfPrFinding($File, [string]$KindName, [int]$Index, [string]$Value) {
    if (-not $lineStarts.ContainsKey($File.Path)) {
        $starts = [System.Collections.Generic.List[int]]::new(); $starts.Add(0)
        foreach ($nl in [regex]::Matches($File.Text, "`n")) { $starts.Add($nl.Index + 1) }
        $lineStarts[$File.Path] = $starts.ToArray()
    }
    $at = [Array]::BinarySearch($lineStarts[$File.Path], $Index)
    $line = if ($at -ge 0) { $at + 1 } else { -$at - 1 }
    $findings.Add([pscustomobject]@{ Kind = $KindName; Path = $File.Path; Line = $line; Value = $Value })
}

$allowedSubs = @($data.allowedSubscriptionIds)
$allowedSubPrefixes = @($data.allowedSubscriptionPrefixes)
$allowedShort = $data.allowedShortIds
$allowedGuids = $data.allowedGuids
$labHashes = @($data.labIdHashes)
$allowedSuffixes = @($data.allowedSuffixes)
$allowedTokens = @($data.allowedTokens13)
$allowedProfiles = @($data.allowedProfiles)
$docDomains = @($data.docDomains)

foreach ($t in $texts) {
    $text = $t.Text
    if ($want.subscriptionId) {
        foreach ($m in $rx.subscription.Matches($text)) {
            if ($allowedSubs -notcontains $m.Groups['g'].Value.ToLowerInvariant()) { Add-VmfPrFinding $t 'subscriptionId' $m.Index $m.Groups['g'].Value }
        }
        foreach ($m in $rx.subPrefix.Matches($text)) {
            if ($allowedSubPrefixes -notcontains $m.Groups['p'].Value.ToLowerInvariant()) { Add-VmfPrFinding $t 'subscriptionId' $m.Index "$($m.Groups['p'].Value)-..." }
        }
        foreach ($m in $rx.shortId.Matches($text)) {
            if (-not $allowedShort.ContainsKey($m.Groups['p'].Value.ToLowerInvariant())) { Add-VmfPrFinding $t 'subscriptionId' $m.Index $m.Value }
        }
    }
    if ($want.labId -or $want.unknownGuid) {
        foreach ($m in $rx.guid.Matches($text)) {
            $g = $m.Value.ToLowerInvariant()
            if ($want.labId -and $labHashes -contains (Get-VmfPrHash $g)) { Add-VmfPrFinding $t 'labId' $m.Index $g; continue }
            if ($want.unknownGuid -and -not (Test-VmfPrPlaceholderGuid $g) -and -not $allowedGuids.ContainsKey($g)) {
                Add-VmfPrFinding $t 'unknownGuid' $m.Index $g
            }
        }
    }
    if ($want.installSuffix) {
        foreach ($m in $rx.suffix.Matches($text)) {
            $s = $m.Groups['s'].Value
            if ($allowedSuffixes -contains $s) { continue }
            if ($s -match '^(?:(.)\1+|[0-9]+)$') { continue }   # vmf-facade-aaaa, vmf-dash-28800: a test's own invention
            Add-VmfPrFinding $t 'installSuffix' $m.Index $m.Value
        }
    }
    if ($want.installToken) {
        foreach ($m in $rx.token13.Matches($text)) {
            if ($allowedTokens -notcontains $m.Value) { Add-VmfPrFinding $t 'installToken' $m.Index $m.Value }
        }
    }
    if ($want.profileFolder) {
        foreach ($m in $rx.profile.Matches($text)) {
            $u = $m.Groups['u'].Value.ToLowerInvariant().TrimEnd('>', '.', ':', ',', ';', ')')
            if ($u -eq '' -or $u.StartsWith('.') -or $u.StartsWith('$')) { continue }   # C:\Users\..., C:\Users\$env:USERNAME
            if ($allowedProfiles -notcontains $u) { Add-VmfPrFinding $t 'profileFolder' $m.Index $m.Value }
        }
    }
    if ($want.personalEmail) {
        foreach ($m in $rx.email.Matches($text)) {
            $domain = ($m.Value -split '@')[1].TrimEnd('.').ToLowerInvariant()
            $ok = $docDomains | Where-Object { $domain -eq $_ -or $domain.EndsWith(".$_") }
            if (-not $ok) { Add-VmfPrFinding $t 'personalEmail' $m.Index $m.Value }
        }
    }
    if ($want.claudeLink) {
        foreach ($m in $rx.claude.Matches($text)) { Add-VmfPrFinding $t 'claudeLink' $m.Index $m.Value }
    }
    if ($want.ownerQuote) {
        $seen = @{}
        foreach ($m in @($rx.ownerDate.Matches($text)) + @($rx.ownerSpeech.Matches($text)) + @($rx.ownerActed.Matches($text)) + @($rx.dateQuote.Matches($text))) {
            if ($seen[$m.Index]) { continue }; $seen[$m.Index] = $true
            Add-VmfPrFinding $t 'ownerQuote' $m.Index $m.Value
        }
    }
}

# Employer names have no shape. Each is the hash of one of its words (to find
# the few files worth reading word by word) and the hash of all its words.
if ($want.employerName -and @($data.employerNames).Count) {
    $all = [System.Collections.Generic.HashSet[string]]::new()
    $split = @{}
    foreach ($t in $texts) {
        $words = [regex]::Split($t.Text.ToLowerInvariant(), '[^a-z0-9-]+')
        $split[$t.Path] = $words
        $all.UnionWith([string[]]$words)
    }
    $wordHashes = @($data.employerNames | ForEach-Object { $_.word })
    $anchors = @(foreach ($w in $all) { if ($w -and $wordHashes -contains (Get-VmfPrHash $w)) { $w } })
    if ($anchors.Count) {
        foreach ($t in $texts) {
            $words = $split[$t.Path]
            if (-not ($anchors | Where-Object { $words -contains $_ })) { continue }
            foreach ($name in $data.employerNames) {
                $n = [int]$name.words
                for ($i = 0; $i -le $words.Count - $n; $i++) {
                    if ((Get-VmfPrHash (($words[$i..($i + $n - 1)]) -join ' ')) -eq $name.name) {
                        $findings.Add([pscustomobject]@{ Kind = 'employerName'; Path = $t.Path; Line = 0; Value = "word $i" })
                    }
                }
            }
        }
    }
}


if ($PassThru) { return $findings.ToArray() }

if ($findings.Count) {
    $findings | Sort-Object Path, Line | Format-Table Kind, Path, Line, Value -AutoSize | Out-String -Width 300 | Write-Host
    Write-Host "PUBLIC-READY: $($findings.Count) finding(s) in $(@($findings | Select-Object -ExpandProperty Path -Unique).Count) file(s)." -ForegroundColor Red
    exit 1
}
Write-Host "PUBLIC-READY: $($texts.Count) files checked, no finding." -ForegroundColor Green
exit 0
