#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCOPE-SUBS-GUID-1: a subscription in a scan's scope goes into a request path
# (/subscriptions/<value>/providers/Microsoft.DesktopVirtualization/hostPools,
# SCAN-SCOPE-READS-1). Nothing checked that the value was a subscription id, so
# a value with a slash in it could point that read at another Azure list path.
#
# Two checks, at two places:
# - the web service refuses a scan request whose scopeSubs holds anything but a
#   subscription id (a GUID, or /subscriptions/<GUID>, which it sends on as the
#   GUID) with a 400 that names the field, before it starts anything;
# - the AVD read refuses (Verified = $false, so the scan stops) any value that
#   is not a GUID before it builds a path from it. That covers the engine's own
#   setting and the subscriptions Resource Graph lists under a management group.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: the facade calls a stand-in, defined BEFORE the
    # guard so the guard mock and the tests' own mocks take one shape.
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:SsgPrincipalHeader {
        param([string]$Identity = 'oper@example.com', [string[]]$Roles = @('Vmf.Operator'))
        $claims = @(@{ typ = 'preferred_username'; val = $Identity }) + @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc))
    }
    # Placeholder ids the NoLiveIdentifiers gate accepts.
    $script:subA = '00000000-0000-0000-0000-000000000000'
    $script:subB = '11111111-2222-3333-4444-555555555555'
}
AfterAll { Remove-Item 'function:\SsgPrincipalHeader', 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue }

