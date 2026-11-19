#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# IMAGE-SCRIPT-MATCH-1 (2026-11-14): the support list admitted whole
# publishers (IMAGE-1), so the scan said "can migrate" for openSUSE Leap
# (publisher SUSE), CBL-Mariner and Azure Linux 3 (publisher
# MicrosoftCBLMariner). nvme-fix.sh has distribution branches only for
# ubuntu|debian and rhel|centos|rocky|almalinux|sles|suse|ol|fedora, and
# reports FAIL "unsupported distro" for any other - in Preparing, after the
# safety copies. Decided 2026-11-14: refuse the three for 1.0, and a check
# that does not catch this is a defect.
#
# THE CLASS: an image the list admits must run a distribution that EACH guest
# script that switches on the distribution has a branch for. The images and
# their os-release IDs are data with sources (tests/fixtures/image-distro-ids.json).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:matrixPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'supported-images.json'
    $script:matrix = Get-Content $script:matrixPath -Raw | ConvertFrom-Json
    $script:distroMap = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'image-distro-ids.json') -Raw | ConvertFrom-Json
    $script:guestDir = Join-Path $script:repoRoot 'src' 'guest' 'linux'

    # Every `case "$X" in` of a guest script where X holds the os-release ID
    # (X = ID, or a variable assigned from $ID or ${ID:-...}). Each result:
    # the script, the line, the explicit patterns of its arms, and whether an
    # ID with no arm of its own is a failure there (no *) arm, or a *) arm that
    # reports FAIL, BLOCKED or unsupported). Comments are removed first.
    function Global:Get-IsmDistroCases {
        param([string]$Path, [string]$Code)
        $text = if ($Code) { $Code } else { Get-VmfCodeOnly -Path $Path }
        $vars = @('ID') + @([regex]::Matches($text, '\b([A-Za-z_][A-Za-z0-9_]*)="\$(\{ID(:-[^}]*)?\}|ID)"') | ForEach-Object { $_.Groups[1].Value })
        $lines = $text -split "`r?`n"
        $found = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], '\bcase\s+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?\s+in\b')
            if (-not $m.Success -or $vars -notcontains $m.Groups[1].Value) { continue }
            $depth = 1; $explicit = [System.Collections.Generic.List[string]]::new(); $star = $null; $inStar = $false
            for ($j = $i + 1; $j -lt $lines.Count -and $depth -gt 0; $j++) {
                $line = $lines[$j]
                if ($depth -eq 1) {
                    $arm = [regex]::Match($line, '^\s*\(?\s*([A-Za-z0-9_.*|"''-]+)\s*\)')
                    if ($arm.Success -and $line -notmatch '\bcase\b') {
                        $pats = @($arm.Groups[1].Value -split '\|' | ForEach-Object { $_.Trim('"', "'") })
                        if ($pats -contains '*') { $inStar = $true; $star = '' } else { $inStar = $false; $pats | ForEach-Object { $explicit.Add($_) } }
                    }
                }
                if ($inStar) { $star += "$line`n" }
                $depth += ([regex]::Matches($line, '(^|[\s;(])case\s')).Count
                $depth -= ([regex]::Matches($line, '(^|[\s;])esac\b')).Count
            }
            $required = ($null -eq $star) -or ($star -match '(?i)FAIL|BLOCKED|unsupported')
            $found.Add([pscustomobject]@{ Script = (Split-Path $Path -Leaf); Line = $i + 1; Explicit = @($explicit); Required = $required })
        }
        @($found)
    }

    function Global:Get-IsmAllDistroCases {
        @(Get-ChildItem $script:guestDir -Filter '*.sh' | ForEach-Object { Get-IsmDistroCases -Path $_.FullName })
    }

    # The scan admits an image when the support list does and it is not an SAP
    # image (Test-VmfSapImage refuses those on its own, SAP-1).
    function Global:Test-IsmAdmitted {
        param([string]$Publisher, [string]$Offer, $Matrix)
        InModuleScope VmMigrationFactory -Parameters @{ pub = $Publisher; off = $Offer; mx = $Matrix } {
            param($pub, $off, $mx)
            $support = if ($mx) { Get-VmfImageSupport -Publisher $pub -Offer $off -Sku 'x' -Matrix $mx } else { Get-VmfImageSupport -Publisher $pub -Offer $off -Sku 'x' }
            [bool]($support.Supported -and -not (Test-VmfSapImage -Publisher $pub -Offer $off).IsSap)
        }
    }

    function Global:Get-IsmMissingBranches {
        param([string]$Id, $Cases)
        @($Cases | Where-Object { $_.Required } | Where-Object { $c = $_; -not @($c.Explicit | Where-Object { $Id -like $_ }).Count } |
            ForEach-Object { "$($_.Script) line $($_.Line)" })
    }
}

