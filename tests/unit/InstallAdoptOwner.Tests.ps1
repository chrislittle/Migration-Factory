#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-ADOPT-OWNER-1: an install never takes over an Entra registration it
# did not make.
#
# identity.bicep UPSERTS each registration by its uniqueName. A first install
# with no recorded key used to look the API registration up by DISPLAY NAME and,
# on one match, record an EMPTY key - so the uniqueName was the display name,
# 'vmf-api-<environment>', which anybody can guess. A tenant member who made
# that registration first owned the application the service trusts, and could
# give themselves the Vmf.Admin role.
#
# The first fix adopted a same-named registration when the installer was its
# one owner and its uniqueName carried a key. The review showed that both are
# under the maker's control: a tenant member can make the registration, give
# themselves Vmf.Admin, make the installer its one owner and leave. So nothing
# the directory shows proves who made a registration, and the rule is now:
#
#   1. a recorded key is used as it is, and the directory is not asked
#      anything (an existing install's next azd up is unchanged);
#   2. no recorded key and no registration with either name -> a NEW random
#      key, so the uniqueName cannot be guessed before the install;
#   3. no recorded key and a registration with either name -> STOP, before the
#      template runs. Never adoption, and never a second registration beside
#      it (a new key would make one, with the same display name).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # `az` is an external command; a FUNCTION of the same name wins
    # resolution, so every directory call is answered here and none reaches
    # Azure.
    function Global:az {
        $line = (@($args) -join ' ')
        $global:azCalls += , $line
        $global:LASTEXITCODE = 0
        if ($line -like 'ad app list --display-name *') {
            $name = [string]$args[4]
            return (@($global:azApps | Where-Object { $_.displayName -eq $name }) | ConvertTo-Json -Depth 5 -AsArray)
        }
        return '[]'
    }
    function Global:SetDirectory {
        param([object[]]$Apps = @())
        $global:azApps = $Apps
        $global:azCalls = @()
        $global:LASTEXITCODE = 0
    }
    $script:apiId = '11111111-1111-1111-1111-111111111111'
    $script:dashId = '22222222-2222-2222-2222-222222222222'
    function Global:NewApp {
        param([string]$Name, [string]$AppId, [string]$UniqueName)
        @{ displayName = $Name; appId = $AppId; id = "object-$AppId"; uniqueName = $UniqueName }
    }
}
AfterAll {
    Remove-Item 'function:\az', 'function:\SetDirectory', 'function:\NewApp' -ErrorAction SilentlyContinue
}

Describe 'A recorded key is used as it is (an existing install is unchanged)' {

    It 'returns the recorded key and asks the directory nothing' {
        SetDirectory -Apps @(NewApp 'vmf-api-prod' $script:apiId 'vmf-api-prod-abc123')
        $r = Resolve-VmfRegistrationKey -RecordedKey 'abc123' -ApiDisplayName 'vmf-api-prod' -DashboardDisplayName 'vmf-dashboard-prod'
        $r.Key | Should -Be 'abc123'
        $r.Source | Should -Be 'recorded'
        @($global:azCalls).Count | Should -Be 0 -Because 'an existing install records its key, so its next azd up reads nothing new'
    }
}

Describe 'No key and no registration: a fresh install gets a new random key' {

    It 'generates a key of six lower-case letters and digits' {
        SetDirectory
        $r = Resolve-VmfRegistrationKey -RecordedKey '' -ApiDisplayName 'vmf-api-prod' -DashboardDisplayName 'vmf-dashboard-prod'
        $r.Source | Should -Be 'new'
        $r.Key | Should -Match '^[a-z0-9]{6}$'
    }

    It 'reads both names before it makes the key' {
        SetDirectory
        $null = Resolve-VmfRegistrationKey -RecordedKey '' -ApiDisplayName 'vmf-api-prod' -DashboardDisplayName 'vmf-dashboard-prod'
        @($global:azCalls) | Should -Contain 'ad app list --display-name vmf-api-prod -o json'
        @($global:azCalls) | Should -Contain 'ad app list --display-name vmf-dashboard-prod -o json'
    }

    It 'never returns an empty key, which would make the uniqueName the display name anybody can guess' {
        SetDirectory
        $keys = 1..20 | ForEach-Object { (Resolve-VmfRegistrationKey -RecordedKey '' -ApiDisplayName 'vmf-api-prod' -DashboardDisplayName 'vmf-dashboard-prod').Key }
        @($keys | Where-Object { -not $_ }).Count | Should -Be 0
        @($keys | Sort-Object -Unique).Count | Should -BeGreaterThan 1 -Because 'the key is random, not fixed'
    }

    It 'takes the key from a cryptographic random source' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
        $code | Should -Match 'RandomNumberGenerator\]::GetInt32'
    }
}

