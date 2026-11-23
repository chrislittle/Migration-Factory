<#
.SYNOPSIS
    DOC-4: write the manual's four generated reference pages from the
    product's own data files, so the manual can never disagree with the screen.
.DESCRIPTION
    The dashboard shows every assessment finding and every stop reason from
    src/VmMigrationFactory/data/*.json, and the two custom roles are derived
    from rbac-actions.json. The manual's reference pages for the same things
    are generated HERE from the same files - one copy of the words. A test
    fails when the generated pages are stale (run this and commit).
    SUPPORT-MATRIX-1: the fourth page, the support matrix, is generated from
    target-families.json, supported-images.json, driver-floors.json and
    assessment-reasons.json, and from the planner's own functions.
.EXAMPLE
    ./tools/Update-VmfManualReference.ps1
#>
[CmdletBinding()]
param([Parameter()][switch]$Check)
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$data = Join-Path $repoRoot 'src' 'VmMigrationFactory' 'data'
$out = Join-Path $repoRoot 'docs' 'manual' 'reference'

function Write-Page {
    param([string]$Name, [string]$Text)
    $path = Join-Path $out $Name
    $current = if (Test-Path $path) { [System.IO.File]::ReadAllText($path) } else { '' }
    # DOCS-NEXT-1: two generators write these three pages. THIS one owns the
    # body; tools/Update-VmfManualNextSteps.ps1 owns the Next footer at the end.
    # Rewriting the whole file would delete that footer, and the page would
    # become a dead end again every time the data changed. So the footer is
    # carried across, and neither generator has to run before the other.
    $footer = [regex]::Match($current, '(?s)\s*<!-- next:begin -->.*?<!-- next:end -->\s*$').Value
    # Exactly the layout Update-VmfManualNextSteps.ps1 writes: body, a blank
    # line, the footer, one newline. Anything else reads as stale for ever.
    if ($footer) { $Text = $Text.TrimEnd("`n") + "`n`n" + $footer.Trim() + "`n" }
    if ($current -eq $Text) { Write-Host "  $Name unchanged"; return $true }
    if ($Check) { Write-Host "  $Name is STALE"; return $false }
    [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  $Name written"
    return $true
}

# ---- assessment findings ------------------------------------------------------------
# MANUAL-V5-1: the line the dashboard's report card shows under a finding that
# names some size series only (seriesLine in src/dashboard/assessment-report.js).
# The same rule: nothing for a finding that applies to every series or to none
# recorded; the v5 sentence only when v5 is not one of them.
function Get-SeriesLine {
    param($AppliesTo)
    $set = @(@($AppliesTo) | Where-Object { $_ })
    if (-not $set.Count) { return '' }
    if (@('v5', 'v6', 'v7' | Where-Object { $set -notcontains $_ }).Count -eq 0) { return '' }
    $series = $set -join ' and '
    if ($set -contains 'v5') { "This applies to $series only." }
    else { "This applies to $series only. A move to v5 does not need this." }
}
function Get-FindingText {
    param($Reason)
    $text = "`n### $($Reason.title)`n`n$($Reason.meaning)`n`n"
    $line = Get-SeriesLine -AppliesTo $Reason.appliesTo
    # MANUAL-REVIEW-1: the page file also moves on a v5 or Bsv2 move to a size
    # with no temporary disk (StateMachine.ps1 GUEST_PREP; tests/fixtures/
    # prep-by-target.json). appliesTo stays v6 and v7, because the page and the
    # engine judge v5 by the target size, so the line says it here.
    if ($Reason.title -eq 'Page file is on the temporary disk') { $line = 'This applies to v6 and v7, and to a v5 or Bsv2 size with no temporary disk.' }
    if ($line) { $text += "**$line**`n`n" }
    $text += "**What to do:** $($Reason.whatToDo)`n`n"
    if ($Reason.docs -and $Reason.docs.url) { $text += "Read more: [$($Reason.docs.label)]($($Reason.docs.url))`n`n" }
    $text
}
$reasons = Get-Content (Join-Path $data 'assessment-reasons.json') -Raw | ConvertFrom-Json
$sb = [System.Text.StringBuilder]::new()
$null = $sb.Append(@"
# What an assessment can find

Every finding an assessment can give, in the words the dashboard uses. This page is generated from the product's own list, so it always matches the screen.

An assessment gives four kinds of answer. A machine that **another platform owns** is left alone: the assessment names it and does nothing more. A finding that **holds a machine back** means the machine cannot migrate, to every size series or to some, until somebody acts. A finding under **what to check before the move** lets the machine move, after a person checks the thing it names. A finding that says **what the product will prepare** means the product does it itself during the migration, and nothing needs doing first.

The assessment also gives each machine a **workload type**, with the Azure facts that decided it. The last part of this page names each type.

## What the assessment leaves alone

The assessment names these machines and never plans a move for them. A machine that another Azure service manages changes its size through that service.

"@)
foreach ($entry in $reasons.excluded.PSObject.Properties) {
    $r = $entry.Value
    $null = $sb.Append("`n### $($r.title)`n`n$($r.meaning)`n`n**What to do:** $($r.whatToDo)`n`n")
    if ($r.docs -and $r.docs.url) { $null = $sb.Append("Read more: [$($r.docs.label)]($($r.docs.url))`n`n") }
}
$null = $sb.Append(@"
## What holds a machine back

A finding that applies to every size series stops the machine. A finding that names some size series closes only those, and the machine can still move to the others. The report shows that kind under **What limits the target**. It counts the machine under **Some targets only** while at least one size series stays open to it. When the findings close every series, it counts the machine under **Cannot yet**.

"@)
foreach ($entry in $reasons.blockers.PSObject.Properties) {
    $null = $sb.Append((Get-FindingText -Reason $entry.Value))
}
# DETECT-PATTERNS-1: the warnings - the machine may still move.
$null = $sb.Append(@"
## What to check before the move

These findings do not stop the machine. A person checks the thing that each one names before the migration starts.

"@)
foreach ($entry in $reasons.warnings.PSObject.Properties) {
    $null = $sb.Append((Get-FindingText -Reason $entry.Value))
}
$null = $sb.Append("## What the product will prepare`n")
foreach ($entry in $reasons.prep.PSObject.Properties) {
    $null = $sb.Append((Get-FindingText -Reason $entry.Value))
}
$null = $sb.Append(@"
## What the assessment records without judging

Some facts are written on the machine's record and left for the planning step, because whether they matter depends on the target size.

- **Accelerated networking.** How many network interfaces have it on. A move to v5, v6 or v7 turns it on for the primary network interface, and leaves the other interfaces as they were. Microsoft requires it on every v6 size and on the Intel D-family and E-family v5 sizes. A move never turns it off. A Linux machine whose kernel has no MANA driver does not move to a size that can give MANA. The wave settings name each machine that gets it turned on, for any reason.
- **Disk encryption.** The scan reads Azure Disk Encryption from the operating system disk, so an encrypted machine is named in the report. The setting is recorded per disk, so a machine encrypted only on its data disks does not appear here. The product asks Azure again before a move to v6 or v7 and before an in-place upgrade (Preview). A machine that has it stops before anything is changed.
- **Infrastructure code.** The assessment does not guess whether Terraform, Bicep or another tool defines a machine. You confirm once per migration that you will update your definitions afterwards.

## Workload types

Microsoft sorts workloads into patterns for the move to v6 and v7. The pattern tells you how a machine moves. The assessment gives each machine one of these types, in this order, and shows the Azure field and the value that decided it.

| Workload type | How it moves |
|---|---|

"@)
# A here-string drops the newline before its end, so the empty line above is
# what puts the first row on a line of its own (review, DETECT-PATTERNS-1).
# DETECT-PATTERNS-1: one row per workload type, from the same data as the screen.
foreach ($entry in $reasons.workloadTypes.PSObject.Properties) {
    $null = $sb.Append("| $($entry.Value.title) | $($entry.Value.meaning) |`n")
}
$null = $sb.Append(@"

A value of **not read** in the facts means that the scan could not read that fact. Then the type is **Type not checked**, never **Standalone machine**.

## What no fact in Azure shows

The assessment cannot find these workloads, because Azure records no fact about them. Look for them yourself before you plan a wave:

- Active Directory domain controllers.
- Self-hosted build agents on single machines.
- NoSQL and search clusters, for example Cassandra, MongoDB or Elasticsearch.
- An Oracle database with Data Guard.
- Omnissa Horizon (VMware Horizon) desktops.
- Veeam or Commvault software that somebody installed on an ordinary machine, not from the vendor's image.
- Service Fabric, HDInsight and Citrix. Microsoft's pages name a fact for each, but the product does not read them.
- A machine in an Azure CycleCloud cluster that does not have the tags that CycleCloud adds, for example because somebody removed them.

A domain controller and a cluster move one machine at a time. Microsoft's page for these patterns tells you how: [Microsoft: workload modernization categories](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-discover)

"@)
$ok = Write-Page -Name 'assessment-findings.md' -Text $sb.ToString()

# ---- stop reasons ------------------------------------------------------------------------
$stops = Get-Content (Join-Path $data 'stop-reasons.json') -Raw | ConvertFrom-Json
$machineWords = @{
    untouched = 'Nothing on this machine was changed.'
    restored  = 'The machine was rolled back to how it was.'
    notBack   = 'The machine is NOT as it was. Read the whole entry before trying again.'
}
$retryWords = @{
    afterFix      = 'Correct what the entry names, then try the machine again.'
    whenAvailable = 'There is nothing to correct. Try again later.'
    unlikely      = 'If you do not correct the cause first, the machine can stop again for the same reason.'
    notSupported  = 'This version of the product cannot migrate this machine.'
    # RETIRE-SCOPE-1: a scope choice, said as scope.
    outOfScope    = 'This machine is outside the scope of this tool. Trying again changes nothing.'
    # DECIDE-1: the stop that is a choice. The other four all answer "try
    # again?" with a fault to correct, a wait, or a refusal. This one has no
    # fault at all, so it takes a different QUESTION as well as a different
    # answer - the page said "Try again? Correct what the entry names, then
    # try the machine again" for a stop where nothing can be corrected.
    decision      = 'An approver accepts this for this machine, or the machine leaves the run. Trying again changes nothing.'
}
$retryLabels = @{ decision = 'Your decision:' }
$sb = [System.Text.StringBuilder]::new()
$null = $sb.Append(@"
# Why a machine stopped

Every reason a machine can stop, in the words the dashboard uses. This page is generated from the product's own list, so it always matches the screen.

For each reason: what it means, what state the machine is in, what to do, and whether trying again makes sense. The machine's own panel on the migration page shows the same words. The recorded state for that machine wins over the usual state given here.

"@)
foreach ($r in $stops.reasons) {
    $state = if ($machineWords.ContainsKey([string]$r.machine)) { $machineWords[[string]$r.machine] } else { [string]$r.machine }
    # PREP-ROLLBACK-1: a stop that is untouched or rolled back by what came before it.
    $varies = $r.PSObject.Properties['machineVaries'] -and $r.machineVaries
    if ($varies) { $state = 'Nothing was changed, or the product rolled the machine back. The panel of the machine says which.' }
    # STOP-POWER-WORDS-1: a stop that returns the machine to the power state
    # Checking found records it changed when that return fails - so the line
    # names that case too, and never a rollback the stop does not have.
    if ($r.PSObject.Properties['machinePowerBack'] -and $r.machinePowerBack) {
        $powerBack = 'the machine is not in its power state from before the move. The panel of the machine says which.'
        $state = if ($varies) { "Nothing was changed, the product rolled the machine back, or $powerBack" } else { "Nothing on this machine was changed, or $powerBack" }
        # ROLLBACK-CAPACITY-1 review: a rolled-back stop whose start Azure
        # refused (rollbackNoCapacity) leaves the machine stopped - one fact.
        if ([string]$r.machine -eq 'restored' -and -not $varies) { $state = 'The machine is rolled back and stopped.' }
    }
    $retry = if ($retryWords.ContainsKey([string]$r.retry)) { $retryWords[[string]$r.retry] } else { [string]$r.retry }
    $label = if ($retryLabels.ContainsKey([string]$r.retry)) { $retryLabels[[string]$r.retry] } else { 'Try again?' }
    $null = $sb.Append("## $($r.title)`n`n$($r.meaning)`n`n**The machine:** $state`n`n**What to do:** $($r.whatToDo)`n`n**$label** $retry`n`n")
}
$ok = (Write-Page -Name 'stop-reasons.md' -Text $sb.ToString()) -and $ok

# ---- permissions ---------------------------------------------------------------------------
$rbac = Get-Content (Join-Path $data 'rbac-actions.json') -Raw | ConvertFrom-Json
$sb = [System.Text.StringBuilder]::new()
$null = $sb.Append(@"
# What the product may do in Azure

The install creates two custom roles in your subscription. Each contains exactly the operations the product performs, listed here from the product's own map. The product holds a role only where it is granted.

The install asks what the product may do with the machines in the install subscription. Unless the answer is no access, the install grants that role on the whole subscription. An administrator grants the roles on other places on the Admin page: a management group, a subscription or a resource group. Azure allows the roles at one management group at most. The product cannot grant itself anything.

A network interface can use a subnet, a network security group, a public IP address or a load balancer in another resource group. Then grant $($rbac.roles.execute.roleName) there too.

## $($rbac.roles.assess.roleName)

Read-only. It discovers and inspects machines so a migration can be planned. It contains nothing that can change anything, so it is safe to grant broadly.

The operations it contains, in Azure's own names, and when the product uses each one:

| Operation | When the product uses it |
|---|---|

"@)
# PERMISSIONS-WHY-1: the sentence for each action is the map's operatorWhy, one
# ASD-STE100 sentence that names the step or the page. tests/unit/
# PermissionsWhy.Tests.ps1 fails an action with none: a security reviewer asks
# why the product holds each one.
function Get-OperatorWhy {
    param([string]$Action)
    if ($rbac.PSObject.Properties['operatorWhy'] -and $rbac.operatorWhy.PSObject.Properties[$Action]) { [string]$rbac.operatorWhy.$Action } else { '' }
}
$assess = @($rbac.operations | Where-Object { $_.role -eq 'assess' -and @($_.actions).Count } | ForEach-Object { $_.actions } | Sort-Object -Unique)
# TEMP-DISK-PREVIEW-1: an action the map marks requiredFor preview is needed only for that move.
$forPreview = @($rbac.operations | Where-Object { $_.PSObject.Properties['requiredFor'] -and [string]$_.requiredFor -eq 'preview' } | ForEach-Object { $_.actions })
# REBUILD-REMOVE-ROLE-1: the note for an action required only for a rebuild
# (DCR-READ-1) is gone with the last such action.
foreach ($a in $assess) {
    $note = if ($forPreview -contains $a) { ' Only the in-place upgrade (Preview) needs it. The product never registers the feature.' }
            else { '' }
    $null = $sb.Append("| ``$a`` | $(Get-OperatorWhy -Action $a)$note |`n")
}
$null = $sb.Append(@"

## $($rbac.roles.execute.roleName)

Everything the assessment role can do, plus the writes a migration performs: stop, resize, snapshot, swap disks, run scripts inside the machine. Grant it as narrowly as the estate allows.

It contains every operation of the assessment role, plus these:

| Operation | When the product uses it |
|---|---|

"@)
$optional = @($rbac.operations | Where-Object { $_.role -eq 'execute' -and $_.PSObject.Properties['optional'] -and $_.optional } | ForEach-Object { $_.actions })
$exec = @($rbac.operations | Where-Object { $_.role -eq 'execute' -and @($_.actions).Count } | ForEach-Object { $_.actions } | Sort-Object -Unique)
foreach ($a in $exec) {
    $note = if ($optional -contains $a) { ' It is optional: the product works without it, and the dashboard says when it is missing.' } else { '' }
    $null = $sb.Append("| ``$a`` | $(Get-OperatorWhy -Action $a)$note |`n")
}
# RESTORE-PERM-MACHINE-1: the operations the map marks restore, which Restore
# this machine reads on the machine before it makes a disk or stops it.
$null = $sb.Append(@"

## What Restore this machine reads first

Before **Restore this machine** makes a disk or stops the machine, the product reads the permissions of its managed identity on the machine. If one of these operations is missing, the restore stops before it changes the machine:


"@)
$restoreOps = @($rbac.operations | Where-Object { $_.PSObject.Properties['restore'] -and $_.restore -eq $true } | ForEach-Object { $_.actions } | Sort-Object -Unique)
foreach ($a in $restoreOps) { $null = $sb.Append("- ``$a```n") }
# Single quotes: a doubled backtick before the a in an expandable string reads as an escape to the hygiene check.
$secretsContainer = '`azure-webjobs-secrets`'
$null = $sb.Append(@"

## What people hold

A person holds a role in the product, given on the Admin page. A person needs no right in Azure to use the product, because the service reads the migration records for them. An administrator who grants access on the Admin page needs Owner or User Access Administrator at that place.

## What the product's own identities hold

Each identity of the product, and each role it holds, is in [Security](../technical/security.md#who-is-who).

## Keys

No part of the product signs in with a password or a key. Every part signs in with an identity Azure manages, and every person signs in as themselves. Two logging settings hold a key. The service has the Application Insights connection string, and Application Insights refuses its key. The Container Apps environment has the key of the Log Analytics workspace. The Functions host of the service also makes its own host keys. It keeps them in the container $secretsContainer. No function of the service accepts a key. See [Security](../technical/security.md#no-secrets).
"@)
$ok = (Write-Page -Name 'permissions.md' -Text $sb.ToString()) -and $ok

# ---- support matrix -----------------------------------------------------------------------
# SUPPORT-MATRIX-1 (2026-10-25): one page that says which machines the
# product moves and which it does not. Every fact on it comes from the data the
# product reads, or from the planner's own functions asked about an example
# size. So the page and the planner cannot give two answers, and
# tests/unit/SupportMatrix.Tests.ps1 fails when a data row does not reach the
# page. Three things are written here by hand, and each says so where it is:
# the example size of each source series, the Windows Server years of the two
# Windows rules (Rules.ps1 holds them as numbers, and a test reads them there),
# and the Arm64 row, which has no reason of its own in assessment-reasons.json.
# SUPPORT-MATRIX-2: the row for a machine changed to Generation 2 by the
# Trusted Launch upgrade, labelled Experimental, is gone. The product offers no
# route from Generation 1 to Generation 2 (2026-10-31).
#
# The planner's functions load into a module of their own that exports
# nothing. That never replaces the VmMigrationFactory module a test session has
# loaded, so a test that runs this tool keeps its mocks (TEST-AZURE-GUARD-2).
$engine = New-Module -Name 'VmfSupportMatrixRules' -ArgumentList (Join-Path $repoRoot 'src' 'VmMigrationFactory') -ScriptBlock {
    param([string]$ModuleRoot)
    # As VmMigrationFactory.psm1 loads them: every error stops.
    $ErrorActionPreference = 'Stop'
    foreach ($file in @(Get-ChildItem (Join-Path $ModuleRoot 'Private'), (Join-Path $ModuleRoot 'Public') -Filter '*.ps1' -Recurse)) { . $file.FullName }
    Export-ModuleMember -Function @()
}
$families = Get-Content (Join-Path $data 'target-families.json') -Raw | ConvertFrom-Json
$images = Get-Content (Join-Path $data 'supported-images.json') -Raw | ConvertFrom-Json
$floors = Get-Content (Join-Path $data 'driver-floors.json') -Raw | ConvertFrom-Json
$nvmeLinux = Get-Content (Join-Path $data 'nvme-linux-releases.json') -Raw | ConvertFrom-Json
$releaseEol = Get-Content (Join-Path $data 'linux-release-eol.json') -Raw | ConvertFrom-Json

# A Microsoft page that target-families.json names by key (the end of its address).
function Get-SourceLink {
    param([string]$Key)
    $src = @($families.sources | Where-Object { ([string]$_.url).TrimEnd('/') -match "/$([regex]::Escape($Key))$" }) | Select-Object -First 1
    if (-not $src) { throw "target-families.json has no source whose address ends in '$Key'." }
    "[Microsoft: $($Key -replace '-', ' ')]($($src.url))"
}
function Get-DocsLink { param($Reason) "[$($Reason.docs.label)]($($Reason.docs.url))" }
function Join-Words {
    param([string[]]$Words)
    $w = @($Words | Where-Object { $_ })
    if ($w.Count -le 1) { return ($w -join '') }
    (($w | Select-Object -First ($w.Count - 1)) -join ', ') + ' or ' + $w[-1]
}
# A cell never holds the table's own separator.
function Format-Cell { param([string]$Text) ($Text -replace '\|', '/').Trim() }

$burstRow = @($families.burstableTargets.series)[0]
$targetSeries = @($families.generations.PSObject.Properties.Name)
# The column "v6 and v7" joins two series. A rule that closes one and not the
# other would be shown wrongly, so the tool stops instead.
foreach ($entry in $reasons.blockers.PSObject.Properties) {
    $applies = @($entry.Value.appliesTo)
    if (($applies -contains 'v6') -ne ($applies -contains 'v7')) { throw "The finding $($entry.Name) closes only one of v6 and v7. The support matrix joins them, so it must change first." }
}

# -- source sizes --
# The series groups, and one example size of each, written here. The example is
# how this tool ASKS the planner: the stage, the retirement date and where the
# machine goes all come from the planner's functions.
$sourceGroups = @(
    @{ Series = 'Basic and Standard A-series (A v1)'; Example = 'Standard_A2' }
    @{ Series = 'Av2'; Example = 'Standard_A2_v2' }
    @{ Series = 'Amv2'; Example = 'Standard_A2m_v2' }
    @{ Series = 'B v1 (Bs, Bms, Bls)'; Example = 'Standard_B2s' }
    @{ Series = 'D-series (D v1)'; Example = 'Standard_D2' }
    @{ Series = 'DS-series (DS v1)'; Example = 'Standard_DS2' }
    @{ Series = 'Dv2'; Example = 'Standard_D2_v2' }
    @{ Series = 'DSv2'; Example = 'Standard_DS2_v2' }
    @{ Series = 'F'; Example = 'Standard_F2' }
    @{ Series = 'Fs'; Example = 'Standard_F2s' }
    @{ Series = 'Fsv2'; Example = 'Standard_F2s_v2' }
    @{ Series = 'Dv3, Dsv3'; Example = 'Standard_D2s_v3' }
    @{ Series = 'Ev3, Esv3'; Example = 'Standard_E2s_v3' }
    @{ Series = 'Dv4'; Example = 'Standard_D2_v4' }
    @{ Series = 'Ddv4'; Example = 'Standard_D2d_v4' }
    @{ Series = 'Dsv4, Ddsv4'; Example = 'Standard_D2ds_v4' }
    @{ Series = 'Dav4'; Example = 'Standard_D2a_v4' }
    @{ Series = 'Dasv4'; Example = 'Standard_D2as_v4' }
    @{ Series = 'Ev4'; Example = 'Standard_E2_v4' }
    @{ Series = 'Edv4'; Example = 'Standard_E2d_v4' }
    @{ Series = 'Esv4, Edsv4'; Example = 'Standard_E2ds_v4' }
    @{ Series = 'Eav4'; Example = 'Standard_E2a_v4' }
    @{ Series = 'Easv4'; Example = 'Standard_E2as_v4' }
    @{ Series = 'Dv5'; Example = 'Standard_D2_v5' }
    @{ Series = 'Ddv5'; Example = 'Standard_D2d_v5' }
    @{ Series = 'Dsv5, Ddsv5'; Example = 'Standard_D2ds_v5' }
    @{ Series = 'Dlsv5, Dldsv5'; Example = 'Standard_D2lds_v5' }
    @{ Series = 'Dasv5, Dadsv5'; Example = 'Standard_D2ads_v5' }
    @{ Series = 'Dalsv5, Daldsv5'; Example = 'Standard_D2alds_v5' }
    @{ Series = 'Ev5'; Example = 'Standard_E2_v5' }
    @{ Series = 'Edv5'; Example = 'Standard_E2d_v5' }
    @{ Series = 'Esv5, Edsv5'; Example = 'Standard_E2ds_v5' }
    @{ Series = 'Ebsv5, Ebdsv5'; Example = 'Standard_E2bds_v5' }
    @{ Series = 'Easv5, Eadsv5'; Example = 'Standard_E2ads_v5' }
)
# Get-VmfShapeSizeChoices offers the Dl, D and E families only.
# SUPPORT-MATRIX-2 (2026-10-31, "a Dl" read as a family): never "a Dl",
# which reads as a family named ADl. The page says what Dl is above the tables.
$byShape = 'a size in the Dl, D or E family: the smallest with at least the machine''s vCPUs and memory.'
# SUPPORT-MATRIX-2 (a target depends on the generation): every cell
# that gives a target says the generations that series takes, from the data,
# so a reader of one row cannot take a Generation 1 machine to v6.
function Get-GenerationWords {
    param($HyperV)
    if (@($HyperV) -contains 'V1') { 'Generation 1 and Generation 2' } else { 'Generation 2 only' }
}
$bt = $burstRow.traits
$v5Gens = @(@($families.generations.v5.hyperVGenerations) | Where-Object { @($bt.hyperVGenerations) -contains $_ })
$v67Gens = @(@($families.generations.v6.hyperVGenerations) | Where-Object { @($families.generations.v7.hyperVGenerations) -contains $_ })
$v5GenWords = Get-GenerationWords $v5Gens
$v67GenWords = Get-GenerationWords $v67Gens
$sourceRows = foreach ($g in $sourceGroups) {
    $ex = $g.Example
    $facts = & $engine {
        param($Size, $Families, $Burst)
        @{
            Stage       = Get-VmfSizeLifecycleStage -SizeName $Size -Families $Families
            Retirement  = Get-VmfSizeRetirement -SizeName $Size -Families $Families
            ByShape     = Test-VmfShapeChoiceSource -SourceSize $Size
            Burstable   = Get-VmfBurstableTargetFor -SourceSize $Size -TargetGeneration ([string]$Burst.option) -Families $Families
            Generation  = Get-VmfSizeGeneration -SizeName $Size
            V5          = @(Get-VmfDefaultSizeCandidates -SourceSize $Size -TargetGeneration 'v5' -Families $Families)
            V6          = @(Get-VmfDefaultSizeCandidates -SourceSize $Size -TargetGeneration 'v6' -Families $Families)
            V7          = @(Get-VmfDefaultSizeCandidates -SourceSize $Size -TargetGeneration 'v7' -Families $Families)
        }
    } $ex $families $burstRow
    # V5-SUCCESSOR-1: a size Microsoft does not list is never a target, so
    # the page leaves it out, and says so when that leaves no size.
    $unlisted = { param($Names) @($Names | Where-Object { (& $engine { param($Size, $Families) (Get-VmfMicrosoftSizeListing -SizeName $Size -Families $Families).Listed } $_ $families) -ne $false }) }
    foreach ($gv in 'V5', 'V6', 'V7') { $facts["$($gv)Listed"] = @(& $unlisted $facts[$gv]) }
    if (-not $facts.Stage) { throw "The lifecycle data gives no stage for $ex. Add a row to target-families.json lifecycle.bySeries." }
    $stage = [string]$facts.Stage.Stage
    $retires = if ($facts.Retirement) { [string]$facts.Retirement.RetiresUtc } else { 'None announced' }
    $retired = $stage -eq 'Retired'
    if ($retired) {
        $v5 = 'None. Microsoft retired this size.'
        $v67 = 'None. Microsoft retired this size.'
    }
    elseif ($facts.ByShape) {
        $v5 = "$v5GenWords. A$($byShape.Substring(1))"
        if ($facts.Burstable) { $v5 = "$v5GenWords. A $($facts.Burstable.series) size first, when the region has one that fits. Else, $byShape" }
        $v67 = "$v67GenWords. A$($byShape.Substring(1))"
    }
    else {
        # The sizes the planner tries for the example, in its order
        # (Get-VmfDefaultSizeCandidates). It takes the first one the region
        # has that fits the machine.
        if (-not $facts.V6.Count -or -not $facts.V7.Count) { throw "The planner gives no v6 or v7 size to try for $ex." }
        $listedWords = { param($Names) if (@($Names).Count) { Join-Words $Names } else { 'none, because Microsoft lists no size of this name' } }
        $v5 = if ($facts.Generation -eq 'v5') { 'None. The machine is already on v5.' } else { "$v5GenWords. $(& $listedWords $facts.V5Listed)." }
        $v67 = "$v67GenWords. v6: $(& $listedWords $facts.V6Listed). v7: $(& $listedWords $facts.V7Listed)."
    }
    $source = if ($facts.Retirement) { [string]$facts.Retirement.Source } else { [string]$facts.Stage.Source }
    $status = if ($retired) { 'Not supported' } else { 'Supported' }
    "| $($g.Series) | ``$ex`` | $stage | $retires | $(Format-Cell $v5) | $(Format-Cell $v67) | $status | $(Get-SourceLink $source) |"
}

# A Generation 1 machine chooses its v5 size by shape too (OLD-SKU-1B), with
# the size of its own name kept as the default where there is one
# (Resolve-VmfEntryTarget). Asked of the planner, so the note goes when the rule does.
$gen1Shape = & $engine { Test-VmfShapeChoiceSource -Generation 'V1' -SourceSize 'Standard_D2_v4' }
$gen1Note = if ($gen1Shape) { " On v5, a Generation 1 machine can also choose a size in the Dl, D or E family by its vCPUs and memory. The size in the table stays its first choice." } else { '' }
$v5Head = "v5 (and $($burstRow.series) for a B v1 machine)"

# -- target series --
# The Windows Server year below which each Windows rule closes a series. The
# years are numbers in Rules.ps1 (Test-VmfMigrationReadiness); a test reads them
# there, so the two cannot come apart.
$windowsRules = @(
    @{ Code = 'windows-version-below-2019'; Year = 2019 }
    @{ Code = 'windows-version-not-proven'; Year = 2016 }
)
function Get-WindowsBlocks {
    param([int]$Year, [string]$Series)
    @($windowsRules | Where-Object { $Year -lt $_.Year -and @($reasons.blockers.($_.Code).appliesTo) -contains $Series })
}
function Get-WindowsFloor {
    param([string]$Series)
    $floor = 0
    foreach ($r in $windowsRules) { if (@($reasons.blockers.($r.Code).appliesTo) -contains $Series -and $r.Year -gt $floor) { $floor = $r.Year } }
    "Windows Server $floor and later"
}

function Get-AnWords {
    param($Required, $Series = @())
    $r = @($Required)
    if (-not $r.Count) { return 'Supported' }
    # DRIFT-11: v6 requires it on every series and processor it is a target
    # for. "Supported on the other sizes" would then name sizes that do not exist.
    $have = @($r | ForEach-Object { "$($_.series)/$($_.processor)" })
    $all = @(foreach ($s in @($Series)) { foreach ($pr in @($families.approvedProcessors)) { "$s/$pr" } })
    if ($all.Count -and -not @($all | Where-Object { $have -notcontains $_ }).Count) { return 'Required on every size.' }
    $names = @($r | ForEach-Object { "$($_.processor) $($_.series)" })
    "Required on the $((Join-Words $names) -replace ' or ', ' and ') sizes. Supported on the other sizes."
}
function Get-ManaWords {
    # SUPPORT-MATRIX-2: -Makers is the processors the series has. Bsv2 is
    # Intel only, and "Sizes with an AMD processor do not give MANA" named
    # sizes that do not exist.
    param($Processors, $Makers = @($families.approvedProcessors))
    $have = @($Processors)
    if ($have.Count -eq 0) { return 'No size gives MANA.' }
    $other = @(@($Makers) | Where-Object { $have -notcontains $_ })
    if (-not $other.Count) { return 'Every size can give MANA.' }
    "Sizes with an $($have -join ' or ') processor can give MANA. Sizes with an $($other -join ' or ') processor do not give MANA."
}
function Get-SeriesStage {
    param([string]$Size)
    $s = & $engine { param($Size, $Families) Get-VmfSizeLifecycleStage -SizeName $Size -Families $Families } $Size $families
    if (-not $s) { throw "The lifecycle data gives no stage for $Size." }
    [string]$s.Stage
}
# SUPPORT-MATRIX-2 (Bsv2 is a family, not a generation like v5, v6 or v7,
# so it is no column header): the columns are the series the data names, and
# Bsv2 has a table of its own below them.
$cols = @($targetSeries)
$cell = @{}
foreach ($g in $targetSeries) {
    $t = $families.generations.$g
    $cell[$g] = [ordered]@{
        Families   = (@($families.seriesByGeneration.$g) -join ', ')
        Controller = [string]$t.controller
        Generation = (Get-GenerationWords $t.hyperVGenerations)
        Windows    = (Get-WindowsFloor $g)
        An         = (Get-AnWords $t.acceleratedNetworkingRequired @($families.seriesByGeneration.$g))
        Mana       = (Get-ManaWords $t.manaProcessors)
        Stage      = (Get-SeriesStage "Standard_D2s_$g")
    }
}
$burstCell = [ordered]@{
    Option     = "$($burstRow.option). The product then offers the $($burstRow.series) size first, when the region has one that fits the machine."
    Families   = "B, for a machine on a B v1 size only"
    Controller = [string]$bt.controller
    Generation = (Get-GenerationWords $bt.hyperVGenerations)
    Windows    = (Get-WindowsFloor ([string]$burstRow.option))
    An         = (Get-AnWords $bt.acceleratedNetworkingRequired)
    Mana       = (Get-ManaWords $bt.manaProcessors @([string]$burstRow.processor))
    Stage      = (Get-SeriesStage 'Standard_B2s_v2')
}
# The F families Microsoft lists on v7, with their processor maker, from the
# data (targetFamilyExamples). An F, Fs or Fsv2 machine is Intel.
$fV7 = @(foreach ($row in @($families.targetFamilyExamples | Where-Object { $_.generation -eq 'v7' })) {
        foreach ($x in @($row.examples | Where-Object { $_ -match '^F' })) { "$x, an $($row.platform) family" } })
if (-not $fV7.Count) { throw 'target-families.json lists F on v7 and names no F family among the v7 examples.' }
$fV7Words = Join-Words $fV7
$targetLabels = [ordered]@{
    Families = 'Families'; Controller = 'Disk controller'; Generation = 'Machine generation'; Windows = 'Windows'
    An = 'Accelerated networking'; Mana = 'Microsoft Azure Network Adapter (MANA)'; Stage = 'Lifecycle stage'
}
$targetTable = [System.Text.StringBuilder]::new()
$null = $targetTable.Append("| | $($cols -join ' | ') |`n|---|$((@($cols | ForEach-Object { '---' })) -join '|')|`n")
foreach ($k in $targetLabels.Keys) {
    $null = $targetTable.Append("| $($targetLabels[$k]) | $((@($cols | ForEach-Object { Format-Cell $cell[$_][$k] })) -join ' | ') |`n")
}
$burstTable = [System.Text.StringBuilder]::new()
$null = $burstTable.Append("| Item | $($burstRow.series), for a machine on a B v1 size |`n|---|---|`n")
$null = $burstTable.Append("| Choose it as | $(Format-Cell $burstCell.Option) |`n")
foreach ($k in $targetLabels.Keys) { $null = $burstTable.Append("| $($targetLabels[$k]) | $(Format-Cell $burstCell[$k]) |`n") }

# -- Windows --
$v5Col = [string]$burstRow.option
$winRows = foreach ($w in @(@{ Name = 'Windows Server 2019 and later'; Year = 2019 }, @{ Name = 'Windows Server 2016'; Year = 2016 }, @{ Name = 'Windows Server older than 2016'; Year = 2012 })) {
    $a = @(Get-WindowsBlocks -Year $w.Year -Series $v5Col)
    $b = @(Get-WindowsBlocks -Year $w.Year -Series 'v6')
    # The reason is the rule with the lowest year that closes a series: it is
    # the one that also closes the series the other rule leaves open.
    $first = @(@($a) + @($b) | Sort-Object { $_.Year }) | Select-Object -First 1
    # Each other rule that closes a series adds its first sentence, so the
    # reason covers both columns (review).
    $why = if ($first) {
        $more = @(@(@($a) + @($b) | Where-Object { $_.Code -ne $first.Code }) | ForEach-Object { $_.Code } | Select-Object -Unique |
                ForEach-Object { ([string]$reasons.blockers.$_.meaning -split '(?<=\.)\s')[0] })
        (@($reasons.blockers.($first.Code).meaning) + $more) -join ' '
    } else { 'Every target series takes this version.' }
    $page = if ($first) { Get-DocsLink $reasons.blockers.($first.Code) } else { Get-DocsLink $reasons.blockers.($windowsRules[0].Code) }
    "| $($w.Name) | $(if ($a.Count) { 'Not supported' } else { 'Supported' }) | $(if ($b.Count) { 'Not supported' } else { 'Supported' }) | $(Format-Cell $why) | $page |"
}
$client = $reasons.excluded.'client-operating-system'
$winRows = @($winRows) + "| Windows client (Windows 10 and Windows 11) | Not supported | Not supported | $(Format-Cell $client.meaning) | $(Get-DocsLink $client) |"

# -- Linux images --
# The distribution each image publisher ships, in Microsoft's names. A
# publisher the data adds later shows its own name until a name is added here.
$distroOf = @{
    Canonical = 'Ubuntu'; RedHat = 'Red Hat Enterprise Linux'; SUSE = 'SUSE Linux Enterprise Server'; Debian = 'Debian'
    Oracle = 'Oracle Linux'; MicrosoftCBLMariner = 'Azure Linux (CBL-Mariner)'; 'microsoft-dsvm' = 'Data Science Virtual Machine'
    microsoftazurelinux = 'Azure Linux 4.0'
    OpenLogic = 'CentOS'; 'center-for-internet-security-inc' = 'CIS hardened images'
}
$supportWords = @{ 'microsoft-published' = 'Microsoft publishes this image.'; endorsed = 'Microsoft endorses this distribution on Azure.' }
$linuxRows = foreach ($entry in @($images.publishers | Where-Object { $_.os -eq 'Linux' })) {
    # IMAGE-SCRIPT-MATCH-1: an entry for some offers of a publisher has its
    # own name (openSUSE Leap of SUSE), and the entry for the rest keeps the
    # name of the publisher's distribution.
    $name = if ($entry.PSObject.Properties['name'] -and [string]$entry.name) { [string]$entry.name } elseif ($distroOf.ContainsKey([string]$entry.publisher)) { $distroOf[[string]$entry.publisher] } else { [string]$entry.publisher }
    # The note in the data is for the people who keep the list, so the page
    # says what the product does with such a machine.
    if ([string]$entry.support -eq 'unsupported') { "| $name | $($entry.publisher) | Not supported | This image is on the list as not supported. The product does not move this machine. |" }
    else {
        $why = if ($supportWords.ContainsKey([string]$entry.support)) { $supportWords[[string]$entry.support] } else { throw "supported-images.json has a support value this tool has no words for: $($entry.support)" }
        "| $name | $($entry.publisher) | Supported | $why |"
    }
}
$notListed = $reasons.blockers.'image-not-supported'
# NO-PLAN-SCOPE-1: a machine with a purchase plan is out of scope, whatever its
# image publisher. The editions named are the ones the item's sweep of every
# supported publisher found with a plan (2026-11-03).
$planScope = $reasons.blockers.'purchase-plan-out-of-scope'
$linuxRows = @($linuxRows) + "| Any other image | Any other | Not supported | $(Format-Cell "$($notListed.meaning) $($notListed.whatToDo)") |"

# -- Linux releases for NVMe (IMAGE-SCRIPT-MATCH-1) --
# One row per release on Microsoft's page, in its order and in its words. No
# status column: the other rules (the list of Linux images, the MANA kernel)
# still apply to each release. The series the finding closes are its appliesTo.
$notOnList = $reasons.blockers.'linux-release-not-on-nvme-list'
# Our table spells AlmaLinux as its vendor does; the data keeps Microsoft's
# own spelling, because a test compares it with the pinned page word for word.
$nvmeReleaseRows = @(foreach ($r in @($nvmeLinux.releases)) { "| $(([string]$r.label) -creplace '^Almalinux\b', 'AlmaLinux') |" })
$nvmeClosed = Join-Words @($notOnList.appliesTo)

# -- Linux release end of standard support (EOL-RELEASE-AN-1) --
# One row per release in the data, with the vendor's date in the vendor's
# terms: a day, or the month when the vendor gives only a month.
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$eolRows = @(foreach ($r in @($releaseEol.releases)) {
    $d = [string]$r.endOfStandardSupport
    $when = if ($d -match '^\d{4}-\d{2}-\d{2}$') { [datetime]::ParseExact($d, 'yyyy-MM-dd', $invariant).ToString('d MMMM yyyy', $invariant) } else { [datetime]::ParseExact("$d-01", 'yyyy-MM-dd', $invariant).ToString('MMMM yyyy', $invariant) }
    "| $([string]$r.label) | $([string]$r.vendor) | $when | [$([string]$r.vendor)]($([string]$r.source)) |"
})
$pastWarn = $reasons.warnings.'linux-release-past-standard-support'
$eolStop = @($stops.reasons | Where-Object { $_.code -eq 'linuxReleaseEndOfLife' })[0]

# -- Linux kernel for MANA --
$distroIds = @{
    almalinux = 'AlmaLinux'; azurelinux = 'Azure Linux'; debian = 'Debian'; ol = 'Oracle Linux'; rocky = 'Rocky Linux'
    rhel = 'Red Hat Enterprise Linux'; sles = 'SUSE Linux Enterprise Server'; ubuntu = 'Ubuntu'
}
$manaRows = foreach ($d in @($floors.mana.linux.distros)) {
    $name = if ($distroIds.ContainsKey([string]$d.id)) { $distroIds[[string]$d.id] } else { [string]$d.id }
    if ($d.PSObject.Properties['kernelFlavor'] -and $d.kernelFlavor -eq 'uek') { $name = "$name, Unbreakable Enterprise Kernel" }
    $version = if ([string]$d.versionId -eq '*') { 'Any' } else { [string]$d.versionId }
    $kernel = if ($d.minKernel) { [string]$d.minKernel } else { "Any $($d.kernelSeries)" }
    "| $name | $version | $kernel |"
}
$fallbackKernel = [string]$floors.mana.linux.fallbackForUnlistedDistros.minKernel
# SUPPORT-MATRIX-2: written here. The finding image-cannot-boot-nvme speaks of
# one machine ("this image"); this column says what every image needs. The
# series it closes are the finding's (appliesTo).
$imageNeeds = "Azure reports the disk controllers that each image supports, and it must report NVMe. When it reports SCSI only, the machine cannot go to $(Join-Words @($reasons.blockers.'image-cannot-boot-nvme'.appliesTo)), because it would not start after the migration. Choose v5 for that machine."

# -- machine generation --
$gen1 = $reasons.blockers.'gen1-requires-redeploy'
$verifyGen = $reasons.prep.'verify-generation'
function Get-GenStatus { param($Gens, [string]$Gen) if (@($Gens) -contains $Gen) { 'Supported' } else { 'Not supported' } }
$genRows = @(
    "| Generation 2 | $(Get-GenStatus $v5Gens 'V2') | $(Get-GenStatus $v67Gens 'V2') | Every target series takes Generation 2. | $(Get-DocsLink $verifyGen) |"
    "| Generation 1 | $(Get-GenStatus $v5Gens 'V1') | $(Get-GenStatus $v67Gens 'V1') | $(Format-Cell "$($gen1.meaning) $($gen1.whatToDo)") | $(Get-DocsLink $gen1) |"
)

# -- machines the product does not move --
# Every machine the assessment leaves alone, and every finding that closes
# every size series. An image that is not on the list is in the Linux table.
$allSeries = @('v5', 'v6', 'v7')
$outRows = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $reasons.excluded.PSObject.Properties) {
    $r = $entry.Value
    $outRows.Add("| $($r.title) | $(Format-Cell $r.meaning) | $(Format-Cell $r.whatToDo) | Not supported | $(Get-DocsLink $r) |")
}
# Written here: Arm64 is refused by the planner (processor-not-approved), and
# no assessment reason holds its words. The processors are the data's.
$outRows.Add("| Machine on an Arm64 size | Microsoft lists only $((@($families.approvedProcessors)) -join ' and ') sizes as v5, v6 and v7 targets. An Arm64 size, such as Dpsv5, is outside the scope of this tool. | Keep this machine on its size. Microsoft names no Arm64 target family. | Not supported | $(Get-SourceLink 'sizes-v6-v7-modernization-overview') |")
foreach ($entry in $reasons.blockers.PSObject.Properties) {
    if ($entry.Name -eq 'image-not-supported') { continue }
    # SCAN-PARTIAL-SUBS-1: a scan that could not read the sizes says nothing
    # about what the product supports. A new assessment clears it.
    if ($entry.Name -eq 'sizes-not-read') { continue }
    # LINUX-VERSION-OVERFLOW-1: nor does a machine whose facts the scan could
    # not read. A new assessment clears it.
    if ($entry.Name -eq 'machine-not-read') { continue }
    $applies = @($entry.Value.appliesTo)
    if (@($allSeries | Where-Object { $applies -notcontains $_ }).Count) { continue }
    $r = $entry.Value
    $title = ([string]$r.title) -replace '\s*\(not in scope\)$', ''
    $outRows.Add("| $title | $(Format-Cell $r.meaning) | $(Format-Cell $r.whatToDo) | Not supported | $(Get-DocsLink $r) |")
}

$sb = [System.Text.StringBuilder]::new()
$null = $sb.Append(@"
# Support matrix

This page says which machines the product can migrate, and which it cannot. It is generated from the data the product reads, so it always matches the assessment and the plan.

Each row gives one of two statuses:

| Status | What it means |
|---|---|
| Supported | The product migrates the machine when the assessment finds nothing that holds it back. |
| Not supported | The product does not migrate the machine. The assessment names it and says why. |

A machine keeps its processor maker: Intel stays Intel, and AMD stays AMD.

Dl is Microsoft's name for the D sizes with less memory: 2 GiB for each vCPU. Each Dl size has the letter l after its number, for example D2ls_v5. For "a size in the Dl, D or E family", the product finds the smallest size of each family that fits the machine. A size fits when it has at least the vCPUs and the memory of the machine. The product starts with the one that has the fewest vCPUs, then the least memory. If the machine is on a constrained vCPU size, the product starts with the constrained vCPU size that has the same active vCPUs. The region must have that size. You can choose another in the **Choose each target** step.

## Source sizes

The size series that a machine can move from, with the lifecycle stage Microsoft gives each one. The retirement date is the date Microsoft gives. From one day before that date, a machine on that size is outside the scope of this tool.

The sizes in the two "On" columns are for the example size. The product takes the first of them that the region has and that fits the machine. A cell that gives a target starts with the machine generations that the series takes.

| Size series | Example size | Lifecycle stage | Retirement | On v5 ($v5GenWords) | On v6 and v7 ($v67GenWords) | Status | Microsoft page |
|---|---|---|---|---|---|---|---|

"@)
foreach ($row in $sourceRows) { $null = $sb.Append("$row`n") }
$null = $sb.Append(@"

A size series that is not in this table is outside the scope of this tool. A constrained vCPU size belongs to the series of its letters: E8-4ds_v5 is an Edsv5 size. An isolated size, such as E104i_v5, gets no target, because a person chooses its size. A machine on a v6 or v7 size cannot move to v5.$gen1Note The Windows and Machine generation tables below can also stop a machine from going to a series.

## Target series

You choose the size series for each machine in the **Choose each target** step. A move to v6 or v7 changes the disk controller from SCSI to NVMe. A move to v5 is a resize, and the disk controller stays SCSI.


"@)
$null = $sb.Append($targetTable.ToString())
$null = $sb.Append(@"

$($burstRow.series) is one series of the B family. It is not a generation, as v5, v6 and v7 are. The product offers a $($burstRow.series) size only to a machine on a B v1 size. A move to $($burstRow.series) is a resize, and the disk controller stays SCSI.


"@)
$null = $sb.Append($burstTable.ToString())
$null = $sb.Append(@"

Microsoft lists F among its v7 target families, as $fV7Words. A machine on an F, Fs or Fsv2 size has an Intel processor, and a machine keeps its processor maker. So the product chooses no F size for it. That machine gets $byShape

The other differences between the series are in [Limits](limits.md). Read more: $(Get-SourceLink 'sizes-v5-modernization-overview'), $(Get-SourceLink 'sizes-v6-v7-modernization-overview')

## Windows

The product reads the version that the machine reports it runs. When the machine does not report a version, it reads the version from the image.

| Operating system | $v5Head | v6 and v7 | Why | Microsoft page |
|---|---|---|---|---|

"@)
foreach ($row in $winRows) { $null = $sb.Append("$row`n") }
$null = $sb.Append(@"

A Windows machine with a Marketplace purchase plan, for example from a Windows Server preview image, is outside the scope of this tool.

## Linux images

The product migrates a Linux machine when Microsoft publishes or endorses its image. The list goes by the image publisher in Azure.

| Distribution | Azure publisher | Status | Why |
|---|---|---|---|

"@)
foreach ($row in $linuxRows) { $null = $sb.Append("$row`n") }
$null = $sb.Append(@"

Some editions of these distributions have a Marketplace purchase plan: Ubuntu Pro, RHEL BYOS and the SUSE offers with a name that ends in -llc. A machine with a purchase plan is outside the scope of this tool, whatever its distribution. The standard images of each distribution in this table have no plan.

Read more: $(Get-DocsLink $planScope)

## Linux releases for NVMe

Microsoft lists the Linux releases that support NVMe disks. The product does not move a Linux machine on another release to $nvmeClosed. The product can move that machine to v5. v5 keeps the SCSI disk controller.

The product reads the release that the Azure Linux Agent reports. If the agent reports no release, the product reads the release from the image of the machine. If the scan cannot compare the release, the assessment shows a warning. The machine can still move.

A release on this list must also be on the list of Linux images. The MANA kernel rules below also apply.

| Linux release |
|---|
$($nvmeReleaseRows -join "`n")

Read more: $(Get-DocsLink $notOnList)

## End of standard support of a Linux release

Each Linux vendor ends the standard support of a release on a date. Microsoft supports accelerated networking only on releases that the vendor has not marked as end of life. A vendor can sell extended support after the end of standard support. A machine on such a release can still move.

The assessment shows the date. Before the move, Checking stops the machine with the reason **$($eolStop.title)**. An approver can accept the release for that machine. The product reads the release that the Azure Linux Agent reports. The image of a machine shows the lowest release that the machine can run. If the release is from the image, the product does not show it as past its date.

| Linux release | Vendor | End of standard support | Vendor page |
|---|---|---|---|
$($eolRows -join "`n")

Read more: $(Get-DocsLink $pastWarn)

## What a move to NVMe needs

A move to v6 or v7 attaches the disks over NVMe. A move to v5, or to $($burstRow.series) for a B v1 machine, keeps the SCSI disk controller. This table does not apply to it.

| Part | What it needs | Microsoft page |
|---|---|---|
| Image | $imageNeeds | $(Get-DocsLink $reasons.blockers.'image-cannot-boot-nvme') |
| Linux | $(Format-Cell $reasons.prep.'linux-nvme-prep'.meaning) The product prepares this during the migration. | $(Get-DocsLink $reasons.prep.'linux-nvme-prep') |
| Windows | $(Format-Cell $reasons.prep.'stornvme'.meaning) The product prepares this during the migration. | $(Get-DocsLink $reasons.prep.'stornvme') |
| Machine generation | $(Get-GenerationWords $families.generations.v6.hyperVGenerations). | $(Get-DocsLink $verifyGen) |

## Linux kernel for MANA

Azure does not update the network drivers inside a machine. A Linux machine needs a kernel with the MANA driver to use accelerated networking on a size that gives MANA. The product checks the kernel before the move. These are the minimum kernels Microsoft lists. A release that Microsoft does not list for MANA, such as Ubuntu 20.04, gets no v6, v7, Bsv2 or Intel v5 size. An AMD machine on it gets AMD v5. For a distribution that is not in this table, the kernel must be $fallbackKernel or later. A distribution must also be on the list of Linux images.

| Distribution | Version | Minimum kernel |
|---|---|---|

"@)
foreach ($row in $manaRows) { $null = $sb.Append("$row`n") }
$null = $sb.Append(@"

Read more: $(Get-DocsLink $reasons.prep.'mana-kernel-floor')

## Machine generation

| Machine generation | $v5Head | v6 and v7 | Why | Microsoft page |
|---|---|---|---|---|

"@)
foreach ($row in $genRows) { $null = $sb.Append("$row`n") }
$null = $sb.Append(@"

## Machines the product does not move

The product does not migrate these machines to any size series. The assessment names each one, with the reason.

| Machine | Why | What to do | Status | Microsoft page |
|---|---|---|---|---|

"@)
foreach ($row in $outRows) { $null = $sb.Append("$row`n") }
$ok = (Write-Page -Name 'support-matrix.md' -Text $sb.ToString()) -and $ok

if ($Check -and -not $ok) { throw 'The generated reference pages are stale. Run ./tools/Update-VmfManualReference.ps1 and commit.' }
