#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STORE-LOGS-1, STORE-LOGS-NSP-1, STORE-LOGS-WORKSPACE-PERIMETER-1: the run
# store keeps no request log in 1.0, and the workspace is outside its perimeter.
#
# MEASURED in the lab, 2026-11-03. A diagnostic setting on the store's blob
# service sent NO row in 21 hours while the store served more than 180,000
# requests, because the store sits in an Enforced perimeter and the workspace
# did not. Microsoft: a PaaS resource's logs go to a destination "associated to
# the same perimeter as the PaaS resource". With the workspace associated, the
# first row arrived 9 minutes later.
#
# MEASURED in the lab, 2026-11-06. With the workspace in the perimeter, the
# perimeter refused the service's Application Insights data even when the
# service signed it with its managed identity. So the Log Analytics workspace
# came out of the perimeter, and the run store request log was dropped for
# 1.0: a setting to a workspace outside the perimeter sends nothing. After 1.0 it goes to a small
# log storage account inside the perimeter (STORE-LOGS-REQUEST-LOG-2).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:platformPath = Join-Path $script:repoRoot 'infra' 'platform.bicep'
    $script:platform = Get-VmfCodeOnly -Path $script:platformPath -Language CStyle

    function Script:Get-VmfBicepBlock {
        param([string]$Text, [string]$Header)
        $at = $Text.IndexOf($Header)
        if ($at -lt 0) { return '' }
        $open = $Text.IndexOf('{', $at)
        $depth = 0
        for ($i = $open; $i -lt $Text.Length; $i++) {
            if ($Text[$i] -eq '{') { $depth++ }
            elseif ($Text[$i] -eq '}') { $depth--; if ($depth -eq 0) { return $Text.Substring($at, $i - $at + 1) } }
        }
        ''
    }
    # The first block in $Text that opens with $Header, from the header to its
    # closing bracket, whichever bracket it opens with.
    function Script:Get-VmfBicepList {
        param([string]$Text, [string]$Header)
        $at = $Text.IndexOf($Header)
        if ($at -lt 0) { return '' }
        $open = $Text.IndexOfAny([char[]]@('[', '{'), $at + $Header.Length)
        $opener = $Text[$open]; $closer = if ($opener -eq '[') { ']' } else { '}' }
        $depth = 0
        for ($i = $open; $i -lt $Text.Length; $i++) {
            if ($Text[$i] -eq $opener) { $depth++ }
            elseif ($Text[$i] -eq $closer) { $depth--; if ($depth -eq 0) { return $Text.Substring($at, $i - $at + 1) } }
        }
        ''
    }
    $script:store = Get-VmfBicepBlock -Text $script:platform -Header 'module store '
    $script:blobServices = Get-VmfBicepList -Text $script:store -Header 'blobServices:'
    $script:storeDiag = Get-VmfBicepList -Text $script:blobServices -Header 'diagnosticSettings:'
    $script:perimeter = Get-VmfBicepBlock -Text $script:platform -Header 'module perimeter '
    $script:associations = Get-VmfBicepList -Text $script:perimeter -Header 'resourceAssociations:'
}

