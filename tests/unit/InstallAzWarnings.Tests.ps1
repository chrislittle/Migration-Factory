#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-AZ-WARNINGS-1: azd up shows no Azure CLI progress as WARNING lines.
#
# Found in the final lab azd up, 2026-11-16: WARNING lines with nothing
# wrong. The Azure CLI writes its progress and its preview notices to stderr as
# warnings: az webapp deploy ("Initiating deployment", "Polling the status",
# "Deployment has completed successfully"), az acr build ("Packing source code
# into tar", "Excluding ..."), az acr manifest ("Command group 'acr manifest'
# is in preview"). The install prints its own step line for each of these, and
# checks the exit code, so the warnings tell the person nothing.
#
# `--only-show-errors` (every command's --help: "Only show errors, suppressing
# warnings") takes the warnings away and keeps the errors. The az acr build log
# stream is not a warning: the CLI prints it to stdout, so a failed build still
# shows the build's own output.
#
# Each call is found with the PowerShell parser over Get-VmfCodeOnly, so a
# comment or a message that names a command is never counted as a call.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Get-VmfTestAzCall {
        # Every `az <words...>` command in one file's code, as parsed objects.
        param([string]$RelativePath, [string[]]$Words)
        $full = Join-Path $script:repoRoot $RelativePath
        $code = Get-VmfCodeOnly -Path $full -Language PowerShell
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
        $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object {
                $elements = @($_.CommandElements)
                if ($_.GetCommandName() -ne 'az' -or $elements.Count -le $Words.Count) { return $false }
                for ($i = 0; $i -lt $Words.Count; $i++) {
                    if ([string]$elements[$i + 1].Extent.Text -ne $Words[$i]) { return $false }
                }
                $true
            } |
            ForEach-Object {
                $flags = @($_.CommandElements | ForEach-Object { [string]$_.Extent.Text })
                $toNull = @($_.Redirections | Where-Object {
                        $_ -is [System.Management.Automation.Language.FileRedirectionAst] -and
                        $_.FromStream -in @('Error', 'All') -and [string]$_.Location.Extent.Text -eq '$null'
                    }).Count -gt 0
                [pscustomobject]@{
                    File           = $RelativePath
                    Text           = $_.Extent.Text
                    HasFlag        = $flags -contains '--only-show-errors'
                    StderrDropped  = $toNull
                }
            }
    }

    # The calls azd up makes that print progress or preview notices. Each one
    # must be found: a rename that loses a call must fail here, not pass empty.
    $script:installCalls = @(
        @{ File = 'tools/Deploy-VmfDashboard.ps1';      Words = @('webapp', 'deploy') }
        @{ File = 'tools/Deploy-VmfFacade.ps1';         Words = @('acr', 'build') }
        @{ File = 'tools/Deploy-VmfFacade.ps1';         Words = @('containerapp', 'job', 'update') }
        @{ File = 'tools/Deploy-VmfFacade.ps1';         Words = @('containerapp', 'job', 'start') }
        @{ File = 'infra/hooks/postprovision.ps1';      Words = @('acr', 'build') }
        @{ File = 'infra/hooks/postprovision.ps1';      Words = @('containerapp', 'job', 'update') }
        @{ File = 'infra/Resolve-VmfImageDigest.ps1';   Words = @('acr', 'manifest', 'show-metadata') }
    )
}

Describe 'INSTALL-AZ-WARNINGS-1: the install calls ask the Azure CLI for errors only' {

    It 'every install call that prints progress carries --only-show-errors' {
        foreach ($c in $script:installCalls) {
            $found = @(Get-VmfTestAzCall -RelativePath $c.File -Words $c.Words)
            $found.Count | Should -BeGreaterThan 0 -Because "$($c.File) runs az $($c.Words -join ' ') during azd up"
            foreach ($call in $found) {
                $call.HasFlag | Should -BeTrue -Because "$($call.File): $($call.Text)"
            }
        }
    }

    It 'no such call throws its errors away' {
        # The warnings go; the errors must still reach the person, either on the
        # console or in the text the script puts into its own error.
        foreach ($c in $script:installCalls) {
            foreach ($call in @(Get-VmfTestAzCall -RelativePath $c.File -Words $c.Words)) {
                $call.StderrDropped | Should -BeFalse -Because "$($call.File): $($call.Text)"
            }
        }
    }

    It 'every az acr build, az acr manifest and az webapp deploy in the install scripts carries it' {
        # The class, not only the calls named above: a new build or deploy call
        # added to a hook or a deploy script gets the same rule.
        $files = @(
            Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'infra') -Recurse -Filter '*.ps1' -File
            Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'tools') -Filter 'Deploy-*.ps1' -File
            Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'tools') -Filter 'Publish-*.ps1' -File
        )
        $seen = 0
        foreach ($f in $files) {
            $rel = [System.IO.Path]::GetRelativePath($script:repoRoot, $f.FullName)
            foreach ($words in @(@('acr', 'build'), @('acr', 'manifest'), @('webapp', 'deploy'))) {
                foreach ($call in @(Get-VmfTestAzCall -RelativePath $rel -Words $words)) {
                    $seen++
                    $call.HasFlag | Should -BeTrue -Because "$rel`: $($call.Text)"
                }
            }
        }
        $seen | Should -BeGreaterOrEqual 4 -Because 'two image builds, one digest read and one dashboard deploy are in the install'
    }

    It 'a Bicep deployment keeps its warnings, because they are information for the operator' {
        # Review of this item: az deployment compiles Bicep, and its compiler,
        # linter and deprecation warnings say something about the template.
        # Nothing showed them as noise, so they stay visible.
        $deployments = @(
            @{ File = 'infra/Resolve-VmfRoleScopes.ps1'; Words = @('deployment', 'sub', 'create') }
            @{ File = 'infra/identity-deploy.ps1';       Words = @('deployment', 'group', 'create') }
        )
        foreach ($c in $deployments) {
            $found = @(Get-VmfTestAzCall -RelativePath $c.File -Words $c.Words)
            $found.Count | Should -BeGreaterThan 0 -Because "$($c.File) runs az $($c.Words -join ' ') during azd up"
            foreach ($call in $found) {
                $call.HasFlag | Should -BeFalse -Because "$($call.File): $($call.Text)"
            }
        }
    }

    It 'the finder sees a call only in code, never in a comment or a message' {
        # The check above is only as good as what it finds. A comment that names
        # the command, and a message that quotes it, are not calls.
        $dir = Join-Path $TestDrive 'finder'
        New-Item -ItemType Directory -Path (Join-Path $dir 'x') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'x' 'a.ps1') -Encoding utf8NoBOM -Value @(
            '# az acr build -r r -t t .'
            'Write-Host ''Run az acr build -r r .'''
            'az acr build -r $r -t t . --output none'
        )
        $saved = $script:repoRoot
        try {
            $script:repoRoot = $dir
            $found = @(Get-VmfTestAzCall -RelativePath 'x/a.ps1' -Words @('acr', 'build'))
        }
        finally { $script:repoRoot = $saved }
        $found.Count | Should -Be 1
        $found[0].HasFlag | Should -BeFalse
        $found[0].StderrDropped | Should -BeFalse
    }
}
