<#
.SYNOPSIS
    MANUAL-SHOTS-1: write a small sample migration into a folder, so the
    manual's picture of the report is the report the product writes.
.DESCRIPTION
    The report is written by the module (New-VmfReport), not by a page, so a
    page's sample data cannot show it. This writes the documents of one
    finished migration - an assessment, a plan of two waves, the state of each
    machine, the acceptances, a sign-off, a quota record and the activity - to
    the schemas in /schemas, with placeholder names only.
    tests/unit/ManualSampleRun.Tests.ps1 holds every document to its schema.
    Export-VmfManualScreenshots.ps1 calls this, writes the report from it, and
    deletes the folder.

    The dates are fixed, so the report does not change from one run of the
    screenshots to the next.
.PARAMETER RunPath
    The folder to write the migration into. It must not exist.
.PARAMETER AcceptanceNameFor
    ACCEPT-NAME-1: give the name this tool writes a wave's acceptance under,
    and write nothing. tests/unit/ManualSampleRun.Tests.ps1 holds it equal to
    the module's Get-VmfWaveOptionsAcceptancePath.
.EXAMPLE
    ./tools/New-VmfManualSampleRun.ps1 -RunPath $env:TEMP/vmf-sample-run
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$RunPath,
    [Parameter(Mandatory, ParameterSetName = 'Name')][string[]]$AcceptanceNameFor
)
$ErrorActionPreference = 'Stop'

# ACCEPT-NAME-1: the name the product writes a wave's acceptance under
# (Get-VmfWaveOptionsAcceptancePath): the wave with every character but a
# letter, a number or a dash made a dash, in lower case, then the first 12
# characters of the SHA-256 of the wave in lower case (Get-VmfNameCode with one
# part). This tool does not load the module, so the rule is written here, and
# the test holds the two equal. The Migrations page reads only names that
# start wave-options-, so a sample under any other name never showed there.
function AcceptanceRel([string]$Wave) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Wave.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    "acceptances/wave-options-$(($Wave -replace '[^A-Za-z0-9\-]', '-').ToLowerInvariant())-$($hash.Substring(0, 12)).json"
}
if ($PSCmdlet.ParameterSetName -eq 'Name') { return @($AcceptanceNameFor | ForEach-Object { AcceptanceRel $_ }) }
if (Test-Path $RunPath) { throw "$RunPath exists already. Give a folder that does not exist." }

$sub = '00000000-0000-0000-0000-000000000000'
$runId = 'billing-move-sample'
function VmId([string]$Name) { "/subscriptions/$sub/resourceGroups/rg-billing/providers/Microsoft.Compute/virtualMachines/$Name" }
function Save([string]$Rel, $Doc) {
    $file = Join-Path $RunPath $Rel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent)
    [System.IO.File]::WriteAllText($file, ($Doc | ConvertTo-Json -Depth 20))
}

# One row per machine: name, operating system, wave, path, size now and its
# disk architecture, target and its disk architecture, series, and the state
# it finished in.
$machines = @(
    @{ n = 'web-01'; os = 'Linux'; osv = '22_04-lts-gen2'; wave = 'web-pilot'; path = 'A'; from = 'Standard_D2s_v4'; arch = 'diskless'; to = 'Standard_D2s_v6'; toArch = 'diskless'; gen = 'v6'; state = 'MIGRATED' }
    @{ n = 'web-02'; os = 'Linux'; osv = '22_04-lts-gen2'; wave = 'web-pilot'; path = 'A'; from = 'Standard_D2s_v4'; arch = 'diskless'; to = 'Standard_D2s_v6'; toArch = 'diskless'; gen = 'v6'; state = 'MIGRATED' }
    @{ n = 'web-03'; os = 'Linux'; osv = '22_04-lts-gen2'; wave = 'web-pilot'; path = 'A'; from = 'Standard_D2s_v4'; arch = 'diskless'; to = 'Standard_D2s_v6'; toArch = 'diskless'; gen = 'v6'; state = 'FAILED_ROLLED_BACK' }
    @{ n = 'report-01'; os = 'Windows'; osv = '2022-datacenter-g2'; wave = 'web-report-db'; path = 'A'; from = 'Standard_D4ds_v4'; arch = 'scsi-temp'; to = 'Standard_D4ds_v6'; toArch = 'nvme-temp'; gen = 'v6'; state = 'MIGRATED'; identity = $true }
    @{ n = 'db-01'; os = 'Windows'; osv = '2016-datacenter-gensecond'; wave = 'web-report-db'; path = 'A'; from = 'Standard_D4s_v4'; arch = 'diskless'; to = 'Standard_D4s_v5'; toArch = 'diskless'; gen = 'v5'; state = 'MIGRATED' }
)
$controller = { param($size) if ($size -match '_v[67]$') { 'NVMe' } else { 'SCSI' } }
$levers = [ordered]@{ requireApproval = $true; onDDataFound = 'stop'; onDriverBelowFloor = 'stop'
    keepSnapshotDays = 7; throttle = 5; capacityGate = 'BestEffort' }