BeforeDiscovery {
    $map = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'image-distro-ids.json') -Raw | ConvertFrom-Json
    $imageCases = @($map.images | ForEach-Object { @{ Publisher = $_.publisher; Offer = $_.offer; Id = $_.osReleaseId; Gap = $(if ($_.PSObject.Properties['gap']) { [string]$_.gap } else { '' }) } })
}

AfterAll {
    Remove-Item 'function:\Get-IsmDistroCases', 'function:\Get-IsmAllDistroCases', 'function:\Test-IsmAdmitted', 'function:\Get-IsmMissingBranches' -ErrorAction SilentlyContinue
}

Describe 'IMAGE-SCRIPT-MATCH-1: the entry for an offer wins over the entry for the whole publisher' {
    BeforeAll {
        $script:wide = [pscustomobject]@{ publisher = 'SUSE'; os = 'Linux'; support = 'endorsed' }
        $script:narrow = [pscustomobject]@{ publisher = 'SUSE'; offerPattern = '^opensuse-leap'; os = 'Linux'; support = 'unsupported'; note = 'The product does not move this machine.' }
    }

    It 'the offer entry decides, whichever comes first in the list' {
        foreach ($order in @(@($script:wide, $script:narrow), @($script:narrow, $script:wide))) {
            InModuleScope VmMigrationFactory -Parameters @{ mx = [pscustomobject]@{ publishers = $order } } {
                param($mx)
                $r = Get-VmfImageSupport -Publisher 'SUSE' -Offer 'opensuse-leap-15-5' -Sku 'gen2' -Matrix $mx
                $r.Supported | Should -BeFalse
                $r.Status | Should -Be 'unsupported'
            }
        }
    }

    It 'another offer of the publisher still gets the publisher entry, whichever comes first' {
        foreach ($order in @(@($script:wide, $script:narrow), @($script:narrow, $script:wide))) {
            InModuleScope VmMigrationFactory -Parameters @{ mx = [pscustomobject]@{ publishers = $order } } {
                param($mx)
                $r = Get-VmfImageSupport -Publisher 'SUSE' -Offer 'sles-15-sp5' -Sku 'gen2' -Matrix $mx
                $r.Supported | Should -BeTrue
                $r.Status | Should -Be 'endorsed'
            }
        }
    }
}

