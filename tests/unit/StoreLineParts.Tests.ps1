#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
EVENTLOG-1: the activity log had a ceiling, and reaching it stopped the run.

An append blob holds 50,000 blocks. Add-VmfStoreLine writes ONE BLOCK PER
EVENT, and the engine writes an event around every Azure call plus about
thirty per machine, so a run of a thousand machines - the size this product
documents itself as handling - reaches it. Past it Azure answers 409
BlockCountExceedsLimit and the old code threw, which meant the migration
started failing on its own logging. Worse, the run could not then be closed
out: closing it out writes a line about closing it out.

So the log rolls into a next part, and every reader takes the parts in order.
The boundary is where this can go wrong, so that is what these tests drive:
the line that does not fit, the part after it, the reader that has to find it,
and the two moments a remembered part goes stale.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # The in-memory blob service StoreBackend.Tests.ps1 uses, plus the one
    # thing this file is about: an append blob has a BLOCK CEILING and refuses
    # the append past it. The real ceiling is 50,000, which would make these
    # tests take an hour, so the number is settable - the behaviour at it is
    # Azure's own: 409, with BlockCountExceedsLimit in the body.
    #
    # The counters are global because the tests read them back, and a test
    # scope is not the scope this function was defined in.
    function Global:Install-CappedBlobService {
        $global:VmfFakeBlobs = @{}         # path -> @{ Content; Type; Blocks }
        $global:VmfFakeAppends = @{}       # path -> how many appends were tried
        $global:VmfFakeBlockCap = [int]::MaxValue
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = $u.AbsolutePath.TrimStart('/')   # container/prefix/rel
            $query = $u.Query

            if ($query -match 'restype=container' -and $query -match 'comp=list') {
                $prefix = [uri]::UnescapeDataString(([regex]::Match($query, 'prefix=([^&]+)')).Groups[1].Value)
                $container = ($path -split '/')[0]
                $names = $global:VmfFakeBlobs.Keys |
                    Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { "<Name>$($_.Substring($container.Length + 1))</Name>" }
                return [pscustomobject]@{ StatusCode = 200; Content = "<EnumerationResults>$($names -join '')</EnumerationResults>"; Headers = @{} }
            }
            if ($query -match 'restype=container') {
                return [pscustomobject]@{ StatusCode = 201; Content = ''; Headers = @{} }
            }
            if ($query -match 'comp=appendblock') {
                $global:VmfFakeAppends[$path] = 1 + [int]$global:VmfFakeAppends[$path]
                if (-not $global:VmfFakeBlobs.ContainsKey($path)) { return [pscustomobject]@{ StatusCode = 404; Content = 'no blob'; Headers = @{} } }
                if ([int]$global:VmfFakeBlobs[$path].Blocks -ge $global:VmfFakeBlockCap) {
                    return [pscustomobject]@{
                        StatusCode = 409
                        Content    = '<Error><Code>BlockCountExceedsLimit</Code><Message>The committed block count cannot exceed the maximum limit of 50,000 blocks.</Message></Error>'
                        Headers    = @{}
                    }
                }
                $global:VmfFakeBlobs[$path].Content += $Body
                $global:VmfFakeBlobs[$path].Blocks = 1 + [int]$global:VmfFakeBlobs[$path].Blocks
                return [pscustomobject]@{ StatusCode = 201; Content = ''; Headers = @{} }
            }
            switch ($Method) {
                'PUT' {
                    if ($Headers['If-None-Match'] -eq '*' -and $global:VmfFakeBlobs.ContainsKey($path)) {
                        return [pscustomobject]@{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} }
                    }
                    $global:VmfFakeBlobs[$path] = @{ Content = [string]$Body; Type = $Headers['x-ms-blob-type']; Blocks = 0 }
                    return [pscustomobject]@{ StatusCode = 201; Content = ''; Headers = @{} }
                }
                'GET' {
                    if (-not $global:VmfFakeBlobs.ContainsKey($path)) { return [pscustomobject]@{ StatusCode = 404; Content = 'BlobNotFound'; Headers = @{} } }
                    return [pscustomobject]@{ StatusCode = 200; Content = $global:VmfFakeBlobs[$path].Content; Headers = @{} }
                }
                'HEAD' {
                    $code = if ($global:VmfFakeBlobs.ContainsKey($path)) { 200 } else { 404 }
                    return [pscustomobject]@{ StatusCode = $code; Content = ''; Headers = @{} }
                }
                'DELETE' {
                    $code = if ($global:VmfFakeBlobs.ContainsKey($path)) { $global:VmfFakeBlobs.Remove($path); 202 } else { 404 }
                    return [pscustomobject]@{ StatusCode = $code; Content = ''; Headers = @{} }
                }
            }
            [pscustomobject]@{ StatusCode = 500; Content = "unhandled: $Method $Uri"; Headers = @{} }
        }
    }
}

