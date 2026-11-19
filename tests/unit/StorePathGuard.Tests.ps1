#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
RUNID-1: both halves of one trust boundary refuse the same input.

The {runId} segment of every runs/... route comes from the BROWSER, and
sixteen endpoints handed it straight to Get-VmfFacadeStorePath, where it
becomes part of a blob key. It was the only browser-supplied value on this
boundary with no check at all - and in the very same expression, two endpoints
refuse the PROJECT half unless it matches a strict pattern. One path, two
halves, one of them checked.

THIS IS NOT AN ATTACK THAT WORKED. A slash does not survive the route at all -
IIS refuses an encoded one and the caller gets a bare 404, which is why
PROJECT-1 moved the project into the request body. So the container cannot be
escaped and another run cannot be reached. It is a boundary whose two halves
disagreed, which is a question somebody has to answer again every time they
read it.

Two changes, tested here:
  1. the run id goes through Resolve-VmfFacadeStoreKey, the guard the store
     endpoints already use - so the same input gets the same answer
  2. Get-VmfStoreBlobUri escapes each segment, so the SINK is safe whatever
     arrives. The listing paths in StoreApi.ps1 have always escaped their
     prefix; the paths that name one document did not.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error, not
    # quietly reach real Azure. It matters here more than usual: one test below
    # deliberately drives the engine dispatch PAST the guard to prove the guard
    # did not close the door, so it goes on to attempt real work.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # The facade reads its store from app settings. A blob account keeps the
    # test on the path the product actually runs on.
    $script:savedStorePath = $env:VMF_STORE_PATH
    $env:VMF_STORE_PATH = $null
    $env:VMF_STORE_ACCOUNT = 'acct'
    $env:VMF_STORE_CONTAINER = 'runs'

    # Every input the store endpoints refuse. The point of the list is that it
    # is ONE list: whatever a browser may not use as a document path, it may
    # not use as a run id either.
    $script:refused = @(
        @{ value = '../../etc'; why = 'a segment that goes up a level' }
        @{ value = '..'; why = 'nothing but a level up' }
        @{ value = 'run/../../other'; why = 'a level up in the middle' }
        @{ value = '/run1'; why = 'an absolute path' }
        @{ value = 'run\1'; why = 'a backslash, which is a separator on the other side' }
        @{ value = 'https://elsewhere/run'; why = 'a scheme' }
        @{ value = 'c:/runs'; why = 'a drive' }
        @{ value = "run$([char]1)1"; why = 'a control character' }
    )

    # Names the product really writes. These must keep working, or the guard
    # has broken the product to protect it.
    $script:allowed = @(
        'run-2026-09-13-a1b2c3',
        'project-one/run-2026-09-13-a1b2c3',
        'run..1',       # two dots inside a name is not a level up
        '..notes',      # nor a name that starts with them
        'RUN_1.2~3'
    )
}

AfterAll {
    $env:VMF_STORE_PATH = $script:savedStorePath
    $env:VMF_STORE_ACCOUNT = $null
    $env:VMF_STORE_CONTAINER = $null
}