Describe 'SCOPE-SUBS-GUID-1: the web service checks scopeSubs before it starts a scan' {
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:ssgStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ssg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:VMF_STORE_PATH = $script:ssgStore
        New-Item -ItemType Directory -Path $script:ssgStore -Force | Out-Null
        $script:operator = ConvertFrom-VmfClientPrincipal -Header (SsgPrincipalHeader)
        $script:ssgCalls = [System.Collections.Generic.List[string]]::new()
        $script:ssgStartBody = $null
        # ASSESS-APPROVAL-HASH-1: the scan start asks Azure whether a scan of the
        # run runs (Test-VmfFacadeEngineRunning); none does.
        
Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            $script:ssgCalls.Add([string]$Method)
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{
                    properties = @{ template = @{ containers = @(@{
                        name = 'engine'; image = 'acr/vmf-engine:dev'
                        resources = @{ cpu = 1; memory = '2Gi' }
                        env = @() }) } }
                } | ConvertTo-Json -Depth 10) }
            }
            $script:ssgStartBody = $Payload
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-xyz' } | ConvertTo-Json) }
        }
    }
    AfterEach {
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:ssgStore) { Remove-Item $script:ssgStore -Recurse -Force }
    }

    It 'sends subscription ids on as they are' {
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r1' `
            -ScopeSubs @($script:subA, $script:subB.ToUpperInvariant()) -Note 'scan' | Out-Null
        $envs = @(($script:ssgStartBody | ConvertFrom-Json -Depth 10).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_SCOPE_SUBS').value | Should -BeExactly "$($script:subA),$($script:subB.ToUpperInvariant())"
    }

    It 'sends /subscriptions/<GUID> on as the GUID alone, the form every engine read takes' {
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r1' `
            -ScopeSubs @("/subscriptions/$($script:subA)", "/SUBSCRIPTIONS/$($script:subB)") -Note 'scan' | Out-Null
        $envs = @(($script:ssgStartBody | ConvertFrom-Json -Depth 10).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_SCOPE_SUBS').value | Should -BeExactly "$($script:subA),$($script:subB)"
    }

    It 'refuses <Case> with a 400 that names scopeSubs, and starts nothing' -TestCases @(
        @{ Case = 'a short name'; Value = 'sub-1' }
        @{ Case = 'a path past the subscription'; Value = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg' }
        @{ Case = 'a parent-folder step'; Value = '../00000000-0000-0000-0000-000000000000' }
        @{ Case = 'a GUID with a query after it'; Value = '00000000-0000-0000-0000-000000000000?x=1' }
        @{ Case = 'a GUID with a new line after it'; Value = "00000000-0000-0000-0000-000000000000`n" }
        @{ Case = 'a GUID with a space before it'; Value = ' 00000000-0000-0000-0000-000000000000' }
        @{ Case = 'an empty value'; Value = '' }
    ) {
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r1' `
            -ScopeSubs @($script:subA, $Value) -Note 'scan' } | Should -Throw '400: The scopeSubs field has a value that is not a subscription ID.'
        $script:ssgCalls.Count | Should -Be 0 -Because 'the request is refused before the web service reads or starts the engine job'
        $script:ssgStartBody | Should -BeNullOrEmpty
    }

    It 'refuses <Case> alone with a 400, and starts nothing (a presence test, not a truth test)' -TestCases @(
        @{ Case = 'one empty value'; Value = @(''); Message = '400: The scopeSubs field has a value that is not a subscription ID.' }
        @{ Case = 'an empty string'; Value = ''; Message = '400: The scopeSubs field has a value that is not a subscription ID.' }
        @{ Case = 'an empty list'; Value = @(); Message = '400: The scopeSubs field has no subscription ID.' }
    ) {
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r1' `
            -ScopeSubs $Value -Note 'scan' } | Should -Throw $Message
        $script:ssgCalls.Count | Should -Be 0 -Because 'an empty scope must not become a scan of the engine''s own subscription'
    }

    It 'sends no VMF_SCOPE_SUBS when the request has no scopeSubs' {
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r1' -ScopeMg 'mg-contoso' -Note 'scan' | Out-Null
        $envs = @(($script:ssgStartBody | ConvertFrom-Json -Depth 10).containers[0].env)
        @($envs | Where-Object name -EQ 'VMF_SCOPE_SUBS').Count | Should -Be 0
    }
    It 'checks scopeSubs before any other step of the start, for every operation' {
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'plan' -RunId 'r1' `
            -ScopeSubs @('x/../../providers/Microsoft.Storage') -Note 'plan' } | Should -Throw '400: The scopeSubs field*'
        $script:ssgCalls.Count | Should -Be 0
    }
}

Describe 'SCOPE-SUBS-GUID-1: the AVD read builds a path only from a subscription id' {
    It 'refuses a scope value that is not a GUID, and reads nothing' -TestCases @(
        @{ Value = 'x/../../providers/Microsoft.Storage' }
        @{ Value = '/subscriptions/00000000-0000-0000-0000-000000000000' }
        @{ Value = "00000000-0000-0000-0000-000000000000`n" }
        @{ Value = 'sub-1' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ Value = $Value; SubA = $script:subA } {
            param($Value, $SubA)
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' } }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @($SubA, $Value)
            $r.Verified | Should -BeFalse -Because 'a value the read cannot use is a scope it cannot verify'
            $r.Detail | Should -Match 'is not a subscription ID'
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly -Because 'no path is built before every value is checked'
        }
    }

    It 'refuses a value Resource Graph lists under a management group that is not a GUID, and reads nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ SubA = $script:subA } {
            param($SubA)
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' } }
            Mock Invoke-VmfResourceGraphQuery {
                [pscustomobject]@{ data = @([pscustomobject]@{ subscriptionId = $SubA }, [pscustomobject]@{ subscriptionId = 'x/../../providers/Microsoft.Storage' }) }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @() -ManagementGroup 'mg-contoso'
            $r.Verified | Should -BeFalse
            $r.Detail | Should -Match 'is not a subscription ID'
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
        }
    }

    It 'reads the host pools of each subscription id, upper case too, at /subscriptions/<GUID>' {
        InModuleScope VmMigrationFactory -Parameters @{ SubA = $script:subA; SubB = $script:subB } {
            param($SubA, $SubB)
            $script:ssgPaths = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-AzRestMethod {
                $script:ssgPaths.Add([string]$Path)
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @($SubA, $SubB.ToUpperInvariant())
            $r.Verified | Should -BeTrue
            @($script:ssgPaths | Sort-Object) | Should -Be @(
                "/subscriptions/$SubA/providers/Microsoft.DesktopVirtualization/hostPools?api-version=2024-04-03",
                "/subscriptions/$SubB/providers/Microsoft.DesktopVirtualization/hostPools?api-version=2024-04-03")
        }
    }
}

