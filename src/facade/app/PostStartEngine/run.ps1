# POST /api/runs/{runId}/engine/{operation} - launch a hosted engine
# execution (assess | plan | wave). Thin wrapper: logic in FacadeCore.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    # WAVE-SIZE-REMOVE-1: no wave size. A grouping makes one wave for each group,
    # of any size. OLD-VERSION-READERS-REMOVE-3: no page of this version sends
    # waveSize, and nothing is public before 1.0, so the route names no field
    # that only an earlier page sent.
    # Only wave starts require a reason (FacadeCore enforces it) - scanning and
    # planning change nothing.
    $params = @{
        Principal = $principal
        Operation = $Request.Params.operation
        RunId     = $Request.Params.runId
        Note      = [string]$body.note
    }
    # PROJECT-1: the project is a path segment the route cannot carry, so it
    # travels in the body. The guard in ApiBodyContract.Tests checks it is read.
    if ($body.project) { $params.Project = [string]$body.project }
    if ($body.wave) { $params.Wave = $body.wave }
    # SCOPE-RG-LIST-1: one name or several. The dashboard sends one today; an
    # estate spread across resource groups needs the allowlist the engine's own
    # setting is named for.
    if ($body.scopeRg) { $params.ScopeRg = @($body.scopeRg) }
    # SCOPE-SUBS-GUID-1: a presence test. "" and [""] are false, so if
    # ($body.scopeSubs) dropped them, and the engine scanned its own
    # subscription. FacadeCore refuses them.
    if ($null -ne $body.scopeSubs) { $params.ScopeSubs = @($body.scopeSubs) }        # SCOPE-1
    if ($body.scopeMg) { $params.ScopeMg = [string]$body.scopeMg }         # SCOPE-1
    if ($body.targetGeneration) { $params.TargetGeneration = [string]$body.targetGeneration }  # V7-UX-1
    if ($body.capacityGate) { $params.CapacityGate = [string]$body.capacityGate }  # CAP-3
    if ($body.waveStrategy) { $params.WaveStrategy = [string]$body.waveStrategy }  # WAVE-1
    if ($body.appGroupTag) { $params.AppGroupTag = [string]$body.appGroupTag }     # WAVE-1
    if ($body.vmId) { $params.VmId = [string]$body.vmId }                                  # RESTORE-1
    if ($body.diskNaming) { $params.DiskNaming = [string]$body.diskNaming }
    # ROLLBACK-ORIGINALS-LEFT-1: which disks deleteearlier deletes.
    if ($body.diskSet) { $params.DiskSet = [string]$body.diskSet }
    if ($body.acceptPreserveRisk) { $params.AcceptPreserveRisk = [bool]$body.acceptPreserveRisk }
    # EVAL-H6: a field FacadeCore declared and the dashboard sent was dropped
    # here once, and the state document then recorded the DEFAULT as what the
    # person chose. RESTORE-COPY-1: which safety copy a restore reads.
    if ($body.diskSource) { $params.DiskSource = [string]$body.diskSource }
    # REACH-1: the operations that used to be PowerShell only. Every
    # parameter FacadeCore declares is forwarded here - EVAL-H6 was two
    # declared-and-dropped fields on the restore path, and the way it hid was
    # that the state document then recorded the DEFAULTS as what the operator
    # chose. ApiBodyContract.Tests.ps1 now compares the two lists, both ways.
    if ($body.headroomVcpus) { $params.HeadroomVcpus = [int]$body.headroomVcpus }
    if ($body.whatIfOnly) { $params.WhatIfOnly = [bool]$body.whatIfOnly }
    # WAVE-APPROVE-1 (review 4): the version of the wave the caller judged;
    # the engine refuses the start if the wave changed since.
    if ($body.waveVersion) { $params.WaveVersion = [string]$body.waveVersion }
    $result = Invoke-VmfFacadeStartEngine @params
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Accepted; Body = ($result | ConvertTo-Json -Depth 6); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
