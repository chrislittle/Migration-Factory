#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-0 piece 1 - the platform carries no lab value as a default, and the
# suffix is derived.
#
# Found 2026-09-04: `baseSuffix=examplesuffix` was passed as a fixed value. It
# must be a generated suffix, as in many deployments and Terraform modules, so
# that names are unique - some Azure resources cannot share a name.
#
# So: both templates derive the suffix from the resource group (the same
# group always yields the same suffix, so identity and platform agree without
# being told); the deploy scripts take parameters and ADOPT an existing
# deployment's suffix rather than deriving a second platform beside it; the
# dashboard's invented default scope is gone; the access script reads its
# region from the resource group. Our lab keeps passing its own suffix, so
# nothing deployed moves.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:infra = Join-Path $script:repoRoot 'infra'
    $script:platform = Get-Content (Join-Path $script:infra 'platform.bicep') -Raw
    $script:identity = Get-Content (Join-Path $script:infra 'identity.bicep') -Raw
    $script:deploy = Get-Content (Join-Path $script:infra 'deploy.ps1') -Raw
    $script:identityDeploy = Get-Content (Join-Path $script:infra 'identity-deploy.ps1') -Raw
    $script:dashDeploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
    $script:grant = Get-Content (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1') -Raw

    # Code only. A comment may NAME the lab while explaining why the lab is
    # not in the code; what must not exist is a lab value that RUNS.
    function Global:StripCodeComments {
        param([string]$Text, [string]$Kind)
        if ($Kind -eq 'ps1') {
            $t = [regex]::Replace($Text, '(?s)<#.*?#>', '')
            return (($t -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        }
        $t = [regex]::Replace($Text, '(?s)/\*.*?\*/', '')
        return (Get-VmfCodeOnly -Language CStyle -Text $t)
    }
    # Our lab's group and region, and any fixed suffix. The lab suffix and our
    # two Entra application ids used to be literals here too; HEAD-SCRUB-1 took
    # them out of this file, and NoLiveIdentifiers.Tests.ps1 now looks for them
    # in every tracked file, by hash.
    $script:labValues = 'rg-vmf-lab|centralus|baseSuffix\s*[:=]\s*[''"][a-z0-9]+'
}
AfterAll { Remove-Item 'function:\StripCodeComments' -ErrorAction SilentlyContinue }

Describe 'INSTALL-0: no template or deploy script carries a lab value in code' {

    It 'found the files, or this proves nothing' {
        @(Get-ChildItem $script:infra -Filter '*.bicep').Count | Should -BeGreaterThan 2
        @(Get-ChildItem $script:infra -Filter '*.ps1').Count | Should -BeGreaterThan 1
    }

    It 'every template and script is clean' {
        $files = @(Get-ChildItem $script:infra -Filter '*.bicep') + @(Get-ChildItem $script:infra -Filter '*.ps1') +
            @(Get-ChildItem (Join-Path $script:infra 'hooks') -Filter '*.ps1') +
            @(Get-ChildItem (Join-Path $script:repoRoot 'tools') -Filter 'Deploy-Vmf*.ps1') +
            @(Get-Item (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1')) +
            @(Get-Item (Join-Path $script:repoRoot 'azure.yaml'))
        $hits = foreach ($f in $files) {
            $code = StripCodeComments -Text (Get-Content $f.FullName -Raw) -Kind ($f.Extension.TrimStart('.'))
            foreach ($m in [regex]::Matches($code, $script:labValues)) { "$($f.Name): $($m.Value)" }
        }
        @($hits) -join ', ' | Should -BeNullOrEmpty -Because 'a customer running this would deploy into OUR group with OUR names'
    }

    It 'and the sample dashboard configuration names no lab resource group' {
        Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'dashboard.sample.config.json') -Raw |
            Should -Not -Match 'rg-vmf-lab'
    }
}

Describe 'INSTALL-0: the suffix is derived, and the two templates agree' {

    It 'platform.bicep derives it from the resource group' {
        $script:platform | Should -Match 'param baseSuffix string = uniqueString\(resourceGroup\(\)\.id\)'
    }

    It 'identity.bicep derives it the same way, so the dashboard address needs no passing' {
        $script:identity | Should -Match 'param baseSuffix string = uniqueString\(resourceGroup\(\)\.id\)'
        $script:identity | Should -Match "param dashboardOrigin string = 'https://vmf-dash-\$\{baseSuffix\}\.azurewebsites\.net'"
    }

    It 'the derived suffix fits the tightest name limit, the storage account' {
        # uniqueString is 13 characters. The storage account is the one name
        # with a 24-character limit and no separators.
        $m = [regex]::Match($script:platform, "var storeName = '([a-z]+)\$\{baseSuffix\}'")
        $m.Success | Should -BeTrue
        ($m.Groups[1].Value.Length + 13) | Should -BeLessOrEqual 24
    }
}

Describe 'INSTALL-0: the deploy scripts adopt an existing deployment rather than deriving a second one' {
    BeforeAll {
        . (Join-Path $script:infra 'Resolve-VmfSuffix.ps1')
        # `az` is an external command; a FUNCTION of the same name wins
        # resolution, so the helper is driven without Azure.
        function Global:SetLabStore { param([string[]]$Names) $script:storeNames = $Names }
        function Global:az {
            $rows = @($script:storeNames | ForEach-Object { @{ name = $_ } })
            $rows | ConvertTo-Json -AsArray
        }
    }
    AfterAll { Remove-Item 'function:\az', 'function:\SetLabStore' -ErrorAction SilentlyContinue }

    It 'both scripts use the one helper' {
        foreach ($s in $script:deploy, $script:identityDeploy) {
            $s | Should -Match "\. \(Join-Path \`$PSScriptRoot 'Resolve-VmfSuffix\.ps1'\)"
            $s | Should -Match 'Resolve-VmfSuffix -ResourceGroup \$ResourceGroup -BaseSuffix \$BaseSuffix'
        }
    }

    It 'a fresh group passes nothing, and the template derives' {
        SetLabStore @()
        Resolve-VmfSuffix -ResourceGroup 'rg-new' | Should -BeNullOrEmpty
        $script:deploy | Should -Match 'if \(\$suffix\) \{ \$params \+= "baseSuffix=\$suffix" \}'
    }

    It 'an existing deployment wins, read from the store that every other name follows' {
        SetLabStore @('vmfstateabc123')
        Resolve-VmfSuffix -ResourceGroup 'rg-lab' | Should -Be 'abc123'
        Resolve-VmfSuffix -ResourceGroup 'rg-lab' -BaseSuffix 'abc123' | Should -Be 'abc123'
    }

    It 'a suffix given by hand that disagrees with what exists is a refusal, not a second platform' {
        SetLabStore @('vmfstateabc123')
        { Resolve-VmfSuffix -ResourceGroup 'rg-lab' -BaseSuffix 'other1' } | Should -Throw '*SECOND platform*'
    }

    It 'two stores in one group is a refusal to guess' {
        SetLabStore @('vmfstateabc123', 'vmfstatedef456')
        { Resolve-VmfSuffix -ResourceGroup 'rg-lab' } | Should -Throw '*Refusing to guess*'
    }

    It 'the API id comes from the directory, never a literal - and by an EXACT name' {
        # It used to be `az ad app list --display-name X --query '[0].appId'`,
        # which takes whichever registration the directory listed first. A
        # display name is not unique in Entra, and this id becomes the
        # application the facade validates every token against.
        $script:deploy | Should -Match 'Get-VmfEntraApplication -DisplayName \$ApiDisplayName'
        $script:deploy | Should -Match '\$apiAppId = \[string\]\$apiApp\.appId'
        (StripCodeComments -Text $script:deploy -Kind 'ps1') | Should -Not -Match 'az ad app list'
        # piece 3: the identity script no longer needs the id at all - the
        # template sets the identifier itself.
        $script:identityDeploy | Should -Not -Match 'apiIdentifierUri'
    }
}

Describe 'INSTALL-0: the smaller lab defaults are gone too' {

    It 'the dashboard deploy no longer invents a default scan scope' {
        # No page ever read the key it wrote. Code only: the comment that
        # explains the removal is allowed to name what was removed.
        $code = StripCodeComments -Text $script:dashDeploy -Kind 'ps1'
        $code | Should -Not -Match 'DefaultScopeRg'
        $code | Should -Not -Match 'scopeRg'
    }

    It 'the access script takes its region from the resource group' {
        $script:grant | Should -Match 'az group show -n \$ResourceGroup --subscription \$SubscriptionId --query location -o tsv'
        # ROLES-1 moved the deployment itself into Set-VmfRoleScopes, so the
        # region is read here and handed over rather than used twice inline.
        # What matters is unchanged: the region comes from the resource group
        # this install lives in, never from a literal of ours.
        $script:grant | Should -Match 'Set-VmfRoleScopes -SubscriptionId \$installSub -Location \$location'
        $script:grant | Should -Not -Match "-l '[a-z]+us'|--location '[a-z]+us'" 
    }
}

# PUBLIC-SYNC-1: in the public repository the workflows are read when there are any.
Describe 'INSTALL-0 piece 2, retired: no deploy principal, so no update model' {
    # INSTALL-0 piece 2 made the deploy principal a choice: empty = a person
    # runs the update, given = a pipeline runs it and the template granted it
    # push and build on the registry, jobs contributor, website contributor
    # and reader. PIPELINE-LATER-1 (2026-11-02) moved every pipeline
    # model past 1.0, so the parameter and every grant it drove are gone.
    # tests/unit/PipelineLater.Tests.ps1 holds the whole of that; what stays
    # here is the one rule of this Describe that outlives the parameter.

    It 'no install file or workflow names a deploy identity for one vendor' {
        foreach ($f in @(Get-ChildItem $script:infra -Filter '*.bicep') + @(Get-ChildItem $script:infra -Filter '*.ps1') +
                       @(if (Test-Path (Join-Path $script:repoRoot '.github' 'workflows')) { Get-ChildItem (Join-Path $script:repoRoot '.github' 'workflows') -Filter '*.yml' })) {
            $code = StripCodeComments -Text (Get-Content $f.FullName -Raw) -Kind 'ps1'
            $code | Should -Not -Match 'githubOidcPrincipalId' -Because "$($f.Name) still names the parameter for one vendor"
        }
    }
}
Describe 'INSTALL-0 piece 3: identity deploys in one pass' {
    # Tokens are issued for api://<the registration's own id>, which does not
    # exist until the registration does. This was a second run of the script
    # with the id pasted in, and the script carried OUR id as a literal.

    It 'has no second-pass parameter' {
        $script:identity | Should -Not -Match 'param apiIdentifierUri'
    }

    It 'sets the identifier from the registration itself, in a second declaration of the same registration' {
        $script:identity | Should -Match "resource apiAppIdentifier 'Microsoft.Graph/applications@v1.0' = \{"
        $script:identity | Should -Match 'uniqueName: apiApp\.uniqueName'
        $script:identity | Should -Match "identifierUris: \[ 'api://\$\{apiApp\.appId\}' \]"
    }

    It 'and the second declaration carries the full definition, so an upsert cannot strip the roles or the API' {
        $blocks = @([regex]::Matches($script:identity, "(?s)resource (apiApp|apiAppIdentifier) 'Microsoft.Graph/applications@v1.0' = \{.*?\n\}"))
        $blocks.Count | Should -Be 2
        foreach ($b in $blocks) {
            $b.Value | Should -Match 'appRoles: apiAppRoles'
            $b.Value | Should -Match 'api: apiApi'
        }
    }

    It 'the deploy script passes nothing for it and speaks of no second run' {
        $script:identityDeploy | Should -Not -Match 'apiIdentifierUri'
        $script:identityDeploy | Should -Not -Match 'redeploy once'
    }

    # PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
    It 'CI compiles every template, every push' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci.yml'))) {
        $ci = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $ci | Should -Match 'name: Templates compile'
        $ci | Should -Match 'az bicep build --file \$t\.FullName'
    }
}

Describe 'INSTALL-0 piece 4: the platform deploys in one pass' {
    # The engine job needs an image that exists, and the registry that holds
    # the real one is created by the same template. This was a second run with
    # deployEngineJob=true after the image was built. Now the job is always
    # created - on Microsoft's public sample job image as a placeholder - and
    # the first publish replaces it. All of it happens inside azd up.
    BeforeAll {
        . (Join-Path $script:infra 'Resolve-VmfSuffix.ps1')
        function Global:SetLabJob { param([string]$Image) $script:jobImage = $Image }
        function Global:az {
            if ($script:jobImage) { @{ properties = @{ template = @{ containers = @(@{ image = $script:jobImage }) } } } | ConvertTo-Json -Depth 8 }
            else { $global:LASTEXITCODE = 3; $null }
        }
    }
    AfterAll { Remove-Item 'function:\az', 'function:\SetLabJob' -ErrorAction SilentlyContinue }

    It 'the second-pass switch is gone from every template, script and workflow' {
        $files = @(Get-ChildItem $script:infra -Filter '*.bicep') + @(Get-ChildItem $script:infra -Filter '*.ps1') +
            @(if (Test-Path (Join-Path $script:repoRoot '.github' 'workflows')) { Get-ChildItem (Join-Path $script:repoRoot '.github' 'workflows') -Filter '*.yml' })
        foreach ($f in $files) {
            $code = StripCodeComments -Text (Get-Content $f.FullName -Raw) -Kind 'ps1'
            $code | Should -Not -Match 'deployEngineJob|engineImageTag' -Because "$($f.Name) still carries the two-pass switch"
        }
    }

    It 'the job is always deployed, on the placeholder by default' {
        $script:platform | Should -Match "param engineImage string = 'mcr\.microsoft\.com/k8se/quickstart-jobs:latest'"
        $script:platform | Should -Match "module engineJob 'br/public:avm/res/app/job:0\.7\.2' = \{"
        $script:platform | Should -Match 'image: engineImage'
        $script:platform | Should -Match 'output engineJobResourceId string = engineJob\.outputs\.resourceId'
        $script:platform | Should -Match 'VMF_ENGINE_JOB_ID: engineJobResourceId'
    }

    It 'a hand redeploy adopts the image a publish pinned rather than putting the placeholder back' {
        $script:deploy | Should -Match 'Resolve-VmfEngineImage -ResourceGroup \$ResourceGroup -JobName "vmf-engine-\$suffix"'
        $script:deploy | Should -Match 'if \(\$engineImage\) \{ \$params \+= "engineImage=\$engineImage" \}'
        SetLabJob 'vmfacr.azurecr.io/vmf-engine@sha256:abc'
        Resolve-VmfEngineImage -ResourceGroup 'rg' -JobName 'vmf-engine-x' | Should -Be 'vmfacr.azurecr.io/vmf-engine@sha256:abc'
    }

    It 'and a fresh install, with no job yet, passes nothing so the template uses the placeholder' {
        SetLabJob ''
        Resolve-VmfEngineImage -ResourceGroup 'rg' -JobName 'vmf-engine-x' | Should -BeNullOrEmpty
        $global:LASTEXITCODE | Should -Be 0 -Because 'a missing job is a fresh install, not an error left behind'
    }

    It 'the service says plainly when the job still runs the placeholder' {
        $core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $core | Should -Match "quickstart-jobs\*'\) \{"
        $core | Should -Match 'No engine image yet\. The first code publish builds it and sets it\.'
    }
}
