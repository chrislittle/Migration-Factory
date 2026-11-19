# SQL-TEMPDB-SIGNOFF-1 (2026-11-16): a SQL Server machine whose
# move can stop SQL Server from starting, because tempdb may be on the
# temporary disk.
#
# Microsoft, "Fix SQL Server on Azure VM deployment and startup failures"
# (learn.microsoft.com, 2026-09-17): on a size with a raw NVMe local disk, SQL
# Server fails to come online when tempdb is on that disk. A size with no
# temporary disk has no D: at all. The lab saw it: SQL Server failed to create
# tempdb on every start after E2ds_v5 to E2ds_v6, and the move said Migrated.
#
# The product cannot solve every problem inside an operating system - so no
# check inside the machine, no new Azure read and no new permission. The
# product uses only what it already knows: the scan's SQL Server finding, and
# the temporary disk of the size now and of the target. The plan sign-off
# names each such machine and asks the approver to confirm that they checked
# where tempdb is. "make sure its ONLY if we detect SQL": a machine with no
# SQL Server finding gets nothing.
#
# The page asks the same rule (help.js sqlTempdbRisk); SqlTempdbSignoff tests
# hold the two to one table of cases.

# The scan's code for "SQL Server runs on this machine" (Rules.ps1): the SQL IaaS
# Agent record of the machine, or a SQL Server image. A member of an Always On
# availability group is blocked instead, and never moves.
$script:VmfSqlServerFinding = 'sql-server-agree-downtime'

function Test-VmfSqlServerFound {
    <#
    .SYNOPSIS
        $true when the scan found SQL Server on the machine (its warning
        sql-server-agree-downtime). Reads the scan record only.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Vm)
    if (-not $Vm -or -not $Vm.PSObject.Properties['warnings']) { return $false }
    [bool](@($Vm.warnings) -ccontains $script:VmfSqlServerFinding)
}

function Test-VmfSqlTempdbRisk {
    <#
    .SYNOPSIS
        $true for a plan entry that moves (path A), where the scan found SQL
        Server (assessment.sqlServerDetected, a stored true only), from a SCSI
        temporary disk (assessment.sourceDiskArch scsi-temp) to an NVMe
        temporary disk or to none (target.diskArch nvme-temp or diskless,
        Get-VmfDiskArchitecture).
    .DESCRIPTION
        A machine with no SCSI temporary disk now has no D: that starts with
        tempdb's folder, so the move does not change it. A target with a SCSI
        temporary disk (a v5 d size) keeps the disk as it is.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Entry)
    if (-not $Entry) { return $false }
    if ([string]$Entry.path -cne 'A') { return $false }
    $a = $Entry.assessment
    if (-not $a -or -not $a.PSObject.Properties['sqlServerDetected'] -or $a.sqlServerDetected -isnot [bool] -or -not $a.sqlServerDetected) { return $false }
    if ([string]$a.sourceDiskArch -cne 'scsi-temp') { return $false }
    if (-not $Entry.target) { return $false }
    [string]$Entry.target.diskArch -cin @('nvme-temp', 'diskless')
}

function Get-VmfSqlTempdbRiskEntries {
    <#
    .SYNOPSIS
        The entries of a plan (or of one wave) for which Test-VmfSqlTempdbRisk
        is true, in plan order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Entries,
        [Parameter()][string]$Wave
    )
    @(@($Entries) | Where-Object { $_ -and (-not $Wave -or [string]$_.wave -ceq $Wave) -and (Test-VmfSqlTempdbRisk -Entry $_) })
}

function Get-VmfSqlTempdbMissing {
    <#
    .SYNOPSIS
        The entries at risk that the list of checked machine ids does not name.
        A machine id is compared without case, as Azure compares it.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$AtRisk,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$Checked
    )
    $named = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in @($Checked)) { if ($c) { [void]$named.Add([string]$c) } }
    @(@($AtRisk) | Where-Object { $_ -and -not $named.Contains([string]$_.vmId) })
}

function Get-VmfSqlTempdbNames {
    <#
    .SYNOPSIS
        The machine names of the entries, joined with a comma, for a message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Entries)
    (@(@($Entries) | Where-Object { $_ } | ForEach-Object { Get-VmfMachineName -VmId ([string]$_.vmId) }) -join ', ')
}
