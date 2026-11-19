# TEMP-DISK-PREVIEW-1: the read of the preview feature VMTempDiskResizePreview.
#
# Since 2026-11-02, the product TELLS, and never registers. It reads the state
# of the feature on a subscription - with Microsoft.Features/providers/features/read,
# which the VMF Assessment role holds - for the targets step (through the
# service) and again in Checking, before any change. Registering the feature
# is the customer's own subscription-wide preview setting: a person with
# Contributor or Owner on the subscription does it, outside the product (a
# deliberate exception to hard rule 12).
#
# A read that fails is "not checked" - never Registered, never NotRegistered.

function Get-VmfPreviewFeatureState {
    <#
    .SYNOPSIS
        The state of the preview feature VMTempDiskResizePreview on one
        subscription, and the subscription's display name.
    .DESCRIPTION
        GET /subscriptions/{id}/providers/Microsoft.Features/providers/
        Microsoft.Compute/features/VMTempDiskResizePreview (api-version
        2021-07-01). Azure's states: NotRegistered, Pending, Registering,
        Registered, Unregistering, Unregistered. Only Registered lets the
        in-place upgrade across temporary disk kinds (measured).

        The name is read with GET /subscriptions/{id} (Microsoft.Resources/
        subscriptions/read, already in the role), so a person reads which
        subscription to register it on. A name that cannot be read is the id.
        Never throws for a failed read: it says it could not read.
        PREVIEW-RG-SCOPE-1: a read that fails also gives the HTTP status and
        the error code that Azure gave (Status 0 when Azure gave no answer),
        so the targets step and the stop of Checking can say them. Only a
        plain Azure code passes (letters, digits, dot, dash, underscore; 80
        characters at most); anything else is ''.
    .OUTPUTS
        @{ Read = bool; Registered = bool; State = string|null;
           SubscriptionName = string; Status = int; ErrorCode = string;
           Detail = string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    if ($SubscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "A subscription id is required to read the preview feature; '$SubscriptionId' is not one."
    }
    $feature = Get-VmfPreviewFeatureName

    $name = $SubscriptionId
    try {
        # PERF-TELEMETRY-1: timed, as every ARM call the service makes.
        $s = Invoke-VmfArmRequest -Method GET -Path "/subscriptions/$($SubscriptionId)?api-version=2022-12-01"
        if ($s -and [int]$s.StatusCode -eq 200 -and $s.Content) {
            $display = [string](($s.Content | ConvertFrom-Json -Depth 10).displayName)
            if ($display) { $name = $display }
        }
    }
    catch { Write-Verbose "The name of subscription $SubscriptionId was not read: $($_.Exception.Message)" }

    $path = "/subscriptions/$SubscriptionId/providers/Microsoft.Features/providers/$($feature.Namespace)/features/$($feature.Name)?api-version=2021-07-01"
    try {
        $r = Invoke-VmfArmRequest -Method GET -Path $path
    }
    catch {
        return @{ Read = $false; Registered = $false; State = $null; SubscriptionName = $name; Status = 0; ErrorCode = ''
                  Detail = "the read of $($feature.Name) failed: $($_.Exception.Message)" }
    }
    $code = if ($r) { [int]$r.StatusCode } else { 0 }
    $state = $null
    $body = $null
    if ($r -and $r.Content) {
        try { $body = $r.Content | ConvertFrom-Json -Depth 10 } catch { $body = $null }
    }
    if ($code -eq 200 -and $body) {
        try { $state = [string]$body.properties.state } catch { $state = $null }
    }
    if (-not $state) {
        $errorCode = Get-VmfArmAnswerCode -Body $body
        $answer = if ($errorCode) { "HTTP $code, $errorCode" } else { "HTTP $code" }
        return @{ Read = $false; Registered = $false; State = $null; SubscriptionName = $name; Status = $code; ErrorCode = $errorCode
                  Detail = "Azure did not give the state of $($feature.Name) ($answer)" }
    }
    @{ Read = $true; Registered = ($state -eq 'Registered'); State = $state; SubscriptionName = $name; Status = $code; ErrorCode = ''; Detail = '' }
}

function Get-VmfArmAnswerCode {
    <#
    .SYNOPSIS
        PREVIEW-RG-SCOPE-1: the error code of an ARM answer body (error.code,
        or code at the top), or '' when it has none or the value is not a
        plain Azure code. Pure: no Azure call, never throws.
    .DESCRIPTION
        The code goes to a page and to a stop, so only the shape of an Azure
        code passes: a letter first, then letters, digits, dot, dash or
        underscore, 80 characters at most (AuthorizationFailed,
        FeatureNotFound). A sentence or markup is ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Body)
    if ($null -eq $Body) { return '' }
    $value = ''
    try {
        if ($Body.PSObject.Properties['error'] -and $Body.error -and $Body.error.PSObject.Properties['code']) { $value = [string]$Body.error.code }
        elseif ($Body.PSObject.Properties['code']) { $value = [string]$Body.code }
    }
    catch { $value = '' }
    if ($value -cmatch '^[A-Za-z][A-Za-z0-9._-]{0,79}\z') { return $value }
    ''
}
