# SCAN-PARTIAL-SUBS-1: a subscription whose sizes the scan could not read.
#
# The scan reads Azure's size list once for each subscription and region its
# machines are in (Read-VmfMachineCatalogs). A read that failed used to throw
# out of the scan, so ONE subscription the identity could not read stopped the
# scan of every other one, and no assessment was saved. Since 2026-11-08: the
# scan finishes for every other subscription, tries a failed read again, and
# then shows the user WHY it failed and how to fix it.
#
# So: a temporary failure is tried again by the product's one retry
# (Invoke-VmfAzOperation - no second loop here). A failure that remains is
# recorded as not read, with Azure's reason, the kind of failure, and the role
# and action the permission map names; the other subscriptions finish; and
# the machines of that subscription are held (blocker sizes-not-read), never
# shown as able to move and never dropped. Everything here is pure.

function Get-VmfReadFailureReason {
    <#
    .SYNOPSIS
        The kind of a read that failed, from Azure's answer: 'permission',
        'subscriptionNotFound' or 'other'. Pure, and it must not throw.
    .DESCRIPTION
        permission: HTTP 403, or Azure's code AuthorizationFailed or
        LinkedAuthorizationFailed. subscriptionNotFound: Azure's code
        SubscriptionNotFound. The status is the one on the error object, else
        one written where a message puts a status ($script:VmfStatusInTextPattern,
        the product's own rule - never a bare number anywhere in the text).
        A code is read from the error object, else as a whole word in the
        text. Anything else is other: never guessed to be a permission.
    .PARAMETER ErrorInfo
        The hashtable from Resolve-VmfOperationError (StatusCode, ErrorCode,
        Message).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$ErrorInfo)
    try {
        if ($null -eq $ErrorInfo) { return 'other' }
        $text = [string]$ErrorInfo.Message
        $code = [string]$ErrorInfo.ErrorCode
        $status = Get-VmfReadFailureStatus -ErrorInfo $ErrorInfo
        $hasCode = { param([string]$Name) $code -eq $Name -or $text -match "\b$Name\b" }
        if ($status -eq 403 -or (& $hasCode 'AuthorizationFailed') -or (& $hasCode 'LinkedAuthorizationFailed')) { return 'permission' }
        if (& $hasCode 'SubscriptionNotFound') { return 'subscriptionNotFound' }
        'other'
    }
    catch { 'other' }
}

function Get-VmfReadFailureStatus {
    <#
    .SYNOPSIS
        The HTTP status of a read that failed: the one on the error object,
        else one written where a message puts a status
        ($script:VmfStatusInTextPattern, the product's own rule). $null when
        neither says one. Pure, and it must not throw.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][AllowNull()]$ErrorInfo)
    try {
        if ($null -eq $ErrorInfo) { return $null }
        if ($null -ne $ErrorInfo.StatusCode) { return [int]$ErrorInfo.StatusCode }
        $m = [regex]::Match([string]$ErrorInfo.Message, $script:VmfStatusInTextPattern)
        if ($m.Success) { return [int]$m.Groups['s'].Value }
        $null
    }
    catch { $null }
}

function Get-VmfOperationAccess {
    <#
    .SYNOPSIS
        The role and the actions the permission map gives one Azure call -
        the name of the role, as the install creates it.
    .DESCRIPTION
        Read from data/rbac-actions.json, never written here, so what the page
        tells a person to give is what the install's role holds.
    .OUTPUTS
        @{ Role = roleName; Actions = string[] }, or $null when the map does
        not list the call.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Cmdlet,
        [Parameter()][string]$Path
    )
    $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'rbac-actions.json' }
    $map = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    $op = @($map.operations | Where-Object { [string]$_.cmdlet -eq $Cmdlet }) | Select-Object -First 1
    if (-not $op) { return $null }
    $roleKey = [string]$op.role
    $roleName = if ($map.roles.PSObject.Properties[$roleKey]) { [string]$map.roles.$roleKey.roleName } else { $roleKey }
    @{ Role = $roleName; Actions = @($op.actions | Where-Object { $_ }) }
}

function Get-VmfSizesNotRead {
    <#
    .SYNOPSIS
        One notRead entry (subject 'sizes') for each subscription and region
        whose size list the scan could not read. Pure.
    .PARAMETER Keys
        The catalog keys (Get-VmfCatalogKey) Read-VmfMachineCatalogs could not
        read.
    .PARAMETER Errors
        Each key -> the hashtable from Resolve-VmfOperationError.
    .PARAMETER Machines
        The inventory, to count the machines of each key.
    .OUTPUTS
        Ordered hashtables: subject, detail, subscriptionId, location, reason,
        statusCode, errorCode, machineCount, requiredRole, requiredAction,
        scope - sorted by subscription, then region.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Keys,
        [Parameter(Mandatory)][hashtable]$Errors,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Machines,
        [Parameter()][string]$IdProperty = 'id',
        [Parameter()][string]$MapPath
    )
    if (-not @($Keys).Count) { return @() }
    $accessArgs = @{ Cmdlet = 'Get-AzComputeResourceSku' }
    if ($MapPath) { $accessArgs.Path = $MapPath }
    $access = Get-VmfOperationAccess @accessArgs
    $entries = foreach ($key in @($Keys | Sort-Object -Unique)) {
        $sub, $loc = $key -split '\|', 2
        $err = $Errors[$key]
        $count = @($Machines | Where-Object {
                $_ -and [string]$_.location -and (Get-VmfCatalogKey -VmId ([string]$_.$IdProperty) -Location ([string]$_.location)) -eq $key }).Count
        $location = [string](@($Machines | Where-Object {
                    $_ -and [string]$_.location -and ([string]$_.location).ToLowerInvariant() -eq $loc }) | Select-Object -First 1).location
        [ordered]@{
            subject        = 'sizes'
            detail         = $(if ($err) { [string]$err.Message } else { $null })
            subscriptionId = $sub
            location       = $(if ($location) { $location } else { $loc })
            reason         = Get-VmfReadFailureReason -ErrorInfo $err
            statusCode     = Get-VmfReadFailureStatus -ErrorInfo $err
            errorCode      = $(if ($err -and $err.ErrorCode) { [string]$err.ErrorCode } else { $null })
            machineCount   = $count
            requiredRole   = $(if ($access) { $access.Role } else { $null })
            requiredAction = $(if ($access) { @($access.Actions)[0] } else { $null })
            scope          = $(if ($sub) { "/subscriptions/$sub" } else { $null })
        }
    }
    @($entries | Sort-Object { $_.subscriptionId }, { $_.location })
}
