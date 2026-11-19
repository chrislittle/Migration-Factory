# TRUST-1: the security posture must survive the migration, and validation
# must prove it rather than assume it.
#
# Why this exists: Path B deletes the machine definition and rebuilds it from
# the capture. Before TRUST-1, the capture carried no securityProfile, the
# rebuild set none, and validation never compared - so a Trusted Launch
# machine's secure boot and vTPM rode entirely on whatever ARM defaulted to,
# and whatever came out the other side passed. A review of what the product
# did with Trusted Launch found nothing at all.
#
# Pure comparer, no Azure - the whole matrix is unit-testable, like
# Test-VmfNicFidelity and Test-VmfDataDiskFidelity beside it.

function Test-VmfSecurityFidelity {
    <#
    .SYNOPSIS
        Compare the machine's live security posture to what was captured.
    .OUTPUTS
        @{ Ok = bool; Detail = string; Verdict = 'MATCH'|'MISMATCH'|'UNKNOWN' }
    .NOTES
        Unknown stays unknown (the DRIVER-1 rule): a capture that predates the
        securityProfile field can prove nothing, and this returns UNKNOWN with
        Ok = $true rather than inventing a pass or manufacturing a failure on
        machines migrated before the field existed. The detail says exactly
        what could not be proven.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Captured,
        [Parameter()][AllowNull()]$Live
    )

    if (-not $Captured) {
        return @{ Ok = $true; Verdict = 'UNKNOWN'
                  Detail = 'no security posture was captured before the migration (pre-TRUST-1 capture) - nothing to compare against, so this proves nothing either way' }
    }

    $capType = if ([string]$Captured.securityType) { [string]$Captured.securityType } else { 'Standard' }
    $liveType = if ($Live -and [string]$Live.securityType) { [string]$Live.securityType } else { 'Standard' }

    if ($capType -ne $liveType) {
        return @{ Ok = $false; Verdict = 'MISMATCH'
                  Detail = "security type changed: the machine was '$capType' before the migration and is '$liveType' now" }
    }

    if ($capType -eq 'TrustedLaunch') {
        # Secure boot and vTPM are the substance of Trusted Launch; the label
        # alone matching proves little if either flag flipped.
        foreach ($flag in @(
            @{ name = 'secure boot'; cap = $Captured.secureBootEnabled; live = $Live.secureBootEnabled },
            @{ name = 'vTPM';        cap = $Captured.vTpmEnabled;       live = $Live.vTpmEnabled })) {
            if ($null -eq $flag.cap) { continue }   # not captured: cannot judge it
            if ([bool]$flag.cap -ne [bool]$flag.live) {
                return @{ Ok = $false; Verdict = 'MISMATCH'
                          Detail = "$($flag.name) changed: it was $([bool]$flag.cap) before the migration and is $([bool]$flag.live) now" }
            }
        }
    }

    @{ Ok = $true; Verdict = 'MATCH'; Detail = "security posture preserved: $capType" }
}
