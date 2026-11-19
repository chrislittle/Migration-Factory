<#
.SYNOPSIS
    Check every word this product shows an operator against ASD-STE100.

.DESCRIPTION
    Since 2026-09-01 the whole portal UX and the docs use ASD-STE100. An
    assessment finding had said "This one is Azure's own answer rather than a
    judgement of ours", which means nothing to a reader and uses no clear term.

    ASD-STE100 (Simplified Technical English) is the aerospace maintenance
    writing standard: https://www.asd-ste100.org/. Its point is that a reader
    under pressure, often not a native speaker, gets ONE meaning per word and
    short sentences. That is exactly the reader here - somebody deciding
    whether to move a production machine.

    THE RULE THAT MATTERS MOST FOR THIS PRODUCT: STE explicitly ALLOWS technical
    names. "NVMe", "Generation 2" and "managed disk" are the correct words, and
    a previous rule in this repo banned them as jargon, which is what produced
    "the new disk type" - a phrase that names nothing and sends the reader
    nowhere. Vagueness is not plain language. Engine vocabulary
    ('stornvme', 'azureops', 'ETag') stays banned, because that is OUR
    machinery, not the reader's subject.

    This reports; it never rewrites. Meaning is the author's job.

.PARAMETER Path
    Repository root. Defaults to the parent of this script's folder.

.PARAMETER Source
    Limit the check to one source by name (see -ListSources).

.PARAMETER ListSources
    Print what would be checked and stop.

.PARAMETER Detailed
    Show every finding rather than the first few per rule.

.EXAMPLE
    ./tools/Test-SimplifiedEnglish.ps1

.EXAMPLE
    ./tools/Test-SimplifiedEnglish.ps1 -Source assessment-reasons -Detailed
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Path,
    [Parameter()][string]$Source,
    [Parameter()][switch]$ListSources,
    [Parameter()][switch]$Detailed
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path -Parent $PSScriptRoot }

# ---------------------------------------------------------------------------
# The vocabulary, in ONE place.
#
# It used to be copied into six Describe blocks in Dashboard.Tests.ps1 and two
# more elsewhere, each drifting from the others - one banned 'NVMe', another
# did not, a third had never heard of 'ETag'. A rule with eight copies is eight
# rules.
# ---------------------------------------------------------------------------

# OUR machinery. An operator never has to know these words to do the job.
$script:EngineJargon = @(
    'azureops', 'stornvme', 'runcmd', 'RunCommand', 'JSONL', 'ETag', 'schemaVersion',
    'idempotent', 'checkpoint', 'azblob', 'blob', 'ARM', 'SKU', 'ODCR', 'IaC',
    'shell', 'PRECHECK', 'deallocat', 'SR-IOV', 'sriov',
    'JMESPath', 'RBAC', 'ARM64', 'cmdlet', 'stdout', 'sha256',
    # From the per-page lists this replaced: the identity vocabulary on the
    # access page, and the wire formats on the help topics.
    'principal', 'tenant', 'SPA', 'JSON', 'API',
    # 'token' on its own is ordinary English, and "no passwords, keys or
    # tokens" is a sentence a reader understands and needs. What an operator
    # never needs is the sign-in machinery by name.
    'access token', 'bearer token', 'ID token', 'refresh token',
    # GATE-WORDS-1: the engine's name for a wave setting. The start gate said
    # "review the wave's levers" on the screen; the page says settings.
    'lever'
)

# GATE-WORDS-1: a command name. Every operator action is reachable from the
# app (hard rule 12), so text a person reads never sends them to one. The
# start gate said "or with Confirm-VmfRunAcknowledgement" in a dialog.
$script:CommandPattern = '\b[A-Z][a-z]+-Vmf[A-Za-z]+\b'

# HELP-JS-RULE12-1: a tool script, for the same reason. The shared help said
# "Run tools/Test-VmfHealth.ps1" to a person looking at a refused call, and a
# script name needs no -Vmf in it to send somebody out of the app.
$script:ScriptPattern = '[\w./-]+\.ps1\b'

# STE Rule 1.5: technical names ARE approved words. These are the reader's
# subject, they appear in Microsoft's own documentation, and replacing them with
# a description makes the text longer and less useful.
$script:TechnicalNames = @(
    # QUOTA-REQUEST-POLL-1: the titles of Microsoft's two quota increase pages,
    # shown as links when Azure refuses a request. They are Microsoft's names, and the
    # drift check watches both pages (docs/upstream-docs.json, azure/quotas). First,
    # because 'quota' below is stripped in order and would split them.
    'Increase VM-family vCPU quotas', 'Increase regional vCPU quotas',
    'NVMe', 'SCSI', 'Generation 1', 'Generation 2', 'managed disk', 'managed disks',
    'accelerated networking', 'Storage Blob Data Reader', 'Storage Blob Data Contributor',
    'Storage Spaces', 'page file', 'temporary disk', 'resource group', 'subscription',
    'management group', 'capacity reservation', 'availability zone', 'quota',
    'virtual machine', 'image', 'snapshot', 'Entra ID', 'Windows Server', 'Linux',
    # Microsoft's own product names. STE Rule 1.5 allows a technical name, and
    # an abbreviation is allowed once the text has written it out in full -
    # which is why 'Microsoft Azure Network Adapter (MANA)' is correct and a
    # bare 'MANA' is what the wording had before.
    'Microsoft Azure Network Adapter', 'MANA', 'ARM template', 'ARM templates',
    # SCOPE-DATA-1: the PROCESSOR architecture, which the manual must name
    # because an Arm64 machine is out of scope and an operator has to know
    # which of their machines that is. Written Arm64, the way Azure's own size
    # documentation writes it - a bare 'ARM' stays banned above, because
    # everywhere else in this product it means Azure Resource Manager, and a
    # reader would take "an ARM machine" to mean something it does not.
    'Arm64',
    'audit log', 'checkbox', 'LVM', 'key vault', 'Terraform', 'Bicep', 'Pulumi', 'Ansible',
    # INSTALL-1: the install guide names the tools a person installs.
    'PowerShell', 'Azure CLI', 'Azure Developer CLI', 'Git', 'Docker',
    # DOC-4: the Azure portal's own field labels, copied exactly so a reader
    # can find them on the screen.
    'Application (client) ID', 'Directory (tenant) ID',
    # DOC-4: the pipeline uses OIDC, and sets no secrets in GitHub Actions.
    # The pipeline page explains it; the name is GitHub's and Microsoft's own,
    # written out in full at first use.
    'OpenID Connect', 'OIDC', 'federated credential', 'GitHub Actions',
    # The value pages name Microsoft's hardware by Microsoft's names.
    'Azure Boost', 'Intel Emerald Rapids', 'AMD Genoa', 'Intel Xeon 6', 'AMD Turin',
    # POWER-ONLY-CHANGED-1: the power state as the Azure portal shows it, so a
    # reader finds it on the machine's page. The engine's own word stays
    # banned above in any other form.
    'Stopped (deallocated)'
)

