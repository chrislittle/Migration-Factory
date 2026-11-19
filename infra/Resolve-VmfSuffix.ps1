# INSTALL-0: which suffix a deployment into this resource group must use.
#
# Found 2026-09-04: the lab's suffix was passed as a fixed value. As in many
# deployments, the suffix must be generated, to make sure it is unique. So the
# templates now DERIVE
# the suffix from the resource group (uniqueString), and a customer types
# nothing.
#
# That creates one hazard, and this function is the guard against it: a
# deployment whose suffix was chosen by hand - ours - must never be redeployed
# with a derived one, because the template would then create a SECOND platform
# beside the first, with different names, and report success. The rule is:
#
#   an existing deployment's suffix wins   (read from the vmfstate* account
#                                           already in the group - the one
#                                           name every other name follows)
#   a fresh group passes nothing            (the template derives it)
#   a suffix given by hand is CHECKED       (against what exists; a mismatch
#                                           is a refusal, not a guess)
#
# Dot-sourced by infra/deploy.ps1 and infra/identity-deploy.ps1, so the two
# always answer the same way for the same group.
function Resolve-VmfSuffix {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter()][string]$BaseSuffix
    )
    # A group that does not exist yet is a fresh install, not an error; the
    # deployment itself will say so if the group is genuinely missing.
    $json = az storage account list -g $ResourceGroup -o json 2>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; $json = '[]' }
    $accounts = @(($json | ConvertFrom-Json) | Where-Object { $_.name -like 'vmfstate*' })

    if ($accounts.Count -gt 1) {
        throw ("Resource group '$ResourceGroup' holds $($accounts.Count) vmfstate* storage accounts " +
               "($(@($accounts | ForEach-Object { $_.name }) -join ', ')). Refusing to guess which deployment this is.")
    }
    $existing = if ($accounts.Count -eq 1) { [string]$accounts[0].name -replace '^vmfstate', '' } else { $null }

    if ($existing -and $BaseSuffix -and $existing -ne $BaseSuffix) {
        throw ("Resource group '$ResourceGroup' already holds a platform with suffix '$existing', and -BaseSuffix " +
               "says '$BaseSuffix'. Deploying would create a SECOND platform beside it. " +
               "Pass -BaseSuffix $existing, or leave it out to adopt what is there.")
    }
    if ($existing) { return $existing }
    return [string]$BaseSuffix   # empty means: the template derives one
}

# INSTALL-0 piece 4: which image the engine job must be deployed with. The job
# is created on a placeholder, and every code publish pins it to a built image
# by digest OUTSIDE the template. A hand redeploy that passed nothing would put
# the placeholder back - the same hazard as the suffix, with the same rule: an
# existing job's image wins; a missing job passes nothing and the template
# uses the placeholder.
function Resolve-VmfEngineImage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$JobName
    )
    $json = az containerapp job show -g $ResourceGroup -n $JobName -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { $global:LASTEXITCODE = 0; return '' }
    $job = $json | ConvertFrom-Json
    # Not `[0]`: this runs under the install hook's Set-StrictMode -Version
    # Latest, where indexing an empty array throws rather than returning null.
    # Same defect class as Get-VmfSubscriptionRoles, same install path.
    $container = @($job.properties.template.containers) | Select-Object -First 1
    if (-not $container) { return '' }
    return [string]$container.image
}

# PUBLISH-IN-1: the same rule for the PUBLISH job, which is created on the same
# placeholder and pinned by the same publish. Deliberately its own function
# rather than a job name parameter on the one above: the two jobs are two
# things, and a caller that had to remember which name goes with which template
# parameter is a caller that will one day put the engine image on the publish
# job. The names differ by one word.
function Resolve-VmfPublishImage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$JobName
    )
    return (Resolve-VmfEngineImage -ResourceGroup $ResourceGroup -JobName $JobName)
}
