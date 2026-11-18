function Remove-VmfProject {
    <#
    .SYNOPSIS
        PROJ-DEL-1: delete an empty project.
    .DESCRIPTION
        The dashboard had no delete button for assessments or projects, so
        there was no way to clear them out from the app.

        A store that fills with projects nobody can remove is a store
        people stop trusting, and "it might be important" is not a reason to
        leave no way out - the same argument that produced Remove-VmfRun.

        THE PROJECT MUST BE EMPTY. This refuses while any assessment or
        migration still lives under the prefix, and it names them. Deleting a
        project is deleting a NAME; deleting the work inside it is a series of
        separate decisions, each with its own question about safety copies, and
        rolling them into one button labelled "delete project" is how somebody
        loses a migration record that still knows how to roll a machine back.

        Nothing here touches a machine. A project is a prefix and a document.
    .PARAMETER StorePath
        The container root - `azblob://<account>/<container>` or a local folder.
    .PARAMETER ProjectId
        The project prefix to remove.
    .PARAMETER Reason
        Why. Recorded with the deletion.
    .PARAMETER RemovedBy
        Who asked, when the caller acts for somebody (the facade does).
    .EXAMPLE
        Remove-VmfProject -StorePath azblob://vmfstate/vmf-runs -ProjectId ux-test-project -Reason 'test project'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)]
        # Case-sensitive, like New-VmfProject: a blob prefix is case-sensitive,
        # so an id that differs only in case is a DIFFERENT project.
        [ValidatePattern('^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$', Options = 'None')]
        [string]$ProjectId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
        [Parameter()][string]$RemovedBy
    )

    $projectPath = "$($StorePath.TrimEnd('/', '\'))/$ProjectId"

    if (-not (Test-VmfStoreItem -RunPath $projectPath -RelPath 'project.json')) {
        throw "There is no project called '$ProjectId' here."
    }
    $doc = Read-VmfStoreJson -RunPath $projectPath -RelPath 'project.json' -Depth 6

    # What is still inside. Read from the store rather than from a count kept
    # somewhere, because a count that can be wrong is worse than no count when
    # the question is "may I delete this".
    $members = @(Get-VmfStorePrefixes -StorePath $projectPath)
    if ($members.Count) {
        $shown = ($members | Select-Object -First 5) -join ', '
        $more = if ($members.Count -gt 5) { " and $($members.Count - 5) more" } else { '' }
        throw ("Project '$ProjectId' still holds $($members.Count) assessment(s) or migration(s): " +
               "$shown$more. Delete those first - each one is its own decision about what to keep.")
    }

    $who = if ($RemovedBy) { $RemovedBy } else { (Get-VmfSignedInIdentity).Identity }
    if (-not $PSCmdlet.ShouldProcess($projectPath, "delete the project '$($doc.name)'")) { return }

    # -Confirm:$false because THIS cmdlet already asked; the helper asking again
    # is the same question twice. Same call shape as Remove-VmfRun.
    $docs = Remove-VmfStorePrefix -RunPath $projectPath -Confirm:$false

    [pscustomobject]@{
        ProjectId = $ProjectId
        Name      = [string]$doc.name
        RemovedBy = $who
        Reason    = $Reason
        Documents = $docs
    }
}