# STE Rule 1.4: one word, one meaning. Pick the word this product uses for each
# idea and use only that word. The alternates are not wrong English - they are
# a second name for something that already has one, and a reader who meets both
# has to work out whether they are the same thing.
$script:OneWordOneMeaning = @(
    # DETECT-PATTERNS-1: 'node pool' (AKS) and 'node type' (Databricks) are Azure's own names.
    # CLUSTER-DETECT-1: and 'cluster node' is the name Windows Server failover
    # clustering and Pacemaker give a machine in a cluster. Only the two words
    # together: a bare 'node' still means 'machine'.
    @{ Use = 'machine';    Instead = @('\bVM\b', '\bVMs\b', '\bbox\b', '(?<!\bcluster )\bnode\b(?! pool| type)') }
    @{ Use = 'migration';  Instead = @('\bcutover\b', '\bflip\b', '\blift and shift\b') }
    @{ Use = 'assessment'; Instead = @('\bsurvey\b', '\baudit\b') }
    @{ Use = 'start';      Instead = @('\bkick off\b', '\bspin up\b', '\bfire off\b') }
    @{ Use = 'stop';       Instead = @('\bkill\b', '\btear down\b') }
    @{ Use = 'find';       Instead = @('\bdig out\b', '\bhunt down\b') }
)

# THE RULE THAT WAS MISSING, and it is the one that matters most here.
#
# Found 2026-09-02: the page on what access this tool needs still used invented
# jargon after the ASD-STE100 rule, for example the terms "look only" and
# "look and change".
#
# The checker read those strings and passed them, because it knew ENGINE jargon
# and a hand-written idiom list and nothing else. It had no concept of the
# product's OWN nouns - so an invented euphemism sailed straight through, which
# is the same failure as "the new disk type": a word made up to avoid a word we
# already have.
#
# STE Rule 1.4 in its strongest form: this product has a name for each thing it
# does, on the navigation bar. Anything that describes one of those things uses
# THAT name. An access level that lets you assess is an ASSESS level, not a
# "look only" level.
$script:ProductWords = @(
    @{ Concept = 'assess';     Use = 'assess / assessment'
       Instead = @('\blook only\b', '\bmay look\b', '\blook at machines\b', '\bjust looks\b') }
    @{ Concept = 'migrate';    Use = 'migrate / migration'
       # NOT 'move machines': this product legitimately says a machine MOVES to
       # new hardware, and the wave editor moves machines BETWEEN WAVES, which
       # is a different action. A rule that cannot tell those apart trains
       # people to ignore it.
       Instead = @('\blook and change\b', '\bchange machines\b') }
    @{ Concept = 'project';    Use = 'project'
       Instead = @('\bpiece of work\b', '\bpieces of work\b', '\bengagement\b') }
    @{ Concept = 'assessment'; Use = 'assessment'
       Instead = @('\btimes looked at\b', '\bthe scan report\b') }
    @{ Concept = 'wave';       Use = 'wave'
       # BATCH-CYCLECLOUD-SIGNAL-1: "Azure Batch" is the name of an Azure service.
       Instead = @('(?<!\bAzure )\bbatch\b', '\bgroup of machines\b') }

    # -- AZURE'S OWN NAMES ------------------------------------------------
    # Found 2026-09-02 on the wave settings: on-demand capacity reservations
    # were listed as "reserve and guarantee (needs reserving separately)";
    # "regular capacity" names nothing in Azure; and "minimum for fast
    # networking" is not the Azure term, which is accelerated networking.
    #
    # The gap was in THIS FILE. TechnicalNames already
    # PERMITTED every correct term - 'accelerated networking', 'temporary
    # disk', 'capacity reservation' were all on the approved list - but
    # nothing REQUIRED them, so four invented substitutes shipped alongside.
    # Permitting a word does not stop somebody inventing a different one.
    #
    # CLAUDE.md rule 10 already said it: never invent a softer word for
    # something that already has one. These are the four that got through.
    @{ Concept = 'accelerated networking'; Use = 'accelerated networking'
       Instead = @('\bfast networking\b', '\bfast network path\b', '\bfast network\b') }
    @{ Concept = 'temporary disk'; Use = 'temporary disk'
       # A drive is a Windows letter; the Azure resource is a disk.
       Instead = @('\btemporary drive\b', '\btemp drive\b') }
    @{ Concept = 'capacity reservation'; Use = 'on-demand capacity reservation'
       # 'Regular capacity' names nothing in Azure. The opposite of holding a
       # reservation is no reservation: the value None.
       Instead = @('\bregular capacity\b', '\breserved and guaranteed\b',
                   '\bguaranteed capacity\b') }
    @{ Concept = 'size series'; Use = 'machine size series'
       # 'Generation' is Azure's word for Gen1/Gen2, which this product also
       # uses ON THE SAME SCREENS. Using it for the v6/v7 size series put two
       # concepts behind one word.
       Instead = @('\bhardware generation\b') }
    # QUOTA-PREVIEW-1, 2026-10-26: nobody "asks Azure"; in Azure's terms, you
    # request a quota increase. Azure names the action:
    # a quota increase request on the Quotas page of the Azure portal, or an
    # Azure support request where support is the channel. "Ask Azure" names
    # no Azure action at all.
    @{ Concept = 'quota increase'; Use = 'request a quota increase, or open an Azure support request'
       Instead = @('\bask Azure\b') }
)

