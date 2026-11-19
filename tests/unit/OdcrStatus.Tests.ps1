#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
ODCR-STATUS-1: a capacity reservation that is stuck at RESERVING is read from
Azure by its recorded resource ID.

MEASURED on the lab install, 2026-11-09: the reservation drill stopped the
engine 4 seconds after it asked Azure for wave-1's capacity reservation, and
Azure made it anyway - Present, Succeeded, real, and billing. The page said
"Reserving..." for 60 minutes and then "Not confirmed", from the clock alone,
and the migration page offered nothing.

Now the five-minute pass of the web service reads such a claim from Azure,
by the resource ID the engine recorded before it asked, when no reserve or
release job of the run runs, and writes what the engine would have written:
  Succeeded            RESERVED - Azure holds it, the wave can use it;
  Failed or Canceled   BLOCKED, reservation-failed - the engine's own rule;
  not found            RELEASED - nothing bills;
  still being made     not confirmed (reservationUnconfirmedUtc), which offers
                       Release, and the next pass reads it again.
The run stays in the record of the runs the pass checks while a claim is
RESERVING. The migration page shows Release beside a claim nobody confirmed
(tests/js/odcr-status.test.js).
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI, so the service tests mock stand-ins, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:temp = New-VmfTestTemp -Prefix 'odcrstatus'

    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:groupId = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000-236250ca"
    $script:resId = "$($script:groupId)/capacityReservations/d2s_v6"

    $script:NewRun = {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'odcr-status-test' | Out-Null }
        $rp
    }
    # A claim at RESERVING that recorded what it asked Azure for, as every ask
    # since RESERVING-STUCK-1 does, before the request.
    $script:PutClaim = { param($rp, [string]$name = 'c1', [string]$state = 'RESERVING', [hashtable]$extra = @{})
        $claim = [ordered]@{
            schemaVersion = 15; runId = 'r1'; wave = 'w1'; subscriptionId = $script:sub
            resourceGroup = 'rg-app'; region = 'centralus'; zone = $null
            size = 'Standard_D2s_v6'; vmFamily = 'StandardDsv6Family'; state = $state; blockReason = $null
            demand = @{ instances = 2; reservableInstances = 2; vcpus = 4; overlapWithSource = $false }
            quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
            # Asked 30 minutes ago: past the margin a not-found answer waits for.
            reservingSinceUtc = [datetime]::UtcNow.AddMinutes(-30).ToString('o')
            reservationAsked = [ordered]@{ groupId = $script:groupId; reservationId = $script:resId; askedUtc = [datetime]::UtcNow.AddMinutes(-30).ToString('o') }
        }
        foreach ($k in $extra.Keys) { $claim[$k] = $extra[$k] }
        $dir = Join-Path $rp 'capacity'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$name.json") -Encoding utf8NoBOM
    }
    $script:ClaimOf = { param($rp, [string]$name = 'c1') Get-Content (Join-Path $rp 'capacity' "$name.json") -Raw | ConvertFrom-Json -DateKind String }
    $script:Lines = { param($rp)
        $f = Join-Path $rp 'logs' 'events.jsonl'
        if (-not (Test-Path $f)) { return @() }
        @(Get-Content $f | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'odcr' })
    }
    $script:Reads = { param($rp) @(InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Get-VmfReservingClaims -RunPath $rp }) }
    $script:Update = { param($rp, $read) InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; r = $read } { param($rp, $r) Update-VmfReservingClaimFromAzure -RunPath $rp -Read $r } }
    $script:Answer = { param([bool]$found, [string]$state = $null, [string]$created = $null)
        [pscustomobject]@{ Found = $found; ProvisioningState = $(if ($state) { $state } else { $null }); TimeCreated = $(if ($created) { $created } else { $null }) } }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Invoke-AzRestMethod', 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'ODCR-STATUS-1: what Azure answered, pure' {
    It 'Found <Found>, provisioningState <State>: <Outcome>' -ForEach @(
        @{ Found = $true; State = 'Succeeded'; Outcome = 'held' }
        @{ Found = $true; State = 'Failed'; Outcome = 'failed' }
        @{ Found = $true; State = 'Canceled'; Outcome = 'failed' }
        @{ Found = $true; State = 'Creating'; Outcome = 'making' }
        @{ Found = $true; State = 'Updating'; Outcome = 'making' }
        @{ Found = $true; State = ''; Outcome = 'making' }
        @{ Found = $false; State = ''; Outcome = 'gone' }
        @{ Found = $false; State = 'Succeeded'; Outcome = 'gone' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ f = $Found; s = $State } { param($f, $s) Get-VmfReservingReadOutcome -Found $f -ProvisioningState $s } |
            Should -Be $Outcome
    }
}

