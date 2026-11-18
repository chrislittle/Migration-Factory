function ConvertFrom-VmfGuestOutput {
    <#
    .SYNOPSIS
        Parse and validate the JSON a guest script emitted via RunCommand.
    .DESCRIPTION
        RunCommand output may wrap the JSON in agent noise (status lines, BOM,
        blank lines). This finds the single vmf.guest/1 object, parses it, and
        enforces the contract (schemas/guest-output.schema.json invariants).
        Throws on any violation - the engine never guesses at guest output.
    .PARAMETER RawOutput
        The raw stdout text returned by Invoke-AzVMRunCommand.
    .OUTPUTS
        [pscustomobject] the validated guest output document.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RawOutput
    )

    if ([string]::IsNullOrWhiteSpace($RawOutput)) {
        throw 'Guest output is empty - the script may not have executed.'
    }

    # Find the vmf.guest JSON object: last line that parses as JSON with our schema marker.
    $doc = $null
    $lines = $RawOutput -split "`r?`n" | Where-Object { $_.Trim() }
    foreach ($line in $lines) {
        $t = $line.Trim().TrimStart([char]0xFEFF)
        if ($t.StartsWith('{') -and $t.Contains('"vmf.guest/')) {
            try { $doc = $t | ConvertFrom-Json -Depth 12 } catch { continue }
        }
    }
    if (-not $doc) {
        # Fallback: whole payload might be pretty-printed JSON
        $t = $RawOutput.Trim().TrimStart([char]0xFEFF)
        if ($t.StartsWith('{') -and $t.Contains('"vmf.guest/')) {
            try { $doc = $t | ConvertFrom-Json -Depth 12 } catch { $doc = $null }
        }
    }
    if (-not $doc) {
        throw 'No vmf.guest JSON object found in guest output.'
    }

    # Contract enforcement
    # GUEST-2 migration, v1 -> v2. v2 promotes facts from checks named
    # "fact:<name>" to a declared `facts` object. BOTH are accepted on READ,
    # deliberately: evidence stored by earlier runs is v1 and must stay
    # readable - a support bundle or a resumed wave should not become
    # unreadable because the contract moved. Guests only ever WRITE v2.
    # ORACLE-UEK-UPDATE-1: vmf.guest/5 declares uekRepositories.
    # CLUSTER-DETECT-1: vmf.guest/4 declares the cluster facts; a v2 or v3
    # output is a valid v4 one without them.
    # KERNEL-OFFER-EDGES-1 / KERNEL-FLOOR-UPLOAD-1: vmf.guest/6 declares
    # releaseverLock and kernelPackageVersion.
    # VF-UNMANAGED-CONFIG-1: vmf.guest/7 declares the facts of the unmanaged
    # network setting; a v2 to v6 output is a valid v7 one without them.
    if ($doc.schema -notin @('vmf.guest/1', 'vmf.guest/2', 'vmf.guest/3', 'vmf.guest/4', 'vmf.guest/5', 'vmf.guest/6', 'vmf.guest/7')) {
        throw "Unsupported guest output schema '$($doc.schema)' (expected vmf.guest/1, vmf.guest/2, vmf.guest/3, vmf.guest/4, vmf.guest/5, vmf.guest/6 or vmf.guest/7)."
    }
    foreach ($req in @('script', 'version', 'result', 'checks')) {
        if ($null -eq $doc.$req) { throw "Guest output missing required field '$req'." }
    }
    $validResults = @('READY', 'NEEDS_PREP', 'FIXED', 'NO_CHANGE', 'BLOCKED', 'PASS', 'FAIL')
    if ($doc.result -notin $validResults) { throw "Guest output has invalid result '$($doc.result)'." }
    if ($doc.version -notmatch '^\d+\.\d+\.\d+$') { throw "Guest output has invalid version '$($doc.version)'." }
    foreach ($check in @($doc.checks)) {
        if ([string]::IsNullOrWhiteSpace($check.name)) { throw 'Guest output check missing name.' }
        if ($check.status -notin @('PASS', 'FAIL', 'WARN', 'FIXED', 'INFO')) {
            throw "Guest output check '$($check.name)' has invalid status '$($check.status)'."
        }
    }

    return $doc
}
