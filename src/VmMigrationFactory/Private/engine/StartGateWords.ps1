# GATE-WORDS-1: the words of the engine's start gates, for the screen.
#
# RETRY-GATE-1 shows a gate's reason in the Try this machine again dialog, and
# the migration's page shows it for the next wave and for a refused wave start.
# The reasons were written for a terminal: they named cmdlets, said "levers",
# and the acknowledgement reason repeated its whole statement. The words now
# live in data/start-gates.json, where tools/Test-SimplifiedEnglish.ps1 checks
# them like every other screen string, and each reason carries a stable code
# beside its sentence - so a caller asks the code, never the words.

function Get-VmfStartGateWords {
    <#
    .SYNOPSIS
        The start gate words (data/start-gates.json), cached per session.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    if (-not $script:VmfStartGateWords) {
        $file = Join-Path $script:VmfModuleRoot 'data' 'start-gates.json'
        $script:VmfStartGateWords = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfStartGateWords
}

function Format-VmfStartGateText {
    <#
    .SYNOPSIS
        Fill a start gate string's {wave}, {machines} and {by} in ONE pass, so a
        wave or user name that happens to contain a placeholder is left as
        written (RESERVE-COVER-1 review: a wave named "{machines}" was filled).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Wave = '', [string]$By = '', [string]$Machines = '')
    $values = @{ wave = $Wave; by = $By; machines = $Machines }
    [regex]::Replace($Text, '\{(wave|by|machines)\}', { param($m) [string]$values[$m.Groups[1].Value] })
}

function New-VmfStartGateRefusal {
    <#
    .SYNOPSIS
        A failed start gate: its code, the gate it belongs to, and the two
        sentences for the screen (what is missing, what to do).
    .OUTPUTS
        @{ Pass = $false; Gate; Code; Detail }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Code,
        [string]$Wave = '',
        [string]$By = '',
        # RESERVE-COVER-1: the capacity gate names machines and their sizes.
        [string]$Machines = ''
    )
    $r = (Get-VmfStartGateWords).reasons.$Code
    # A code with no words is a defect here, not a reason to show nothing.
    if (-not $r) { throw "The start gate gave the code '$Code', and data/start-gates.json has no words for it." }
    @{
        Pass   = $false
        Gate   = [string]$r.gate
        Code   = $Code
        Detail = Format-VmfStartGateText -Text "$($r.missing) $($r.toDo)" -Wave $Wave -By $By -Machines $Machines
    }
}

function Get-VmfStartGateLine {
    <#
    .SYNOPSIS
        The line that leads a gate's reason where it is shown: waveWaits, the
        next wave of a signed-off plan. A refused wave start has no lead line,
        because the page shows only the first sentence of a failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('waveWaits')][string]$Name, [Parameter(Mandatory)][string]$Wave)
    Format-VmfStartGateText -Text ([string](Get-VmfStartGateWords).lines.$Name) -Wave $Wave
}
