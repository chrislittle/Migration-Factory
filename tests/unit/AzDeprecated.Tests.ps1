#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ACR-DEPRECATED-1 - the install must not run a command Azure is retiring.
#
# Found in an install log on a work subscription:
#
#   Run ID: ds1 was successful after 56s
#   WARNING: This command has been deprecated and will be removed in a future
#   release. Use 'acr manifest list-metadata' instead.
#
# Three places ran `az acr repository show-manifests`: the install hook, the
# facade publisher and the deploy workflow (removed 2026-11-05). Each resolves the digest of the image
# it just built, which is the step that makes a deployment traceable to bytes
# rather than to a movable tag - so this is not a cosmetic warning. When the
# command goes, all three break, and the failure lands in the middle of a
# customer's install.
#
# A DEPRECATION WARNING IS A DATED NOTICE. It costs nothing to act on it now
# and costs an install later.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # Every file that calls the Azure CLI at all, found rather than listed -
    # a list goes out of date the first time somebody adds a script.
    $script:azFiles = @(
        Get-ChildItem $script:repoRoot -Recurse -File -Include '*.ps1', '*.yml', '*.yaml', '*.sh' |
            Where-Object { $_.FullName -notmatch '\\(\.git|node_modules|CLAUDE-SECURITY-[^\\]*)\\' } |
            Where-Object { (Get-Content $_.FullName -Raw) -match '(?m)^\s*\$?\w*\s*=?\s*az\s' })

    # COMMENT-TRAP-1: three of these files now EXPLAIN the retired command by
    # name, so a check over file text matches its own explanation and can never
    # fail. Comments are dropped first; only code is read.
    #
    # YAML IS READ A DIFFERENT WAY, and the reason is measured rather than
    # assumed. `Get-VmfCodeOnly -Language Shell` does NOT strip comments from
    # a workflow file (measured on the deploy workflow, removed 2026-11-05):
    # its quote-aware scanner meets an apostrophe in an earlier
    # comment, believes it is inside a string from then on, and hands the file
    # back whole. There is no YAML mode.
    #
    # So a YAML file drops the lines whose FIRST character is a comment marker.
    # CLAUDE.md warns that a line filter keeps `$x = $null # the thing`, and
    # that is true here too - a retired command named in a TRAILING comment
    # would be reported. That failure is a false alarm somebody must read and
    # clear, not a silent pass, which is the direction this has to fail in.
    $script:azCode = @{}
    foreach ($f in $script:azFiles) {
        $rel = $f.FullName.Substring($script:repoRoot.Length + 1)
        $script:azCode[$rel] = if ($f.Extension -in '.yml', '.yaml') {
            ((Get-Content $f.FullName) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        }
        else {
            $language = if ($f.Extension -eq '.sh') { 'Shell' } else { 'PowerShell' }
            Get-VmfCodeOnly -Path $f.FullName -Language $language
        }
    }
}

