#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PREVIEW-RESTORE-UPFRONT-1: the web service refuses Restore this machine from
# the first copy of a Preview move before it starts a job, when the preview
# feature is not registered.
#
# THE DEFECT. PREVIEW-PUTBACK-1 made the engine (Restore-VmfVm) read the
# preview feature VMTempDiskResizePreview before it makes a disk or stops the
# machine, and refuse there. Nothing on the machine changed, but the service
# started the restore job without that read: the person saw a restore start
# and then fail, not a refusal in the dialog. The retirement check
# (RETIRE-SCOPE-1) is refused in both places; the feature check was only in
# the engine.
#
# THE RULE IS ONE RULE. The service asks the engine module's own decision
# (Get-VmfPreviewPutBackVerdict, the function Get-VmfPreviewPutBackCheck uses)
# with what it reads itself, so the words in the dialog are the words the
# engine writes. The service reads only with Az.Accounts (FacadeAzModules.Tests.ps1):
# the feature with Get-VmfPreviewFeatureState and the machine's size with a
# GET of the machine (Get-VmfVmSizeByArm), both through Invoke-VmfArmRequest.
#
# The service refuses only on a definite answer: the feature read says not
# registered, and the size read gives a size that is not the original one. A
# read that fails is left to the engine, which asks again with its own
# identity and refuses when it cannot read either. The engine's check stays:
# it is the guarantee.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:sub = "/subscriptions/$($script:subId)/resourceGroups/rg-app/providers/Microsoft.Compute"
    $script:vmId = "$($script:sub)/virtualMachines/win-01"
    $script:original = 'Standard_D4ds_v4'
    $script:target = 'Standard_D4ds_v6'
    $script:caller = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }

    # A Windows machine moved from D4ds_v4 to D4ds_v6 by -Method, with its
    # first copies. -NoStarted: a record from before STATE-TARGET-1.
    function Global:PruRun {
        param([string]$RunPath, [string]$Method = 'preview', [string]$EntryMethod = '', [switch]$NoStarted)
        $em = if ($EntryMethod) { $EntryMethod } else { $Method }
        $started = [pscustomobject]@{ path = 'A'; series = 'v6'; size = $script:target; controller = 'NVMe'
            target = [pscustomobject]@{ size = $script:target; controller = 'NVMe'; diskArch = 'nvme-temp'
                choice = [pscustomobject]@{ option = 'v6'; source = 'person'; method = $Method } } }
        $entry = [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; path = 'A'; wave = 'w1'
            target = [ordered]@{ size = $script:target; controller = 'NVMe'; diskArch = 'nvme-temp'
                choice = [ordered]@{ option = 'v6'; source = 'person'; method = $em } } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $script:vmId; sub = $script:sub; orig = $script:original
            started = $(if ($NoStarted) { $null } else { $started }); entry = $entry } {
            param($rp, $id, $sub, $orig, $started, $entry)
            Initialize-VmfRun -RunPath $rp -RunId (Split-Path $rp -Leaf) | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId (Split-Path $rp -Leaf) -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $captured = [ordered]@{
                vmConfig = [pscustomobject]@{ name = 'win-01'; size = $orig; controller = 'SCSI'; location = 'centralus'; osType = 'Windows'; zones = @()
                    osDisk = [pscustomobject]@{ name = 'win-01-os'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/win-01-os"; deleteOption = 'Delete' }
                    dataDisks = @(); tags = @{}; nics = @() } }
            if ($started) { $captured.startedTarget = $started }
            $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]$captured)
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/snapshots/win-01-prepared"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/snapshots/win-01-pristine"; pristineSnapshotLocked = $true })
            $doc.state = 'MIGRATED'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @($entry) }) -Depth 24
        }
    }

    # Azure, at the one place both reads go: Invoke-VmfArmRequest. feature is
    # the state Azure gives, or 'unread' (refused); size is the machine's size
    # now, 'gone' (404) or 'fail' (500).
    function Global:PruAzure([string]$Feature = 'NotRegistered', [string]$Size = $script:target) {
        $global:pru = @{ feature = $Feature; size = $Size; calls = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Invoke-VmfArmRequest {
            if ($Path -match '/providers/Microsoft\.Features/') {
                $global:pru.calls.Add('feature')
                if ($global:pru.feature -eq 'unread') { return [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ state = $global:pru.feature } } | ConvertTo-Json -Depth 5) }
            }
            if ($Path -match '/virtualMachines/') {
                $global:pru.calls.Add("vm:$Path")
                if ($global:pru.size -eq 'gone') { return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"ResourceNotFound"}}' } }
                if ($global:pru.size -eq 'fail') { return [pscustomobject]@{ StatusCode = 500; Content = '{"error":{"code":"InternalServerError"}}' } }
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ name = 'win-01'; properties = @{ hardwareProfile = @{ vmSize = $global:pru.size } } } | ConvertTo-Json -Depth 5) }
            }
            if ($Path -match '^/subscriptions/[^/]+\?') {
                $global:pru.calls.Add('subscription')
                return [pscustomobject]@{ StatusCode = 200; Content = '{"displayName":"Applications"}' }
            }
            throw "PREVIEW-RESTORE-UPFRONT-1 test: an ARM call nobody expected: $Method $Path"
        }
    }
    # The start, as the restore dialog sends it. Returns the message it threw.
    function Global:PruStart([string]$Run, [string]$DiskSource = 'pristine') {
        $failed = $null
        try {
            Invoke-VmfFacadeStartEngine -Principal $script:caller -Operation restore -RunId $Run -VmId $script:vmId -Note 'Put the machine back.' -DiskSource $DiskSource -ErrorAction Stop | Out-Null
        }
        catch { $failed = $_.Exception.Message }
        $failed
    }
}
AfterAll {
    Remove-Item 'function:\PruRun', 'function:\PruAzure', 'function:\PruStart' -ErrorAction SilentlyContinue
    Remove-Variable pru -Scope Global -ErrorAction SilentlyContinue
}

