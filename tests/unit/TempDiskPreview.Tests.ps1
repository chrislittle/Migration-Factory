#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEMP-DISK-PREVIEW-1: the in-place upgrade with the preview feature
# VMTempDiskResizePreview, for a Windows machine with a SCSI temporary disk.
#
# THE DEFECT. A Windows machine on a size with a SCSI temporary disk (D2ds_v4,
# a v3 size, B2s) reached v6, v7 or its Bsv2 size only by a rebuild around the
# same disks (Get-VmfPathSelection: Windows and a change of temporary disk is
# Path B). The rebuild deletes the machine definition, and with it the
# system-assigned identity, the extensions and the links other services hold.
#
# MEASURED 2026-11-01 and 2026-11-02 (docs/research/temp-disk-in-place-preview.md):
# with Microsoft.Compute/VMTempDiskResizePreview registered on the subscription,
# Azure accepts the in-place resize across the temporary disk kinds, forward
# and back, on eight shapes, and refuses it without the feature.
#
# Decided 2026-11-02:
#   - detection by a read the assess role holds
#     (Microsoft.Features/providers/features/read);
#   - TELL, never register: the product never registers the feature;
#   - Checking reads the feature again before any change, and a machine whose
#     subscription does not have it stops untouched;
#   - a Preview move is Path A, only when the saved method is preview.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    # Az is not installed in CI: a stand-in with the one shape the mocks take
    # (TEST-AZURE-GUARD-1), defined before the guard.
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '00000000-0000-0000-0000-000000000000'
    function Global:TpSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '4' }
                [pscustomobject]@{ Name = 'MemoryGB'; Value = '16' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:TpCatalog {
        $c = @{}
        foreach ($s in @((TpSku 'Standard_D4ds_v4' '153600'), (TpSku 'Standard_D4ds_v6' '0'), (TpSku 'Standard_D4s_v6' '0'),
                (TpSku 'Standard_D4ds_v7' '0'), (TpSku 'Standard_D4ds_v5' '153600' 'V1,V2'), (TpSku 'Standard_D4s_v5' '0' 'V1,V2'))) { $c[$s.Name] = $s }
        $c
    }
    function Global:TpVm([string]$Os = 'Windows', [string]$Gen = 'V2', [string]$Arch = 'scsi-temp', [string]$Name = 'win-01', [string[]]$Blockers = @()) {
        [pscustomobject]@{
            vmId = "/subscriptions/$($script:sub)/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = $(if ($Blockers.Count) { 'Blocked' } else { 'ReadyAfterPrep' }); gen = $Gen; os = $Os
            osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter-g2' } else { '22_04-lts-gen2' })
            sourceSize = 'Standard_D4ds_v4'; sourceDiskArch = $Arch; sourceTempDisks = $(if ($Arch -eq 'scsi-temp') { 1 } else { 0 })
            diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 0; primaryNicAccelerated = $false
            platformManaged = $false; blockers = @($Blockers); prepNeeded = @(); identityType = 'None'; identityPrincipalId = ''
        }
    }
    function Global:TpPath($Vm, [string]$Arch, [string]$Series = 'v6', [string]$Method = '') {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; a = $Arch; s = $Series; m = $Method } {
            param($v, $a, $s, $m) Get-VmfPathSelection -Assessment $v -TargetDiskArch $a -TargetGeneration $s -Method $m
        }
    }
    function Global:TpTarget($Vm, [string]$Series = 'v6', [string]$Method = '', [string]$Chosen = '') {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; c = (TpCatalog); s = $Series; m = $Method; ch = $Chosen } {
            param($v, $c, $s, $m, $ch) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $s -Method $m -ChosenSize $ch
        }
    }
    function Global:TpAdvise([object[]]$Vms, [hashtable]$Catalog = (TpCatalog)) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vms) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
    # A plan entry of a preview move, as New-VmfPlan writes it.
    function Global:TpEntry([string]$Method = 'preview', [string]$Path = 'A') {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/$($script:sub)/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/win-01"; wave = 'w1'; path = $Path
            assessment = [pscustomobject]@{ os = 'Windows'; gen = 'V2'; sourceSize = 'Standard_D4ds_v4'; sourceDiskArch = 'scsi-temp' }
            target = [pscustomobject]@{ size = 'Standard_D4ds_v6'; controller = 'NVMe'; diskArch = 'nvme-temp'; tempDisks = 1
                choice = [pscustomobject]@{ option = 'v6'; source = 'person'; chosenBy = 'operator@example.com'; method = $Method } }
            policy = [pscustomobject]@{ targetGeneration = 'v6' } }
    }
    function Global:TpGate($Entry, [string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ e = $Entry; rp = $RunPath; s = $script:sub } {
            param($e, $rp, $s) Get-VmfPreviewFeatureGate -Context @{ RunPath = $rp; VmId = [string]$e.vmId; SubscriptionId = $s } -PlanEntry $e
        }
    }
    function Global:TpRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'tp' | Out-Null }
        $rp
    }
}
AfterAll {
    Remove-Item 'function:\TpSku', 'function:\TpCatalog', 'function:\TpVm', 'function:\TpPath', 'function:\TpTarget', 'function:\TpAdvise',
        'function:\TpEntry', 'function:\TpGate', 'function:\TpRun', 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
    Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'vmf-tp-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# REBUILD-REMOVE-PLAN-1 (2026-11-07): the rebuild around the same disks is
# removed. The Preview is no longer a choice beside a rebuild that a saved method
# turns into Path A: it is the one move of its shape, and Generation 1 is measured
# too. The tests of its path, of the target advice, of the Bsv2 size and of the
# save and the plan that were here pinned the old rule; they are rewritten to the
# new one in RebuildRemovePlan.Tests.ps1.

Describe 'TEMP-DISK-PREVIEW-1: the read of the feature (azureops)' {
    It 'reads the feature of the subscription with one GET, and gives Registered' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '/features/' } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"state":"Registered"},"name":"Microsoft.Compute/VMTempDiskResizePreview"}' } }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '^/subscriptions/[^/]+\?' } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"displayName":"Applications"}' } }
        $r = InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } { param($s) Get-VmfPreviewFeatureState -SubscriptionId $s }
        $r.Read | Should -BeTrue
        $r.State | Should -Be 'Registered'
        $r.Registered | Should -BeTrue
        $r.SubscriptionName | Should -Be 'Applications'
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq "/subscriptions/$($script:sub)/providers/Microsoft.Features/providers/Microsoft.Compute/features/VMTempDiskResizePreview?api-version=2021-07-01" }
    }
    It 'NotRegistered is a read answer, not registered' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '/features/' } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"state":"NotRegistered"}}' } }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '^/subscriptions/[^/]+\?' } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"displayName":"Applications"}' } }
        $r = InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } { param($s) Get-VmfPreviewFeatureState -SubscriptionId $s }
        $r.Read | Should -BeTrue
        $r.Registered | Should -BeFalse
        $r.State | Should -Be 'NotRegistered'
    }
    It 'a read that fails (<Case>) is not checked - never registered, never not registered' -ForEach @(
        @{ Case = 'HTTP 403'; Code = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
        @{ Case = 'HTTP 500'; Code = 500; Content = '' }
        @{ Case = 'no state'; Code = 200; Content = '{"properties":{}}' }
    ) {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '/features/' } {
            [pscustomobject]@{ StatusCode = $Code; Content = $Content } }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '^/subscriptions/[^/]+\?' } {
            [pscustomobject]@{ StatusCode = 403; Content = '' } }
        $r = InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } { param($s) Get-VmfPreviewFeatureState -SubscriptionId $s }
        $r.Read | Should -BeFalse
        $r.Registered | Should -BeFalse
        $r.State | Should -BeNullOrEmpty
        $r.SubscriptionName | Should -Be $script:sub -Because 'a name that cannot be read is the id'
    }
    It 'a call that throws is not checked too' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { throw 'network down' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } { param($s) Get-VmfPreviewFeatureState -SubscriptionId $s }
        $r.Read | Should -BeFalse
        $r.Detail | Should -Match 'network down'
    }
    It 'refuses a subscription that is not an id, before any call' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { throw 'not expected' }
        { InModuleScope VmMigrationFactory { Get-VmfPreviewFeatureState -SubscriptionId 'x/../y' } } | Should -Throw '*subscription id*'
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 0 -Exactly
    }
    It 'lives behind the azureops boundary' {
        $hits = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter *.ps1 |
                Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match 'function Get-VmfPreviewFeatureState' })
        $hits.Count | Should -Be 1
        $hits[0].FullName | Should -Match 'azureops'
    }
}

