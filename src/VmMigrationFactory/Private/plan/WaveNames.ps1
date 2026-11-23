function Find-VmfWaveNameClash {
    <#
    .SYNOPSIS
        WAVE-CASE-1: the first wave name of a layout that the engine cannot
        tell apart from another wave name, or nothing.
    .DESCRIPTION
        The engine compares wave names without letter case: Start-VmfWave
        picks a wave's machines with -eq, and Group-Object, -in and the plan
        run do the same. Blob names keep letter case, so approvals/Wave1.json
        and approvals/wave1.json are two files on blob storage and one file on
        the file store. So a layout may not hold:
          * same   - two waves with one name;
          * case   - two waves whose names differ only in letter case;
          * stored - a wave whose name differs only in letter case from a wave
                     name of the stored plan. -ne keeps the stored name on
                     every machine of such a rename, so the save would say it
                     changed a name it did not change.
        'unscheduled' means no wave and is not a wave name here; the reserved
        names are refused before this is asked.
        The wave editor asks the same rule (findWaveNameClash in waves.js),
        and one fixture holds both: tests/fixtures/wave-name-clash.json.
    .OUTPUTS
        $null, or [pscustomobject]@{ Name; Other; Kind }.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Names = @(),
        [Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$StoredNames = @()
    )
    $isWave = { param($n) -not [string]::IsNullOrEmpty([string]$n) -and [string]$n -cne 'unscheduled' }
    $stored = @(@($StoredNames) | Where-Object { & $isWave $_ } | ForEach-Object { [string]$_ })
    $seen = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in @($Names)) {
        if (-not (& $isWave $raw)) { continue }
        $name = [string]$raw
        if ($seen.ContainsKey($name)) {
            $other = $seen[$name]
            $kind = if ($other -ceq $name) { 'same' } else { 'case' }
            return [pscustomobject]@{ Name = $name; Other = $other; Kind = $kind }
        }
        $seen[$name] = $name
        if ($stored -cnotcontains $name) {
            $storedOther = @($stored | Where-Object { $_ -eq $name }) | Select-Object -First 1
            if ($storedOther) { return [pscustomobject]@{ Name = $name; Other = $storedOther; Kind = 'stored' } }
        }
    }
    return $null
}

function Get-VmfWaveNameClashRefusal {
    <#
    .SYNOPSIS
        WAVE-CASE-1: the words of the refusal for a clash Find-VmfWaveNameClash
        found.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Clash)
    switch ([string]$Clash.Kind) {
        'same' { "Two waves have the name '$($Clash.Name)'. Give each wave a different name." }
        'case' { "Wave names '$($Clash.Other)' and '$($Clash.Name)' are different only in letter case. The engine reads them as one wave. Give each wave a different name." }
        default { "Wave name '$($Clash.Name)' is different from the saved wave '$($Clash.Other)' only in letter case. The product cannot change only the letter case of a wave name. Use a different name." }
    }
}