Describe 'ODCR-STATUS-1: the read of a capacity reservation by its resource ID' {
    It 'one GET of the recorded ID, and Azure''s provisioningState and creation time' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfArmRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"provisioningState":"Succeeded","timeCreated":"2026-11-09T10:00:05.1234567+00:00"}}' } }
        $r = InModuleScope VmMigrationFactory -Parameters @{ id = $script:resId } { param($id) Get-VmfCapacityReservationByArm -ReservationId $id }
        $r.Found | Should -BeTrue
        $r.ProvisioningState | Should -Be 'Succeeded'
        $r.TimeCreated | Should -Match '^2026-11-09T10:00:05'
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfArmRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq "$($script:resId)?api-version=2024-07-01" }
    }

    It 'Azure says the <Code> is not found: not found' -ForEach @(@{ Code = 'ResourceNotFound' }, @{ Code = 'ParentResourceNotFound' }, @{ Code = 'ResourceGroupNotFound' }) {
        $answer = [pscustomobject]@{ StatusCode = 404; Content = (@{ error = @{ code = $Code; message = 'not there' } } | ConvertTo-Json -Compress) }
        Mock -ModuleName VmMigrationFactory Invoke-VmfArmRequest { $answer }.GetNewClosure()
        $r = InModuleScope VmMigrationFactory -Parameters @{ id = $script:resId } { param($id) Get-VmfCapacityReservationByArm -ReservationId $id }
        $r.Found | Should -BeFalse
        $r.ProvisioningState | Should -BeNullOrEmpty
    }

    It 'any other answer is no answer, and throws: <Why>' -ForEach @(
        @{ Why = 'a refused read'; Status = 403; Content = '{"error":{"code":"AuthorizationFailed","message":"no"}}' }
        @{ Why = 'a subscription Azure does not know'; Status = 404; Content = '{"error":{"code":"SubscriptionNotFound","message":"no"}}' }
        @{ Why = 'a 404 that names no code'; Status = 404; Content = '' }
        @{ Why = 'throttled'; Status = 429; Content = '{"error":{"code":"TooManyRequests"}}' }
        @{ Why = 'a 200 with no body'; Status = 200; Content = '' }
    ) {
        $answer = [pscustomobject]@{ StatusCode = $Status; Content = $Content }
        Mock -ModuleName VmMigrationFactory Invoke-VmfArmRequest { $answer }.GetNewClosure()
        { InModuleScope VmMigrationFactory -Parameters @{ id = $script:resId } { param($id) Get-VmfCapacityReservationByArm -ReservationId $id } } | Should -Throw
    }

    It 'an ID that is not a capacity reservation is refused before Azure is asked' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfArmRequest { throw 'must not be called' }
        { InModuleScope VmMigrationFactory -Parameters @{ id = $script:groupId } { param($id) Get-VmfCapacityReservationByArm -ReservationId $id } } | Should -Throw '*capacity reservation*'
        { InModuleScope VmMigrationFactory { Get-VmfCapacityReservationByArm -ReservationId "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/capacityReservationGroups/g/capacityReservations/r?api-version=1" } } | Should -Throw
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfArmRequest -Times 0 -Exactly
    }
}

