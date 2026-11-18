#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CONTRACT-1: every shipped sample validates against its own schema, LOCALLY.
#
# This exists because CI caught something the local suite could not. GUEST-2
# bumped the guest contract to vmf.guest/2 across the schema and all 15 guest
# scripts - and left `schemas/samples/guest-output.sample.json` saying v1. 755
# local tests passed; CI failed on its check-jsonschema step.
#
# The gap was that sample-versus-schema validation existed ONLY in CI. Two
# samples happened to be checked locally by StateContract.Tests.ps1 because
# those items needed it; the other four were checked nowhere but the pipeline.
# A guard that only runs after a push is a guard that finds things late.
#
# Pester expands -ForEach at DISCOVERY, so the pairs are built there.
BeforeDiscovery {
    $script:root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:pairs = @(
        Get-ChildItem (Join-Path $script:root 'schemas') -Filter '*.schema.json' | ForEach-Object {
            $name = $_.Name -replace '\.schema\.json$', ''
            [pscustomobject]@{
                Name = $name
                Schema = $_.FullName
                Sample = Join-Path $script:root "schemas/samples/$name.sample.json"
            }
        }
    )
}

BeforeAll {
    $script:root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:pairs = @(
        Get-ChildItem (Join-Path $script:root 'schemas') -Filter '*.schema.json' | ForEach-Object {
            $name = $_.Name -replace '\.schema\.json$', ''
            [pscustomobject]@{
                Name = $name
                Schema = $_.FullName
                Sample = Join-Path $script:root "schemas/samples/$name.sample.json"
            }
        }
    )
}

Describe 'CONTRACT-1: shipped samples match their schemas' {
    It 'found the schemas' {
        @($script:pairs).Count | Should -BeGreaterThan 4
    }

    It 'every schema HAS a sample - CI fails the build without one' {
        $missing = @($script:pairs | Where-Object { -not (Test-Path $_.Sample) } | ForEach-Object { $_.Name })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It '<_.Name> sample conforms' -ForEach $script:pairs {
        $pair = $_
        Test-Path $pair.Sample | Should -BeTrue -Because "$($pair.Name) needs a sample"
        $json = Get-Content $pair.Sample -Raw
        try {
            Test-Json -Json $json -SchemaFile $pair.Schema -ErrorAction Stop | Should -BeTrue
        }
        catch {
            # Say WHICH field, not just "invalid" - the CI message that caught
            # GUEST-2 was actionable precisely because it named $.schema.
            throw "$($pair.Name).sample.json does not match $($pair.Name).schema.json: $($_.Exception.Message)"
        }
    }
}

Describe 'CONTRACT-1: the check is real' {
    It 'a sample that contradicts its schema is REJECTED' {
        # Guard the guard: if Test-Json accepted anything, every test above
        # would pass vacuously - which is how the stale sample survived.
        $schema = (Join-Path $script:root 'schemas' 'guest-output.schema.json')
        $bad = '{"schema":"vmf.guest/1","script":"x.ps1","version":"1.0.0","result":"PASS","checks":[]}'
        { Test-Json -Json $bad -SchemaFile $schema -ErrorAction Stop } | Should -Throw -Because 'this is the exact stale-version mistake CI caught'
    }
}