Describe 'IMAGE-SCRIPT-MATCH-1: openSUSE Leap, CBL-Mariner and Azure Linux 3 are refused' {
    It '<Publisher>:<Offer> is refused, and the reason says the product does not move it' -ForEach @(
        @{ Publisher = 'SUSE'; Offer = 'opensuse-leap-15-3' }
        @{ Publisher = 'SUSE'; Offer = 'opensuse-leap-15-6' }
        @{ Publisher = 'SUSE'; Offer = 'openSUSE-Leap' }
        @{ Publisher = 'MicrosoftCBLMariner'; Offer = 'cbl-mariner' }
        @{ Publisher = 'MicrosoftCBLMariner'; Offer = 'azure-linux-3' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ pub = $Publisher; off = $Offer } {
            param($pub, $off)
            $r = Get-VmfImageSupport -Publisher $pub -Offer $off -Sku 'gen2'
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'unsupported'
            $r.Reason | Should -Match 'The product does not move this machine\.$'
        }
    }

    It 'an offer of MicrosoftCBLMariner the list does not name is refused as an offer the product does not recognize' {
        InModuleScope VmMigrationFactory {
            (Get-VmfImageSupport -Publisher 'MicrosoftCBLMariner' -Offer 'cbl-mariner-test' -Sku 'x').Status | Should -Be 'unknown-offer'
        }
    }

    It 'SUSE Linux Enterprise Server is still supported' {
        InModuleScope VmMigrationFactory {
            (Get-VmfImageSupport -Publisher 'SUSE' -Offer 'sles-15-sp6' -Sku 'gen2').Status | Should -Be 'endorsed'
        }
    }

    It 'each new entry names its source, the date it was read, and why' {
        foreach ($pattern in '^opensuse-leap', '^cbl-mariner$', '^azure-linux-3$') {
            $e = @($script:matrix.publishers | Where-Object { $_.PSObject.Properties['offerPattern'] -and $_.offerPattern -eq $pattern })
            $e.Count | Should -Be 1 -Because "the list has one entry for $pattern"
            $e[0].support | Should -Be 'unsupported'
            $e[0].name | Should -Not -BeNullOrEmpty
            $e[0].source | Should -Match '^https://'
            $e[0].readUtc | Should -Be '2026-11-14'
            $e[0].why | Should -Match 'IMAGE-SCRIPT-MATCH-1'
        }
    }

    It 'the support matrix names each of them as not supported, and SUSE Linux Enterprise Server as supported' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'support-matrix.md') -Raw
        foreach ($row in @('| openSUSE Leap | SUSE | Not supported |', '| CBL-Mariner | MicrosoftCBLMariner | Not supported |',
                '| Azure Linux 3.0 | MicrosoftCBLMariner | Not supported |', '| SUSE Linux Enterprise Server | SUSE | Supported |')) {
            $page | Should -Match ([regex]::Escape($row))
        }
    }

    It 'the scan blocks an openSUSE Leap machine with image-not-supported' {
        InModuleScope VmMigrationFactory {
            $row = [pscustomobject]@{
                id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-leap'
                name = 'vm'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                imagePublisher = 'SUSE'; imageOffer = 'opensuse-leap-15-5'; imageSku = 'gen2'; imageId = ''
                vmssId = ''; hibernationEnabled = $false; securityType = ''
                dataDiskCount = 0; nicCount = 1; availabilitySetId = ''; tags = $null
            }
            $r = Get-VmfAssessmentRecord -Vm $row
            $r.classification | Should -Be 'Blocked'
            @($r.blockers) | Should -Contain 'image-not-supported'
            $r.imageSupport | Should -Be 'unsupported'
        }
    }
}

Describe 'IMAGE-SCRIPT-MATCH-1: the reader of the guest scripts finds each switch on the distribution' {
    It 'finds the switches of nvme-fix.sh and kernel-update.sh, and each is one an unknown ID fails in' {
        $cases = Get-IsmAllDistroCases
        @($cases | Where-Object { $_.Script -eq 'nvme-fix.sh' -and $_.Required }).Count | Should -BeGreaterOrEqual 1
        @($cases | Where-Object { $_.Script -eq 'kernel-update.sh' -and $_.Required }).Count | Should -BeGreaterOrEqual 1
        $fix = @($cases | Where-Object { $_.Script -eq 'nvme-fix.sh' -and $_.Required })[0]
        $fix.Explicit | Should -Contain 'ubuntu'
        $fix.Explicit | Should -Contain 'rhel'
        $fix.Explicit | Should -Contain 'sles'
    }

    It 'a switch whose default arm works (in_initrd of nvme-fix.sh) needs no arm for each ID' {
        $cases = @(Get-IsmAllDistroCases | Where-Object { $_.Script -eq 'nvme-fix.sh' })
        @($cases | Where-Object { -not $_.Required }).Count | Should -BeGreaterOrEqual 1
    }

    It 'reads a switch on any variable that holds the ID, nested switches and patterns with a star' {
        $code = @(
            'OSID="${ID:-unknown}"'
            'case "$OSID" in'
            '    ubuntu)'
            '        case "$KVER" in'
            '            *-azure) x=1 ;;'
            '            *) NORULE=1 ;;'
            '        esac ;;'
            '    sles*|debian) y=1 ;;'
            'esac'
            'case "$OTHER" in'
            '    foo) z=1 ;;'
            'esac'
        ) -join "`n"
        $cases = @(Get-IsmDistroCases -Path 'x.sh' -Code $code)
        $cases.Count | Should -Be 1
        $cases[0].Required | Should -BeTrue
        @($cases[0].Explicit) | Should -Be @('ubuntu', 'sles*', 'debian')
        @(Get-IsmMissingBranches -Id 'sles_sap' -Cases $cases).Count | Should -Be 0
        @(Get-IsmMissingBranches -Id 'mariner' -Cases $cases).Count | Should -Be 1
    }
}

