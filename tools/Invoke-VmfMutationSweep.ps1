# A mutation sweep over every check added on 2026-09-16/17.
#
# Break the thing each check guards, and see whether anything notices. A check
# that survives its own mutation is not a check.
#
# Pester is pinned explicitly here rather than going through
# tools/Invoke-VmfTests.ps1, because the sweep runs the suite sixteen times and
# the gates would add ten minutes of the same clean result. The final
# verification is a full Invoke-VmfTests.ps1 run.
param([string]$RepoRoot = 'C:\dev-work\vm-migration-factory')

Import-Module Pester -RequiredVersion 5.9.1
Set-Location $RepoRoot

$mutations = @(
    @{ n = 'CI-RUNNER-3: upstream-drift back on a GitHub runner'
       f = '.github/workflows/upstream-drift.yml'; t = 'tests/unit/CiRunner.Tests.ps1'
       a = 'runs-on: [self-hosted, Linux, vmf-ci-linux]'; b = 'runs-on: ubuntu-latest' }
    @{ n = 'CI-RUNNER-3: a runner label this project does not own'
       f = '.github/workflows/upstream-drift.yml'; t = 'tests/unit/CiRunner.Tests.ps1'
       a = 'runs-on: [self-hosted, Linux, vmf-ci-linux]'; b = 'runs-on: [self-hosted, Linux, vmf-ci-imaginary]' }

    @{ n = 'DRILL-SWITCH-1: take -ReportPath back out of the flow drill'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = "    [Parameter()][string]`$ReportPath = ''"; b = '' }
    @{ n = 'DRILL-SWITCH-1: document a switch that does not exist'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '.PARAMETER ReportPath'; b = ".PARAMETER Imaginary`r`n    Nothing.`r`n.PARAMETER ReportPath" }

    @{ n = 'ACR-DIGEST-1: the hook asks show, which has no digest'
       f = 'infra/Resolve-VmfImageDigest.ps1'; t = 'tests/unit/AzDeprecated.Tests.ps1'
       a = 'az acr manifest show-metadata --registry'; b = 'az acr manifest show --registry' }
    @{ n = 'ACR-DIGEST-1: drop the empty-answer guard'
       f = 'infra/Resolve-VmfImageDigest.ps1'; t = 'tests/unit/AzDeprecated.Tests.ps1'
       a = 'if ($LASTEXITCODE -ne 0 -or -not $digest) {'; b = 'if ($false) {' }
    @{ n = 'ACR-DIGEST-1: drop the digest SHAPE check'
       f = 'infra/Resolve-VmfImageDigest.ps1'; t = 'tests/unit/AzDeprecated.Tests.ps1'
       a = "if (`$digest -notmatch '^sha256:[0-9a-f]{64}`$') {"; b = 'if ($false) {' }
    @{ n = 'ACR-DIGEST-1: the hook grows its own copy of the lookup back'
       f = 'infra/hooks/postprovision.ps1'; t = 'tests/unit/AzDeprecated.Tests.ps1'
       a = "`$built = Resolve-VmfImageDigest -Registry `$acr -Repository 'vmf-engine' -Tag `$tag -What 'engine'"
       b = "`$digest = az acr manifest show-metadata --registry `$acr --name `"vmf-engine:`$tag`" --query digest -o tsv; `$built = [pscustomobject]@{ Image = `"`$acr.azurecr.io/vmf-engine@`$digest`" }" }

    @{ n = 'DRILL-TEARDOWN-1: a delete that cannot take a resource id'
       f = 'tests/lab/Invoke-InstallDigestDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'az resource delete --ids $registryId -o none'; b = 'az acr delete --ids $registryId --yes -o none' }
    @{ n = 'DRILL-TEARDOWN-1: let an unreadable answer print as removed'
       f = 'tests/lab/Invoke-InstallDigestDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '"cannot tell: the registry list could not be read. Check $registry by hand"'; b = '"removed"' }
    @{ n = 'INSTALL-DRILL-1: the drill drills a copy, not the real step'
       f = 'tests/lab/Invoke-InstallDigestDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'Resolve-VmfImageDigest -Registry $registry -Repository $repository -Tag $tag'
       b = 'az acr manifest show-metadata --registry $registry --name "${repository}:${tag}" --query digest -o tsv' }
    @{ n = 'INSTALL-DRILL-1: only one build, so no untagged manifest'
       f = 'tests/lab/Invoke-InstallDigestDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'az acr build -r $registry -t "${repository}:${tag}" -f Dockerfile . --output none'
       b = 'Write-Host "skipped"'; all = $true }

    @{ n = 'DRILL-ACCEPT-1: drop planHash from the accept body'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '-Body @{ project = $projectId; wave = $firstWave; planHash = $planHash }'
       b = '-Body @{ project = $projectId; wave = $firstWave }' }
    @{ n = 'DRILL-ACCEPT-1: hash a parsed object, not the stored text'
       f = 'tests/lab/_FacadeApi.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'Invoke-WebRequest'; b = 'Invoke-RestMethod' }
    @{ n = 'DRILL-ACCEPT-1: break the matcher so nothing pairs (VACUITY)'
       f = 'tests/unit/DrillFlow.Tests.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'if ($routeSegments.Count -ne $callerSegments.Count) { continue }'; b = 'if ($true) { continue }' }
    @{ n = 'DRILL-ACCEPT-1: hash in UPPER-case hex, which the service will not match'
       f = 'tests/lab/_FacadeApi.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = "ToString('x2')"; b = "ToString('X2')" }
    @{ n = 'DRILL-ACCEPT-1: hash with the wrong algorithm'
       f = 'tests/lab/_FacadeApi.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '[System.Security.Cryptography.SHA256]::Create()'; b = '[System.Security.Cryptography.SHA512]::Create()' }
    @{ n = 'INSTALL-DRILL-1: schedule the drill that spends money'
       f = '.github/workflows/upstream-drift.yml'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'jobs:'; b = "jobs:`r`n  # Invoke-InstallDigestDrill.ps1" }
    @{ n = 'DOC-ADDRESS-1: refuse over a plan without saying which plan'
       f = 'src/VmMigrationFactory/Public/Confirm-VmfWaveOptions.ps1'; t = 'tests/unit/WaveApproval.Tests.ps1'
       a = "The plan at '`$PlanPath' now reads"; b = 'The plan now reads' }
    @{ n = 'DOC-ADDRESS-1: and the same on the approval gate'
       f = 'src/VmMigrationFactory/Public/Approve-VmfWave.ps1'; t = 'tests/unit/WaveApproval.Tests.ps1'
       a = "The plan at '`$PlanPath' now reads"; b = 'The plan now reads' }
    @{ n = 'DOC-ADDRESS-1: stop saying where a missing plan was looked for'
       f = 'src/VmMigrationFactory/Public/Confirm-VmfWaveOptions.ps1'; t = 'tests/unit/WaveApproval.Tests.ps1'
       a = "throw `"No plan found at '`$PlanPath'.`""; b = 'throw "No plan found."' }
    @{ n = 'STORE-DOC-1: stop reading the version out of the refusal'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = "if (`$said -match 'The plan now reads ([0-9a-f]{6,})') { `$wanted = `$Matches[1] }"
       b = "`$wanted = ''" }
    @{ n = 'STORE-DOC-1: search only the one plan already known about'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = "`$plans = @(@(`$all.names) | Where-Object { `$_ -like '*plan.json' })"
       b = "`$plans = @(`"`$migPath/plan.json`")" }
    @{ n = 'STORE-DOC-1: say nothing when the document is not under the project'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'NOT under this project'; b = 'no comment' }
    @{ n = 'DRILL-EVIDENCE-1: go back to printing failures only in the table'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = "        foreach (`$row in @(`$rows | Where-Object { `$_.Result -eq 'FAIL' })) {"
       b = "        foreach (`$row in @(`$rows | Where-Object { `$_.Result -eq 'NOPE' })) {" }
    @{ n = 'DRILL-EVIDENCE-1: hide the diagnosis that says why'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = "        foreach (`$row in @(`$rows | Where-Object { `$_.Result -eq 'INFO' })) {"
       b = "        foreach (`$row in @(`$rows | Where-Object { `$_.Result -eq 'NOPE' })) {" }
    @{ n = 'DRILL-EVIDENCE-1: let the retry count as a pass'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = "Add-Row 'A second attempt with a fresh version' 'INFO' ``"
       b = "Add-Row 'A second attempt with a fresh version' 'OK' ``" }
    @{ n = 'DRILL-EVIDENCE-1: stop saying whether the plan moved'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'the plan MOVED'; b = 'something happened' }
    @{ n = 'ZERO-CAUSE-1: blame the resource group again'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '$why = "nothing in $ScopeResourceGroup"'
       b = '$why = "nothing in $ScopeResourceGroup - point it at a resource group that holds VMs"' }
    @{ n = 'ZERO-CAUSE-1: stop reading the engine identity'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'az role assignment list --assignee'; b = 'az role definition list --custom-role-only true #' }
    @{ n = 'ZERO-CAUSE-1: match the scope exactly, so a subscription grant reads as a miss'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '$scopeId.StartsWith([string]$_.scope, [System.StringComparison]::OrdinalIgnoreCase)'
       b = '$scopeId -eq [string]$_.scope' }
    @{ n = 'ZERO-CAUSE-1: let a check that could not run pick an answer'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'was not established'; b = 'so the group is empty' }
    @{ n = 'MISE-1: stop asking the sign-in layer to use MISE'
       f = 'infra/platform.bicep'; t = 'tests/unit/Install.Tests.ps1'
       a = "WEBSITE_AAD_ENABLE_MISE: 'true'"; b = "WEBSITE_AAD_SOMETHING_ELSE: 'true'" }
    @{ n = 'MISE-1: move the facade to a Linux function app, where MISE cannot run'
       f = 'infra/platform.bicep'; t = 'tests/unit/Install.Tests.ps1'
       a = "    kind: 'functionapp'"; b = "    kind: 'functionapp,linux'" }
    @{ n = 'MISE-1: drop the issuer, which returns 401 for every caller'
       f = 'infra/platform.bicep'; t = 'tests/unit/Install.Tests.ps1'
       a = 'openIdIssuer:'; b = 'openIdIssuerNot:' }
    @{ n = 'MISE-1: relax the gate instead of changing the validator'
       f = 'infra/platform.bicep'; t = 'tests/unit/Install.Tests.ps1'
       a = 'requireAuthentication: true'; b = 'requireAuthentication: false' }
    @{ n = 'ODCR-FAMILY-1: judge each cell on its own demand again'
       f = 'src/VmMigrationFactory/Public/Test-VmfQuota.ps1'; t = 'tests/unit/AssessAndPlan.Tests.ps1'
       a = 'if ($headroom -ge $familyNeeded) { $state = ''QUOTA_VERIFIED'' }'
       b = 'if ($headroom -ge $needed) { $state = ''QUOTA_VERIFIED'' }' }
    @{ n = 'ODCR-FAMILY-1: stop naming the sizes that share the pool'
       f = 'src/VmMigrationFactory/Public/Test-VmfQuota.ps1'; t = 'tests/unit/AssessAndPlan.Tests.ps1'
       a = '" - this plan asks for $needed here and $familyNeeded in total for the family, shared with $($sharers -join '', '')"'
       b = '""' }
    @{ n = 'ODCR-FAMILY-1: total the family across ALL sizes, including its own, twice'
       f = 'src/VmMigrationFactory/Public/Test-VmfQuota.ps1'; t = 'tests/unit/AssessAndPlan.Tests.ps1'
       a = '$familyAsk[$key].Vcpus += ($cell.Count * [int]$(if ($perVm) { $perVm.Value } else { 0 }))'
       b = '$familyAsk[$key].Vcpus += (2 * $cell.Count * [int]$(if ($perVm) { $perVm.Value } else { 0 }))' }
    @{ n = 'ACCEPT-HASH-1: the drill computes a version the engine will not take'
       f = 'tests/lab/_FacadeApi.ps1'; t = 'tests/unit/WaveApproval.Tests.ps1'
       a = '$bytes = [System.Text.Encoding]::UTF8.GetBytes($PlanText)'
       b = '$bytes = [System.Text.Encoding]::Unicode.GetBytes($PlanText)' }
    @{ n = 'ACCEPT-HASH-1: the engine stops comparing, so any version is taken'
       f = 'src/VmMigrationFactory/Public/Confirm-VmfWaveOptions.ps1'; t = 'tests/unit/WaveApproval.Tests.ps1'
       a = 'if ($ExpectedPlanHash -and $ExpectedPlanHash -ne $planHash) {'; b = 'if ($false) {' }
    @{ n = 'BUILD-MATCH-1: treat an unknown build as a match'
       f = 'tests/lab/_FacadeApi.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = 'IsCurrent  = [bool]($serviceCommit -and $localCommit -and $serviceCommit -eq $localCommit)'
       b = 'IsCurrent  = [bool]($serviceCommit -eq $localCommit)' }
    @{ n = 'BUILD-MATCH-1: let each drill carry its own comparison'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '$build = Get-VmfServiceBuild -Api $facadeApi'
       b = '$build = [pscustomobject]@{ Comparable = $true; IsCurrent = $true; Commit = (git rev-parse HEAD); Local = (git rev-parse HEAD) }' }
    @{ n = 'BUILD-MATCH-1: cast the object instead of reading the field'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '$service = [string]$version.service.version'; b = '$service = [string]$version.service' }
    @{ n = 'BUILD-MATCH-1: check the build AFTER asking to spend'
       f = 'tests/lab/Invoke-VmfEndToEnd.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = '    $build = Get-VmfServiceBuild -Api $checkApi'; b = '    $build = $null' }
    @{ n = 'BUILD-MATCH-1: make a stale service a FAIL, which teaches people to ignore it'
       f = 'tests/lab/Invoke-FlowDrill.ps1'; t = 'tests/unit/DrillFlow.Tests.ps1'
       a = "Add-Row 'The service runs this code' 'WARN'"; b = "Add-Row 'The service runs this code' 'FAIL'" }
    @{ n = 'ACCEPT-EVIDENCE-1: refuse without saying what was compared'
       f = 'src/VmMigrationFactory/Public/Confirm-VmfWaveOptions.ps1'; t = 'tests/unit/WaveApproval.Tests.ps1'
       a = '"The plan at ''$PlanPath'' now reads $(Get-VmfShortHash $planHash) and the caller sent $(Get-VmfShortHash $ExpectedPlanHash). " +'
       b = '' }
    @{ n = 'ACCEPT-EVIDENCE-1: drop a missing half silently'
       f = 'src/VmMigrationFactory/Private/state/PlanContract.ps1'; t = 'tests/unit/WaveApproval.Tests.ps1'
       a = "if ([string]::IsNullOrWhiteSpace(`$Hash)) { return 'nothing' }"
       b = "if ([string]::IsNullOrWhiteSpace(`$Hash)) { return '' }" }
    @{ n = 'ACCEPT-EVIDENCE-1: stop refusing, only report'
       f = 'src/VmMigrationFactory/Public/Confirm-VmfWaveOptions.ps1'; t = 'tests/unit/WaveApproval.Tests.ps1'
       a = 'if ($ExpectedPlanHash -and $ExpectedPlanHash -ne $planHash) {'; b = 'if ($false) {' }
)

$results = foreach ($m in $mutations) {
    $path = Join-Path $RepoRoot $m.f
    $original = Get-Content $path -Raw
    $applied = $false
    if ($original.Contains($m.a)) {
        $mutated = if ($m.all) { $original.Replace($m.a, $m.b) } else {
            $index = $original.IndexOf($m.a)
            $original.Substring(0, $index) + $m.b + $original.Substring($index + $m.a.Length)
        }
        Set-Content -LiteralPath $path -Value $mutated -NoNewline -Encoding utf8NoBOM
        $applied = $true
    }
    if (-not $applied) {
        [pscustomobject]@{ Mutation = $m.n; Verdict = 'NOT APPLIED'; Failed = 0 }
        continue
    }
    # SUITE-SPEED-1: no TestRegistry key per file (see Invoke-VmfPesterParallel.ps1).
    $sweepConfig = New-PesterConfiguration
    $sweepConfig.Run.Path = (Join-Path $RepoRoot $m.t)
    $sweepConfig.Run.PassThru = $true
    $sweepConfig.Output.Verbosity = 'None'
    $sweepConfig.TestRegistry.Enabled = $false
    $run = Invoke-Pester -Configuration $sweepConfig
    Set-Content -LiteralPath $path -Value $original -NoNewline -Encoding utf8NoBOM
    [pscustomobject]@{
        Mutation = $m.n
        Verdict  = if ($run.FailedCount -gt 0) { 'caught' } else { 'SURVIVED' }
        Failed   = $run.FailedCount
    }
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Host
$bad = @($results | Where-Object { $_.Verdict -ne 'caught' })
Write-Host ""
Write-Host "$($results.Count) mutations, $($results.Count - $bad.Count) caught, $($bad.Count) not." -ForegroundColor $(if ($bad.Count) { 'Red' } else { 'Green' })