Describe 'ODCR-STATUS-1: the RESERVING claims of a run' {
    It 'only the claims at RESERVING, each with the version it was read at' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp 'c1' 'RESERVING'
        & $script:PutClaim $rp 'c2' 'RESERVED'
        & $script:PutClaim $rp 'c3' 'QUOTA_VERIFIED'
        $reads = & $script:Reads $rp
        @($reads).Count | Should -Be 1
        $reads[0].Name | Should -Be 'c1.json'
        $reads[0].Claim.state | Should -Be 'RESERVING'
        $text = Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw
        $reads[0].Version | Should -Be (InModuleScope VmMigrationFactory -Parameters @{ t = $text } { param($t) Get-VmfDocumentVersion -Text $t })
    }

    It 'a run with no capacity folder has none' {
        @(& $script:Reads (& $script:NewRun)).Count | Should -Be 0
    }
}

Describe 'ODCR-STATUS-1: a RESERVING claim takes the answer Azure gives' {
    It 'Succeeded: RESERVED by the recorded IDs, so the wave can use it, and the activity says it bills' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp 'c1' 'RESERVING' @{ reservationUnconfirmedUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o') }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $true; ProvisioningState = 'Succeeded'; TimeCreated = '2026-11-09T10:00:05.0000000Z' } }
        $o = & $script:Update $rp (& $script:Reads $rp)[0]
        $o.Outcome | Should -Be 'held'
        $c = & $script:ClaimOf $rp
        $c.state | Should -Be 'RESERVED'
        $c.reservation.groupId | Should -Be $script:groupId
        $c.reservation.reservationId | Should -Be $script:resId
        $c.reservation.createdUtc | Should -Be '2026-11-09T10:00:05.0000000Z'
        $c.reservation.releasedUtc | Should -BeNullOrEmpty
        $c.reservation.consumedInstances | Should -Be 0
        $c.PSObject.Properties['reservationUnconfirmedUtc'] | Should -BeNullOrEmpty -Because 'Azure confirmed it now'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm -Times 1 -Exactly -ParameterFilter { $ReservationId -eq $script:resId }
        $l = @(& $script:Lines $rp)
        $l.Count | Should -Be 1
        $l[0].outcome | Should -Be 'ok'
        $l[0].detail | Should -Match 'Azure holds the on-demand capacity reservation for Standard_D2s_v6 in centralus'
        $l[0].detail | Should -Match 'bills'
    }

    It 'Failed: BLOCKED with reservation-failed, the engine''s rule for that answer' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $true; ProvisioningState = 'Failed'; TimeCreated = $null } }
        (& $script:Update $rp (& $script:Reads $rp)[0]).Outcome | Should -Be 'failed'
        $c = & $script:ClaimOf $rp
        $c.state | Should -Be 'BLOCKED'
        $c.blockReason | Should -Be 'reservation-failed'
        (@($c.notes) -join ' ') | Should -Match 'provisioningState is Failed'
        (& $script:Lines $rp)[0].outcome | Should -Be 'fail'
    }

    It 'not found: RELEASED, because nothing bills, and the activity says how to reserve again' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $false; ProvisioningState = $null; TimeCreated = $null } }
        (& $script:Update $rp (& $script:Reads $rp)[0]).Outcome | Should -Be 'gone'
        $c = & $script:ClaimOf $rp
        $c.state | Should -Be 'RELEASED'
        $c.reservation.reservationId | Should -Be $script:resId
        $c.reservation.releasedUtc | Should -Not -BeNullOrEmpty
        $c.reservation.createdUtc | Should -BeNullOrEmpty -Because 'nobody saw it made'
        $d = (& $script:Lines $rp)[0].detail
        $d | Should -Match 'Azure has no on-demand capacity reservation for Standard_D2s_v6 in centralus'
        $d | Should -Match 'nothing bills'
        $d | Should -Match 'check the quota on the wave, then reserve'
    }

    It 'not found within 10 minutes of the ask: nothing is written, because the create can still land' {
        $rp = & $script:NewRun
        $asked = [datetime]::UtcNow.AddMinutes(-9).ToString('o')
        & $script:PutClaim $rp 'c1' 'RESERVING' @{ reservingSinceUtc = $asked
            reservationAsked = [ordered]@{ groupId = $script:groupId; reservationId = $script:resId; askedUtc = $asked } }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $false; ProvisioningState = $null; TimeCreated = $null } }
        $before = Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw
        (& $script:Update $rp (& $script:Reads $rp)[0]).Outcome | Should -Be 'unchanged'
        Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw | Should -BeExactly $before
        @(& $script:Lines $rp).Count | Should -Be 0
    }

    It 'not found 11 minutes after the ask: RELEASED' {
        $rp = & $script:NewRun
        $asked = [datetime]::UtcNow.AddMinutes(-11).ToString('o')
        & $script:PutClaim $rp 'c1' 'RESERVING' @{ reservingSinceUtc = $asked
            reservationAsked = [ordered]@{ groupId = $script:groupId; reservationId = $script:resId; askedUtc = $asked } }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $false; ProvisioningState = $null; TimeCreated = $null } }
        (& $script:Update $rp (& $script:Reads $rp)[0]).Outcome | Should -Be 'gone'
        (& $script:ClaimOf $rp).state | Should -Be 'RELEASED'
    }

    It 'not found, and the record gives no time it asked: nothing is written' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp 'c1' 'RESERVING' @{ reservingSinceUtc = $null
            reservationAsked = [ordered]@{ groupId = $script:groupId; reservationId = $script:resId; askedUtc = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $false; ProvisioningState = $null; TimeCreated = $null } }
        (& $script:Update $rp (& $script:Reads $rp)[0]).Outcome | Should -Be 'unchanged'
        (& $script:ClaimOf $rp).state | Should -Be 'RESERVING'
    }

    It 'still being made: not confirmed, once, so Release is offered; the next read writes nothing' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $true; ProvisioningState = 'Creating'; TimeCreated = $null } }
        (& $script:Update $rp (& $script:Reads $rp)[0]).Outcome | Should -Be 'making'
        $c = & $script:ClaimOf $rp
        $c.state | Should -Be 'RESERVING'
        $c.reservationUnconfirmedUtc | Should -Not -BeNullOrEmpty
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } { param($c) Test-VmfClaimReservingStuck -Claim $c } | Should -BeTrue -Because 'a claim nobody confirmed offers Release'
        (& $script:Lines $rp)[0].detail | Should -Match 'provisioningState is Creating'
        $before = Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw
        (& $script:Update $rp (& $script:Reads $rp)[0]).Outcome | Should -Be 'unchanged'
        Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw | Should -BeExactly $before -Because 'a write each pass would refuse a Release that read the claim before it'
        @(& $script:Lines $rp).Count | Should -Be 1
    }

    It 'a claim that changed after the pass read it is left as it is' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp
        $read = (& $script:Reads $rp)[0]
        # A Release saved the claim in between.
        $c = & $script:ClaimOf $rp
        $c.state = 'RELEASED'
        $c | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'capacity' 'c1.json') -Encoding utf8NoBOM
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $true; ProvisioningState = 'Succeeded'; TimeCreated = $null } }
        (& $script:Update $rp $read).Outcome | Should -Be 'changed'
        (& $script:ClaimOf $rp).state | Should -Be 'RELEASED'
        @(& $script:Lines $rp).Count | Should -Be 0
    }

    It 'a recorded ID in another subscription than the claim is not read' {
        $rp = & $script:NewRun
        $other = '11111111-1111-1111-1111-111111111111'
        & $script:PutClaim $rp 'c1' 'RESERVING' @{ subscriptionId = $other }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { throw 'must not be called' }
        { & $script:Update $rp (& $script:Reads $rp)[0] } | Should -Throw '*not in the subscription of its claim*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm -Times 0 -Exactly
        (& $script:ClaimOf $rp).state | Should -Be 'RESERVING'
    }

    It 'a read Azure refuses changes nothing, and says so to the caller' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { throw 'HTTP 403 AuthorizationFailed' }
        { & $script:Update $rp (& $script:Reads $rp)[0] } | Should -Throw '*403*'
        $c = & $script:ClaimOf $rp
        $c.state | Should -Be 'RESERVING'
        $c.PSObject.Properties['reservationUnconfirmedUtc'] | Should -BeNullOrEmpty -Because 'no answer is not an answer'
    }

    It 'a claim no longer at RESERVING is not read' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp 'c1' 'RESERVED'
        $text = Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw
        $read = [pscustomobject]@{ Name = 'c1.json'; Handle = "$rp/capacity/c1.json"; Claim = ($text | ConvertFrom-Json)
                                   Version = (InModuleScope VmMigrationFactory -Parameters @{ t = $text } { param($t) Get-VmfDocumentVersion -Text $t }) }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { throw 'must not be called' }
        (& $script:Update $rp $read).Outcome | Should -Be 'unchanged'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm -Times 0 -Exactly
    }
}