# STE Rules 1.6, 2.x: no idioms, no slang, no words that point at nothing.
# Every one of these has been in this product's UI at some point.
$script:VagueOrIdiom = @(
    'this one', 'that one', 'the heck', 'carry on', 'piece of work', 'sort out',
    'at the ready', 'have a look', 'take a look', 'under the hood', 'out of the box',
    'a bit of', 'handy', 'nice to', 'as such', 'of course', 'simply', 'just click',
    'somebody has to', 'nothing to worry', 'no big deal', 'and so on', 'etc',
    'obviously', 'basically', 'actually', 'stuff', 'things like',
    # Euphemisms this product invented for its OWN nouns. The navigation says
    # Projects, Assessments and Migrations; a page that says "piece of work"
    # instead has made the reader translate. The term is project.
    'pieces of work', 'times looked at',
    # README-2. Metaphors for a document or a page, such as "so neither route
    # can quietly rot". A word like 'rot' has no place here. A document does not
    # rot and a page is not a door - both make a reader translate a picture
    # back into the plain fact it stands for, which is what STE Rule 1.6 is
    # about. All three were in the README, which is the first page anybody
    # reads.
    #
    # 'load-bearing' has never reached a page. It is here because it came up
    # in review as a word that does not help a reader understand a request,
    # and a rule that stops a known-bad word before it ships costs nothing.
    'rot', 'front door', 'load-bearing'
)

# TERMS-AUDIT-1: invented terms and phrasal verbs, as DATA with a source each
# (tools/ste-terms.json). Found 2026-11-04: the line "Checking the network is running
# on accelerated hardware" was one of many such lines, so a full check was
# needed before 1.0; and "Tidying up the disk it left behind" was not
# ASD-STE100 either. The lists above passed both, because
# they held the words found before and nothing else. Each entry in the file
# carries a sentence it must catch and one it must leave alone, and
# SimplifiedEnglish.Tests.ps1 runs every one of them through this tool.
$script:TermsFile = Join-Path $PSScriptRoot 'ste-terms.json'
$script:Terms = @(
    if (Test-Path $script:TermsFile) {
        $doc = Get-Content $script:TermsFile -Raw | ConvertFrom-Json
        foreach ($t in @($doc.bannedPhrases)) {
            # MANUAL-REVIEW-1: a rule marked rawText also reads every line of a
            # manual page as written - inline code, fenced code and table rows -
            # because a lab resource group or a region is most often written in
            # code, and the sentence reader puts code away.
            [pscustomobject]@{ Rule = 'banned-term'; Regex = [regex]::new([string]$t.pattern, 'IgnoreCase'); Use = [string]$t.use; Except = @($t.except | Where-Object { $_ })
                               RawText = [bool]($t.PSObject.Properties['rawText'] -and $t.rawText) }
        }
        foreach ($t in @($doc.phrasalVerbs)) {
            [pscustomobject]@{ Rule = 'phrasal-verb'; Regex = [regex]::new([string]$t.pattern, 'IgnoreCase'); Use = [string]$t.use; Except = @($t.except | Where-Object { $_ }); RawText = $false }
        }
    }
)
# MANUAL-REVIEW-1: a finding of a term rule in a source that another open
# branch of the same review rewrites. Each entry names the source (as
# -ListSources names it), the pattern of the rule, and the owner. The finding
# is reported as waived, not counted, and SimplifiedEnglish.Tests.ps1 fails an
# entry that waives nothing, so each one goes when its owner fixes the text.
$script:Pending = @(
    if (Test-Path $script:TermsFile) {
        foreach ($p in @((Get-Content $script:TermsFile -Raw | ConvertFrom-Json).pending)) {
            if ($p) { [pscustomobject]@{ Source = [string]$p.source; IdPrefix = [string]$p.idPrefix; Pattern = [string]$p.pattern; Owner = [string]$p.owner } }
        }
    }
)

# STE Rule 2.1: use the full form.
$script:ContractionPattern = "\b\w+'(t|re|ve|ll|d|m|s)\b"
$script:AllowedApostrophe = @("Azure's", "Microsoft's", "Windows'", "today's")

$script:MaxWordsInstruction = 20   # STE: procedural sentence
$script:MaxWordsDescriptive = 25   # STE: descriptive sentence

# STE writes SENTENCES, not telegraphic fragments. "Search your directory, pick
# a role, done" is three fragments and a shrug; "One resource group - the
# smallest choice, and the one to prefer" is a caption pretending to be help.
# Short labels and buttons are exempt - "New assessment" is a name, not a
# sentence - so the rule applies once a string is long enough to be prose.
$script:SentenceFloorWords = 8

# ---------------------------------------------------------------------------
# What gets checked. Each source yields items: Id, Text, Kind.
# Kind 'instruction' is text that tells somebody to do something (a whatToDo,
# a button, a step); 'descriptive' is everything else.
# ---------------------------------------------------------------------------
function Get-VmfUiStrings {
    param([string]$File)
    # CSP-INLINE-1: a page's strings are in its own script (wizard.js beside
    # wizard.html), so the page is read with that script put back inline.
    $text = Get-VmfPageSource -Path $File
    $m = [regex]::Match($text, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END')
    if (-not $m.Success) { return @() }
    # key: 'value' - single or double quoted, one per line.
    [regex]::Matches($m.Groups[1].Value, "(?m)^\s*(\w+)\s*:\s*(['`"])(.*?)\2\s*,?\s*$") |
        ForEach-Object {
            [pscustomobject]@{
                Id   = "$(Split-Path $File -Leaf):$($_.Groups[1].Value)"
                Text = $_.Groups[3].Value
                # A string whose name says it is a button or a step is an
                # instruction; the rest describe.
                Kind = if ($_.Groups[1].Value -match 'Btn$|Button|Next|Back|Action|Do$') { 'instruction' } else { 'descriptive' }
            }
        }
}