Describe 'RUNID-1: the run id gets the check the document path already got' {

    It 'has inputs to check, so this cannot pass by testing nothing' {
        $script:refused.Count | Should -BeGreaterThan 5
        $script:allowed.Count | Should -BeGreaterThan 3
    }

    It 'refuses <why>' -TestCases $script:refused {
        param($value, $why)
        { Get-VmfFacadeStorePath -RunId $value } | Should -Throw -Because $why
    }

    It 'and refuses it with a 400, so the endpoint says Bad Request and not Server Error' {
        foreach ($case in $script:refused) {
            $err = $null
            try { Get-VmfFacadeStorePath -RunId $case.value } catch { $err = "$_" }
            $err | Should -BeLike '400*' -Because "$($case.why) is the caller's mistake, not ours"
        }
    }

    It 'the SAME input is refused as a document path - one boundary, one answer' {
        # The defect was that these two disagreed. This is the assertion that
        # holds them together: whatever the store endpoints refuse, the run
        # endpoints refuse.
        foreach ($case in $script:refused) {
            { Resolve-VmfFacadeStoreKey -Path $case.value } | Should -Throw -Because "the store endpoints refuse $($case.why)"
        }
    }

    It 'still builds the path for a real run id' {
        Get-VmfFacadeStorePath -RunId 'run-2026-09-13-a1b2c3' |
            Should -Be 'azblob://acct/runs/run-2026-09-13-a1b2c3'
    }

    It 'still builds the path for a run inside a project' {
        # PROJECT-1: a run inside a project is `project/run`, assembled by the
        # endpoint from the route and the request body. A guard that refused
        # the slash would have broken every project.
        Get-VmfFacadeStorePath -RunId 'project-one/run-a1b2c3' |
            Should -Be 'azblob://acct/runs/project-one/run-a1b2c3'
    }

    It 'allows <_>' -TestCases $script:allowed {
        { Get-VmfFacadeStorePath -RunId $_ } | Should -Not -Throw
    }

    It 'no run id at all still names the whole store' {
        # Listing runs is a real request and it has no run id.
        Get-VmfFacadeStorePath | Should -Be 'azblob://acct/runs'
        Get-VmfFacadeStorePath -RunId '' | Should -Be 'azblob://acct/runs'
    }

    It 'refuses a level up on the LOCAL backend too, which is where it would have worked' {
        # On a file store the value reaches Join-Path, and `..` there is a real
        # directory above the store root. Tests and development use this
        # backend, so it is the one place the traversal was not theoretical.
        # A TestDrive folder, never a drive-root one (TEST-WRITES-OUTSIDE-TESTDRIVE-1).
        $store = Join-Path $TestDrive 'vmf-store'
        $env:VMF_STORE_PATH = $store
        try {
            { Get-VmfFacadeStorePath -RunId '..' } | Should -Throw
            Get-VmfFacadeStorePath -RunId 'run-1' | Should -Be (Join-Path $store 'run-1')
        }
        finally { $env:VMF_STORE_PATH = $null }
    }

    It 'no endpoint builds a store path for itself' {
        # The guard is worth nothing on an endpoint that assembles the path
        # itself, and there are sixteen taking a run id.
        $appDir = Join-Path $script:repoRoot 'src' 'facade' 'app'
        $offenders = @()
        $users = @()
        foreach ($handler in (Get-ChildItem $appDir -Recurse -Filter 'run.ps1')) {
            $source = Get-Content $handler.FullName -Raw
            # PROJECT-2: an endpoint hands the whole REQUEST to
            # Get-VmfFacadeRunStorePath now, which reads the run id from the
            # route and the project from the body or the query - and then
            # passes both through the guard below, exactly as before. So the
            # endpoints that take a run id are the ones that call it.
            if ($source -notmatch '\$Request\.Params\.runId|Get-VmfFacadeRunStorePath -Request') { continue }
            $users += $handler.Directory.Name
            if ($source -match 'azblob://') { $offenders += $handler.Directory.Name }
        }
        $users.Count | Should -BeGreaterThan 10 -Because 'the endpoints do take a run id'
        $offenders | Should -BeNullOrEmpty -Because 'a handwritten store path is outside the guard'
    }

    It 'the ENGINE DISPATCH checks it too, because its run id never reaches the store path builder' {
        <#
            FOUND BY THE TEST ABOVE, in its first form. PostStartEngine takes a
            run id and does not call Get-VmfFacadeStorePath at all on most
            branches: it puts the value in VMF_RUN_ID, and the engine CONTAINER
            builds its own store path from that. A guard on one of the two ways
            in is a guard on neither.
        #>
        $operator = @{ Identity = 'op@contoso.com'; Roles = @('Vmf.Operator') }
        foreach ($case in $script:refused) {
            $err = $null
            try {
                Invoke-VmfFacadeStartEngine -Principal $operator -Operation 'wave' `
                    -RunId $case.value -Wave 'prod-1' -Note 'x'
            }
            catch { $err = "$_" }
            $err | Should -BeLike '400*' -Because "the engine must not be dispatched with $($case.why)"
        }
    }

    It 'and the dispatch still starts for a real run id - the guard did not close the door' {
        # It must fail LATER than the guard, on something else entirely. A test
        # that only proves refusals passes just as well when everything is
        # refused.
        $operator = @{ Identity = 'op@contoso.com'; Roles = @('Vmf.Operator') }
        $err = $null
        try {
            Invoke-VmfFacadeStartEngine -Principal $operator -Operation 'wave' `
                -RunId 'run-2026-09-13-a1b2c3' -Wave 'prod-1' -Note 'starting the wave'
        }
        catch { $err = "$_" }
        $err | Should -Not -BeLike '400*' -Because 'a real run id must get past the guard'
    }
}

Describe 'RUNID-1: a store path cannot rewrite the request that carries it' {

    It 'leaves every path the product actually writes exactly as it was' {
        # The safety property. If this changed a single ordinary path, every
        # document ever written would be addressed by a new name.
        $unchanged = @(
            'run-1/logs/events.jsonl',
            'run-1/logs/events-2.jsonl',
            'project-one/run-1/state/vm-01.json',
            'run-1/approvals/first-five.json',
            'run-1/leases/vm-01.lease',
            'run-1/reports/customer.html',
            'RUN_1.2~3/plan.json'
        )
        foreach ($path in $unchanged) {
            InModuleScope VmMigrationFactory -Parameters @{ p = $path } {
                Get-VmfStoreBlobPath -Path $p
            } | Should -Be $path -Because 'an ordinary path must not move'
        }
    }

    It 'keeps the separators - the path names a document, not one blob with slashes in it' {
        InModuleScope VmMigrationFactory {
            Get-VmfStoreBlobPath -Path 'a/b/c'
        } | Should -Be 'a/b/c'
    }

    It 'escapes the characters that are URI SYNTAX rather than part of a name' {
        # A '?' does not name a blob, it starts a query string; a '#' throws
        # away everything after it. Either one turns a read of one document
        # into a request for something else entirely.
        InModuleScope VmMigrationFactory {
            [pscustomobject]@{
                query    = Get-VmfStoreBlobPath -Path 'run?x/plan.json'
                fragment = Get-VmfStoreBlobPath -Path 'run#x/plan.json'
                space    = Get-VmfStoreBlobPath -Path 'first five/plan.json'
                percent  = Get-VmfStoreBlobPath -Path 'run%2f/plan.json'
            }
        } | ForEach-Object {
            $_.query | Should -Be 'run%3Fx/plan.json'
            $_.fragment | Should -Be 'run%23x/plan.json'
            $_.space | Should -Be 'first%20five/plan.json'
            $_.percent | Should -Be 'run%252f/plan.json'
        }
    }

    It 'so the built URI still addresses the run, whatever the run is called' {
        $uri = InModuleScope VmMigrationFactory {
            $ctx = Get-VmfStoreContext -RunPath 'azblob://acct/runs/run?x'
            Get-VmfStoreBlobUri $ctx 'plan.json'
        }
        # Before this, everything after the '?' was a QUERY STRING - the
        # request asked for a blob called "run" and carried the rest as
        # parameters.
        $uri | Should -Be 'https://acct.blob.core.windows.net/runs/run%3Fx/plan.json'
        ([uri]$uri).Query | Should -BeNullOrEmpty -Because 'nothing in a document name may become a request parameter'
        ([uri]$uri).AbsolutePath | Should -BeLike '*plan.json' -Because 'the document is still the one that was asked for'
    }

    It 'a level up is REFUSED, because escaping does not stop one' {
        <#
            FOUND BY THIS TEST IN ITS FIRST FORM, which expected escaping to
            cover it. A dot is an UNRESERVED character, so escaping leaves '..'
            exactly as it was - and .NET then normalises it away while building
            the request. A read of `<run>/../plan.json` left the run entirely
            and asked for /runs/plan.json.

            So it is refused rather than escaped. Nothing here names a document
            '..', and the facade already refuses one on the way in; this is the
            sink saying so as well.
        #>
        { InModuleScope VmMigrationFactory { Get-VmfStoreBlobPath -Path 'run-1/../plan.json' } } |
            Should -Throw -Because 'a path that had to be corrected to be safe is not a path to answer'
        { InModuleScope VmMigrationFactory { Get-VmfStoreBlobPath -Path '..' } } | Should -Throw
        { InModuleScope VmMigrationFactory { Get-VmfStoreBlobPath -Path '../run-1/plan.json' } } | Should -Throw
    }

    It 'but a name that merely CONTAINS dots is still a name' {
        # run..1 and ..notes are ordinary names. Refusing them would be the
        # guard breaking the product to protect it.
        foreach ($path in @('run..1/plan.json', '..notes/plan.json', 'run-1/..notes.json', 'run-1/a..b.json')) {
            InModuleScope VmMigrationFactory -Parameters @{ p = $path } {
                Get-VmfStoreBlobPath -Path $p
            } | Should -Be $path
        }
    }

    It 'and the whole URI stays inside the run for every path it does accept' {
        $uri = InModuleScope VmMigrationFactory {
            $ctx = Get-VmfStoreContext -RunPath 'azblob://acct/runs/run-1'
            Get-VmfStoreBlobUri $ctx 'logs/events.jsonl'
        }
        ([uri]$uri).AbsolutePath | Should -Be '/runs/run-1/logs/events.jsonl'
    }
}
