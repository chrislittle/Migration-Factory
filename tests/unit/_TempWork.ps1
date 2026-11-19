# TEMP-LITTER-1: a test that makes a temporary folder must take it away again.
#
# MEASURED 2026-09-22: 4,307 `vmf-*` items in one PC's temp folder, oldest
# 24 August, 4.3 MB. 1.8 MB and 3,932 items five days earlier - it grows by
# about seventy-five a day and nothing removes any of them.
#
# The cost is not disk. The cost is that the temp folder stopped being
# readable: when an install failed on a file in there, the first useful
# question was "what else is in this folder", and the answer was four thousand
# things from a fortnight of test runs. TEMP-LOCK-1 was a file in it.
#
# THE RULE THIS PUTS IN ONE PLACE: a test owns what it creates, the removal is
# CHECKED, and a removal that fails SAYS SO. The worst of the three sites found
# by this item already called Remove-Item - and the call was refused every
# time, because that test deliberately builds folders this account may not
# write to, and `-ErrorAction SilentlyContinue` swallowed the refusal. A
# cleanup that reports success it never achieved is the defect this repository
# keeps finding in other places.

$script:VmfTestTempPaths = [System.Collections.Generic.List[string]]::new()

function New-VmfTestTemp {
    <#
    .SYNOPSIS
        A temporary folder for one test file, remembered so it can be removed.
    .DESCRIPTION
        One folder per test FILE, not one per call: fifteen loose json files
        per run is what built two thirds of the pile, and a folder is one thing
        to remove rather than fifteen things to forget.
    .PARAMETER Prefix
        A short name for the test that owns it, so a leak names its owner.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Prefix)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) (
        'vmf-{0}-{1}' -f $Prefix, [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:VmfTestTempPaths.Add($path)
    $path
}

function Remove-VmfTestTemp {
    <#
    .SYNOPSIS
        Take away everything New-VmfTestTemp made, and THROW if anything stays.
    .DESCRIPTION
        Called from AfterAll. A throw there fails the container, which is what
        turns a silent leak into something somebody has to look at.

        Permissions are put back first. A test may build a folder that denies
        this very account - that is the point of one of them - and the account
        that made it owns it, so it may always change the permission back.
    #>
    [CmdletBinding()]
    param()

    $left = @()
    foreach ($path in @($script:VmfTestTempPaths)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Reset-VmfTestTempAcl -Path $path
        try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
        catch { $left += "$path ($($_.Exception.Message))" }
        if (Test-Path -LiteralPath $path) { $left += "$path (still there after the removal reported no error)" }
    }
    $script:VmfTestTempPaths.Clear()
    if ($left.Count -gt 0) {
        throw ("TEMP-LITTER-1: these temporary folders were left behind - " + ($left -join '; '))
    }
}

function Reset-VmfTestTempAcl {
    <#
    .SYNOPSIS
        Give this account write permission back on a folder tree, so it can be
        removed. Windows only; does nothing anywhere else.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($null -ne $IsWindows -and -not $IsWindows) { return }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User

    # TOP DOWN, one level at a time. A folder that denies this account cannot
    # be ENUMERATED either, so collecting the whole tree first and then fixing
    # it reaches none of the folders that need fixing. Each one is opened up,
    # and only then are its children asked for.
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Path)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        try {
            $dir = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            # Never follow a junction or a link: this test makes both, and
            # their targets are somebody else's folders as far as this knows.
            if ($dir.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { continue }

            # ACCESS ONLY. Get-Acl also fetches the audit list, and writing
            # that back needs SeSecurityPrivilege, which this account does not
            # hold - so the whole reset failed with a message about auditing
            # on a call that was only ever about permissions.
            $access = [System.Security.AccessControl.AccessControlSections]::Access
            $sec = [System.IO.FileSystemAclExtensions]::GetAccessControl($dir, $access)
            $sec.SetAccessRuleProtection($false, $false)
            $sec.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            [System.IO.FileSystemAclExtensions]::SetAccessControl($dir, $sec)
        }
        catch {
            # Already gone, or something this account cannot open at all. The
            # removal says whether it mattered; guessing here would hide that.
        }
        # FILES TOO. The first version of this walked folders only, and the
        # check caught it by name: a protected FILE inside an opened-up folder
        # still cannot be deleted. That test protects the script it installs,
        # which is the entire point of it.
        foreach ($file in @(Get-ChildItem -LiteralPath $current -Force -File -ErrorAction SilentlyContinue)) {
            try {
                if ($file.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { continue }
                $fileSec = [System.IO.FileSystemAclExtensions]::GetAccessControl(
                    $file, [System.Security.AccessControl.AccessControlSections]::Access)
                $fileSec.SetAccessRuleProtection($false, $false)
                $fileSec.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                    $me, 'FullControl', 'Allow'))
                [System.IO.FileSystemAclExtensions]::SetAccessControl($file, $fileSec)
            }
            catch { }
        }

        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -Directory -ErrorAction SilentlyContinue)) {
            $queue.Enqueue($child.FullName)
        }
    }
}