Describe 'PREVIEW-RESTORE-UPFRONT-1: the service refuses a Preview restore before its job' {
    BeforeAll {
        $script:storeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pru-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:storeRoot | Out-Null
        $script:oldStore = $env:VMF_STORE_PATH
        $env:VMF_STORE_PATH = $script:storeRoot
        Global:PruRun -RunPath (Join-Path $script:storeRoot 'preview')
        Global:PruRun -RunPath (Join-Path $script:storeRoot 'inplace') -Method 'in-place'
        Global:PruRun -RunPath (Join-Path $script:storeRoot 'record') -Method 'preview' -EntryMethod 'in-place'
        Global:PruRun -RunPath (Join-Path $script:storeRoot 'norecord') -NoStarted
    }
    AfterAll {
        $env:VMF_STORE_PATH = $script:oldStore
        if ($script:storeRoot -and (Test-Path $script:storeRoot)) { Remove-Item $script:storeRoot -Recurse -Force }
    }

    It 'THE DEFECT: not registered, the machine on its new size - refused with a 400 before a job starts, naming the feature, the subscription and the state' {
        Global:PruAzure -Feature 'NotRegistered'
        $failed = Global:PruStart 'preview'
        $failed | Should -BeLike '400: *'
        $failed | Should -Not -BeLike '*VMF_ENGINE_JOB_ID*' -Because 'the refusal comes before the service reads the engine job'
        $failed | Should -Match 'in-place upgrade \(Preview\)'
        $failed | Should -Match 'VMTempDiskResizePreview'
        $failed | Should -Match ([regex]::Escape("Applications ($($script:subId))"))
        $failed | Should -Match 'Azure gives its state as NotRegistered'
        $failed | Should -Match 'Nothing on the machine changed'
        $failed | Should -Match $script:original
    }
    It 'every state that is not Registered is refused: <State>' -ForEach @(@{ State = 'Unregistered' }, @{ State = 'Unregistering' }, @{ State = 'Pending' }, @{ State = 'Registering' }) {
        Global:PruAzure -Feature $State
        Global:PruStart 'preview' | Should -Match ([regex]::Escape("400: This machine took the in-place upgrade (Preview)"))
    }
    It 'ONE RULE: the words are the words the engine writes for the same answer' {
        Global:PruAzure -Feature 'NotRegistered'
        $failed = Global:PruStart 'preview'
        $engine = InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId; s = $script:subId; o = $script:original; t = $script:target; rp = (Join-Path $script:storeRoot 'preview') } {
            param($id, $s, $o, $t, $rp)
            (Get-VmfPreviewPutBackCheck -Context ([pscustomobject]@{ RunPath = $rp; VmId = $id; SubscriptionId = $s; Rg = 'rg-app'; VmName = 'win-01' }) -Kind restore -Method preview -Size $o -SizeNow $t).Detail
        }
        $engine | Should -Not -BeNullOrEmpty
        $failed | Should -BeExactly "400: $engine"
        # The page test (tests/js/preview-restore-upfront.test.js) shows these
        # words in the restore dialog: its sentence is the engine's.
        $js = Get-Content (Join-Path $script:repoRoot 'tests' 'js' 'preview-restore-upfront.test.js') -Raw
        $decl = [regex]::Match($js, '(?s)const SENTENCE = (.+?);').Groups[1].Value
        $sentence = (@([regex]::Matches($decl, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value })) -join ''
        $sentence | Should -BeExactly $engine
    }
    It 'the size is read from the machine the record names, by a GET of its resource id' {
        Global:PruAzure -Feature 'NotRegistered'
        $null = Global:PruStart 'preview'
        @($global:pru.calls | Where-Object { $_ -like 'vm:*' }) | Should -HaveCount 1
        ($global:pru.calls | Where-Object { $_ -like 'vm:*' }) | Should -BeLike "vm:$($script:vmId)?api-version=*"
    }
    It 'registered: past this check, to the engine - and the size is not read' {
        Global:PruAzure -Feature 'Registered'
        $failed = Global:PruStart 'preview'
        $failed | Should -BeLike '*VMF_ENGINE_JOB_ID*' -Because 'it got as far as wanting the engine job'
        @($global:pru.calls | Where-Object { $_ -like 'vm:*' }) | Should -HaveCount 0
    }
    It 'not registered, but the machine is on its original size already: past this check, as the engine lets it go on' {
        Global:PruAzure -Feature 'NotRegistered' -Size $script:original.ToLowerInvariant()
        Global:PruStart 'preview' | Should -BeLike '*VMF_ENGINE_JOB_ID*'
    }
    It 'a read that gives no definite answer is left to the engine, which asks again: <Case>' -ForEach @(
        @{ Case = 'the feature read is refused'; Feature = 'unread'; Size = 'Standard_D4ds_v6' },
        @{ Case = 'the size read fails'; Feature = 'NotRegistered'; Size = 'fail' },
        @{ Case = 'Azure does not find the machine'; Feature = 'NotRegistered'; Size = 'gone' }
    ) {
        Global:PruAzure -Feature $Feature -Size $Size
        Global:PruStart 'preview' | Should -BeLike '*VMF_ENGINE_JOB_ID*'
    }
    It 'a move that is not a Preview reads nothing' {
        Global:PruAzure -Feature 'NotRegistered'
        Global:PruStart 'inplace' | Should -BeLike '*VMF_ENGINE_JOB_ID*'
        @($global:pru.calls) | Should -HaveCount 0
    }
    It 'the record of the move decides, as in the engine: a plan entry changed to in-place after a Preview move started is still refused' {
        Global:PruAzure -Feature 'NotRegistered'
        Global:PruStart 'record' | Should -Match 'VMTempDiskResizePreview'
    }
    It 'a record with no started move is no method, as in the engine: nothing is read' {
        Global:PruAzure -Feature 'NotRegistered'
        Global:PruStart 'norecord' | Should -BeLike '*VMF_ENGINE_JOB_ID*'
        @($global:pru.calls) | Should -HaveCount 0
    }
    It 'from the other copy the size does not change, so nothing is read' {
        Global:PruAzure -Feature 'NotRegistered'
        Global:PruStart 'preview' -DiskSource 'prepared' | Should -BeLike '*VMF_ENGINE_JOB_ID*'
        @($global:pru.calls) | Should -HaveCount 0
    }
    It 'a resume of a restore that stopped part way is not asked again' {
        Global:PruAzure -Feature 'NotRegistered'
        $failed = InModuleScope FacadeCore -Parameters @{ c = $script:caller; id = $script:vmId } {
            param($c, $id)
            $script:VmfResumeDispatch = 'op-1'
            try { Invoke-VmfFacadeStartEngine -Principal $c -Operation restore -RunId 'preview' -VmId $id -Note 'again' -DiskSource pristine -ErrorAction Stop | Out-Null; $null }
            catch { $_.Exception.Message }
            finally { $script:VmfResumeDispatch = $null }
        }
        $failed | Should -BeLike '*VMF_ENGINE_JOB_ID*'
        @($global:pru.calls) | Should -HaveCount 0
    }
    It 'a run with no record of the machine is left to the engine' {
        Global:PruAzure -Feature 'NotRegistered'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:storeRoot 'empty') -Force
        Global:PruStart 'empty' | Should -Not -Match 'VMTempDiskResizePreview'
    }
}

