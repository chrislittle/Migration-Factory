# SCALE-UX-1: what the workers weigh, measured where they run.
#
# The engine container is sized from "how many machines at once" by a table
# whose per-worker budget (300 MB) rested on a LOCAL, IDLE measurement
# (187 MB). This is the instrument that replaces that assumption with a
# number from the real container under real load: the orchestrator samples
# its worker processes every pass of its loop and writes what it saw into the
# run's activity log, so a support bundle carries it and a drill can read it.
#
# Pure where it can be: the sampler takes process-shaped objects and reads
# WorkingSet64, so a unit test can hand it fakes. The container total comes
# from the cgroup when there is one - v2 first, v1 second, and honestly
# nothing on a machine that has neither (a Windows desktop running a drill).

function Get-VmfWorkerMemorySample {
    <#
    .SYNOPSIS
        One reading of the live workers' memory, and the container's total.
    .OUTPUTS
        alive, minMB, avgMB, maxMB, containerMB (or null), cgroup ('v2'|'v1'|null)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Workers,
        # Where the cgroup files live; a parameter so a test can point at a
        # temporary directory instead of a real kernel interface.
        [Parameter()][string]$CgroupRoot = '/sys/fs/cgroup'
    )

    $sizes = foreach ($w in @($Workers)) {
        if ($null -eq $w) { continue }
        if ($w.PSObject.Properties['HasExited'] -and $w.HasExited) { continue }
        try { if ($w.PSObject.Methods['Refresh']) { $w.Refresh() } } catch { Write-Verbose "a worker could not be refreshed (it is probably gone): $($_.Exception.Message)" }
        $bytes = $w.PSObject.Properties['WorkingSet64'] ? $w.WorkingSet64 : $null
        if ($null -ne $bytes -and $bytes -gt 0) { [double]$bytes / 1MB }
    }
    $sizes = @($sizes)

    $containerMB = $null
    $cgroup = $null
    foreach ($try in @(@{ v = 'v2'; f = 'memory.current' }, @{ v = 'v1'; f = 'memory/memory.usage_in_bytes' })) {
        $f = Join-Path $CgroupRoot $try.f
        if (Test-Path -LiteralPath $f) {
            try {
                $raw = (Get-Content -LiteralPath $f -Raw -ErrorAction Stop).Trim()
                if ($raw -match '^\d+$') { $containerMB = [math]::Round([double]$raw / 1MB); $cgroup = $try.v; break }
            } catch { Write-Verbose "the cgroup file could not be read: $($_.Exception.Message)" }
        }
    }

    [pscustomobject]@{
        alive       = $sizes.Count
        minMB       = $(if ($sizes.Count) { [math]::Round(($sizes | Measure-Object -Minimum).Minimum) } else { 0 })
        avgMB       = $(if ($sizes.Count) { [math]::Round(($sizes | Measure-Object -Average).Average) } else { 0 })
        maxMB       = $(if ($sizes.Count) { [math]::Round(($sizes | Measure-Object -Maximum).Maximum) } else { 0 })
        containerMB = $containerMB
        cgroup      = $cgroup
    }
}

function Update-VmfMemoryPeak {
    <#
    .SYNOPSIS
        Fold one sample into the running peak - the number the sizing table needs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][hashtable]$Peak,
        [Parameter(Mandatory)]$Sample
    )
    if (-not $Peak) { $Peak = @{ workerMB = 0; containerMB = 0; workersAtPeak = 0; samples = 0 } }
    $Peak.samples++
    if ($Sample.maxMB -gt $Peak.workerMB) { $Peak.workerMB = $Sample.maxMB; $Peak.workersAtPeak = $Sample.alive }
    if ($null -ne $Sample.containerMB -and $Sample.containerMB -gt $Peak.containerMB) { $Peak.containerMB = $Sample.containerMB }
    $Peak
}