Save 'run.json' ([ordered]@{ schemaVersion = 9; kind = 'migration'; runId = $runId; createdUtc = '2026-09-24T18:00:00Z'
        createdBy = 'operator@example.com'; fromAssessment = 'billing-first-look' })
Save 'assessment.json' ([ordered]@{
        schemaVersion = 17; runId = 'billing-first-look'; generatedUtc = '2026-09-23T09:00:00Z'
        scope = @{ subscriptions = @($sub); resourceGroups = @('rg-billing') }
        summary = @{ ReadyAfterPrep = $machines.Count }
        vms = @($machines | ForEach-Object {
                [ordered]@{ vmId = (VmId $_.n); name = $_.n; resourceGroup = 'rg-billing'; location = 'centralus'
                    classification = 'ReadyAfterPrep'; gen = 'V2'; os = $_.os; osVersion = $_.osv; sourceSize = $_.from
                    sourceDiskArch = $_.arch; diskController = 'SCSI'; blockers = @(); prepNeeded = @(); notes = @()
                    identityType = $(if ($_.identity) { 'SystemAssigned' } else { '' }) }
            })
    })
Save 'plan.json' ([ordered]@{
        schemaVersion = 18; assessmentRunId = 'billing-first-look'; generatedUtc = '2026-09-24T18:00:00Z'
        entries = @($machines | ForEach-Object {
                [ordered]@{ schemaVersion = 37; vmId = (VmId $_.n); wave = $_.wave; path = $_.path
                    assessment = [ordered]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $_.os; osVersion = $_.osv
                        sourceSize = $_.from; sourceDiskArch = $_.arch; location = 'centralus'
                        identityType = $(if ($_.identity) { 'SystemAssigned' } else { '' }) }
                    target = [ordered]@{ size = $_.to; diskArch = $_.toArch; controller = (& $controller $_.to)
                        choice = @{ option = $_.gen; source = 'default' } }
                    policy = [ordered]@{} + $levers + @{ targetGeneration = $_.gen; acceleratedNetworking = 'ensureOn' }
                    planNotes = @() }
            })
    })
Save 'plan-approval.json' ([ordered]@{ schemaVersion = 4; runId = $runId; waves = @('web-pilot', 'web-report-db')
        approvedBy = @{ identity = 'approver@example.com'; tenantId = '00000000-0000-0000-0000-000000000000' }
        approvedUtc = '2026-09-24T19:00:00Z'; planHash = ('a' * 64); note = 'Reviewed every wave with the application owners.' })
foreach ($w in 'web-pilot', 'web-report-db') {
    $inWave = @($machines | Where-Object { $_.wave -eq $w })
    Save (AcceptanceRel $w) ([ordered]@{ schemaVersion = 9; runId = $runId; wave = $w; acceptedBy = 'operator@example.com'
            acceptedUtc = '2026-09-24T18:40:00Z'; machineCount = $inWave.Count; optionsHash = ('a' * 64)
            levers = @($inWave | ForEach-Object { [ordered]@{} + $levers + @{ targetGeneration = $_.gen } })
            note = 'Read with the application owners.' })
}
Save 'acknowledgements/infrastructure-as-code.json' ([ordered]@{ schemaVersion = 1; runId = $runId; topic = 'infrastructure-as-code'
        acknowledgedBy = 'operator@example.com'; acknowledgedUtc = '2026-09-24T18:45:00Z'
        statement = 'Terraform, Bicep, Pulumi, ARM templates and Ansible keep their own definition of each machine. This migration makes these changes, and those definitions do not know about them: The size of the machine changes.'; note = $null })