Describe 'PREVIEW-RESTORE-UPFRONT-1: the size read the service uses' {
    BeforeEach { Global:PruAzure }
    It '200: the size Azure gives' {
        InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } { param($id) Get-VmfVmSizeByArm -VmId $id } | Should -Be 'Standard_D4ds_v6'
    }
    It '404: no machine, no size' {
        $global:pru.size = 'gone'
        InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } { param($id) Get-VmfVmSizeByArm -VmId $id } | Should -BeExactly ''
    }
    It 'any other answer throws - an empty size is never the answer to no answer' {
        $global:pru.size = 'fail'
        { InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } { param($id) Get-VmfVmSizeByArm -VmId $id } } | Should -Throw '*500*'
    }
    It 'only a full machine id is read' {
        { InModuleScope VmMigrationFactory { Get-VmfVmSizeByArm -VmId 'rg-app/win-01' } } | Should -Throw '*Not a full virtual machine resource id*'
    }
    It 'it lives behind the azureops boundary, and reads only' {
        $hit = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter *.ps1 |
                Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match 'function Get-VmfVmSizeByArm' })
        $hit | Should -HaveCount 1
    }
}

Describe 'PREVIEW-RESTORE-UPFRONT-1: the decision is one rule' {
    It 'the engine check and the service ask the same decision function' {
        $gate = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PreviewFeatureGate.ps1')
        ([regex]::Matches($gate, 'Get-VmfPreviewPutBackVerdict\s+-')).Count | Should -Be 2 -Because 'Get-VmfPreviewPutBackCheck (engine) and Get-VmfPreviewPutBackRefusal (service) both call it'
        ([regex]::Matches($gate, 'changes the temporary disk again')).Count | Should -Be 1 -Because 'the words are written once'
    }
    It 'the service asks it on the restore path, after the retirement check' {
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $retire = $core.IndexOf('Get-VmfPutBackRetirementRefusal')
        $preview = $core.IndexOf('Get-VmfPreviewPutBackRefusal')
        $job = $core.IndexOf('$job = Get-VmfFacadeEngineJob')
        $preview | Should -BeGreaterThan $retire
        $preview | Should -BeLessThan $job -Because 'refused before the service reads or starts the engine job'
    }
    It 'the permission map says the web service reads the feature and the size before a restore' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $op = @($map.operations | Where-Object { @($_.actions) -contains 'Microsoft.Features/providers/features/read' })
        $op[0].why | Should -Match 'The web service reads it too before it starts Restore this machine from the first copy'
    }
}