function Get-VmfReasonStrings {
    param([string]$File)
    $doc = Get-Content $File -Raw | ConvertFrom-Json
    $name = Split-Path $File -Leaf

    # stop-reasons.json: a flat LIST under .reasons, each with a code.
    foreach ($r in @($doc.reasons)) {
        foreach ($field in 'title', 'meaning', 'whatToDo') {
            if ([string]::IsNullOrWhiteSpace($r.$field)) { continue }
            [pscustomobject]@{
                Id   = "${name}:$($r.code).$field"
                Text = [string]$r.$field
                Kind = if ($field -eq 'whatToDo') { 'instruction' } else { 'descriptive' }
            }
        }
    }

    # LAB-UX-1: stop-reasons.json also holds the line shown after whatToDo for
    # each retry kind. The page used to declare these; the file holds them now.
    if ($doc.PSObject.Properties['retryLines'] -and $doc.retryLines) {
        foreach ($line in $doc.retryLines.PSObject.Properties) {
            [pscustomobject]@{ Id = "${name}:retryLines.$($line.Name)"; Text = [string]$line.Value; Kind = 'instruction' }
        }
    }

    # assessment-reasons.json: groups of entries keyed by code.
    # DETECT-PATTERNS-1: the warnings and the workload types too.
    foreach ($group in 'blockers', 'prep', 'excluded', 'warnings', 'workloadTypes') {
        if (-not $doc.$group) { continue }
        foreach ($entry in $doc.$group.PSObject.Properties) {
            foreach ($field in 'title', 'meaning', 'whatToDo') {
                if ([string]::IsNullOrWhiteSpace($entry.Value.$field)) { continue }
                [pscustomobject]@{
                    Id   = "${name}:$group.$($entry.Name).$field"
                    Text = [string]$entry.Value.$field
                    Kind = if ($field -eq 'whatToDo') { 'instruction' } else { 'descriptive' }
                }
            }
        }
    }
}

# GATE-WORDS-1: the start gate reasons the engine gives, which the migration's
# page shows in the Try this machine again dialog, under the next wave, and as
# a refused wave start. The gate did not read engine text before; the words
# moved to a data file so that it can. {wave} and {by} are left in: each counts
# as one word, as the name that fills it does.
function Get-VmfStartGateStrings {
    param([string]$File)
    $doc = Get-Content $File -Raw | ConvertFrom-Json
    $name = Split-Path $File -Leaf
    foreach ($r in $doc.reasons.PSObject.Properties) {
        [pscustomobject]@{ Id = "${name}:$($r.Name).missing"; Text = [string]$r.Value.missing; Kind = 'descriptive' }
        [pscustomobject]@{ Id = "${name}:$($r.Name).toDo"; Text = [string]$r.Value.toDo; Kind = 'instruction' }
    }
    foreach ($line in $doc.lines.PSObject.Properties) {
        [pscustomobject]@{ Id = "${name}:lines.$($line.Name)"; Text = [string]$line.Value; Kind = 'descriptive' }
    }
}

function Get-VmfGuideStrings {
    param([string]$File)
    $doc = Get-Content $File -Raw | ConvertFrom-Json
    $name = Split-Path $File -Leaf

    foreach ($screen in $doc.screens.PSObject.Properties) {
        $page = $screen.Name
        foreach ($field in 'title', 'what', 'nextStep') {
            if ([string]::IsNullOrWhiteSpace($screen.Value.$field)) { continue }
            [pscustomobject]@{
                Id   = "${name}:$page.$field"
                Text = [string]$screen.Value.$field
                Kind = if ($field -eq 'nextStep') { 'instruction' } else { 'descriptive' }
            }
        }
        $i = 0
        foreach ($line in @($screen.Value.howToRead)) {
            [pscustomobject]@{ Id = "${name}:$page.howToRead[$i]"; Text = [string]$line; Kind = 'descriptive' }
            $i++
        }
    }
    if ($doc.general.title) {
        [pscustomobject]@{ Id = "${name}:general.title"; Text = [string]$doc.general.title; Kind = 'descriptive' }
    }
    $i = 0
    foreach ($pt in @($doc.general.points)) {
        [pscustomobject]@{ Id = "${name}:general.points[$i]"; Text = [string]$pt; Kind = 'descriptive' }
        $i++
    }
}

# PERMISSIONS-WHY-1: rbac-actions.json gives each Azure action one sentence for
# the operator (operatorWhy), keyed by the action. The developer reasons in the
# same file (why) are not read: no page shows them.
function Get-VmfRbacWhyStrings {
    param([string]$File)
    $doc = Get-Content $File -Raw | ConvertFrom-Json
    $name = Split-Path $File -Leaf
    if (-not $doc.PSObject.Properties['operatorWhy']) { return }
    foreach ($a in $doc.operatorWhy.PSObject.Properties) {
        [pscustomobject]@{ Id = "${name}:$($a.Name)"; Text = [string]$a.Value; Kind = 'descriptive' }
    }
}

