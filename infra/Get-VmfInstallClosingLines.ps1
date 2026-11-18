# INSTALL-CLOSING-AFTER-CONSENT-1: lines of the install's closing that change
# with what the install read back. Dot-sourced by infra/hooks/postprovision.ps1.

function Get-VmfScopeAdminPageLine {
    <#
    .SYNOPSIS
        The line that sends the administrator to the Admin page to widen or
        narrow the product's reach. Nothing when the installer is not the
        administrator.
    .DESCRIPTION
        "Widen or narrow that on the Admin page at any time" was untrue for
        anybody whose directory keeps admin consent for an administrator, so
        the line said "once your directory has approved the product". That was
        printed also when the install had just read admin consent back as
        given (final lab, 2026-11-16) - a condition already met, said as one
        still open. Only a read back of 'given' drops it: a partial grant, no
        grant, a read that failed and a consent never read keep it.
    .PARAMETER AdminDone
        The installer holds Vmf.Admin, as the install read it back.
    .PARAMETER Consent
        What Get-VmfAdminConsentState (or Invoke-VmfAdminConsentInFlow)
        returned, or $null when the directory was not read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][bool]$AdminDone,
        [AllowNull()]$Consent
    )
    if (-not $AdminDone) { return }
    $given = $null -ne $Consent -and [string]$Consent.State -eq 'given'
    if ($given) { return 'Widen or narrow that on the Admin page.' }
    return 'Widen or narrow that on the Admin page, once your directory has approved the product.'
}