Describe 'STORE-LOGS-REQUEST-LOG-2: the run store keeps no request log in 1.0' {

    It 'found the store and its blob service, or this proves nothing' {
        $script:store | Should -Match "^module store 'br/public:avm/res/storage/storage-account:"
        $script:blobServices | Should -Match '^blobServices:'
    }

    It 'gives the store no diagnostic setting, on the account or its blob service' {
        # A setting to the workspace sends nothing while the workspace is
        # outside the store's perimeter (measured, 2026-11-03).
        $script:store | Should -Not -Match 'diagnosticSettings'
        $script:store | Should -Not -Match 'vmf-store-to-logs'
        $script:store | Should -Not -Match 'StorageWrite|StorageDelete'
    }

    It 'no longer waits for the workspace, which only the setting named' {
        $script:store | Should -Not -Match '(?s)dependsOn: \[[^\]]*\blogs\b[^\]]*\]'
    }
}
Describe 'STORE-LOGS-WORKSPACE-PERIMETER-1: the workspace is outside the perimeter, and the store stays in it, Enforced' {
    # MEASURED on the lab install, 2026-11-06, after azd up of the branch with
    # the service signing its telemetry with its managed identity: the
    # perimeter still refused the service's telemetry/write on the workspace
    # (NspPublicInboundPerimeterRulesDenied, an EMPTY SourceAppId), six times
    # in 23 minutes, and AppRequests stayed empty. The association was then
    # deleted by hand at 15:15 UTC, and AppRequests and AppTraces arrived
    # within a minute. On 2026-11-06 the Log Analytics workspace came out of
    # the perimeter.

    It 'found the associations, or this proves nothing' {
        $script:associations | Should -Match '^resourceAssociations:'
    }

    It 'does not associate the workspace' {
        $script:associations | Should -Not -Match 'logs-workspace'
        $script:perimeter | Should -Not -Match 'logsResourceId' -Because 'the workspace leaves the perimeter'
    }

    It 'keeps the run store associated, Enforced, on the store profile' {
        $entry = [regex]::Match($script:associations, "(?s)\{[^{}]*name: 'run-store'[^{}]*\}").Value
        $entry | Should -Not -BeNullOrEmpty
        $entry | Should -Match 'privateLinkResource: storeResourceId'
        $entry | Should -Match 'profile: nspProfileName'
        $entry | Should -Match "accessMode: 'Enforced'"
        @([regex]::Matches($script:associations, 'privateLinkResource:')).Count | Should -Be 1
    }

    It 'the workspace has no managed identity, which it held only for the perimeter' {
        $logs = Get-VmfBicepBlock -Text $script:platform -Header 'module logs '
        $logs | Should -Match "^module logs 'br/public:avm/res/operational-insights/workspace:"
        $logs | Should -Not -Match 'managedIdentities'
        $logs | Should -Not -Match 'roleAssignments'
    }

    It 'the perimeter waits for the store only' {
        $script:perimeter | Should -Match '(?m)^\s*dependsOn: \[ store \]\s*$'
    }
}

Describe 'STORE-LOGS: the compiled template' {
    BeforeAll {
        $script:compiled = $null
        if (Get-Command az -ErrorAction SilentlyContinue) {
            $out = az bicep build --file $script:platformPath --stdout 2>$null
            if ($LASTEXITCODE -eq 0) { $script:compiled = ($out -join "`n") | ConvertFrom-Json -Depth 100 }
        }
        function Script:Get-VmfDeployment {
            param($Template, [string]$Name)
            $items = if ($Template.resources -is [array]) { $Template.resources } else { $Template.resources.PSObject.Properties.Value }
            @($items | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and [string]$_.name -eq $Name })[0]
        }
    }

    It 'gives the store module no diagnostic setting' {
        if (-not $script:compiled) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $deploy = Get-VmfDeployment -Template $script:compiled -Name 'vmf-store-deploy'
        $deploy | Should -Not -BeNullOrEmpty
        $deploy.properties.parameters.blobServices.value.PSObject.Properties.Name | Should -Not -Contain 'diagnosticSettings'
        $deploy.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'diagnosticSettings'
    }
    It 'gives the perimeter one Enforced association: the run store' {
        if (-not $script:compiled) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $deploy = Get-VmfDeployment -Template $script:compiled -Name 'vmf-nsp-deploy'
        $deploy | Should -Not -BeNullOrEmpty
        $assoc = @($deploy.properties.parameters.resourceAssociations.value)
        $assoc.Count | Should -Be 1
        $assoc[0].name | Should -Be 'run-store'
        $assoc[0].accessMode | Should -Be 'Enforced'
        [string]$assoc[0].privateLinkResource | Should -Be "[variables('storeResourceId')]"
    }
}
