# HELD-READ-DEPTH-1 and WRITE-DEPTH-OPEN-1: how deep a store document can nest,
# and which document a store path names. Dot-source it in a BeforeAll:
#
#   . (Join-Path $PSScriptRoot '_StoreDocumentDepth.ps1')
#
# StoreReadDepth.Tests.ps1 asks it of every store read, StoreWriteDepth.Tests.ps1
# of every store write, and StoreDirectDepth.Tests.ps1 (COPY-DEPTH-GATE-1) of
# every direct ConvertFrom-Json of store text and every in-memory copy. ONE
# copy, so the three gates measure a document the same way.
#
# A schema with an open part (an object with no "additionalProperties": false)
# can nest to any depth: Get-SchemaNesting returns 99 for it, and a read or a
# write of it must take the full default depth of 24.

$script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
$script:schemaDir = Join-Path $script:repoRoot 'schemas'

# A schema branch (allOf, anyOf, oneOf, then, else) with no type only adds
# rules to the object it sits in: it does not open that object.
function Script:CloseBranch($b) {
    if ($b -is [System.Collections.IDictionary] -and -not $b.Contains('additionalProperties') -and -not $b.Contains('type')) {
        $c = @{} + $b; $c['additionalProperties'] = $false; return $c
    }
    $b
}
# The deepest nesting a schema permits, counted as ConvertFrom-Json counts
# it (the root object is 1). 99 means the schema has an open part.
function Script:Get-SchemaNesting($s, $root, $seen) {
    if ($null -eq $s -or $s -is [bool]) { if ($s -eq $true) { return 99 }; return 0 }
    if ($s.Contains('$ref')) {
        $ref = [string]$s['$ref']
        if ($seen -contains $ref -or $ref -notlike '#/*') { return 99 }
        $node = $root
        foreach ($part in $ref.Substring(2).Split('/')) { $node = $node[$part] }
        return Script:Get-SchemaNesting $node $root (@($seen) + $ref)
    }
    $best = 0
    foreach ($k in 'oneOf', 'anyOf', 'allOf') {
        if ($s.Contains($k)) { foreach ($b in $s[$k]) { $best = [Math]::Max($best, (Script:Get-SchemaNesting (Script:CloseBranch $b) $root $seen)) } }
    }
    foreach ($k in 'then', 'else') {
        if ($s.Contains($k)) { $best = [Math]::Max($best, (Script:Get-SchemaNesting (Script:CloseBranch $s[$k]) $root $seen)) }
    }
    $types = @($s['type'])
    if (($types -contains 'object') -or $s.Contains('properties')) {
        $inner = 0
        foreach ($k in 'properties', 'patternProperties') {
            if ($s.Contains($k)) { foreach ($v in $s[$k].Values) { $inner = [Math]::Max($inner, (Script:Get-SchemaNesting $v $root $seen)) } }
        }
        $extra = if ($s.Contains('additionalProperties')) { $s['additionalProperties'] } else { $true }
        if ($extra -is [System.Collections.IDictionary]) { $inner = [Math]::Max($inner, (Script:Get-SchemaNesting $extra $root $seen)) }
        elseif ($extra -eq $true) { $inner = 99 }
        $best = [Math]::Max($best, [Math]::Min(99, 1 + $inner))
    }
    if (($types -contains 'array') -or $s.Contains('items')) {
        $inner = if ($s.Contains('items')) { Script:Get-SchemaNesting $s['items'] $root $seen } else { 99 }
        $best = [Math]::Max($best, [Math]::Min(99, 1 + $inner))
    }
    $best
}
function Script:Get-DocumentNesting([string]$Kind) {
    if ($script:noSchema.Contains($Kind)) { return $script:noSchema[$Kind] }
    if ($Kind -eq 'plan') {
        # plan.json: { entries: [ <plan-entry> ] } beside plan-wide fields.
        $entry = Script:Get-DocumentNesting 'plan-entry'
        return [Math]::Min(99, 2 + $entry)
    }
    $file = Join-Path $script:schemaDir "$Kind.schema.json"
    $schema = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Script:Get-SchemaNesting $schema $schema @()
}
# The depth a read or a write of a document needs: its nesting, or 24 when its
# schema has an open part.
function Script:Get-DocumentDepthNeeded([string]$Kind) {
    $need = Script:Get-DocumentNesting $Kind
    if ($need -ge 99) { return 24 }
    $need
}

# Documents with no schema, and the deepest nesting their one writer makes.
# 99: an open part (the writer takes fields from its caller).
$script:noSchema = @{
    'vm-claim'        = 1   # New-VmfVmClaim: schemaVersion, vmId, runId, runPath, claimedUtc, takenFrom, takenBy
    'halt-flag'       = 1   # Set-VmfWaveHalt: haltedUtc, reason
    'pacing'          = 1   # Write-VmfThrottleSignal: schemaVersion, throttledUntilUtc, observedUtc
    'boot-diagnostics' = 1  # Get-VmfBootDiagnostics: screenshotUri, serialLogUri, fetchedUtc (or error)
    'event-line'      = 99  # Write-VmfEvent: a caller's -Data fields go into the line as they are
    'deletion-line'   = 4   # Remove-VmfRun: machinesLeftChanged[].safetyCopies[]
    'html-report'     = 0   # New-VmfReport: HTML, not JSON
}
# Which document a path names, by the text of the path. First match wins.
$script:kindByPath = [ordered]@{
    "assessment\.json"                         = 'assessment'
    "plan-approval\.json"                      = 'plan-approval'
    "plan-run\.json"                           = 'plan-run'
    "'approval\.json'"                         = 'assessment-approval'
    "'run\.json'"                              = 'run-manifest'
    "run-status\.json"                         = 'run-status'
    "retention-status\.json"                   = 'retention-status'
    "schedule-status\.json"                    = 'schedule-status'
    "VmfScheduleDueName|schedule-due\.json"    = 'schedule-due'
    "target-advice\.json"                      = 'target-advice'
    "target-choices\.json"                     = 'target-choices'
    "machine-choices\.json"                    = 'machine-choices'
    "'plan\.json'"                             = 'plan'
    "project\.json"                            = 'project'
    "approvals/"                               = 'wave-approval'
    "acceptances/|Resolve-VmfWaveOptionsAcceptancePath" = 'wave-options-acceptance'
    "acknowledgements/"                        = 'run-acknowledgement'
    "capacity-history/"                        = 'capacity-history'
    "capacity/"                                = 'capacity-claim'
    "catalog/"                                 = 'size-catalog'
    "leases/|Get-VmfLeaseRelPath"              = 'lease'
    "schedules/"                               = 'wave-schedule'
    "state/"                                   = 'vm-state'
    "Get-VmfClaimRelPath|Get-VmfClaimLegacyRelPath" = 'vm-claim'
    "Get-VmfDecisionCarryNotePath"             = 'decision-carry'
    "halt\.flag"                               = 'halt-flag'
    "stopped\.json"                            = 'run-stop'
    "pacing\.json"                             = 'pacing'
    "evidence/\`$bdName"                       = 'boot-diagnostics'
    "logs/events\.jsonl"                       = 'event-line'
    "deletions\.jsonl"                         = 'deletion-line'
    "evidence/\`$evidenceName"                 = 'guest-output'
    "Get-VmfRecordName"                        = 'migration-record'
    "customer-report\.html"                    = 'html-report'
}
