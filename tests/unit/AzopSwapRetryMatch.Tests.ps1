#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AZOP-SWAP-RETRY-MATCH-1: the data-disk update on a stopped machine is tried
# again only when Azure says it is busy - decided as Invoke-VmfAzOperation
# decides (Resolve-VmfOperationError, then Get-VmfTransientVerdict).
#
# Update-VmfVmWhileBusy sends every update of Set-VmfVmDataDisks (the data-disk
# swap and its put-back) and of Add-VmfVmDataDiskOnEmptyLun. It used a whole-word
# match on the error's outer message, '\b(429|...)\b'. A hyphen is a word
# boundary, so an error that named a disk 'disk-429' or a machine 'vm-503' was
# sent again up to three times, with waits of 5 and 10 seconds, on a stopped
# machine. And a real 503 that only the status code or the inner exception
# carried was not sent again.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
}

Describe 'AZOP-SWAP-RETRY-MATCH-1: Update-VmfVmWhileBusy sends an update again only for a temporary error' {
    BeforeEach {
        # Each entry is what the next send throws; an empty queue is a success.
        $global:asrThrows = [System.Collections.Generic.Queue[object]]::new()
        $global:asrSends = 0
        $global:asrWaits = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName VmMigrationFactory Clear-VmfDiskPerfProperties { $Vm }
        Mock -ModuleName VmMigrationFactory Update-AzVM -RemoveParameterType 'VM' {
            $global:asrSends++
            if ($global:asrThrows.Count -gt 0) { throw $global:asrThrows.Dequeue() }
        }
        Mock -ModuleName VmMigrationFactory Start-Sleep { $global:asrWaits.Add([int]$Seconds) }
        function Global:Invoke-AsrUpdate {
            InModuleScope VmMigrationFactory { Update-VmfVmWhileBusy -ResourceGroupName 'rg-app' -Vm ([pscustomobject]@{ Name = 'vm1' }) }
        }
    }
    AfterEach {
        Remove-Variable asrThrows, asrSends, asrWaits -Scope Global -ErrorAction SilentlyContinue
        Remove-Item 'function:\Invoke-AsrUpdate' -ErrorAction SilentlyContinue
    }

    It 'an error that is not temporary, naming the disk or machine <name>, is sent once' -ForEach @(
        @{ name = 'disk-429'; words = 'OperationNotAllowed: The disk disk-429 cannot be attached to the machine.' }
        @{ name = 'vm-503';   words = 'OperationNotAllowed: Machine vm-503 cannot attach the disk data-500-a.' }
        @{ name = 'app-throttle-01'; words = "Conflict: Changing property 'dataDisk.managedDisk.id' is not allowed for disk 'app-throttle-01'." }
    ) {
        $global:asrThrows.Enqueue([System.Exception]::new($words))
        { Invoke-AsrUpdate } | Should -Throw -ExpectedMessage "*$($words.Substring(0, 20))*"
        $global:asrSends | Should -Be 1 -Because 'a number or word inside a name is not Azure saying it is busy'
        $global:asrWaits.Count | Should -Be 0
    }

    It 'a 429 on the error object, with words that name no status, is sent again and goes through' {
        $global:asrThrows.Enqueue([System.Net.Http.HttpRequestException]::new('The request failed.', $null, [System.Net.HttpStatusCode]::TooManyRequests))
        Invoke-AsrUpdate
        $global:asrSends | Should -Be 2
    }

    It 'a 503 that only the inner exception carries is sent again and goes through' {
        $inner = [System.Net.Http.HttpRequestException]::new('Service down.', $null, [System.Net.HttpStatusCode]::ServiceUnavailable)
        $global:asrThrows.Enqueue([System.Exception]::new('An error occurred while sending the request.', $inner))
        Invoke-AsrUpdate
        $global:asrSends | Should -Be 2
    }

    It 'a 403 on the error object is sent once, whatever its words say' {
        $global:asrThrows.Enqueue([System.Net.Http.HttpRequestException]::new('Forbidden: ServiceUnavailable timed out (request 8b429503).', $null, [System.Net.HttpStatusCode]::Forbidden))
        { Invoke-AsrUpdate } | Should -Throw
        $global:asrSends | Should -Be 1
    }

    It 'Azure''s TooManyRequests code is sent again' {
        $global:asrThrows.Enqueue([System.Exception]::new('TooManyRequests: try again later'))
        Invoke-AsrUpdate
        $global:asrSends | Should -Be 2
    }

    It 'keeps its own limit: three sends in all, with waits of 5 and 10 seconds, then the error' {
        foreach ($i in 1..5) { $global:asrThrows.Enqueue([System.Net.Http.HttpRequestException]::new('Busy.', $null, [System.Net.HttpStatusCode]::TooManyRequests)) }
        { Invoke-AsrUpdate } | Should -Throw -ExpectedMessage '*Busy*'
        $global:asrSends | Should -Be 3
        @($global:asrWaits) | Should -Be @(5, 10)
    }

    It 'decides with Resolve-VmfOperationError and Get-VmfTransientVerdict, never with a number in the text' {
        $fn = Get-VmfCodeOnly -Text (InModuleScope VmMigrationFactory { ${function:Update-VmfVmWhileBusy}.ToString() })
        $fn | Should -Match 'Resolve-VmfOperationError'
        $fn | Should -Match 'Get-VmfTransientVerdict'
        $fn | Should -Not -Match '429'
    }
}
