# RESTORE-COPY-1: the safety copy an operator chooses reaches the engine.
#
# A migration takes TWO copies:
#
#   pristine  before anything was touched. It predates the guest preparation
#             that lets the machine boot on the new hardware, so restoring it
#             ALSO returns the size and disk controller to what they were. It is
#             the real way back.
#   prepared  taken when the machine was stopped and ready to move. The guest is
#             already converted, so the machine stays on the new hardware.
#
# THE DEFECT, found on a live install after the first real migration.
# Restore-VmfVm has always taken either, through -From. NOTHING BETWEEN THE APP
# AND THE JOB CARRIED THE CHOICE:
#
#   * the dashboard never sent one,
#   * FacadeCore's restore dispatch set VMF_VM_ID, VMF_RESTORED_BY, VMF_NOTE,
#     VMF_DISK_NAMING and VMF_ACCEPT_PRESERVE_RISK - and no disk source,
#   * so the entrypoint never passed -From and every restore from the app used
#     the default, 'prepared'.
#
# The pristine copy could not be asked for from the product at all, while the
# dialog said the button would put the machine back to the point before it was
# migrated - which is the OTHER copy. The words promised one thing and the
# button did another.
#
# THIS IS THE SECOND TIME THIS EXACT PATH HAS LOST A FIELD between the caller
# and the job. EVAL-H6 is the first, in PostStartEngine, on the same operation,
# and its own comment says the way it hid was that the state document then
# recorded the DEFAULTS as what the operator chose. A field dropped in the
# middle does not fail; it silently answers a question nobody asked.
#
# So this checks the WHOLE CHAIN, layer by layer, rather than any one link.
# COMMENT-TRAP-1: every read below is Get-VmfCodeOnly output.

. (Join-Path $PSScriptRoot '_CodeOnly.ps1')

