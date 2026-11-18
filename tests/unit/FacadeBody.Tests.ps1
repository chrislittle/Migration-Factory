#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# BODY-HASH-1, 2026-09-23. A JSON body reaches PowerShell as a HASHTABLE, and
# the route read it as an object.
#
# A migration stalled on its last machine. "Accept this and continue" was
# pressed on a machine parked below the MANA kernel floor, and the
# service answered:
#
#   That change cannot be applied: '' is not a setting for 'onDriverBelowFloor'
#   - it must be one of: stop, proceed.
#
# The page was sending `proceed`. `PostResolve/run.ps1` converted the body
# with:
#
#   foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
#
# Azure Functions hands a JSON body to PowerShell as a Hashtable. Iterating
# `.PSObject.Properties` on a Hashtable yields the Hashtable's own .NET
# members - Count, SyncRoot, IsReadOnly, Keys, Values - and NOT its entries.
#
# THEN IT GETS WORSE, and this is why the message made no sense. The result
# contains a literal entry named `Keys`, whose value is the original key
# collection. So the validator's `$Override.Keys` returns `onDriverBelowFloor`
# - the real key - and looking that key up finds nothing, which reads as ''.
# The key survives and the value vanishes.
#
# It also walks past a guard. `Invoke-VmfFacadeResolve` refuses to let anybody
# but an approver remove a wave's sign-off, and asks
# `$PolicyOverride.ContainsKey('requireApproval')`. On the mangled hashtable
# the real keys are Count/SyncRoot/Keys/Values, so that is false and the check
# never runs. The request then fails anyway, on the empty value - so it fails
# closed BY ACCIDENT, not by design.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:facade = Join-Path $script:repoRoot 'src' 'facade'
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:facade 'FacadeCore' 'FacadeCore.psd1') -Force -ErrorAction SilentlyContinue
    # TEST-AZURE-GUARD-2: the facade module calls Azure itself.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:body = '{"vmId":"x","note":"go","policyOverride":{"onDriverBelowFloor":"proceed"}}'
}

Describe 'BODY-HASH-1: a request body converts from EITHER shape' {

    It 'converts the shape Azure Functions actually delivers - a Hashtable' {
        # THE DEFECT. This is what the failing request looked like.
        $asHashtable = $script:body | ConvertFrom-Json -AsHashtable
        $h = ConvertTo-VmfHashtable $asHashtable.policyOverride
        $h['onDriverBelowFloor'] | Should -Be 'proceed'
        @($h.Keys) | Should -Be @('onDriverBelowFloor')
    }

    It 'and the shape ConvertFrom-Json gives - a PSCustomObject' {
        # Tests and any caller that parses the body themselves.
        $asObject = $script:body | ConvertFrom-Json
        $h = ConvertTo-VmfHashtable $asObject.policyOverride
        $h['onDriverBelowFloor'] | Should -Be 'proceed'
    }

    It 'keeps a hashtable free of the container own members' {
        # Count, SyncRoot, IsReadOnly, Keys and Values are how the value was
        # lost. None of them may appear as a setting.
        $h = ConvertTo-VmfHashtable ($script:body | ConvertFrom-Json -AsHashtable).policyOverride
        foreach ($own in @('Count', 'SyncRoot', 'IsReadOnly', 'IsFixedSize', 'Keys', 'Values')) {
            $h.ContainsKey($own) | Should -BeFalse -Because "'$own' is the container, not a setting"
        }
    }

    It 'a key the guard reads survives, so the guard can run' {
        # `ContainsKey('requireApproval')` was FALSE on the mangled hashtable,
        # so the approver check never ran at all.
        $withAppr = '{"policyOverride":{"requireApproval":false}}' | ConvertFrom-Json -AsHashtable
        $h = ConvertTo-VmfHashtable $withAppr.policyOverride
        $h.ContainsKey('requireApproval') | Should -BeTrue
        $h['requireApproval'] | Should -Be $false
    }

    It 'passes null through, because an absent override is not an empty one' {
        # EXACTLY null, not "null or empty". An empty hashtable is TRUE in
        # PowerShell, so `if ($PolicyOverride)` would start running on a
        # request that carried no override at all. Found by mutation: the
        # looser check could not tell the two apart and let it through.
        $null -eq (ConvertTo-VmfHashtable $null) | Should -BeTrue
    }
}

Describe 'BODY-HASH-1: one conversion, not one per route' {

    It 'no route carries its own copy' {
        # FOUR routes defined this function. Three never called it - dead
        # copies, each carrying the same defect for whoever used one next.
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($f in (Get-ChildItem (Join-Path $script:facade 'app') -Filter 'run.ps1' -Recurse -File)) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            if ($code -match 'function ConvertTo-VmfHashtable') {
                $offenders.Add($f.Directory.Name)
            }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty `
            -Because 'the conversion belongs in FacadeCore, where one fix reaches every route'
    }

    It 'and the module that holds it is the one the routes already load' {
        $core = Get-VmfCodeOnly -Path (Join-Path $script:facade 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Match 'function ConvertTo-VmfHashtable'
        $core | Should -Match 'IDictionary'
    }

    It 'the route that needs it still calls it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:facade 'app' 'PostResolve' 'run.ps1')
        $code | Should -Match 'ConvertTo-VmfHashtable \$body\.policyOverride'
    }
}