Describe 'TEMP-DISK-PREVIEW-1: TELL, never register (2026-11-02)' {
    It 'no code of the product registers a preview feature or a resource provider' {
        $files = @(Get-ChildItem (Join-Path $script:repoRoot 'src') -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.html', '.js' })
        $bad = foreach ($f in $files) {
            $lang = if ($f.Extension -in '.html', '.js') { 'CStyle' } else { $null }
            $code = if ($lang) { Get-VmfCodeOnly -Path $f.FullName -Language $lang } else { Get-VmfCodeOnly -Path $f.FullName }
            # The page shows the commands for a person to run: they are text,
            # in one constant, never a call. A call is a REST path or a cmdlet.
            if ($code -match '(?i)features/[^"''\s]*/register|/register\?api-version|Register-AzProviderFeature\s+-|Register-AzResourceProvider\s+-' -and
                $f.Name -notin 'wizard.html', 'wizard.js') { $f.Name }
            # CSP-INLINE-1: the page's script is wizard.js, read on its own and
            # through the page.
            if ($f.Name -in 'wizard.html', 'wizard.js' -and $code -match '(?i)api\(\s*[''"`]POST[''"`][^)]*(feature|register)') { $f.Name }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'the role holds the read only: no register action, in either role' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $assess = @($map.operations | Where-Object role -eq 'assess' | ForEach-Object { $_.actions })
        $all = @($map.operations | ForEach-Object { $_.actions })
        $assess | Should -Contain 'Microsoft.Features/providers/features/read'
        @($all | Where-Object { $_ -like 'Microsoft.Features/*' }) | Should -Be @('Microsoft.Features/providers/features/read')
        @($all | Where-Object { $_ -match '(?i)register' }) | Should -BeNullOrEmpty
        $why = @($map.operations | Where-Object { @($_.actions) -contains 'Microsoft.Features/providers/features/read' })[0].why
        $why | Should -Match 'TEMP-DISK-PREVIEW-1'
        $why | Should -Match 'never registers'
    }
    It 'the permissions page of the manual lists the read (Update-VmfManualReference.ps1)' {
        Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'permissions.md') -Raw | Should -Match ([regex]::Escape('Microsoft.Features/providers/features/read'))
    }
}

Describe 'TEMP-DISK-PREVIEW-1: Checking reads the feature again before any change' {
    It 'a move that is not a Preview reads nothing' {
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState { throw 'not expected' }
        TpGate (TpEntry -Method 'in-place') (TpRun) | Should -BeNullOrEmpty
        TpGate (TpEntry -Method 'rebuild' -Path 'B') (TpRun) | Should -BeNullOrEmpty
        $old = TpEntry; $old.target.PSObject.Properties.Remove('choice')
        TpGate $old (TpRun) | Should -BeNullOrEmpty -Because 'an entry older than v23 has no method'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState -Times 0 -Exactly
    }
    It 'Registered: the move goes on, and the line says so' {
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState { @{ Read = $true; Registered = $true; State = 'Registered'; SubscriptionName = 'Applications'; Detail = '' } }
        $rp = TpRun
        TpGate (TpEntry) $rp | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:sub }
        $line = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -eq 'precheck' })[-1] }
        $line.detail | Should -Match 'VMTempDiskResizePreview is registered on subscription Applications'
    }
    It 'THE STOP: <Case> stops the machine untouched, naming the feature and the subscription' -ForEach @(
        @{ Case = 'NotRegistered'; State = @{ Read = $true; Registered = $false; State = 'NotRegistered'; SubscriptionName = 'Applications'; Detail = '' }; Says = 'is not registered'; Code = 'previewFeatureNotRegistered' }
        @{ Case = 'Registering'; State = @{ Read = $true; Registered = $false; State = 'Registering'; SubscriptionName = 'Applications'; Detail = '' }; Says = 'Registering'; Code = 'previewFeatureNotRegistered' }
        # STOP-TEXT-SPECIFIC-1: a read that failed is its own stop, not a feature that is not registered.
        @{ Case = 'a read that failed'; State = @{ Read = $false; Registered = $false; State = $null; SubscriptionName = '00000000-0000-0000-0000-000000000000'; Detail = 'HTTP 403' }; Says = 'could not read'; Code = 'previewFeatureNotRead' }
    ) {
        $s = $State
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState { $s }
        $r = TpGate (TpEntry) (TpRun)
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be $Code
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'VMTempDiskResizePreview'
        $r.Detail | Should -Match ([regex]::Escape([string]$s.SubscriptionName))
        $r.Detail | Should -Match $Says
        $r.Detail | Should -Match 'Nothing on the machine changed'
    }
    It 'the stop reason is in stop-reasons.json: the machine untouched, and a retry after the fix' {
        $j = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $r = @($j.reasons | Where-Object code -eq 'previewFeatureNotRegistered')
        $r.Count | Should -Be 1
        $r[0].machine | Should -Be 'untouched'
        $r[0].retry | Should -Be 'afterFix'
        $r[0].meaning | Should -Match 'VMTempDiskResizePreview'
        Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'stop-reasons.md') -Raw | Should -Match ([regex]::Escape($r[0].title))
    }
    It 'PRECHECK asks it after the permission check and before the first thing that changes the machine' {
        $sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $start = $sm.IndexOf('function Invoke-VmfStepPrecheck')
        $end = $sm.IndexOf('function ', $start + 30)
        $body = $sm.Substring($start, $end - $start)
        $gate = $body.IndexOf('Get-VmfPreviewFeatureGate')
        $gate | Should -BeGreaterThan 0
        $gate | Should -BeGreaterThan $body.IndexOf('Get-VmfMissingActions -RequiredActions (Get-VmfRequiredActions)')
        $gate | Should -BeLessThan $body.IndexOf('Save-VmfCapturedFacts -Context $Context -Facts @{ startedTarget')
        $gate | Should -BeLessThan $body.IndexOf('Get-VmfWorkloadCheckStop') -Because 'the cluster check can start a machine; a stop before it finds the machine as it was'
    }
}