Describe 'SCOPE-SUBS-GUID-1: the scan says the value, not a role, when a scope value is not a subscription ID' {
    It 'stops the scan with the value and no Admin page step' {
        InModuleScope VmMigrationFactory -Parameters @{ SubA = $script:subA } {
            param($SubA)
            Mock Get-VmfFleetInventory { , @([pscustomobject]@{
                id = "/subscriptions/$SubA/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1"
                name = 'vm1'; resourceGroup = 'rg'; location = 'centralus'; sku = 'Standard_D4s_v5'
            }) }
            Mock Get-VmfSkuCatalog { , @() }
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' } }
            Mock Invoke-VmfResourceGraphQuery {
                [pscustomobject]@{ data = @([pscustomobject]@{ subscriptionId = 'x/../../providers/Microsoft.Storage' }) }
            }
            $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ssg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                $msg = $null
                try { Invoke-VmfAssessment -Scope @{ ManagementGroup = 'mg-contoso' } -OutPath $out | Out-Null }
                catch { $msg = $_.Exception.Message }
                $msg | Should -BeExactly "The scan cannot verify which machines are AVD session hosts. The scan scope has the value 'x/../../providers/microsoft.storage', which is not a subscription ID. The scan assessed no machine."
            }
            finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
        }
    }
}

Describe 'SCOPE-SUBS-GUID-1: the scan route passes every scopeSubs it is sent' {
    BeforeAll {
        if (-not ('HttpResponseContext' -as [type])) {
            Add-Type -TypeDefinition 'public class HttpResponseContext { public object StatusCode; public object Body; public string ContentType; public System.Collections.IDictionary Headers; }'
        }
        function Global:Push-OutputBinding { param($Name, $Value) $global:VmfSsgResponse = $Value }
        $script:SsgRoute = { param($body)
            $global:VmfSsgResponse = $null
            $request = [pscustomobject]@{
                Headers = @{ 'x-ms-client-principal' = (SsgPrincipalHeader) }
                Params  = @{ operation = 'assess'; runId = 'r1' }
                Body    = $body
            }
            & (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1') -Request $request -TriggerMetadata $null
            $global:VmfSsgResponse
        }
    }
    AfterAll { Remove-Item Function:\Push-OutputBinding, Variable:\global:VmfSsgResponse, Variable:\global:VmfSsgCalls, Variable:\global:VmfSsgStartBody -ErrorAction SilentlyContinue }
    BeforeEach {
        # Globals: run.ps1 is a script of its own, so a mock's $script: names its scope.
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:ssgStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ssg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:VMF_STORE_PATH = $script:ssgStore
        New-Item -ItemType Directory -Path $script:ssgStore -Force | Out-Null
        $global:VmfSsgCalls = [System.Collections.Generic.List[string]]::new()
        $global:VmfSsgStartBody = $null
        # ASSESS-APPROVAL-HASH-1: the scan start asks Azure whether a scan of the
        # run runs (Test-VmfFacadeEngineRunning); none does.
        
Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            $global:VmfSsgCalls.Add([string]$Method)
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{
                    properties = @{ template = @{ containers = @(@{
                        name = 'engine'; image = 'acr/vmf-engine:dev'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } }
                } | ConvertTo-Json -Depth 10) }
            }
            $global:VmfSsgStartBody = $Payload
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-xyz' } | ConvertTo-Json) }
        }
    }
    AfterEach {
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:ssgStore) { Remove-Item $script:ssgStore -Recurse -Force }
    }

    It 'answers 400 to a body whose scopeSubs is <Case>, and starts nothing' -TestCases @(
        @{ Case = 'an empty string'; Body = @{ scopeSubs = '' } }
        @{ Case = 'one empty value'; Body = @{ scopeSubs = @('') } }
        @{ Case = 'an empty list'; Body = @{ scopeSubs = @() } }
        @{ Case = 'a value with a path in it'; Body = @{ scopeSubs = @('x/../../providers/Microsoft.Storage') } }
    ) {
        $resp = & $script:SsgRoute $Body
        [int]$resp.StatusCode | Should -Be 400
        ($resp.Body | ConvertFrom-Json).error | Should -Match '^400: The scopeSubs field'
        $global:VmfSsgCalls.Count | Should -Be 0
    }

    It 'starts the scan with the subscription ID of a good body' {
        $resp = & $script:SsgRoute @{ scopeSubs = @('00000000-0000-0000-0000-000000000000'); note = 'scan' }
        [int]$resp.StatusCode | Should -Be 202 -Because ([string]$resp.Body)
        $envs = @(($global:VmfSsgStartBody | ConvertFrom-Json -Depth 10).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_SCOPE_SUBS').value | Should -BeExactly '00000000-0000-0000-0000-000000000000'
    }
}
