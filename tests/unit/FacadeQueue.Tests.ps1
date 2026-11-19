#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FACADE-QUEUE-1 - a page request on Consumption waits for a NEW, cold
# instance of the facade.
#
# MEASURED 2026-11-08 on the lab install (Y1, PowerShell 7.6), Application
# Insights, 7 days: 164 facade instances started, and 131 of them started
# within one minute of an HTTP request that another instance served - the
# platform scaled OUT during an operator's session, not up from zero. The
# requests in the 30 seconds either side of a new instance's start took
# p50 7.6 s and p90 25 s, because each new process loads the modules (2-4 s)
# and signs in as the managed identity (5-8 s) before the function body runs.
# 16 of the 21 requests whose wait before the body was over 3 s in 3 hours had
# a profile.ps1 start-up on their own instance inside the request.
#
# NOT the worker's concurrency setting. Microsoft, "PowerShell developer
# reference for Azure Functions", Concurrency (ms.date 2026-05-20, read
# 2026-11-08): "By default, the number of runspaces is set to 1,000 in version
# 4.x of the Functions runtime." The host sets PSWorkerInProcConcurrencyUpperBound
# to 1000 when the app does not (azure-functions-host,
# DefaultWorkerProcessFactory.cs, DefaultConcurrencyLimit = "1000"). The lab
# install sets neither that nor FUNCTIONS_WORKER_PROCESS_COUNT, one process
# created 13 runspaces, and no "requests are being queued" warning was logged.
#
# THE FIX: on Consumption only, the facade may not scale out past ONE
# instance. Microsoft, "Event-driven scaling in Azure Functions", Limit
# scale-out (ms.date 2026-08-03, read 2026-11-08): "In a Consumption or Elastic
# Premium plan, you can specify a lower maximum limit for your app by modifying
# the value of the functionAppScaleLimit site configuration setting." The ARM
# reference for Microsoft.Web/sites: "This setting only applies to the
# Consumption and Elastic Premium Plans" - so a Basic (B1) install, which has
# one worker and Always On already, does not carry it.
# One instance is enough: the busiest lab instance served 524 requests in
# 30 minutes with 13 runspaces and 504 MB private bytes, against the 1.5 GB a
# Consumption instance has ("Azure Functions Scale and Hosting", Service
# limits, Max memory 1.5 GB per instance).
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    # COMMENT-FREE: the template explains this setting in a comment that names it.
    $script:platform = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Language CStyle
    $script:facadeBlock = [regex]::Match($script:platform, "(?s)module facade 'br/public:avm/res/web/site:[^']+' = \{.*?\r?\n\}").Value
    $script:dashboardBlock = [regex]::Match($script:platform, "(?s)module dashboard 'br/public:avm/res/web/site:[^']+' = \{.*?\r?\n\}").Value
    $script:hostJson = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'host.json') -Raw | ConvertFrom-Json
}

Describe 'FACADE-QUEUE-1: the facade stays on one warm instance on Consumption' {

    It 'the template was read, and both site modules were found' {
        $script:facadeBlock | Should -Match 'kind: .functionapp.'
        $script:facadeBlock | Should -Match 'siteConfig:'
        $script:dashboardBlock | Should -Match 'siteConfig:'
    }

    It 'the facade scale-out limit is one instance, on Consumption only' {
        # warm is the Basic (B1) choice. A B1 plan is a Dedicated plan, where
        # functionAppScaleLimit does not apply, so it is left out there.
        $script:facadeBlock | Should -Match 'warm \? \{\} : \{\s*functionAppScaleLimit: 1\s*\}' `
            -Because 'a new Consumption instance makes the request wait 10 to 25 seconds for its start-up'
    }

    It 'the limit is in the site configuration of the facade, not anywhere else' {
        @([regex]::Matches($script:platform, 'functionAppScaleLimit')).Count | Should -Be 1
        $script:dashboardBlock | Should -Not -Match 'functionAppScaleLimit'
        $siteConfig = [regex]::Match($script:facadeBlock, '(?s)siteConfig: union\(.*?\r?\n    \)').Value
        $siteConfig | Should -Match 'functionAppScaleLimit: 1'
        $siteConfig | Should -Match 'alwaysOn: warm' -Because 'the settings every plan gets stay in the first object'
    }

    It 'the worker keeps the documented default concurrency' {
        # The host gives 1000 runspaces to a PowerShell worker when the app
        # sets no PSWorkerInProcConcurrencyUpperBound. A lower value queues
        # requests behind the schedule pass, which holds one runspace for up
        # to 3.5 minutes. A second worker process
        # (FUNCTIONS_WORKER_PROCESS_COUNT) loads the modules and signs in
        # again, so each new process adds 7 to 12 seconds and about 450 MB.
        $script:platform | Should -Not -Match 'PSWorkerInProcConcurrencyUpperBound'
        $script:platform | Should -Not -Match 'FUNCTIONS_WORKER_PROCESS_COUNT'
        @($script:hostJson.PSObject.Properties.Name) | Should -Not -Contain 'concurrency'
    }
}