Describe 'TEMP-DISK-PREVIEW-1: a Preview move killed after Checking finishes the move it started (kill-resume)' {
    It 'the record of the start keeps Path A and the method preview, and a resume uses it when the entry changed' {
        $entry = TpEntry
        $started = InModuleScope VmMigrationFactory -Parameters @{ e = $entry } { param($e) Get-VmfStartedTarget -PlanEntry $e }
        $started.path | Should -Be 'A'
        $started.target.choice.method | Should -Be 'preview'
        # Killed after Checking. A person then plans the machine again as a
        # rebuild; the worker that resumes holds the new entry.
        $saved = $started | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
        $changed = TpEntry -Method 'rebuild' -Path 'B'
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = $changed; s = $saved } { param($e, $s) Resolve-VmfStartedTarget -PlanEntry $e -Started $s }
        $r.Entry.path | Should -Be 'A' -Because 'a resume finishes the in-place upgrade it started, never a rebuild'
        $r.Entry.target.choice.method | Should -Be 'preview'
        ($r.Changed -join ' ') | Should -Match 'in-place upgrade'
    }
    It 'a resume inside Checking runs Checking again, so it reads the feature again' {
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState { @{ Read = $true; Registered = $false; State = 'NotRegistered'; SubscriptionName = 'Applications'; Detail = '' } }
        $rp = TpRun
        (TpGate (TpEntry) $rp).Reason | Should -Be 'previewFeatureNotRegistered'
        (TpGate (TpEntry) $rp).Reason | Should -Be 'previewFeatureNotRegistered' -Because 'the gate keeps no answer: every run of Checking asks Azure'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState -Times 2 -Exactly
    }
}