$script:vmfRoot = Join-Path $PSScriptRoot '..' '..'
$script:vmfCore = Get-VmfCodeOnly -Path (
    Join-Path $script:vmfRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
$script:vmfEntry = Get-VmfCodeOnly -Path (
    Join-Path $script:vmfRoot 'docker' 'entrypoint.ps1')
$script:vmfHttp = Get-VmfCodeOnly -Path (
    Join-Path $script:vmfRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1')
$script:vmfPage = Get-VmfCodeOnly -Path (
    Join-Path $script:vmfRoot 'src' 'dashboard' 'migrations.html')
$script:vmfRestore = Get-VmfCodeOnly -Path (
    Join-Path $script:vmfRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1')

# The restore branch of the engine DISPATCH, on its own.
#
# Two things make this fiddly, and both were got wrong first time:
#   * the file also builds a REBUILD, which has always passed a disk source, so
#     a whole-file search finds that one and reports the chain intact while the
#     restore drops it;
#   * there are TWO blocks opening `if ($Operation -eq 'restore') {` - the
#     VALIDATION near the top and the dispatch further down. The first match is
#     the validation, and a check anchored there passes on a chain that is still
#     broken.
# So: every such block, and the one that builds the job is the one naming the
# machine.
$script:vmfRestoreDispatch = $(
    # No regex. Two attempts at one failed for different reasons - the first
    # matched the VALIDATION block, which opens identically and sits above the
    # dispatch, and the second matched nothing at all. A check anchored on the
    # validation passes while the chain is still broken, which is the exact
    # failure this file exists to stop.
    #
    # The dispatch is simply the LAST block opening this way, and it runs to the
    # next closing brace at its own indentation.
    $marker = "if (`$Operation -eq 'restore') {"
    $at = $script:vmfCore.LastIndexOf($marker)
    $to = $script:vmfCore.IndexOf("`n    }", $at)
    if ($at -lt 0 -or $to -lt 0) { '' } else { $script:vmfCore.Substring($at, $to - $at) }
)

BeforeAll {
    # TEST-AZURE-GUARD-2: the facade module calls Azure itself. It is imported
    # once, here, and guarded after - an import after the guard has no guard.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'RESTORE-COPY-1: the chosen safety copy reaches the engine' -ForEach @(
    @{ Core = $script:vmfCore; Entry = $script:vmfEntry; Http = $script:vmfHttp
       Page = $script:vmfPage; Restore = $script:vmfRestore
       Dispatch = $script:vmfRestoreDispatch; Repo = $script:vmfRoot }
) {

    It 'every file was read, so nothing below can pass on an empty string' {
        foreach ($text in @($Core, $Entry, $Http, $Page, $Restore)) {
            $text.Length | Should -BeGreaterThan 500
        }
        # THE VACUITY GUARD THAT MATTERS: the restore dispatch is isolated from
        # the rebuild one, and a miss would make every check below read ''.
        $Dispatch.Length | Should -BeGreaterThan 100 `
            -Because 'the restore branch of the engine dispatch was found'
        $Dispatch | Should -Not -Match 'rebuild' -Because 'and it is not the rebuild branch'
    }

    It 'the engine can still read either copy - the capability was never missing' {
        $Restore | Should -Match "ValidateSet\('prepared', 'pristine'\)"
        $Restore | Should -Match '\$From'
    }

    It 'LINK 1: the page offers the choice and sends it' {
        $Page | Should -Match 'function restoreCopyField'
        $Page | Should -Match 'diskSource: v\.diskSource' `
            -Because 'the answer travels in the request body'
        $Page | Should -Match 'pristineSnapshotId' `
            -Because 'and it is only offered when there are two copies to choose from'
    }

    It 'LINK 2: the HTTP endpoint forwards it' {
        $Http | Should -Match '\$body\.diskSource' `
            -Because 'EVAL-H6 was two declared-and-dropped fields on this same path'
    }

    It 'LINK 3: the engine dispatch passes it to the job' {
        # THE BROKEN LINK. Everything either side of it was already in place.
        $Dispatch | Should -Match 'VMF_DISK_SOURCE' `
            -Because 'the restore dispatch must hand the choice to the container'
    }

    It 'LINK 4: the entrypoint gives it to the command' {
        $restoreBranch = [regex]::Match($Entry, "(?s)'restore' \{.*?Restore-VmfVm").Value
        $restoreBranch.Length | Should -BeGreaterThan 100
        $restoreBranch | Should -Match 'VMF_DISK_SOURCE'
        $restoreBranch | Should -Match '\.From = ' `
            -Because 'and it arrives as the parameter the command declares'
    }

    # REBUILD-REMOVE-RECOVER-1: 'disks' was the rebuild's source. The rebuild
    # is gone, so the parameter takes the two copies only, and the guard is
    # the parameter itself.
    It 'a restore is REFUSED a copy name that is not one of the two copies' {
        # DRIVEN, not read. The first version of this matched the refusal's
        # SENTENCE in the source - and the sentence is still there when the
        # guard around it is disabled, so the check survived its own mutation.
        # The validation runs before anything reaches Azure, so it can simply be
        # called: 'disks' is a rebuild source and means nothing to a restore.
        $caller = [pscustomobject]@{ Identity = 'tester'; Roles = @('Vmf.Operator') }
        { Invoke-VmfFacadeStartEngine -Principal $caller -Operation restore -RunId r1 `
            -VmId '/s/vm1' -Note 'n' -DiskSource 'disks' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*does not belong to the set*pristine,prepared*'
    }

    It 'and both real copy names get PAST that guard' {
        # The other half. A guard that refuses everything would pass the check
        # above and break the feature. These two fall through to the missing
        # engine configuration, which is proof they were accepted.
        $caller = [pscustomobject]@{ Identity = 'tester'; Roles = @('Vmf.Operator') }
        foreach ($copy in @('prepared', 'pristine')) {
            $failed = $null
            try {
                Invoke-VmfFacadeStartEngine -Principal $caller -Operation restore -RunId r1 `
                    -VmId '/s/vm1' -Note 'n' -DiskSource $copy -ErrorAction Stop | Out-Null
            } catch { $failed = $_.Exception.Message }
            # It gets past the guard and stops at the engine configuration,
            # which is absent here on purpose - there is no Azure in a unit test.
            # What matters is WHICH refusal it is.
            $failed | Should -Not -BeLike '*two safety copies*' -Because "$copy is a safety copy"
            $failed | Should -BeLike '*VMF_ENGINE_JOB_ID*' `
                -Because 'it got as far as wanting the engine job, so the value was accepted'
        }
    }

    It 'the wording tells the two copies apart by what they DO' {
        # The defect was not only the missing plumbing. The dialog described the
        # pristine copy while the button used the prepared one, so an operator
        # asking to put a machine back as it was got something else.
        # RESTORE-LABELS-1: the product's word is the disk controller, and the
        # prepared copy keeps the CURRENT hardware - a rolled-back machine is
        # not on new hardware.
        $Page | Should -Match 'original size and disk controller' `
            -Because 'the pristine option says it reverts the hardware'
        $Page | Should -Match 'current size and disk controller' `
            -Because 'and the prepared option says it does not'
    }
}