#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CODE-CONTAINER-WRITE-1 - nothing but the publish job can write the service's
# program code.
#
# The run store account holds two kinds of thing: the records (vmf-runs) and
# the service's program code (vmf-deploy/facade.zip, which the Functions host
# fetches with WEBSITE_RUN_FROM_PACKAGE on every start). The engine held
# Storage Blob Data Contributor and the service Storage Blob Data Owner on the
# WHOLE ACCOUNT, so both could overwrite the code the service runs - and the
# engine runs every migration, reads guest output and holds the migration role
# over customer machines. One write by it would become code that runs as the
# service's identity at its next start.
#
# Every blob data role is now granted on a container. These checks read the
# COMPILED template (az bicep build), not the bicep text, so a comment that
# names a grant cannot satisfy them, and a grant moved back to the account
# cannot hide in a module parameter.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:platformPath = Join-Path $script:repoRoot 'infra' 'platform.bicep'
    $script:platformText = Get-Content $script:platformPath -Raw
    $script:haveAz = [bool](Get-Command az -CommandType Application -ErrorAction SilentlyContinue)

    # The built-in blob data roles, by id (az role definition list --name ...).
    $script:blobRoles = @{
        '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' = 'Storage Blob Data Reader'
        'ba92f5b4-2d11-453d-a403-e96b0029c9fe' = 'Storage Blob Data Contributor'
        'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' = 'Storage Blob Data Owner'
    }
    $script:blobWriters = @('ba92f5b4-2d11-453d-a403-e96b0029c9fe', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')

    function script:Get-VmfStoreGrants {
        # One row per role assignment the store module makes:
        # Scope = 'account' or the container name; Who = the module the
        # principal comes from (engineIdentity, facade, publishIdentity);
        # Role = the role definition id.
        param($Template)
        $resources = if ($Template.resources -is [array]) { $Template.resources } else { @($Template.resources.PSObject.Properties.Value) }
        $store = @($resources | Where-Object { $_.name -eq 'vmf-store-deploy' })
        if ($store.Count -ne 1) { throw "expected one store module, found $($store.Count)" }
        $params = $store[0].properties.parameters
        $resolve = {
            param($a, [string]$scope)
            $who = [regex]::Match([string]$a.principalId, "reference\('(?<m>[^']+)'\)").Groups['m'].Value
            if (-not $who) { throw "a store grant names a principal this test cannot read: $($a.principalId)" }
            $role = [string]$a.roleDefinitionIdOrName
            $v = [regex]::Match($role, "^\[variables\('(?<n>[^']+)'\)\]$")
            if ($v.Success) { $role = [string]$Template.variables.($v.Groups['n'].Value) }
            [pscustomobject]@{ Scope = $scope; Who = $who; Role = $role }
        }
        foreach ($a in @($params.roleAssignments.value)) { if ($a) { & $resolve $a 'account' } }
        foreach ($c in @($params.blobServices.value.containers)) {
            foreach ($a in @($c.roleAssignments)) { if ($a) { & $resolve $a ([string]$c.name) } }
        }
    }

    $script:grants = @()
    $script:containers = @()
    if ($script:haveAz) {
        $out = az bicep build --file $script:platformPath --stdout 2>&1
        if ($LASTEXITCODE -ne 0) { throw "platform.bicep does not compile: $($out -join "`n")" }
        $template = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n" | ConvertFrom-Json
        $script:grants = @(Get-VmfStoreGrants -Template $template)
        $resources = if ($template.resources -is [array]) { $template.resources } else { @($template.resources.PSObject.Properties.Value) }
        $store = $resources | Where-Object { $_.name -eq 'vmf-store-deploy' }
        $script:containers = @($store.properties.parameters.blobServices.value.containers | ForEach-Object { [string]$_.name })
    }
}

Describe 'CODE-CONTAINER-WRITE-1: only the publish job can write the service''s program code' {

    BeforeEach {
        if (-not $script:haveAz) { Set-ItResult -Skipped -Because 'az (with bicep) is not installed' }
    }

    It 'the template is read, so these checks prove something' {
        $script:grants.Count | Should -BeGreaterThan 3
        $script:containers | Should -Contain 'vmf-runs'
        $script:containers | Should -Contain 'vmf-deploy'
    }

    It 'no blob data role is granted on the whole account' {
        # An account-wide blob role reaches vmf-deploy, which holds the code.
        $wide = @($script:grants | Where-Object { $_.Scope -eq 'account' -and $script:blobRoles.ContainsKey($_.Role) })
        $wide | ForEach-Object { "$($_.Who) holds $($script:blobRoles[$_.Role]) on the account" } | Should -BeNullOrEmpty
    }

    It 'only the publish job may write the container the service runs its code from' {
        # The container is the one WEBSITE_RUN_FROM_PACKAGE names, read from the
        # setting rather than assumed.
        $m = [regex]::Match($script:platformText, "WEBSITE_RUN_FROM_PACKAGE: 'https://\$\{storeName\}\.blob\.\$\{environment\(\)\.suffixes\.storage\}/(?<c>[^/']+)/")
        $m.Success | Should -BeTrue -Because 'the service must run from a package in the run store'
        $code = $m.Groups['c'].Value
        $script:containers | Should -Contain $code
        # A grant on the account reaches this container as well.
        $writers = @($script:grants | Where-Object { $_.Scope -in @($code, 'account') -and $script:blobWriters -contains $_.Role } | ForEach-Object { $_.Who } | Sort-Object -Unique)
        $writers | Should -Be @('publishIdentity')
    }

    It 'and the service can still read its code there, and nothing more' {
        $mine = @($script:grants | Where-Object { $_.Scope -eq 'vmf-deploy' -and $_.Who -eq 'facade' })
        $mine.Count | Should -Be 1
        $mine[0].Role | Should -Be '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' -Because 'the host fetches its package with its own identity, and Storage Blob Data Reader is enough'
    }

    It 'the engine reaches no container but the one it is told to use' {
        $jobs = [regex]::Matches($script:platformText, "\{ name: 'VMF_STORE_CONTAINER', value: '(?<c>[^']+)' \}")
        $jobs.Count | Should -Be 1 -Because 'the engine job names its records container once'
        $records = $jobs[0].Groups['c'].Value
        $engine = @($script:grants | Where-Object { $_.Who -eq 'engineIdentity' })
        @($engine | ForEach-Object { $_.Scope } | Sort-Object -Unique) | Should -Be @($records)
        @($engine | Where-Object { $_.Role -eq 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' }).Count | Should -Be 1 -Because 'the engine reads and writes every record'
    }

    It 'the service can still read and write the records container it is told to use' {
        $m = [regex]::Match($script:platformText, "VMF_STORE_CONTAINER: '(?<c>[^']+)'")
        $m.Success | Should -BeTrue
        $records = @($script:grants | Where-Object { $_.Who -eq 'facade' -and $_.Scope -eq $m.Groups['c'].Value -and $script:blobWriters -contains $_.Role })
        $records.Count | Should -Be 1
    }

    It 'the Functions host keeps Storage Blob Data Owner on the two containers it keeps its own data in' {
        # Microsoft gives Storage Blob Data Owner for an identity-based
        # AzureWebJobsStorage. The host keeps its locks, timer status and host
        # id in azure-webjobs-hosts and its keys in azure-webjobs-secrets. The
        # template makes both, so the host never needs to create a container,
        # and grants the role on each container only.
        foreach ($c in 'azure-webjobs-hosts', 'azure-webjobs-secrets') {
            $script:containers | Should -Contain $c -Because "the template must make $c before the host needs it"
            $here = @($script:grants | Where-Object { $_.Scope -eq $c })
            @($here | ForEach-Object { "$($_.Who) $($_.Role)" }) | Should -Be @('facade b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
        }
    }

    It 'the publish job and the engine get nothing outside their own containers' {
        @($script:grants | Where-Object { $_.Who -eq 'publishIdentity' -and $_.Scope -ne 'vmf-deploy' }) | Should -BeNullOrEmpty
        @($script:grants | Where-Object { $_.Who -eq 'engineIdentity' -and $_.Scope -eq 'vmf-deploy' }) | Should -BeNullOrEmpty
    }

    It 'the queue and table roles the host needs stay, and give no blob access' {
        $account = @($script:grants | Where-Object { $_.Scope -eq 'account' } | ForEach-Object { "$($_.Who) $($_.Role)" } | Sort-Object)
        $account | Should -Be @(
            'facade 0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'   # Storage Table Data Contributor
            'facade 974c5e8b-45b9-4653-ba55-5f855dd0fb88'   # Storage Queue Data Contributor
        )
    }
}