Describe 'ODCR-STATUS-1: the five-minute pass reads only when no job makes or releases the reservation' {
    BeforeEach {
        $script:rp = & $script:NewRun
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $true; ProvisioningState = 'Succeeded'; TimeCreated = $null } }
    }

    It 'a run with no claim at RESERVING asks Azure nothing' {
        & $script:PutClaim $script:rp 'c1' 'RESERVED'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { throw 'must not be called' }
        $r = Invoke-VmfFacadeReadReservingClaims -StorePath $script:rp -RunId 'p1/r1'
        @($r.Remaining).Count | Should -Be 0
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm -Times 0 -Exactly
    }

    It 'a reserve or release job of the run runs: no read and no write, and the claim stays to check' {
        & $script:PutClaim $script:rp
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        $r = Invoke-VmfFacadeReadReservingClaims -StorePath $script:rp -RunId 'p1/r1'
        @($r.Remaining).Count | Should -Be 1
        $r.EngineRuns | Should -BeTrue
        (& $script:ClaimOf $script:rp).state | Should -Be 'RESERVING'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm -Times 0 -Exactly
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -Times 1 -Exactly -ParameterFilter {
            $RunId -eq 'p1/r1' -and -not $Project -and $Fresh -and @($Operation).Count -eq 2 -and 'reserve' -in $Operation -and 'release' -in $Operation }
    }

    It 'no such job: the claim takes Azure''s answer, and only a claim still RESERVING stays to check' {
        & $script:PutClaim $script:rp 'c1'
        & $script:PutClaim $script:rp 'c2'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        $script:n = 0
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm {
            $script:n++
            if ($script:n -eq 1) { [pscustomobject]@{ Found = $true; ProvisioningState = 'Succeeded'; TimeCreated = $null } }
            else { [pscustomobject]@{ Found = $true; ProvisioningState = 'Creating'; TimeCreated = $null } }
        }
        $r = Invoke-VmfFacadeReadReservingClaims -StorePath $script:rp -RunId 'r1'
        @($r.Outcomes.Outcome) | Should -Be @('held', 'making')
        @($r.Remaining).Count | Should -Be 1
        $r.Remaining[0].Name | Should -Be 'c2.json'
    }

    It 'a read that fails for one claim is a warning; the others are read, and it stays to check' {
        & $script:PutClaim $script:rp 'c1'
        & $script:PutClaim $script:rp 'c2'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        $script:n = 0
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm {
            $script:n++
            if ($script:n -eq 1) { throw 'HTTP 429 TooManyRequests' }
            [pscustomobject]@{ Found = $false; ProvisioningState = $null; TimeCreated = $null }
        }
        $r = Invoke-VmfFacadeReadReservingClaims -StorePath $script:rp -RunId 'r1' -WarningVariable w 3>$null
        (@($w | ForEach-Object { [string]$_ }) -join ' ') | Should -Match 'c1\.json.*429'
        (& $script:ClaimOf $script:rp 'c2').state | Should -Be 'RELEASED'
        @($r.Remaining.Name) | Should -Be @('c1.json')
    }

    It 'the list of jobs that Azure does not give throws, and the claim is not read' {
        & $script:PutClaim $script:rp
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { throw 'HTTP 503' }
        { Invoke-VmfFacadeReadReservingClaims -StorePath $script:rp -RunId 'r1' } | Should -Throw '*503*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm -Times 0 -Exactly
    }
}