$start = [datetime]::Parse('2026-09-24T22:00:00Z').ToUniversalTime()
$i = 0
foreach ($m in $machines) {
    $t0 = $start.AddMinutes(25 * $i); $i++
    $at = { param($min) $t0.AddMinutes($min).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @(@('PRECHECK', 0), @('SAFETY_PRISTINE', 2), @('GUEST_PREP', 5), @('STOPPED', 8), @('SAFETY_COPY', 9), @('CONVERTING', 11), @('STARTING', 14))) {
        $history.Add([ordered]@{ tsUtc = (& $at $step[1]); state = $step[0]; outcome = 'ok'; durationSec = 60 })
    }
    if ($m.state -eq 'MIGRATED') {
        $history.Add([ordered]@{ tsUtc = (& $at 17); state = 'VALIDATING'; outcome = 'ok'; durationSec = 90 })
        $history.Add([ordered]@{ tsUtc = (& $at 19); state = 'MIGRATED'; outcome = 'ok' })
    }
    else {
        $history.Add([ordered]@{ tsUtc = (& $at 19); state = 'FAILED_ROLLED_BACK'; outcome = 'fail'; machineState = 'restored'
                reasonCode = 'bootFailedAfterConversion'; detail = "The machine did not report that it started within 15 minutes on $($m.to)." })
    }
    # vm-state v47: PRECHECK writes the first capture with this attempt's, and
    # every capture says its capacity reservation group and patch settings.
    $vmc = { [ordered]@{ size = $m.from; controller = 'SCSI'; capturedUtc = (& $at 0); capacityReservationGroupId = $null; patchSettings = $null
            osDisk = @{ name = "$($m.n)-osdisk"; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null }; dataDisks = @() } }
    Save "state/$($m.n).json" ([ordered]@{
            schemaVersion = 51; runId = $runId; vmId = (VmId $m.n); wave = $m.wave; state = $m.state
            captured = [ordered]@{ vmConfig = (& $vmc); original = [ordered]@{ vmConfig = (& $vmc); capturedUtc = (& $at 0) } }
            safety = [ordered]@{ pristineSnapshotId = "/subscriptions/$sub/resourceGroups/rg-billing/providers/Microsoft.Compute/snapshots/$($m.n)-vmf-pristine"
                snapshotId = "/subscriptions/$sub/resourceGroups/rg-billing/providers/Microsoft.Compute/snapshots/$($m.n)-vmf-copy"
                pristineSnapshotLocked = $true; snapshotLocked = $true; locksAllowed = $true; cloneVmId = $null }
            guestExecutions = @(); history = @($history)
        })
}

Save 'capacity/web-pilot-d2s.json' ([ordered]@{ schemaVersion = 15; runId = $runId; wave = 'web-pilot'; subscriptionId = $sub
        resourceGroup = 'rg-billing'; region = 'centralus'; zone = $null; size = 'Standard_D2s_v6'; vmFamily = 'standardDSv6Family'
        state = 'QUOTA_VERIFIED'; blockReason = $null; regionalShort = $false; demand = @{ instances = 3; reservableInstances = 3; ownGroupVmIds = @(); vcpus = 6; familyVcpus = 6; regionalVcpus = 0; regionalAdds = 0 }
        quota = @{ limit = 20; used = 4; regionalLimit = 40; regionalUsed = 12; checkedUtc = '2026-09-24T18:30:00Z'; requestId = $null; requestedUtc = $null }; notes = @(); fallback = @() })

$events = @(
    @{ tsUtc = '2026-09-24T18:45:00Z'; step = 'acknowledge'; outcome = 'ok'; detail = 'infrastructure-as-code' }
    @{ tsUtc = '2026-09-24T19:00:00Z'; step = 'approve-plan'; outcome = 'ok' }
    @{ tsUtc = '2026-09-25T01:00:00Z'; step = 'wave'; outcome = 'ok'; detail = 'web-report-db complete' }
)
$log = Join-Path $RunPath 'logs' 'events.jsonl'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $log -Parent)
[System.IO.File]::WriteAllText($log, (($events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join "`n") + "`n")
$RunPath