AfterAll {
    Remove-Item 'function:\Install-CappedBlobService' -ErrorAction SilentlyContinue
    Remove-Variable -Name VmfFakeBlobs, VmfFakeAppends, VmfFakeBlockCap -Scope Global -ErrorAction SilentlyContinue
}

Describe 'EVENTLOG-1: what the next part of a log is called' {
    BeforeAll {
        # The engine names the parts in PowerShell and the dashboard reads them
        # in JavaScript, so the rule is written twice and could drift apart
        # without either side failing. This is the one list of cases both are
        # held to; tests/js/log-parts.test.js takes the same file.
        $fixture = Join-Path $PSScriptRoot '..' 'fixtures' 'log-part-names.json'
        $script:partCases = @((Get-Content $fixture -Raw | ConvertFrom-Json).cases)
    }

    It 'has cases to check' {
        # A fixture that failed to load would make the case check below vacuous.
        $script:partCases.Count | Should -BeGreaterThan 5
    }

    It 'names the next part the way the dashboard expects' {
        foreach ($case in $script:partCases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ from = $case.from } {
                Get-VmfStoreLinePartName -RelPath $from
            }
            $got | Should -Be $case.to -Because $case.why
        }
    }
}

Describe 'EVENTLOG-1: a log that fills carries on in the next part' {
    BeforeEach {
        Install-CappedBlobService
        $global:VmfFakeBlockCap = 3
    }

    It 'does not throw when the part is full - the defect this fixes' {
        # Before this, the 409 came back out of Write-VmfEvent and into the
        # engine, which writes an event around every Azure call. The migration
        # would have started failing on its own logging.
        {
            InModuleScope VmMigrationFactory {
                $rp = 'azblob://acct/cont/run-nothrow'
                Initialize-VmfStore -RunPath $rp
                1..10 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
            }
        } | Should -Not -Throw
    }

    It 'keeps every line, in order, across the parts' {
        $lines = InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-order'
            Initialize-VmfStore -RunPath $rp
            1..10 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
            Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
        }
        @($lines).Count | Should -Be 10
        @($lines | ForEach-Object { ($_ | ConvertFrom-Json).n }) | Should -Be @(1..10)
    }

    It 'fills a part before it starts the next one' {
        # The boundary itself: three lines fit, the fourth is the one that has
        # to move, and it must BE the fourth - not lost, and not a second copy
        # of the third.
        $parts = InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-boundary'
            Initialize-VmfStore -RunPath $rp
            1..7 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
            # Read-VmfStoreLines answers with all of them now, so the parts are
            # looked at one at a time underneath it.
            [pscustomobject]@{
                all   = Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
                one   = Read-VmfStoreText -RunPath $rp -RelPath 'logs/events.jsonl'
                two   = Read-VmfStoreText -RunPath $rp -RelPath 'logs/events-2.jsonl'
                three = Read-VmfStoreText -RunPath $rp -RelPath 'logs/events-3.jsonl'
                four  = Read-VmfStoreText -RunPath $rp -RelPath 'logs/events-4.jsonl'
            }
        }
        $lines = { param($text) @(($text -split "`n") | Where-Object { $_.Trim() }) }
        @($parts.all).Count | Should -Be 7
        @(& $lines $parts.one) | Should -Be @('{"n":1}', '{"n":2}', '{"n":3}')
        @(& $lines $parts.two) | Should -Be @('{"n":4}', '{"n":5}', '{"n":6}')
        @(& $lines $parts.three) | Should -Be @('{"n":7}')
        $parts.four | Should -BeNullOrEmpty -Because 'a part is only made when the one before it is full'
    }

    It 'asks the full part once, not once per line' {
        <#
        The part in hand is remembered per process. Without that, EVERY line
        for the rest of the run would ask the full part first and be told no -
        two wasted requests per event, for ever, on the busiest thing the
        engine does.
        #>
        InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-cache'
            Initialize-VmfStore -RunPath $rp
            1..3 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
        }
        [int]$global:VmfFakeAppends['cont/run-cache/logs/events.jsonl'] | Should -Be 3 -Because 'three lines fit'

        InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-cache'
            4..20 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
        }
        # One more attempt on the full part: the line that discovered it was
        # full. Twenty would mean nothing was remembered.
        [int]$global:VmfFakeAppends['cont/run-cache/logs/events.jsonl'] | Should -Be 4
    }

    It 'forgets the part when the run is deleted' {
        <#
        A cache of something that moves forward is safe until the thing it
        describes goes backwards, and a deleted run is exactly that. A writer
        still aiming at part two would put the next line somewhere no reader
        reaches - readers stop at the first part that is not there, so the
        WHOLE log would be invisible rather than short.
        #>
        $lines = InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-deleted'
            Initialize-VmfStore -RunPath $rp
            1..5 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
            Remove-VmfStorePrefix -RunPath $rp -Confirm:$false | Out-Null
            Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line '{"n":"after"}'
            Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
        }
        @($lines).Count | Should -Be 1
        # @(...) first: one line comes back as a string, and indexing a string
        # gives a CHARACTER. That reads as a JSON error rather than a wrong
        # answer, which is a slow way to find out.
        (@($lines)[0] | ConvertFrom-Json).n | Should -Be 'after'
    }

    It 'forgets the part when the run is set up again' {
        <#
        The other way the store can go backwards under a process that is still
        running: the parts go WITHOUT this process removing them - a lifecycle
        rule on the container, a person with the portal open, another process
        clearing the run. The store is emptied here directly for that reason;
        deleting the run through the product clears the memory on its own, and
        a test that went that way would prove nothing about setting up.
        #>
        InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-reinit'
            Initialize-VmfStore -RunPath $rp
            1..5 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
        }
        $global:VmfFakeBlobs.Clear()

        $lines = InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-reinit'
            Initialize-VmfStore -RunPath $rp
            Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line '{"n":"after"}'
            Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
        }
        # Without the forgetting, the line lands in part two - which no reader
        # reaches, because they stop at the first part that is not there. The
        # log would be invisible, not short.
        @($lines).Count | Should -Be 1
        (@($lines)[0] | ConvertFrom-Json).n | Should -Be 'after'
    }

    It 'keeps one run parts out of another run log' {
        $out = InModuleScope VmMigrationFactory {
            $a = 'azblob://acct/cont/run-a'
            $b = 'azblob://acct/cont/run-b'
            Initialize-VmfStore -RunPath $a
            Initialize-VmfStore -RunPath $b
            1..5 | ForEach-Object { Add-VmfStoreLine -RunPath $a -RelPath 'logs/events.jsonl' -Line "{`"n`":`"a$_`"}" }
            Add-VmfStoreLine -RunPath $b -RelPath 'logs/events.jsonl' -Line '{"n":"b1"}'
            [pscustomobject]@{
                a = Read-VmfStoreLines -RunPath $a -RelPath 'logs/events.jsonl'
                b = Read-VmfStoreLines -RunPath $b -RelPath 'logs/events.jsonl'
            }
        }
        @($out.a).Count | Should -Be 5
        @($out.b).Count | Should -Be 1 -Because 'run b never filled anything'
        (@($out.b)[0] | ConvertFrom-Json).n | Should -Be 'b1'
    }

    It 'keeps two documents in the same run apart' {
        # The remembered part is per DOCUMENT as well as per run: an events log
        # that rolled must not send the deletions ledger to deletions-2.
        $out = InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-two-docs'
            Initialize-VmfStore -RunPath $rp
            1..5 | ForEach-Object { Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line "{`"n`":$_}" }
            Add-VmfStoreLine -RunPath $rp -RelPath 'deletions.jsonl' -Line '{"d":1}'
            [pscustomobject]@{
                events = Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
                dels   = Read-VmfStoreText -RunPath $rp -RelPath 'deletions.jsonl'
            }
        }
        @($out.events).Count | Should -Be 5
        $out.dels.Trim() | Should -Be '{"d":1}'
    }

    It 'still reports a failure that is not a full part' {
        # Rolling must not become a way to swallow every 409. A log written by
        # an older version as a block blob has its own handling; anything else
        # has to reach the caller.
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            if ($Uri -match 'comp=appendblock') {
                return [pscustomobject]@{ StatusCode = 403; Content = 'AuthorizationPermissionMismatch'; Headers = @{} }
            }
            [pscustomobject]@{ StatusCode = 201; Content = ''; Headers = @{} }
        }
        {
            InModuleScope VmMigrationFactory {
                Add-VmfStoreLine -RunPath 'azblob://acct/cont/run-403' -RelPath 'logs/events.jsonl' -Line '{}'
            }
        } | Should -Throw '*403*'
    }

    It 'refuses to walk for ever if every part says it is full' {
        # A store that answered BlockCountExceedsLimit to everything would
        # otherwise spin inside the one function every component writes
        # through. It stops, and says what it decided.
        $global:VmfFakeBlockCap = 0
        {
            InModuleScope VmMigrationFactory {
                $rp = 'azblob://acct/cont/run-forever'
                Initialize-VmfStore -RunPath $rp
                Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line '{}'
            }
        } | Should -Throw '*no part with room*'
    }
}

Describe 'EVENTLOG-1: reading a log that is in parts' {
    BeforeEach {
        $script:filePath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-parts-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach { if (Test-Path $script:filePath) { Remove-Item $script:filePath -Recurse -Force } }

    It 'reads the parts in order, on the file backend as well' {
        # The lab drills and the support bundle run against a file store, so
        # the walk cannot be something only the blob backend does.
        $lines = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:filePath } {
            Initialize-VmfStore -RunPath $rp
            Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line '{"n":1}'
            Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events-2.jsonl' -Line '{"n":2}'
            Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events-3.jsonl' -Line '{"n":3}'
            Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
        }
        @($lines | ForEach-Object { ($_ | ConvertFrom-Json).n }) | Should -Be @(1, 2, 3)
    }

    It 'stops at the first part that is not there' {
        <#
        The rule that makes the walk end: parts are made in order and whatever
        makes one appends to it in the same breath, so a gap is the end.
        Reading past a gap would mean two hundred reads on every refresh of the
        console to find nothing.
        #>
        $lines = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:filePath } {
            Initialize-VmfStore -RunPath $rp
            Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line '{"n":1}'
            Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events-3.jsonl' -Line '{"n":3}'
            Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
        }
        @($lines).Count | Should -Be 1
    }

    It 'a log that never rolled still reads, and one that is not there is empty' {
        $out = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:filePath } {
            Initialize-VmfStore -RunPath $rp
            $missing = Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
            Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line '{"n":1}'
            [pscustomobject]@{
                missing = $missing
                present = Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl'
            }
        }
        $out.missing | Should -BeNullOrEmpty
        @($out.present).Count | Should -Be 1
    }
}

Describe 'EVENTLOG-1: the engine keeps logging past the ceiling' {
    BeforeEach {
        Install-CappedBlobService
        $global:VmfFakeBlockCap = 4
    }

    It 'writes and reads the whole run through Write-VmfEvent' {
        # The end the operator sees: the console reads the log through
        # Read-VmfEvents, and a run that filled a part must still show all of
        # it - the last line included, which is the one that says the run is
        # over.
        $events = InModuleScope VmMigrationFactory {
            $rp = 'azblob://acct/cont/run-events'
            Initialize-VmfStore -RunPath $rp
            1..9 | ForEach-Object {
                Write-VmfEvent -RunPath $rp -Step 'assessment' -Outcome 'ok' -Detail "machine $_"
            }
            Write-VmfEvent -RunPath $rp -Step 'run' -Outcome 'ok' -Detail 'the run is finished'
            Read-VmfEvents -RunPath $rp
        }
        @($events).Count | Should -Be 10
        @($events)[-1].detail | Should -Be 'the run is finished'
        @($events | Where-Object { $_.step -eq 'assessment' }).Count | Should -Be 9
    }
}