Describe 'ODCR-STATUS-1: a run with a claim at RESERVING stays in the record of the runs to check' {
    It 'a claim at RESERVING: now (reservingClaim)' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp
        $n = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Get-VmfRunScheduleNeed -RunPath $rp -StateDocs @() }
        $n.Reason | Should -Be 'reservingClaim'
        $n.NextUtc | Should -Not -BeNullOrEmpty
    }

    It 'claims RESERVED, BLOCKED or RELEASED: nothing' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp 'c1' 'RESERVED'
        & $script:PutClaim $rp 'c2' 'BLOCKED'
        & $script:PutClaim $rp 'c3' 'RELEASED'
        (InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Get-VmfRunScheduleNeed -RunPath $rp -StateDocs @() }).NextUtc | Should -BeNullOrEmpty
    }

    It 'the claims the pass already read are used, not read again: <Why>' -ForEach @(
        @{ Why = 'none left at RESERVING'; Left = 0; Reason = $null }
        @{ Why = 'one left at RESERVING'; Left = 1; Reason = 'reservingClaim' }
    ) {
        $rp = & $script:NewRun
        & $script:PutClaim $rp
        $left = @(1..$Left | Where-Object { $Left -gt 0 } | ForEach-Object { [pscustomobject]@{ Name = 'c1.json' } })
        Mock -ModuleName VmMigrationFactory Get-VmfReservingClaims { throw 'must not be read again' }
        $n = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; l = $left } { param($rp, $l) Get-VmfRunScheduleNeed -RunPath $rp -StateDocs @() -ReservingClaims $l }
        $n.Reason | Should -Be $Reason
    }
}