# INSTALL-1: the install guide is prose an operator reads before the first
# command, so it is checked like every screen. Markdown is read as: a heading
# is descriptive; a numbered line is an instruction; every other paragraph
# and bullet is descriptive. Fenced code is skipped - a command is not a
# sentence. Inline code, links and emphasis are unwrapped to their text.
function Get-VmfMarkdownStrings {
    param([string]$File)
    $name = Split-Path $File -Leaf
    $lines = Get-Content $File
    $inCode = $false
    $buffer = [System.Collections.Generic.List[string]]::new()
    $kind = 'descriptive'
    $n = 0
    $flush = {
        if ($buffer.Count) {
            $script:mdItems.Add([pscustomobject]@{ Id = "${name}:$n"; Text = ($buffer -join ' '); Kind = $kind; Markdown = $true })
            $buffer.Clear()
        }
    }
    $script:mdItems = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $lines) {
        $n++
        if ($raw -match '^\s*```') { & $flush; $inCode = -not $inCode; continue }
        # MANUAL-REVIEW-1: every line as written, for the rules that read raw
        # text (a lab resource group, a region): code and tables included.
        $script:mdItems.Add([pscustomobject]@{ Id = "${name}:$n"; Text = $raw; Kind = 'raw' })
        if ($inCode) { continue }
        # A one-line HTML comment is never shown to a reader.
        if ($raw -match '^\s*<!--((?!-->).)*-->\s*$') { continue }
        # README-SCOPE-1: a line of HTML (the <picture> that gives a light and
        # a dark image) is markup, not a sentence. Its alt text is what a
        # screen reader says instead of the image, so the alt text is read.
        if ($raw -match '^\s*<') {
            & $flush
            foreach ($alt in [regex]::Matches($raw, '\balt="([^"]*)"')) {
                $script:mdItems.Add([pscustomobject]@{ Id = "${name}:$n"; Text = $alt.Groups[1].Value; Kind = 'descriptive'; Markdown = $true })
            }
            continue
        }
        $line = $raw -replace '`[^`]*`', 'this' -replace '\[([^\]]+)\]\([^)]*\)', '$1' -replace '\*\*([^*]+)\*\*', '$1' -replace '(?<!\w)\*([^*]+)\*(?!\w)', '$1'
        if ($line -match '^\s*$') { & $flush; continue }
        # A table row is not a sentence, but a term in it is still a term
        # (MANUAL-REVIEW-1): kind 'code' answers to the term rules only.
        if ($line -match '^\s*\|') { & $flush; $script:mdItems.Add([pscustomobject]@{ Id = "${name}:$n"; Text = $line.Trim(); Kind = 'code'; Markdown = $true }); continue }
        if ($line -match '^\s*#+\s*(.+)$') { & $flush; $kind = 'descriptive'; $buffer.Add($Matches[1].Trim()); & $flush; continue }
        if ($line -match '^\s*\d+\.\s+(.+)$') { & $flush; $kind = 'instruction'; $buffer.Add($Matches[1].Trim()); continue }
        if ($line -match '^\s*[-*]\s+(.+)$') { & $flush; $kind = 'descriptive'; $buffer.Add($Matches[1].Trim()); continue }
        if (-not $buffer.Count) { $kind = 'descriptive' }
        $buffer.Add($line.Trim())
    }
    & $flush
    $script:mdItems
}

# README-SCOPE-1: the pictures on the README. Every word in them is a word a
# reader reads, and nothing else checked them. A picture spreads one sentence
# over several <text> lines, so a line that does not end a sentence joins the
# next line when that line starts with a small letter. A line that starts
# with a capital, or with a series name such as v5, starts a new item: a
# label, or the next entry of a list. The
# light and dark files hold the same words (ReadmeImages.Tests.ps1), so only
# the light file of each pair is read.
function Get-VmfSvgStrings {
    param([string]$File)
    $name = 'images/' + (Split-Path $File -Leaf)
    $doc = [xml][System.IO.File]::ReadAllText($File)
    $label = $doc.DocumentElement.GetAttribute('aria-label')
    if ($label) { [pscustomobject]@{ Id = "${name}:aria-label"; Text = $label; Kind = 'descriptive' } }
    $buffer = ''
    $i = 0
    foreach ($node in $doc.SelectNodes("//*[local-name()='title' or local-name()='text']")) {
        $line = ($node.InnerText -replace '\s+', ' ').Trim()
        if (-not $line) { continue }
        if ($buffer -and $buffer -notmatch '[.!?:]$' -and $line -cmatch '^[a-z]' -and $line -notmatch '^v\d') { $buffer = "$buffer $line"; continue }
        if ($buffer) { $i++; [pscustomobject]@{ Id = "${name}:$i"; Text = $buffer; Kind = 'descriptive' } }
        $buffer = $line
    }
    if ($buffer) { $i++; [pscustomobject]@{ Id = "${name}:$i"; Text = $buffer; Kind = 'descriptive' } }
}

