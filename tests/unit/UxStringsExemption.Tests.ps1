#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STRING-SWEEP-2: the "enumerated whole" exemption must mean the OBJECT.
#
# Test-UxStrings has two rules. The second says every declared string is read
# somewhere, and it sensibly gives up on an object that is read WITHOUT naming
# a key - `UX[someVariable]`, `Object.keys(UX)`, `...UX`, or UX handed to a
# function whole - because then it genuinely cannot tell what is used.
#
# The enumeration test ended at a word boundary, so `Object.keys(UX.roleWords)`
# matched it. That line NAMES A KEY. It says nothing about the other forty
# strings in the object, and it excused the whole of access.html from
# dead-string detection from the day the gate was written - while the gate's
# own summary line kept saying "nothing is declared unread".
#
# Tightening it surfaced ZERO real findings, measured before the change: the
# page was clean, it had simply never been looked at. That is the good outcome
# and it is also the reason this test exists - with nothing to fail on in the
# product, only a fixture can prove the rule still works.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'Test-UxStrings.ps1'

    # A page the way the gate expects one: `const UX = {` at the start of a
    # line, a key that is read, and a key that is not.
    function Global:NewFixturePage {
        param([string]$Folder, [string]$Name, [string]$Usage)
        $html = @"
<!doctype html><html><body>
<script>
const UX = {
  group:  'a group of things',
  used:   'this one is rendered',
  dead:   'nothing renders this',
};
function render() {
  document.title = UX.used;
  return $Usage;
}
</script>
</body></html>
"@
        Set-Content -LiteralPath (Join-Path $Folder $Name) -Value $html -Encoding utf8NoBOM
    }
}
AfterAll { Remove-Item 'function:\NewFixturePage' -ErrorAction SilentlyContinue }

Describe 'STRING-SWEEP-2: enumerating a KEY does not excuse the whole object' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ux-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
    }
    AfterEach { if (Test-Path $script:dir) { Remove-Item $script:dir -Recurse -Force } }

    It 'Object.keys(UX.group) still leaves the rest of the object checked' {
        # THE DEFECT. This line reaches THROUGH the object to one key, so it
        # tells us nothing about `dead`, which nothing renders.
        NewFixturePage -Folder $script:dir -Name 'page.html' -Usage 'Object.keys(UX.group)'
        $r = & $script:tool -DashboardPath $script:dir
        $unused = @($r.Findings | Where-Object { $_.Rule -eq 'unused-string' })
        @($unused | Where-Object { $_.Detail -match 'UX\.dead' }).Count |
            Should -Be 1 -Because 'naming one key says nothing about the others'
    }

    It 'Object.keys(UX) DOES excuse the whole object, because it reads every key' {
        # The legitimate case the exemption exists for: enumeration really does
        # use every key, so reporting any of them dead would be crying wolf -
        # which this gate was rewritten once to stop doing.
        NewFixturePage -Folder $script:dir -Name 'page.html' -Usage 'Object.keys(UX)'
        $r = & $script:tool -DashboardPath $script:dir
        @($r.Findings | Where-Object { $_.Rule -eq 'unused-string' }).Count |
            Should -Be 0 -Because 'enumerating the object really does read every key'
    }

    It 'and the other three exemptions still hold' {
        foreach ($usage in @('UX[pick]', 'Object.values(UX)', 'Object.entries(UX)')) {
            NewFixturePage -Folder $script:dir -Name 'page.html' -Usage $usage
            $r = & $script:tool -DashboardPath $script:dir
            @($r.Findings | Where-Object { $_.Rule -eq 'unused-string' }).Count |
                Should -Be 0 -Because "$usage reads the object without naming a key"
        }
    }

    It 'a dead string with no enumeration at all is still reported' {
        # The control: without this the two tests above could both pass on a
        # rule that reports nothing, ever.
        NewFixturePage -Folder $script:dir -Name 'page.html' -Usage 'UX.group'
        $r = & $script:tool -DashboardPath $script:dir
        @($r.Findings | Where-Object { $_.Detail -match 'UX\.dead' }).Count | Should -Be 1
    }

    It 'the real dashboard is clean under the tightened rule' {
        # Measured before the change was made: tightening it surfaces nothing.
        # If this ever fails, a page has gained a string nothing renders - which
        # is the whole point of turning the rule back on.
        $r = & $script:tool -DashboardPath (Join-Path $script:repoRoot 'src' 'dashboard')
        @($r.Findings | Where-Object { $_.Rule -eq 'unused-string' }).Count | Should -Be 0
    }
}