Describe 'ODCR-STATUS-1: a reserve marks its run for the five-minute pass' {
    It 'New-VmfWaveReservation marks the run after it wrote RESERVING, before Azure is asked' {
        $rp = & $script:NewRun
        & $script:PutClaim $rp 'c1' 'QUOTA_VERIFIED' @{ reservingSinceUtc = $null; reservationAsked = $null }
        $c = & $script:ClaimOf $rp
        $c.PSObject.Properties.Remove('reservationAsked'); $c.PSObject.Properties.Remove('reservingSinceUtc')
        $c | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'capacity' 'c1.json') -Encoding utf8NoBOM
        $global:OdcrMarkSaw = $null
        $global:OdcrOrder = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Add-VmfRunScheduleDue {
            $global:OdcrOrder.Add('mark')
            $global:OdcrMarkSaw = (Get-Content (Join-Path $RunPath 'capacity' 'c1.json') -Raw | ConvertFrom-Json).state
            $true
        }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { $global:OdcrOrder.Add('ask'); @{ GroupId = '/g'; ReservationId = '/g/r' } }
        try {
            New-VmfWaveReservation -OutPath $rp -Wave 'w1' | Out-Null
            $global:OdcrMarkSaw | Should -Be 'RESERVING'
            @($global:OdcrOrder) | Should -Be @('mark', 'ask')
            Should -Invoke -ModuleName VmMigrationFactory Add-VmfRunScheduleDue -Times 1 -Exactly -ParameterFilter { $RunPath -eq $rp -and $Reason -eq 'engine' }
        }
        finally { Remove-Variable -Name OdcrMarkSaw, OdcrOrder -Scope Global -ErrorAction SilentlyContinue }
    }
}

