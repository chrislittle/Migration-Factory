# AN-PRIMARY-1: the assessment format's version, in one place - the same
# arrangement the plan has (PlanContract.ps1).
#
# Every read of an assessment that gates on its version comes through
# Assert-VmfSupportedAssessment. OLD-VERSION-READERS-REMOVE-1 (2026-11-11:
# no install has an earlier version): nothing is public before 1.0, so no
# store holds an assessment of an earlier version. The check takes the
# version this build writes and no other: a newer one is refused because this
# build cannot know what it means, and an older one because no reader of this
# build takes its shape. The versions and what each changed are in
# docs/schema-migrations.md.

$script:VmfAssessmentSchemaVersion = 17

function Get-VmfAssessmentSchemaVersion {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $script:VmfAssessmentSchemaVersion
}

function Assert-VmfSupportedAssessment {
    <#
    .SYNOPSIS
        Refuse an assessment of any version but the one this build writes.
    .DESCRIPTION
        Version 17 (TARGET-CAPABILITY-PRECHECK-1: encryptionAtHost and
        ultraSsdEnabled on each machine) is the current version. The
        earlier versions are in docs/schema-migrations.md; no reader of this
        build takes them (OLD-VERSION-READERS-REMOVE-1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Assessment,
        [Parameter()][string]$Source = 'assessment.json'
    )
    $current = Get-VmfAssessmentSchemaVersion
    $version = 0
    if (-not $Assessment -or -not [int]::TryParse([string]$Assessment.schemaVersion, [ref]$version) -or $version -lt 1) {
        throw "Unsupported assessment schemaVersion '$($Assessment.schemaVersion)'."
    }
    if ($version -gt $current) {
        throw ("This assessment ($Source) was written by a newer version of the product - it is version $version and this build understands up to $current. " +
               'Refusing to use it rather than guessing what the newer fields mean. Upgrade the product, or scan again with this one.')
    }
    if ($version -lt $current) {
        throw ("This assessment ($Source) is version $version, and this version of the product reads only version $current. " +
               'Scan again with this version, then use the new assessment.')
    }
}