Describe 'TEMP-DISK-PREVIEW-1: the service reads the feature for the targets step' {
    BeforeAll {
        function Global:TpPrincipal([string[]]$Roles = @('Vmf.Viewer')) {
            $claims = @(@{ typ = 'preferred_username'; val = 'viewer@example.com' }) + @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5))))
        }
    }
    AfterAll { Remove-Item 'function:\TpPrincipal' -ErrorAction SilentlyContinue }

    It 'any role may read it, and the answer names the feature, the subscription and the state' {
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState { @{ Read = $true; Registered = $true; State = 'Registered'; SubscriptionName = 'Applications'; Detail = '' } }
        $r = Get-VmfFacadePreviewFeature -Principal (TpPrincipal) -SubscriptionId $script:sub
        $r.subscriptionId | Should -Be $script:sub
        $r.subscriptionName | Should -Be 'Applications'
        $r.feature | Should -Be 'VMTempDiskResizePreview'
        $r.namespace | Should -Be 'Microsoft.Compute'
        $r.read | Should -BeTrue
        $r.registered | Should -BeTrue
        $r.state | Should -Be 'Registered'
    }
    It 'a person with no role is refused' {
        { Get-VmfFacadePreviewFeature -Principal (TpPrincipal -Roles @()) -SubscriptionId $script:sub } | Should -Throw '403*'
    }
    It 'a subscription that is not an id is refused with 400' {
        { Get-VmfFacadePreviewFeature -Principal (TpPrincipal) -SubscriptionId 'not-a-guid' } | Should -Throw '400*'
    }
    It 'the endpoint is a GET, and the targets step calls it' {
        $fn = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'GetPreviewFeature' 'function.json') -Raw | ConvertFrom-Json
        @($fn.bindings[0].methods) | Should -Be @('get')
        $fn.bindings[0].route | Should -Be 'preview-feature'
        (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html') -Language CStyle) | Should -Match 'api\(''GET'', `preview-feature\?subscriptionId='
    }
}

Describe 'TEMP-DISK-PREVIEW-1: the run report names the in-place upgrade (Preview)' {
    It 'the record keeps the method of the plan, and the report says Preview in Moves and in Machines' {
        $html = InModuleScope VmMigrationFactory -Parameters @{ e = (TpEntry) } { param($e)
            $plan = [pscustomobject]@{ entries = @($e) }
            $doc = [pscustomobject]@{ vmId = [string]$e.vmId; state = 'MIGRATED'; history = @() }
            $rec = ConvertTo-VmfMigrationRecord -Manifest @{ runId = 'r' } -Plan $plan -StateDocs @($doc) -GeneratedBy 'x' -Reason 'downloaded'
            $rec.machines[0].target.method | Should -Be 'preview'
            ConvertTo-VmfReportHtml -Record $rec
        }
        ([regex]::Matches($html, [regex]::Escape('In-place upgrade (Preview)'))).Count | Should -Be 2
    }
    It 'an in-place upgrade keeps its name' {
        $html = InModuleScope VmMigrationFactory {
            $m = { param($n, $p, $method) [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/x/$n"; name = $n; wave = 'w'; path = $p; state = 'MIGRATED'; outcome = 'migrated'
                before = @{ size = 'a' }; target = @{ size = 'b'; method = $method }; now = @{ size = 'b'; basis = 'x' }; steps = @(); guestScripts = @(); activity = @() } }
            ConvertTo-VmfReportHtml -Record ([ordered]@{ runId = 'r'; decisions = @(); machines = @((& $m 'one' 'A' 'in-place'), (& $m 'old' 'A' $null)) })
        }
        $html | Should -Not -Match 'Preview'
        $html | Should -Match 'In-place upgrade'
        # OLD-REBUILD-RESTORE-READERS-1: the report has no name for a rebuild.
        $html | Should -Not -Match 'Rebuild around the same disks'
    }
}

Describe 'TEMP-DISK-PREVIEW-1 review: Checking requires the feature read only of a Preview move' {
    BeforeAll {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Invoke-VmfAzOperation { & $Operation }
        # The machine's state document, as a worker has it when Checking starts.
        Mock -ModuleName VmMigrationFactory Read-VmfStateDoc { [pscustomobject]@{ vmId = 'x'; state = 'PRECHECK' } }
        Mock -ModuleName VmMigrationFactory Write-VmfStateDoc { }
        # The step after the permission check, answered with a marker: a move
        # that reaches it got past the permission check.
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureGate { @{ Next = 'NEEDS_DECISION'; Reason = 'pastPermissions'; Detail = 'marker' } }
        # A VMF Migration role from before TEMP-DISK-PREVIEW-1: every action of
        # the map but the feature read. DCR-READ-1: with the read a rebuild
        # needs (requiredFor rebuild), which is not under test here.
        $script:oldRole = InModuleScope VmMigrationFactory { @(Get-VmfRequiredActions -For 'rebuild') + @(Get-VmfRequiredActions -Optional) }
        function Global:TpPrecheck($Entry, [string[]]$Actions) {
            $acts = $Actions
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @($acts); notActions = @() }) }.GetNewClosure()
            $rp = TpRun
            InModuleScope VmMigrationFactory -Parameters @{ e = $Entry; rp = $rp } { param($e, $rp)
                Invoke-VmfStepPrecheck -Context @{ RunPath = $rp; VmId = [string]$e.vmId; SubscriptionId = '00000000-0000-0000-0000-000000000000'; Plan = $e; Rg = 'rg'; VmName = 'win-01' }
            }
        }
    }
    AfterAll { Remove-Item 'function:\TpPrecheck' -ErrorAction SilentlyContinue }

    It 'the map: the read is required only for a Preview, and never optional' {
        InModuleScope VmMigrationFactory {
            Get-VmfRequiredActions | Should -Not -Contain 'Microsoft.Features/providers/features/read'
            Get-VmfRequiredActions -Optional | Should -Not -Contain 'Microsoft.Features/providers/features/read'
            Get-VmfRequiredActions -For 'preview' | Should -Contain 'Microsoft.Features/providers/features/read'
            Get-VmfRequiredActions -Role @('assess') -For 'preview' | Should -Contain 'Microsoft.Features/providers/features/read'
        }
        $script:oldRole | Should -Not -Contain 'Microsoft.Features/providers/features/read'
    }
    It 'THE DEFECT: a move that is not a Preview goes on past Checking with a role that lacks the read: <Method>' -ForEach @(
        @{ Method = 'in-place'; Path = 'A' }, @{ Method = ''; Path = 'A' }
    ) {
        $e = TpEntry -Method $Method -Path $Path
        if (-not $Method) { $e.target.PSObject.Properties.Remove('choice') }
        (TpPrecheck $e $script:oldRole).Reason | Should -Be 'pastPermissions'
    }
    It 'a Preview move with a role that lacks the read stops untouched at the permission check, which names the read' {
        $r = TpPrecheck (TpEntry) $script:oldRole
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionsMissing' -Because 'the permission check runs first and names the missing action; nothing has changed the machine'
        $r.Detail | Should -Match ([regex]::Escape('Microsoft.Features/providers/features/read'))
    }
    It 'a Preview move with a role that holds the read goes on to the read of the feature' {
        (TpPrecheck (TpEntry) (@($script:oldRole) + 'Microsoft.Features/providers/features/read')).Reason | Should -Be 'pastPermissions'
    }
}

# REBUILD-REMOVE-PLAN-1 review: Checking asked Azure about Azure Disk Encryption
# only on an NVMe target or Path B. A Preview to a SCSI size (v5, Bsv2) skipped
# it, and that read is the only catch for encryption on a data disk only, or a
# plan made from an older scan. ADE stays refused for 1.0 on a Preview.
Describe 'REBUILD-REMOVE-PLAN-1: Checking asks about Azure Disk Encryption on a Preview to a SCSI size' {
    BeforeAll {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Invoke-VmfAzOperation { & $Operation }
        Mock -ModuleName VmMigrationFactory Read-VmfStateDoc { [pscustomobject]@{ vmId = 'x'; state = 'PRECHECK' } }
        Mock -ModuleName VmMigrationFactory Write-VmfStateDoc { }
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureGate { $null }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $true }
        # The step after the encryption check, answered with a marker. The
        # hibernated stop that was the marker is gone (REBUILD-MOVE-HOST-1), so
        # the lock check answers it.
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfLockVerdict { @{ Blocked = $true; Reason = 'pastEncryptionMarker'; Detail = 'marker' } }
        $script:allActs = InModuleScope VmMigrationFactory { @(Get-VmfRequiredActions -For 'rebuild') + @(Get-VmfRequiredActions -For 'preview') + @(Get-VmfRequiredActions -Optional) }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @($script:allActs); notActions = @() }) }
        function Global:TpV5Entry([string]$Method) {
            $e = TpEntry -Method $Method
            $e.target.size = 'Standard_D4s_v5'; $e.target.controller = 'SCSI'; $e.target.diskArch = 'diskless'; $e.target.tempDisks = 0
            $e.target.choice.option = 'v5'; $e.policy.targetGeneration = 'v5'
            $e
        }
        function Global:TpAdeCheck($Entry) {
            $rp = TpRun
            InModuleScope VmMigrationFactory -Parameters @{ e = $Entry; rp = $rp } { param($e, $rp)
                Invoke-VmfStepPrecheck -Context @{ RunPath = $rp; VmId = [string]$e.vmId; SubscriptionId = '00000000-0000-0000-0000-000000000000'; Plan = $e; Rg = 'rg'; VmName = 'win-01' }
            }
        }
    }
    AfterAll { Remove-Item 'function:\TpV5Entry', 'function:\TpAdeCheck' -ErrorAction SilentlyContinue }

    It 'a Preview to v5 is asked about the encryption' {
        # ADE-DETECT-ANY-NAME-1: the check now reads the extension list and
        # each disk, later in Checking than this marker, so the step itself is
        # driven in AdeDetectAnyName.Tests.ps1 (a Preview to v5 with an
        # encrypted data disk stops on diskEncryptionPresent). Here: the
        # condition still names the in-place upgrade (Preview).
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Match "\`$adeStops = \(\`$plan\.target\.controller -eq 'NVMe' -or \(Get-VmfEntryMethod -Entry \`$plan\) -eq 'preview'\)"
    }
    It 'a plain v5 resize keeps the encryption and is not asked (GEN-V5-1)' {
        (TpAdeCheck (TpV5Entry 'in-place')).Reason | Should -Be 'pastEncryptionMarker' -Because 'the marker of the step after the encryption check'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfAdeExtension -Times 0 -Exactly -Scope It
    }
    It 'the words of an unknown answer say what is true now: no rebuild' {
        # ADE-DETECT-ANY-NAME-1: the words moved with the stop to Get-VmfAdeStop.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'DiskEncryption.ps1')
        $code | Should -Not -Match 'does not rebuild an encrypted machine'
        $code | Should -Match 'does not move an encrypted machine by the in-place upgrade \(Preview\)'
    }
}