Describe 'ODCR-STATUS-1: the five-minute pass, end to end on a store on disk' {
    BeforeAll {
        $script:oldStore = $env:VMF_STORE_PATH
    }
    AfterAll {
        if ($null -eq $script:oldStore) { Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue } else { $env:VMF_STORE_PATH = $script:oldStore }
    }

    It 'a stuck claim is RESERVED within one pass, and the run leaves the record once nothing is RESERVING' {
        $root = Join-Path $script:temp "pass-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $rp = Join-Path $root 'run01'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'run01' | Out-Null }
        & $script:PutClaim $rp
        $env:VMF_STORE_PATH = $root
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $true; ProvisioningState = 'Succeeded'; TimeCreated = $null } }
        & (Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Timer $null 3>$null 6>$null
        (& $script:ClaimOf $rp).state | Should -Be 'RESERVED'
        $due = Join-Path $root 'schedule-due.json'
        if (Test-Path $due) { @((Get-Content $due -Raw | ConvertFrom-Json).runs | Where-Object runId -eq 'run01').Count | Should -Be 0 }
    }

    It 'the records of a run are read once a pass: the need check is given what the read left' {
        $root = Join-Path $script:temp "pass-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $rp = Join-Path $root 'run01'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'run01' | Out-Null }
        & $script:PutClaim $rp
        $env:VMF_STORE_PATH = $root
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $true; ProvisioningState = 'Creating'; TimeCreated = $null } }
        $global:OdcrReads = 0
        Mock -ModuleName VmMigrationFactory Get-VmfReservingClaims {
            $global:OdcrReads++
            & (Get-Module VmMigrationFactory) { param($a) & (Get-Command Get-VmfReservingClaims -CommandType Function) -RunPath $a } $RunPath
        }
        try {
            & (Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Timer $null 3>$null 6>$null
            $global:OdcrReads | Should -Be 1
            (& $script:ClaimOf $rp).reservationUnconfirmedUtc | Should -Not -BeNullOrEmpty -Because 'the check ran'
        }
        finally { Remove-Variable -Name OdcrReads -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'a claim Azure still makes keeps its run in the record, and the next pass reads it again' {
        $root = Join-Path $script:temp "pass-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $rp = Join-Path $root 'run01'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'run01' | Out-Null }
        & $script:PutClaim $rp
        $env:VMF_STORE_PATH = $root
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $true; ProvisioningState = 'Creating'; TimeCreated = $null } }
        & (Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Timer $null 3>$null 6>$null
        $due = Get-Content (Join-Path $root 'schedule-due.json') -Raw | ConvertFrom-Json
        @($due.runs | Where-Object runId -eq 'run01').Count | Should -Be 1
        (& $script:ClaimOf $rp).reservationUnconfirmedUtc | Should -Not -BeNullOrEmpty
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $false; ProvisioningState = $null; TimeCreated = $null } }
        & (Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Timer $null 3>$null 6>$null
        (& $script:ClaimOf $rp).state | Should -Be 'RELEASED'
    }
}

Describe 'ODCR-STATUS-1: in the code' {
    It 'the read is one ARM GET through Invoke-VmfArmRequest, which the web service has: no Get-AzCapacityReservation' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsCapacity.ps1')
        $fn = [regex]::Match($code, '(?s)function Get-VmfCapacityReservationByArm \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Match 'Invoke-VmfArmRequest -Method GET'
        $fn | Should -Not -Match 'Get-AzCapacityReservation'
    }
}