Describe 'No key and a registration with the name: a stop, never adoption' {

    It 'stops on an API registration with the name, even one whose uniqueName carries a key' {
        # The shape of the review's exploit: a keyed uniqueName and any owner
        # the maker chose. Nothing about it is read as proof.
        SetDirectory -Apps @(NewApp 'vmf-api-prod' $script:apiId 'vmf-api-prod-k3y9zz')
        { Resolve-VmfRegistrationKey -RecordedKey '' -ApiDisplayName 'vmf-api-prod' -DashboardDisplayName 'vmf-dashboard-prod' } |
            Should -Throw -ExpectedMessage "*already in use*'vmf-api-prod'*$($script:apiId)*remove*different environment name*"
    }

    It 'stops on a DASHBOARD registration with the name, where the administrator consent goes' {
        SetDirectory -Apps @(NewApp 'vmf-dashboard-prod' $script:dashId 'vmf-dashboard-prod-k3y9zz')
        { Resolve-VmfRegistrationKey -RecordedKey '' -ApiDisplayName 'vmf-api-prod' -DashboardDisplayName 'vmf-dashboard-prod' } |
            Should -Throw -ExpectedMessage "*'vmf-dashboard-prod'*$($script:dashId)*"
    }

    It 'names both when both exist' {
        SetDirectory -Apps @(
            (NewApp 'vmf-api-prod' $script:apiId 'vmf-api-prod-k3y9zz'),
            (NewApp 'vmf-dashboard-prod' $script:dashId 'vmf-dashboard-prod-k3y9zz')
        )
        { Resolve-VmfRegistrationKey -RecordedKey '' -ApiDisplayName 'vmf-api-prod' -DashboardDisplayName 'vmf-dashboard-prod' } |
            Should -Throw -ExpectedMessage "*$($script:apiId)*$($script:dashId)*"
    }

    It 'reads no owner and no uniqueName: nothing the maker controls decides it' {
        SetDirectory -Apps @(NewApp 'vmf-api-prod' $script:apiId 'vmf-api-prod-k3y9zz')
        try { $null = Resolve-VmfRegistrationKey -RecordedKey '' -ApiDisplayName 'vmf-api-prod' -DashboardDisplayName 'vmf-dashboard-prod' } catch { }
        @($global:azCalls | Where-Object { $_ -notlike 'ad app list --display-name *' }).Count | Should -Be 0
    }

    It 'leaves no adoption path in the code' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
        $code | Should -Not -Match "Source = 'adopted'"
        $code | Should -Not -Match 'app\s+owner'
    }
}

Describe 'The removal says what a kept pair does' {

    It 'the No answer says a later install with this name stops, never that it adopts them' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1')
        $code | Should -Not -Match 'adopts them'
        $code | Should -Match 'no\|No\. Keep them\. A later install with this environment name then stops'
    }
}

Describe 'Every install route uses the rule, and stops before the template runs' {

    BeforeAll {
        $script:preprov = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')
        $script:idDeploy = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'identity-deploy.ps1')
    }

    It 'preprovision decides the key through Resolve-VmfRegistrationKey, and never records an empty one' {
        $script:preprov | Should -Match 'Resolve-VmfRegistrationKey -RecordedKey'
        $script:preprov | Should -Not -Match "Set-AzdValue -Name 'VMF_REGISTRATION_KEY' -Value ''"
        $script:preprov | Should -Not -Match "'adopted'"
    }

    It 'preprovision decides the key before it runs identity-deploy' {
        $script:preprov.IndexOf('Resolve-VmfRegistrationKey') |
            Should -BeLessThan $script:preprov.IndexOf("'identity-deploy.ps1'")
    }

    It 'identity-deploy resolves an empty key the same way, before the template deployment' {
        $script:idDeploy | Should -Match 'Resolve-VmfRegistrationKey -RecordedKey \$RegistrationKey'
        $resolveAt = $script:idDeploy.IndexOf('Resolve-VmfRegistrationKey')
        $script:idDeploy.IndexOf('Get-VmfEntraApplication -DisplayName') | Should -BeGreaterThan $resolveAt
        $script:idDeploy.IndexOf('az deployment group create') | Should -BeGreaterThan $resolveAt
    }
}