# HELP-JS-RULE12-1: the words every page shares, in src/dashboard/help.js -
# the sign-in card, the Get help menu, the About dialog (TEXT), and the
# sentence that replaces an error (FAILURES). A page declares its strings one
# per line between markers; help.js joins long ones with '+' across lines and
# builds some in a function, so it has its own reader.
#
# Comments go first, through the one hardened scanner, so a comment that
# quotes a sentence is never read as one. The regular expressions in FAILURES
# go next: "it's" inside one would open a string that never closes.
. (Join-Path $PSScriptRoot '..' 'tests' 'unit' '_CodeOnly.ps1')
$script:JsLiteral = '''(?:[^''\\\r\n]|\\.)*''|"(?:[^"\\\r\n]|\\.)*"|`(?:[^`\\]|\\.)*`'
$script:JsLiteralRun = "(?:$script:JsLiteral)(?:\s*\+\s*(?:$script:JsLiteral))*"

function ConvertFrom-VmfJsLiteralRun {
    param([string]$Run)
    $parts = foreach ($m in [regex]::Matches($Run, $script:JsLiteral)) {
        $v = $m.Value.Substring(1, $m.Value.Length - 2)
        # An escaped quote is the quote a reader sees: "isn\'t" is a
        # contraction. A value filled in at run time (${need}) stays as it
        # is and counts as one word, as {wave} does in start-gates.json.
        $v -replace '\\(.)', '$1'
    }
    -join $parts
}

function Get-VmfHelpScriptStrings {
    param([string]$File)
    $name = Split-Path $File -Leaf
    $code = Get-VmfCodeOnly -Path $File -Language CStyle

    $text = [regex]::Match($code, '(?s)const TEXT = \{(.*?)\n\s*\};')
    if ($text.Success) {
        foreach ($m in [regex]::Matches($text.Groups[1].Value, "(?m)^\s*(\w+)\s*:\s*($script:JsLiteralRun)")) {
            $key = $m.Groups[1].Value
            [pscustomobject]@{
                Id   = "${name}:TEXT.$key"
                Text = ConvertFrom-VmfJsLiteralRun -Run $m.Groups[2].Value
                # The same naming rule as a page's strings.
                Kind = if ($key -match 'Btn$|Button|Next|Back|Action|Do$') { 'instruction' } else { 'descriptive' }
            }
        }
    }

    $failures = [regex]::Match($code, '(?s)const FAILURES = \[(.*?)\n\s*\];')
    if ($failures.Success) {
        $body = [regex]::Replace($failures.Groups[1].Value, 'when:\s*/(?:[^/\\\r\n]|\\.)+/[a-z]*', 'when: null')
        $n = 0
        foreach ($m in [regex]::Matches($body, $script:JsLiteralRun)) {
            $n++
            # Each one tells a person what to do next, so the shorter limit.
            [pscustomobject]@{ Id = "${name}:FAILURES.$n"; Text = ConvertFrom-VmfJsLiteralRun -Run $m.Value; Kind = 'instruction' }
        }
    }
}

# TERMS-AUDIT-1: every string literal the engine, the service, the engine's
# start script and the dashboard scripts hold - the activity lines, the stop
# panels, the report and the refusals all come from these. The gate read none
# of them, so "moves on general capacity" was written in eleven engine files
# and nothing caught it. Comments and help are not read: they are never shown.
# Kind 'code': the term rules only (see Test-VmfTermItem).
function Get-VmfEngineStrings {
    param([string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rel = { param($f) $f.Substring($rootFull.Length + 1) -replace '\\', '/' }
    $psFiles = @(
        foreach ($dir in (Join-Path $Root 'src' 'VmMigrationFactory'), (Join-Path $Root 'src' 'facade'), (Join-Path $Root 'docker')) {
            if (Test-Path $dir) { Get-ChildItem $dir -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } }
        }
    )
    foreach ($f in $psFiles) {
        $name = & $rel $f.FullName
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        # A bare word (a command name, a -Step value) holds no space, so the
        # rule below leaves it out with every other one-word string.
        $found = $ast.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $a -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true)
        foreach ($s in $found) {
            # A string inside a $( ) of a larger string is read with it.
            $up = $s.Parent; $inside = $false
            while ($up) {
                if ($up -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $inside = $true; break }
                $up = $up.Parent
            }
            if ($inside) { continue }
            # A term is two words or more, so a one-word string holds none.
            if ([string]$s.Value -notmatch '\s') { continue }
            [pscustomobject]@{ Id = "${name}:$($s.Extent.StartLineNumber)"; Text = [string]$s.Value; Kind = 'code' }
        }
    }
    $dash = Join-Path $Root 'src' 'dashboard'
    if (Test-Path $dash) {
        foreach ($f in Get-ChildItem $dash -File -Filter '*.js' | Where-Object { $_.Name -notlike '*.min.js' }) {
            $name = & $rel $f.FullName
            $code = Get-VmfCodeOnly -Path $f.FullName -Language CStyle
            $line = 1; $at = 0
            foreach ($m in [regex]::Matches($code, $script:JsLiteral)) {
                $line += ([regex]::Matches($code.Substring($at, $m.Index - $at), "`n")).Count
                $at = $m.Index
                $v = $m.Value.Substring(1, $m.Value.Length - 2) -replace '\\(.)', '$1'
                if ($v -match '\s') { [pscustomobject]@{ Id = "${name}:$line"; Text = $v; Kind = 'code' } }
            }
        }
    }
}

function Get-VmfSources {
    param([string]$Root)
    # Materialised, not deferred: a scriptblock closure gets its own scope and
    # cannot see the functions above it, which is a fine way to spend twenty
    # minutes finding out that every source has zero strings in it.
    $dash = Join-Path $Root 'src' 'dashboard'
    $data = Join-Path $Root 'src' 'VmMigrationFactory' 'data'
    foreach ($page in Get-ChildItem $dash -Filter '*.html') {
        [pscustomobject]@{
            Name  = [IO.Path]::GetFileNameWithoutExtension($page.Name)
            Items = @(Get-VmfUiStrings -File $page.FullName)
        }
    }
    $help = Join-Path $dash 'help.js'
    if (Test-Path $help) {
        [pscustomobject]@{ Name = 'help'; Items = @(Get-VmfHelpScriptStrings -File $help) }
    }
    foreach ($f in 'assessment-reasons.json', 'stop-reasons.json') {
        $full = Join-Path $data $f
        if (Test-Path $full) {
            [pscustomobject]@{
                Name  = [IO.Path]::GetFileNameWithoutExtension($f)
                Items = @(Get-VmfReasonStrings -File $full)
            }
        }
    }
    $gates = Join-Path $data 'start-gates.json'
    if (Test-Path $gates) {
        [pscustomobject]@{ Name = 'start-gates'; Items = @(Get-VmfStartGateStrings -File $gates) }
    }
    $guide = Join-Path $data 'operator-guide.json'
    if (Test-Path $guide) {
        [pscustomobject]@{ Name = 'operator-guide'; Items = @(Get-VmfGuideStrings -File $guide) }
    }
    # PERMISSIONS-WHY-1: the sentence for each Azure action, which the manual's
    # permissions page shows in a table column. A table row answers to the term
    # rules only, so the sentences are read here, from the map, as sentences.
    $rbac = Join-Path $data 'rbac-actions.json'
    if (Test-Path $rbac) {
        [pscustomobject]@{ Name = 'rbac-actions'; Items = @(Get-VmfRbacWhyStrings -File $rbac) }
    }
    $install = Join-Path $Root 'docs' 'install.md'
    if (Test-Path $install) {
        [pscustomobject]@{ Name = 'install-guide'; Items = @(Get-VmfMarkdownStrings -File $install) }
    }
    # README-2: the front door. It is the FIRST page anybody reads, and it was
    # the only operator-facing page this gate did not look at, and it said
    # "so neither route can quietly rot", a metaphor that has no place here.
    #
    # It could not join before DOCS-SPLIT-2, when the layout table and the
    # development commands moved to CLAUDE.md. What is left is a page for a
    # reader, so it is held to the same rule as every other page a reader sees.
    $readme = Join-Path $Root 'README.md'
    if (Test-Path $readme) {
        [pscustomobject]@{ Name = 'README'; Items = @(Get-VmfMarkdownStrings -File $readme) }
    }
    $readmeImages = Join-Path $Root 'docs' 'images' 'readme'
    if (Test-Path $readmeImages) {
        [pscustomobject]@{ Name = 'README-images'; Items = @(Get-ChildItem $readmeImages -Filter '*-light.svg' | Sort-Object Name | ForEach-Object { Get-VmfSvgStrings -File $_.FullName }) }
    }
    # SECURITY-MD-1: the page a person reads to report a vulnerability, and
    # the severity scale and fix deadlines it links to. A reporter is a reader
    # too, so both answer to the same rule as the README.
    $security = Join-Path $Root 'SECURITY.md'
    if (Test-Path $security) {
        [pscustomobject]@{ Name = 'SECURITY'; Items = @(Get-VmfMarkdownStrings -File $security) }
    }
    $securityPolicy = Join-Path $Root 'docs' 'security-policy.md'
    if (Test-Path $securityPolicy) {
        [pscustomobject]@{ Name = 'security-policy'; Items = @(Get-VmfMarkdownStrings -File $securityPolicy) }
    }
    # TERMS-AUDIT-1: the engine's own strings, for the term rules.
    [pscustomobject]@{ Name = 'engine-strings'; Items = @(Get-VmfEngineStrings -Root $Root) }
    # DOC-4: the manual, every page. One source per page, named by its path
    # under docs/manual, so a finding says which page to open.
    $manual = Join-Path $Root 'docs' 'manual'
    if (Test-Path $manual) {
        foreach ($page in Get-ChildItem $manual -Filter '*.md' -Recurse | Where-Object { $_.Name -ne '_sidebar.md' }) {
            $rel = $page.FullName.Substring($manual.Length + 1) -replace '\\', '/'
            [pscustomobject]@{ Name = "manual/$rel"; Items = @(Get-VmfMarkdownStrings -File $page.FullName) }
        }
    }
}

# ---------------------------------------------------------------------------
# The rules.
# ---------------------------------------------------------------------------
function Split-VmfSentences {
    param([string]$Text)
    # Deliberately simple. A sentence ends at . ! ? followed by a space or the
    # end. Abbreviations are rare in this copy and a false split only makes the
    # length rule kinder.
    ($Text -split '(?<=[.!?])\s+') | Where-Object { $_.Trim() }
}

# FILTER-DRIVER-READ-1 (2026-11-14): a sentence of Microsoft's, quoted
# word for word, is Microsoft's text - not ours to rewrite - so the rules do
# not read inside it. Only a quote in double quotation marks, of 8 words or
# more, that ONE pinned Microsoft page (docs/upstream-docs) holds byte for
# byte - case, spaces and marks as on the page (ROLLBACK-CAPACITY-1 review,
# 2026-11-15: no spaces made one, no text joined across two pages). The one
# change: a page string's escape ("aren\'t") is read as the letter it
# writes. Anything else in quotation marks is read as usual. The quote counts
# as one word, and its last mark stays, so the sentence around it is still
# read.
$script:UpstreamPages = $null
function Remove-VmfVerifiedQuote {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text) -or $Text -notmatch '"') { return $Text }
    if ($null -eq $script:UpstreamPages) {
        $up = Join-Path $Path 'docs' 'upstream-docs'
        $script:UpstreamPages = if (Test-Path $up) {
            @(Get-ChildItem $up -Recurse -File -Filter '*.md' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
        } else { @() }
    }
    [regex]::Replace($Text, '"([^"]+)"', {
            param($m)
            # A page string keeps its escapes: "aren\'t" is the word aren't.
            $q = $m.Groups[1].Value -replace '\\(.)', '$1'
            $words = @($q -split ' ' | Where-Object { $_ -match '\w' }).Count
            $onPage = $false
            if ($words -ge 8) {
                foreach ($page in $script:UpstreamPages) { if ($page.Contains($q, [System.StringComparison]::Ordinal)) { $onPage = $true; break } }
            }
            if ($onPage) {
                $end = if ($q -match '([.!?])$') { $Matches[1] } else { '' }
                "quoted$end"
            } else { $m.Value }
        })
}
function Test-VmfTermItem {
    # TERMS-AUDIT-1: the banned terms and the phrasal verbs. The only rules an
    # engine string answers to: its sentences are built from parts at run
    # time, so the length and sentence rules cannot read them.
    param([pscustomobject]$Item)
    # MANUAL-REVIEW-1: a raw line of a manual page answers only to a rule that
    # reads raw text, and such a rule reads a manual page only through its raw
    # lines - so one fact gives one finding, not two.
    $markdown = [bool]($Item.PSObject.Properties['Markdown'] -and $Item.Markdown)
    foreach ($t in $script:Terms) {
        if ($Item.Kind -eq 'raw' -and -not $t.RawText) { continue }
        if ($markdown -and $t.RawText) { continue }
        # An entry's 'except' is a name somebody else gave - the title of a
        # Microsoft page, quoted in a link - and it is Azure's word, not ours.
        $text = Remove-VmfVerifiedQuote -Text $Item.Text
        foreach ($x in $t.Except) { $text = [regex]::Replace($text, [regex]::Escape([string]$x), ' ', 'IgnoreCase') }
        $m = $t.Regex.Match($text)
        if ($m.Success) {
            $what = if ($t.Rule -eq 'banned-term') { 'an invented term' } else { 'a phrasal verb' }
            [pscustomobject]@{ Rule = $t.Rule; Id = $Item.Id; Detail = "'$($m.Value)' is $what - write $($t.Use)"; Text = $Item.Text; Pattern = $t.Regex.ToString() }
        }
    }
}

function Test-VmfItem {
    param([pscustomobject]$Item)

    Test-VmfTermItem -Item $Item
    if ($Item.Kind -in 'code', 'raw') { return }

    $text = Remove-VmfVerifiedQuote -Text $Item.Text
    # Strip the technical names before the jargon scan so that a permitted name
    # containing a banned substring cannot trip it.
    $stripped = $text
    foreach ($n in $script:TechnicalNames) { $stripped = $stripped -replace [regex]::Escape($n), ' ' }

    foreach ($b in $script:EngineJargon) {
        $hit = if ($b -cmatch '^[A-Z0-9-]+$') { $stripped -cmatch [regex]::Escape($b) } else { $stripped -match [regex]::Escape($b) }
        if ($hit) { [pscustomobject]@{ Rule = 'jargon'; Id = $Item.Id; Detail = "uses engine vocabulary '$b'"; Text = $text } }
    }

    if ($text -cmatch $script:CommandPattern) {
        [pscustomobject]@{ Rule = 'jargon'; Id = $Item.Id; Detail = "names the command '$($Matches[0])' - name the button in the app"; Text = $text }
    }

    if ($text -match $script:ScriptPattern) {
        [pscustomobject]@{ Rule = 'jargon'; Id = $Item.Id; Detail = "names the script '$($Matches[0])' - name the page in the app"; Text = $text }
    }

    foreach ($v in $script:VagueOrIdiom) {
        if ($text -match "(?i)\b$([regex]::Escape($v))\b") {
            [pscustomobject]@{ Rule = 'vague'; Id = $Item.Id; Detail = "says '$v', which points at nothing a reader can act on"; Text = $text }
        }
    }

    foreach ($rule in $script:ProductWords) {
        foreach ($alt in $rule.Instead) {
            # A DEFINITION uses both words on purpose - "A wave is a group of
            # machines that move together" teaches the noun rather than dodging
            # it. Only a SUBSTITUTION is a fault, so a match introduced by the
            # concept word and "is a" is left alone.
            if ($text -match "(?i)\b$($rule.Concept)\w*\s+is\s+an?\s+\w*\s*$alt") { continue }
            if ($stripped -match "(?i)$alt") {
                [pscustomobject]@{ Rule = 'product-word'; Id = $Item.Id
                    Detail = "invents a word for '$($rule.Concept)' - this product says '$($rule.Use)'"
                    Text = $text }
            }
        }
    }

    foreach ($rule in $script:OneWordOneMeaning) {
        foreach ($alt in $rule.Instead) {
            # $stripped, not $text: 'audit log' is Entra's own name for a thing
            # this product does not have a word of its own for, and banning
            # 'audit' inside it would be the same mistake as banning 'NVMe'.
            if ($stripped -cmatch $alt) {
                [pscustomobject]@{ Rule = 'one-word'; Id = $Item.Id; Detail = "matches $alt - this product says '$($rule.Use)'"; Text = $text }
            }
        }
    }

    $contraction = [regex]::Matches($text, $script:ContractionPattern) |
        Where-Object { $_.Value -notin $script:AllowedApostrophe } |
        Where-Object { $_.Value -notmatch "^\w+'s$" -or $_.Value -match "^(it|that|there|what|who|he|she)'s$" }
    foreach ($c in $contraction) {
        [pscustomobject]@{ Rule = 'contraction'; Id = $Item.Id; Detail = "'$($c.Value)' - use the full form"; Text = $text }
    }

    # Prose must be prose - but a STATUS LABEL is not prose. "Switching the
    # virtual machine to its new size" is a clean phrase doing its job, and
    # demanding a full stop on it would be pedantry.
    #
    # What is actually wrong in the strings found in review is narrower
    # and always one of two shapes:
    #   "Search your directory, pick a role, done"   - comma-spliced fragments
    #   "One resource group - the smallest choice"   - a dash-appended aside
    # Both are captions pretending to be help. So the rule fires on a long
    # string with no full stop that ALSO carries one of those shapes.
    $wordCount = @($text -split '\s+' | Where-Object { $_ -match '\w' }).Count
    if ($wordCount -ge $script:SentenceFloorWords -and $text.Trim() -notmatch '[.!?:]$') {
        $commas = @([regex]::Matches($text, ',')).Count
        $dashAside = $text -match '\s-\s'
        if ($commas -ge 2 -or $dashAside) {
            $why = if ($dashAside) { 'an aside hung off a dash' } else { 'comma-spliced fragments' }
            [pscustomobject]@{ Rule = 'not-a-sentence'; Id = $Item.Id
                Detail = "$why, and no full stop - write it as a sentence"
                Text = $text }
        }
    }

    $max = if ($Item.Kind -eq 'instruction') { $script:MaxWordsInstruction } else { $script:MaxWordsDescriptive }
    foreach ($s in Split-VmfSentences -Text $text) {
        $words = @($s -split '\s+' | Where-Object { $_ -match '\w' }).Count
        if ($words -gt $max) {
            [pscustomobject]@{ Rule = 'long-sentence'; Id = $Item.Id; Detail = "$words words (limit $max for $($Item.Kind))"; Text = $s }
        }
    }
}

# ---------------------------------------------------------------------------

$sources = @(Get-VmfSources -Root $Path)
if ($Source) { $sources = @($sources | Where-Object { $_.Name -eq $Source }) }

if ($ListSources) {
    $sources | ForEach-Object { '{0,-22} {1} string(s)' -f $_.Name, $_.Items.Count }
    return
}
if (-not $sources) { throw "no such source '$Source' - run with -ListSources" }

$waived = [System.Collections.Generic.List[object]]::new()
$findings = foreach ($s in $sources) {
    foreach ($item in $s.Items) {
        foreach ($f in @(Test-VmfItem -Item $item)) {
            if (-not $f) { continue }
            $owner = if ($f.PSObject.Properties['Pattern']) {
                $script:Pending | Where-Object {
                    $_.Source -eq $s.Name -and $_.Pattern -eq $f.Pattern -and
                    (-not $_.IdPrefix -or $f.Id.StartsWith($_.IdPrefix, [StringComparison]::Ordinal))
                } | Select-Object -First 1
            }
            if ($owner) { $waived.Add(($f | Add-Member -NotePropertyName Source -NotePropertyValue $s.Name -PassThru -Force)); continue }
            $f
        }
    }
}
$findings = @($findings)

if (-not $findings) {
    Write-Host 'Simplified Technical English: no findings.' -ForegroundColor Green
    return [pscustomobject]@{ Findings = @(); Count = 0; Waived = @($waived) }
}

Write-Host "ASD-STE100 findings: $($findings.Count)" -ForegroundColor Yellow
foreach ($g in $findings | Group-Object Rule | Sort-Object Count -Descending) {
    Write-Host ("`n{0} ({1})" -f $g.Name, $g.Count) -ForegroundColor Cyan
    $show = if ($Detailed) { $g.Group } else { $g.Group | Select-Object -First 6 }
    foreach ($f in $show) {
        Write-Host ("  {0}`n    {1}`n    > {2}" -f $f.Id, $f.Detail, ($f.Text -replace '\s+', ' '))
    }
    if (-not $Detailed -and $g.Count -gt 6) { Write-Host "  ... $($g.Count - 6) more (use -Detailed)" }
}
[pscustomobject]@{ Findings = $findings; Count = $findings.Count; Waived = @($waived) }
