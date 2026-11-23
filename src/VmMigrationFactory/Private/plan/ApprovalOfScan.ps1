function Assert-VmfApprovalOfScan {
    <#
    .SYNOPSIS
        ASSESS-APPROVAL-HASH-1: refuse an assessment approval that is not of
        the scan being planned from.
    .DESCRIPTION
        Approve-VmfAssessment records assessmentHash: the version (PLANVER-2,
        Get-VmfDocumentVersion over the stored text) of the scan the approver
        read. New-VmfPlan and New-VmfTargetAdvice used to ask only that an
        approval was there, so a scan that replaced the approved one was
        planned from with nobody having read it (Claude Security scan, F13).

        The caller reads the assessment text ONCE, makes the plan or the
        options from that text, and passes its version here. An approval with
        no hash names no scan, so it is refused as well. Every approval 1.0.0
        wrote holds the hash of the text it read, by the same function, and an
        assessment is never written again after its scan (Invoke-VmfAssessment
        creates it only), so a valid approval always passes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Approval,
        [Parameter(Mandatory)][string]$AssessmentVersion,
        [Parameter()][AllowEmptyString()][string]$AssessmentId = ''
    )
    $approved = [string](Get-VmfRecordField -Object $Approval -Name 'assessmentHash')
    if (-not [string]::Equals($approved, $AssessmentVersion, [System.StringComparison]::Ordinal)) {
        throw ("The approval of assessment '$AssessmentId' is for a different scan of these machines. " +
               'The product cannot plan a migration from it. Scan the machines again under a new name, and approve that scan.')
    }
}