Describe 'ACR-DEPRECATED-1: nothing runs a retired Azure CLI command' {

    It 'found the files that call the Azure CLI, or nothing below proves anything' {
        $script:azFiles.Count | Should -BeGreaterThan 5
    }

    It 'the comment reader really is dropping comments, in both kinds of file' {
        # Each of these files names the retired command in a comment explaining
        # why it stopped using it. If a pair ever fails, either the specimen is
        # gone or comments are reaching the checks below - and either way they
        # are measuring nothing.
        # ACR-DIGEST-1 moved the specimen when it moved the comments: the three
        # copies became one, so the file that now explains the retired command
        # by name is the resolver. Found by looking rather than named, so a
        # rename does not turn this into a check of nothing.
        $explainers = @($script:azCode.Keys | Where-Object {
            (Get-Content (Join-Path $script:repoRoot $_) -Raw) -match 'show-manifests' })
        @($explainers).Count | Should -BeGreaterThan 0 -Because 'something must still explain why the retired command went'
        foreach ($name in $explainers) {
            $script:azCode[$name] | Should -Not -Match 'show-manifests' -Because "$name explains it in a comment, and the reader must drop it"
        }

        # And YAML specifically, because it is read a DIFFERENT way - whole-line
        # comments dropped, since Get-VmfCodeOnly has no YAML mode. Both readers
        # have to be exercised or half of this file rests on an untested one.
        $commentedYaml = @($script:azCode.Keys | Where-Object {
            ($_ -like '*.yml' -or $_ -like '*.yaml') -and
            (Get-Content (Join-Path $script:repoRoot $_) -Raw) -match '(?m)^\s*#\s*\S' })
        # PUBLIC-SYNC-1: the public repository may hold no workflow that calls
        # the Azure CLI (this repository's workflows do not ship). Then the YAML
        # reader reads nothing, and there is nothing for it to prove.
        $yamlCalls = @($script:azCode.Keys | Where-Object { $_ -like '*.yml' -or $_ -like '*.yaml' })
        if ($yamlCalls.Count) {
            @($commentedYaml).Count | Should -BeGreaterThan 0 -Because 'a workflow with no comments cannot show the YAML reader works'
        }
        foreach ($name in $commentedYaml) {
            $script:azCode[$name] | Should -Not -Match '(?m)^\s*#' -Because "$name still has comment lines in its code"
        }
    }

    It 'no file runs az acr repository show-manifests' {
        $offenders = foreach ($name in $script:azCode.Keys) {
            if ($script:azCode[$name] -match 'show-manifests') { $name }
        }
        @($offenders) | Should -BeNullOrEmpty -Because 'Azure says to use acr manifest list-metadata'
    }

    It 'and the three digest lookups still HAPPEN, on the command that replaced it' {
        # Without this, deleting the lookups passes the check above - and the
        # deployment would go back to naming a movable tag.
        #
        # ACR-TAG-1 changed WHICH replacement: `list-metadata` returned every
        # manifest and the filtering on it broke an install, so the lookup asks
        # for the one tag now.
        #
        # ACR-DIGEST-1 made it ONE lookup, in infra/Resolve-VmfImageDigest.ps1,
        # called from the three places that used to hold a copy. Three copies
        # were changed three times in two days and were wrong in all three at
        # once every time.
        $callers = @($script:azCode.Keys | Where-Object {
            $script:azCode[$_] -match 'az acr manifest show' })
        @($callers).Count | Should -Be 1 -Because 'the lookup lives in one file now'
        ($callers[0] -replace '\\', '/') | Should -BeLike '*infra/Resolve-VmfImageDigest.ps1'
    }

    It 'every call names the registry and the repository in full' {
        # THE TRAP IN THIS RENAME: `-n` is the REGISTRY in the retired command
        # and the REPOSITORY in its replacement. A swap that keeps the short
        # flags asks for the wrong thing, and the error names neither.
        $bad = foreach ($name in $script:azCode.Keys) {
            foreach ($line in ($script:azCode[$name] -split "`n")) {
                if ($line -notmatch 'az acr manifest list-metadata') { continue }
                if ($line -notmatch '--registry' -or $line -notmatch '--name') { "$name : $($line.Trim())" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'and reads the answer as objects rather than through a bracket query' {
        # CLAUDE.md, measured 2026-08-30: PowerShell hands `--query "[?...]"` to
        # cmd, which eats the bracket and the question mark, so the FILTER never
        # reaches Azure and an error string comes back as if it were a result.
        # Cost: nine orphaned disks from a teardown that reported success.
        $bad = foreach ($name in $script:azCode.Keys) {
            foreach ($line in ($script:azCode[$name] -split "`n")) {
                if ($line -notmatch 'az acr manifest list-metadata') { continue }
                if ($line -match '--query') { "$name : $($line.Trim())" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'GRANT-FIX-1: no az call filters with a bracket query' {
    # CLAUDE.md, measured 2026-08-30: PowerShell hands `--query "[?...]"` to
    # cmd, which eats the bracket and the question mark. The filter never
    # reaches Azure, an error string comes back, and a script reads it as an
    # answer. Cost: nine orphaned disks from a teardown that reported success.
    #
    # Grant-VmfAccess.ps1 was the last file still doing it, in the two lines
    # that find the product's identities and the one that checks for an
    # existing grant - so the one supported way to grant access without the
    # Admin page was unreliable on Windows, which is where installs run.

    It 'no file runs one' {
        $offenders = foreach ($name in $script:azCode.Keys) {
            if ($script:azCode[$name] -match '--query\s+"\[\?') { $name }
        }
        @($offenders) | Should -BeNullOrEmpty -Because 'cmd eats the bracket and the filter never runs'
    }

    It 'and the calls that replaced them still filter, in PowerShell' {
        # Without this, deleting the lookups passes the test above.
        $grant = $script:azCode['tools\Grant-VmfAccess.ps1']
        $grant | Should -Not -BeNullOrEmpty
        $grant | Should -Match 'az identity list[^\n]*-o json'
        # ID-ADDRESS-1 part 3: the filter is the shared rule the grant script calls.
        $grant | Should -Match 'Select-VmfOneByName -Items @\(\$identities \| ConvertFrom-Json\)'
        $rule = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
        $rule | Should -Match "Where-Object \{ \[string\]\`$_\.name -like `"\`$Prefix\*`" \}"
        $grant | Should -Match 'az role assignment list[^\n]*-o json'
    }

    It 'the rule does not ban a plain projection, which has no bracket' {
        # Only the FILTER breaks. `--query id` reaches Azure intact, and this
        # file uses it three times - banning every --query would be a rule
        # nobody could follow.
        #
        # THE RULE ITSELF is driven here, both ways. Pinning a line of the
        # script instead made a test that could not fail: the same line appears
        # three times, so rewriting one left the others matching. Mutation
        # testing found that.
        $rule = '--query\s+"\[\?'
        'az account show --query id -o tsv' | Should -Not -Match $rule
        'az x --query "[?name==''a''].id" -o tsv' | Should -Match $rule
    }
}

Describe 'GRANT-FIX-1: no az call puts a parenthesis on the command line' {
    # MEASURED on a workstation, running a command this project had handed out:
    #
    #   az ad sp list --filter "startswith(displayName,'vmf-api')" -o json
    #   -o was unexpected at this time.
    #
    # Same cause as the bracket in `--query "[?...]"`, one character class
    # wider: az.cmd hands its arguments to cmd, and cmd reads ( and ) as its
    # own grouping syntax. The command never runs.
    #
    # `--filter "appId eq '<id>'"` is fine and stays - no parenthesis. Only the
    # function-call forms break, which is why this test names the character
    # rather than the word "filter".

    It 'no file passes an az argument containing a parenthesis' {
        $offenders = foreach ($name in $script:azCode.Keys) {
            foreach ($line in ($script:azCode[$name] -split "`n")) {
                if ($line -notmatch '\baz\b') { continue }
                if ($line -match '--(?:filter|query)\s+"[^"]*\(') { "$name : $($line.Trim())" }
            }
        }
        @($offenders) | Should -BeNullOrEmpty -Because 'cmd reads the parenthesis and the command never runs'
    }

    It 'and the filter that has no parenthesis is untouched, because it works' {
        # Proving the rule is not "ban --filter": the install has used this one
        # since the beginning.
        $resolve = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
        $resolve | Should -Match "appId eq "
    }
}

Describe 'ACR-TAG-1: a digest is asked for by tag, never filtered out of a list' {
    # WHAT HAPPENED. ACR-DEPRECATED-1 swapped `az acr repository show-manifests`
    # for `az acr manifest list-metadata` in three places, and each then filtered
    # the whole list on `$_.tags`. A registry that holds an UNTAGGED manifest -
    # which any registry does, the moment a tag is moved or a build is retried -
    # returns one with NO tags property at all, and reading a property that is
    # not there throws:
    #
    #   The property 'tags' cannot be found on this object.
    #
    # It names neither the registry, the tag, nor the image. It stopped `azd up`
    # dead on a real install on 2026-09-17, in a hook, after the image had
    # already been built and paid for.
    #
    # The tests that shipped with ACR-DEPRECATED-1 checked WHICH COMMAND was
    # called. They were right about that and said nothing about what was done
    # with the answer - the shape of every defect this project has found by use.
    BeforeAll {
        # COMMENT-TRAP-1 AGAIN, and it caught the first version of this block:
        # the three files now EXPLAIN the old filter by name, so a check over
        # file TEXT matched its own explanation and failed for that reason.
        # $script:azCode is already comment-free, and is what to read.
        #
        # ACR-DIGEST-1: these three no longer hold the lookup - they CALL it.
        # The resolver joins them, because the rules below are about it now.
        $script:acrFiles = @(
            'infra/hooks/postprovision.ps1'
            'tools/Deploy-VmfFacade.ps1'
            'infra/Resolve-VmfImageDigest.ps1'
        ) | ForEach-Object {
            $name = $_
            $match = @($script:azCode.Keys | Where-Object { ($_ -replace '\\', '/') -like "*$name" })
            if ($match.Count -ne 1) { throw "expected one code entry for $name, found $($match.Count)" }
            [pscustomobject]@{ Name = $name; Text = $script:azCode[$match[0]] }
        }
    }

    It 'there are files to check, so this cannot pass by finding none' {
        # WORKFLOWS-UNUSED-1 removed the deploy workflow, the fourth caller.
        @($script:acrFiles).Count | Should -Be 3
    }

    It 'THE DEFECT: nothing reads a tags property off a MANIFEST listing' {
        # Over every file that lists manifests, not the four above - the drill
        # lists them too and must ask the property bag rather than the object.
        #
        # SCOPED TO MANIFESTS ON PURPOSE, and the first version was not. A flat
        # ban on `$_.tags` fails lab/teardown.ps1, which reads RESOURCE tags off
        # `az resource list` to tell the lab's keepers from its litter. Azure
        # always gives a resource a tags property; a MANIFEST with no tags has
        # no such property at all. Same spelling, different objects, and only
        # one of them is a defect - a rule that cannot tell them apart would be
        # one somebody has to work around, which is how rules die.
        $listers = @($script:azCode.Keys | Where-Object {
            $script:azCode[$_] -match 'acr manifest list-metadata' })
        $offenders = foreach ($name in $listers) {
            if ($script:azCode[$name] -match '\$_\.tags') { $name }
        }
        @($offenders) | Should -BeNullOrEmpty `
            -Because 'an untagged manifest has no tags property, so reading one throws on the object being looked for'
    }

    It 'and the digest is never picked out of a manifest listing' {
        # Asking for the tag is one call, needs no filtering, and assumes
        # nothing about the shape of what comes back.
        #
        # THE RULE IS ABOUT THE DIGEST, NOT ABOUT LISTING. Listing manifests to
        # look at a registry is a fair thing to do - the install drill does it
        # to prove an untagged manifest is there. What must never happen is a
        # digest a deployment gets PINNED to coming out of a list.
        $resolver = @($script:acrFiles | Where-Object { $_.Name -like '*Resolve-VmfImageDigest*' })
        @($resolver).Count | Should -Be 1
        $resolver[0].Text | Should -Match 'acr manifest show-metadata --registry' `
            -Because 'the resolver asks for the one tag'
        $resolver[0].Text | Should -Not -Match 'acr manifest list-metadata' `
            -Because 'the resolver must not list'

        foreach ($file in @($script:acrFiles | Where-Object { $_.Name -notlike '*Resolve-VmfImageDigest*' })) {
            $file.Text | Should -Match 'Resolve-VmfImageDigest' `
                -Because "$($file.Name) must call the one resolver, not carry a copy"
            $file.Text | Should -Not -Match 'az acr manifest' `
                -Because "$($file.Name) must not talk to the registry about manifests itself"
        }
    }

    It 'and no caller builds a pinned image reference by hand' {
        # The reference ending in `@` is what an empty digest produces, and
        # three places building that string was three chances to do it. The
        # resolver returns the whole reference for that reason.
        foreach ($file in @($script:acrFiles | Where-Object { $_.Name -notlike '*Resolve-VmfImageDigest*' })) {
            $file.Text | Should -Not -Match 'azurecr\.io/[^"'']*@' `
                -Because "$($file.Name) should take .Image from the resolver"
        }
    }

    It 'the long flags stay, because -n means two different things' {
        # `-n` names the REGISTRY in the retired show-manifests and the
        # REPOSITORY in this one. A swap that kept the short flags asks for the
        # wrong thing and the error names neither.
        foreach ($file in $script:acrFiles) {
            $file.Text | Should -Not -Match 'acr manifest show(-metadata)? -n ' -Because "$($file.Name) must spell the flags out"
        }
    }

    It 'and a failed lookup is a failure, not an empty digest' {
        # An empty digest builds an image reference ending in `@`, which Azure
        # refuses later somewhere that does not name the cause. `--query digest`
        # on the wrong command prints nothing and exits 0, so the exit code
        # alone was never enough.
        $resolver = @($script:acrFiles | Where-Object { $_.Name -like '*Resolve-VmfImageDigest*' })[0]
        $resolver.Text | Should -Match '\$read\.ExitCode -ne 0 -or -not \$digest' `
            -Because 'the call may fail, and it may also answer with nothing'
        # And the answer is checked for SHAPE, because a registry that replied
        # with a word rather than a digest would otherwise be found out by
        # Container Apps, somewhere that names none of this.
        $resolver.Text | Should -Match 'sha256:\[0-9a-f\]\{64\}' `
            -Because 'a digest that is not a digest must be refused here'
    }
}
Describe 'ACR-DIGEST-1: a digest is never asked of a command that has none' {
    # MEASURED on a corporate install, 2026-09-17, the THIRD failure
    # in three days in the same five lines:
    #
    #   Run ID: dsr was successful after 26s
    #   Exception: Built the image but could not resolve the digest for
    #   vmf-engine:8efbd3802f2d in registry vmfacrexamplesuffix.
    #
    # ACR-TAG-1 replaced a manifest LISTING with `az acr manifest show`, to ask
    # for one tag rather than filter a list. Right about the shape and wrong
    # about the command.
    #
    #   `az acr manifest show`          GET /v2/<repo>/manifests/<tag>
    #       returns the MANIFEST: schemaVersion, mediaType, config, layers.
    #       There is no digest on it. `config.digest` is the config blob, which
    #       is a different thing wearing the right name.
    #
    #   `az acr manifest show-metadata` GET /acr/v1/<repo>/_manifests/<tag>
    #       returns the artifact's METADATA: digest, tags, createdTime. This is
    #       the one, and it is what `list-metadata` was returning all along.
    #
    # So `--query digest` asked a real command a question it cannot answer. It
    # printed nothing and exited 0. Only the `-not $digest` guard from ACR-TAG-1
    # turned that into a message instead of an image reference ending in `@`.
    #
    # THE RULE IS OVER EVERY FILE, not over these three. `az acr manifest show`
    # is a legitimate command; pairing it with `--query digest` never is.

    It 'nothing asks az acr manifest show for a digest' {
        $wrong = foreach ($name in $script:azCode.Keys) {
            foreach ($line in ($script:azCode[$name] -split "`n")) {
                if ($line -notmatch 'az acr manifest show(?!-metadata)') { continue }
                if ($line -match '--query\s+digest') { "$name : $($line.Trim())" }
            }
        }
        @($wrong) | Should -BeNullOrEmpty -Because 'manifest show returns the manifest, which carries no digest'
    }

    It 'the rule tells the two commands apart, which is the whole difficulty' {
        # Driven on source text. One word separates them, and `show-metadata`
        # contains `show`, so a rule written with a plain substring bans both.
        $rule = 'az acr manifest show(?!-metadata)'
        'az acr manifest show --registry r --name a:b --query digest -o tsv' | Should -Match $rule
        'az acr manifest show-metadata --registry r --name a:b --query digest -o tsv' | Should -Not -Match $rule
        # And the ban is on the PAIRING. Reading a manifest is a fair thing to
        # want, and a rule that forbade it would be one nobody could follow.
        'az acr manifest show --registry r --name a:b --query config.mediaType' | Should -Not -Match '--query\s+digest'
    }

    It 'and the three lookups still ask the command that does answer' {
        # Without this, deleting all three passes everything above, and the
        # deployment goes back to naming a movable tag.
        $callers = @($script:azCode.Keys | Where-Object {
            $script:azCode[$_] -match 'az acr manifest show-metadata' })
        @($callers).Count | Should -Be 1 -Because 'ACR-DIGEST-1 made the three copies one resolver'
    }
}
