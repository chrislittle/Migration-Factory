function ConvertTo-VmfIsoUtc {
    <#
    .SYNOPSIS
        A stored time, written as ISO 8601 UTC ('2026-11-01T14:00:00Z').
    .DESCRIPTION
        ConvertFrom-Json turns an ISO date into a date value, and [string] of
        that is month-first with no zone (CLAUDE.md). REPORT-RELEASED-1 found
        the customer report printing reservation windows and restore times as
        "11/01/2026 14:00:00". One helper, for every writer of a time a person
        reads. A value that is not a date is returned as it was.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()]$Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    [string]$Value
}
