<#
    Resolving the digest of an image that was just built.

    WHY THIS IS A FILE OF ITS OWN. These eight lines existed in THREE copies -
    the azd install hook, the facade publisher and the deploy workflow (removed
    2026-11-05) - and were changed three times in two days:

      ACR-DEPRECATED-1  `az acr repository show-manifests` is being retired
      ACR-TAG-1         listing every manifest and filtering on `$_.tags`
                        throws on a registry holding an UNTAGGED manifest
      ACR-DIGEST-1      `manifest show` has no digest on it at all

    Every one of those was found by the owner running `azd up`, and every one
    had to be fixed in three places. A copied contract is how two halves come to
    disagree; three copies of a command nobody can run in CI is worse.

    THE TWO COMMANDS THAT LOOK THE SAME.

      az acr manifest show           GET /v2/<repo>/manifests/<tag>
          the MANIFEST: schemaVersion, mediaType, config, layers. There is no
          digest on it. `config.digest` IS there and is the config blob - a
          different thing wearing the right name, which is what made this easy
          to get wrong twice.

      az acr manifest show-metadata  GET /acr/v1/<repo>/_manifests/<tag>
          the artifact's METADATA: digest, tags, createdTime. This is the one.

    `--query digest` on `show` prints an empty line and exits 0, so the check
    below is not defensive tidiness - it is the only thing between a silent
    empty answer and an image reference ending in `@`, which Azure refuses much
    later in a message naming neither the registry nor the tag.

    LONG FLAGS ON PURPOSE: `-n` names the REGISTRY in the retired
    show-manifests and the REPOSITORY in this one, so a rewrite that keeps the
    short flags asks for the wrong thing and the error names neither.

    ASK FOR ONE TAG, never a list. It is one call, it needs no filtering, and
    it assumes nothing about the shape of what comes back.

    Drilled against a real registry by tests/lab/Invoke-InstallDigestDrill.ps1,
    which is the only way this can be tested: every failure above was a fact
    about what an Azure CLI command returns, and no test that reads source can
    see one.
#>

# INSTALL-THROTTLE-RETRY-2: the digest read tries a throttled answer again.
. (Join-Path $PSScriptRoot 'Invoke-VmfAzStep.ps1')

function Resolve-VmfImageDigest {
    <#
    .SYNOPSIS
        The digest of one tag in one registry, and the reference that pins it.
    .DESCRIPTION
        Returns an object with two properties:

          Digest  sha256:... , as the registry reports it
          Image   <registry>.azurecr.io/<repository>@<digest>

        Image is here rather than at each caller because an image reference
        ending in `@` is the failure this whole file exists to prevent, and
        three places building that string by hand is three chances to do it.

        A lookup that fails, or that answers with nothing, THROWS. An absent
        digest is never an empty string passed on to the next step.
    .PARAMETER Registry
        The registry NAME, not its login server - `myregistry`, not
        `myregistry.azurecr.io`.
    .PARAMETER Repository
        The repository inside it, such as `vmf-engine`.
    .PARAMETER Tag
        The tag just built.
    .PARAMETER What
        Named in the error, so a failure says which image could not be
        resolved. Defaults to the repository.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter()][string]$What = ''
    )
    if (-not $What) { $What = $Repository }

    # INSTALL-THROTTLE-RETRY-2: a throttled read is tried again; a refusal
    # keeps its own words, and says a throttle.
    $read = Invoke-VmfAzCall -Step "read the digest of the $What image" -Command {
        az acr manifest show-metadata --registry $Registry --name "${Repository}:${Tag}" --query digest --only-show-errors -o tsv
    }
    $digest = $read.Output
    if ($read.ExitCode -ne 0 -or -not $digest) {
        throw ("Built the $What image but could not resolve the digest for ${Repository}:${Tag} in registry $Registry." +
               (Get-VmfAzThrottleNote -Result $read))
    }
    $digest = ([string]$digest).Trim()

    # The shape is checked because the caller pins a deployment to this string.
    # A registry that answered with a word rather than a digest would otherwise
    # be found out by Container Apps, somewhere that names none of this.
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "The registry answered '$digest' for ${Repository}:${Tag}, which is not a digest."
    }

    [pscustomobject]@{
        Digest = $digest
        Image  = "$Registry.azurecr.io/${Repository}@${digest}"
    }
}