Describe 'IMAGE-SCRIPT-MATCH-1: the map of images to os-release IDs covers the list' {
    It 'every Linux publisher the list supports has an image in the map' {
        $pubs = @($script:matrix.publishers | Where-Object { $_.os -eq 'Linux' -and [string]$_.support -ne 'unsupported' } | ForEach-Object { [string]$_.publisher } | Sort-Object -Unique)
        $pubs.Count | Should -BeGreaterThan 4
        foreach ($pub in $pubs) {
            @($script:distroMap.images | Where-Object { [string]$_.publisher -eq $pub }).Count | Should -BeGreaterThan 0 -Because "the list supports $pub"
        }
    }

    It 'every entry for an offer has an image in the map that it matches' {
        foreach ($e in @($script:matrix.publishers | Where-Object { $_.PSObject.Properties['offerPattern'] })) {
            @($script:distroMap.images | Where-Object { [string]$_.publisher -ieq [string]$e.publisher -and [string]$_.offer -imatch [string]$e.offerPattern }).Count |
                Should -BeGreaterThan 0 -Because "the entry $($e.publisher) $($e.offerPattern) is exercised by an image"
        }
    }

    It 'every os-release ID in the map names its source' {
        foreach ($img in @($script:distroMap.images | Where-Object { $_.osReleaseId })) {
            [string]$script:distroMap.ids.($img.osReleaseId) | Should -Not -BeNullOrEmpty -Because "$($img.osReleaseId) needs a source"
        }
    }

    # PUBLIC-SYNC-1: the work items do not ship to the public repository.
    It 'every image with no measured ID names an open item that measures it' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'docs' 'backlog'))) {
        foreach ($img in @($script:distroMap.images | Where-Object { -not $_.osReleaseId })) {
            [string]$img.gap | Should -Match '^[A-Z0-9-]+$'
            $file = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'backlog') -Filter "$(([string]$img.gap).ToLowerInvariant())-*.md")
            $file.Count | Should -Be 1 -Because "$($img.gap) has its own item file"
            (Get-Content $file[0].FullName -Raw) | Should -Match '\*\*OPEN\.\*\*'
        }
    }
}

Describe 'IMAGE-SCRIPT-MATCH-1: every image the scan admits runs a distribution each guest script has a branch for' {
    BeforeAll { $script:distroCases = Get-IsmAllDistroCases }

    It '<Publisher>:<Offer> (<Id>)' -ForEach $imageCases {
        if (-not (Test-IsmAdmitted -Publisher $Publisher -Offer $Offer)) { return }
        if ($Gap) { Set-ItResult -Skipped -Because "the scan admits it, and nobody measured its os-release ID: $Gap"; return }
        $missing = @(Get-IsmMissingBranches -Id $Id -Cases $script:distroCases)
        $missing | Should -BeNullOrEmpty -Because "the scan admits $Publisher $Offer, which runs $Id, so each guest script that switches on the distribution needs a branch for it"
    }

    It 'the test fails for an admitted image whose distribution has no branch' {
        $mx = [pscustomobject]@{ publishers = @([pscustomobject]@{ publisher = 'SUSE'; os = 'Linux'; support = 'endorsed' }) }
        Test-IsmAdmitted -Publisher 'SUSE' -Offer 'opensuse-leap-15-5' -Matrix $mx | Should -BeTrue
        @(Get-IsmMissingBranches -Id 'opensuse-leap' -Cases $script:distroCases) | Should -Contain (@($script:distroCases | Where-Object { $_.Script -eq 'nvme-fix.sh' -and $_.Required })[0] | ForEach-Object { "$($_.Script) line $($_.Line)" })
    }
}
