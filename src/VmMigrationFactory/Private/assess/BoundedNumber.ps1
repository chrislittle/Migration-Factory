# LINUX-VERSION-OVERFLOW-1: a number a machine reports is read only when it
# fits.
#
# The VM agent reports the release of a Linux machine (Resource Graph
# osVersionRunning), and a guest script reports its kernel, its release and
# its disks. Root inside the machine controls each of them. A cast such as
# [int]'22.99999999999' throws "Value was either too large or too small for an
# Int32", and the module runs with $ErrorActionPreference = 'Stop': one machine
# stopped the assessment, or the target advice, of every machine in scope.
#
# So every reader of such a number asks here. A number that does not fit is
# not read: the caller treats it as unknown, never as a pass and never as a
# fail (CLAUDE.md: unknown is its own answer). Pure, and it never throws.

function ConvertTo-VmfBoundedNumber {
    <#
    .SYNOPSIS
        A run of digits as a number, or $null when it is not only digits or
        does not fit. Pure, and it never throws.
    .PARAMETER Text
        The digits, as the machine reported them.
    .PARAMETER Long
        Read it as a 64-bit number (a kernel version segment) - else 32-bit.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Text,
        [switch]$Long
    )
    # NumberStyles.None: digits only - no sign, no space, no separator.
    $style = [System.Globalization.NumberStyles]::None
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Long) {
        $n = [long]0
        if ([long]::TryParse([string]$Text, $style, $culture, [ref]$n)) { return $n }
        return $null
    }
    $i = 0
    if ([int]::TryParse([string]$Text, $style, $culture, [ref]$i)) { return $i }
    $null
}

function Test-VmfVersionInRange {
    <#
    .SYNOPSIS
        Does every run of digits in this version fit a 32-bit number? $false
        when one does not, or when the version has no digits. Pure.
    .DESCRIPTION
        '22.04' and '9.6' are in range; '22.99999999999' is not. A version
        that is not in range is a version the product cannot read.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Version)
    $runs = @([regex]::Matches([string]$Version, '\d+'))
    if (-not $runs.Count) { return $false }
    foreach ($r in $runs) {
        if ($null -eq (ConvertTo-VmfBoundedNumber -Text $r.Value)) { return $false }
    }
    $true
}
