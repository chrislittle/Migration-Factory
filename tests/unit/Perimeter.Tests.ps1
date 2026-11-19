#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NSP-3 - the perimeter around the run store, in the stack.
#
# A corporate policy with the modify effect forces publicNetworkAccess to
# Disabled on every storage account as it is created, and clears bypass to None
# with it. The template asks for neither; the policy wins, silently, on every
# deployment. With the store closed, nothing on the public path reaches it.
#
# NSP-1 measured the answer, and a corporate subscription confirmed
# it independently: a subscription-based INBOUND rule admits the Container Apps
# job, the Function App and the Web App, even though none of them can be a
# perimeter MEMBER. The negative control is what makes it proof - removing the
# rule blocked all three again.
#
# THE PRECONDITION IS THE POINT OF THIS FILE. A subscription rule admits things
# IN the subscription and can NEVER admit a laptop or a browser. So the
# perimeter only works because four earlier changes removed every store call
# made from outside Azure. The last Describe here is what stops one coming
# back - and it would come back silently, breaking every install in a
# subscription that has the policy, with an error naming a network rule rather
# than the line somebody added.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:template = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
    $script:nsp = [regex]::Match($script:template, "(?s)module perimeter 'br/public:avm/res/network/network-security-perimeter.*?\n\}").Value

    # THE CODE OF A SCRIPT, WITH ITS COMMENTS REMOVED - by the PowerShell
    # parser, not by dropping lines that start with a hash.
    #
    # Four checks in this repository have now matched their own comment: two in
    # STORE-READ-1, one here, and one that survived the first fix because
    # `$x = $null # az containerapp job start` is a TRAILING comment on a line
    # of code. Dropping whole-line comments is a rule that looks right and
    # fails on exactly the form somebody writes when disabling something.
    #
    # The parser knows. It tokenises the file and says which spans are
    # comments, so nothing is guessed at - a hash inside a string stays, and a
    # comment anywhere goes.
    function Script:Get-CodeOnly {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        $text = Get-Content $Path -Raw
        # Back to front, so removing one span does not move the next one.
        $comments = @($tokens | Where-Object { $_.Kind -eq 'Comment' }) |
            Sort-Object { $_.Extent.StartOffset } -Descending
        foreach ($t in $comments) {
            $text = $text.Remove($t.Extent.StartOffset, $t.Extent.EndOffset - $t.Extent.StartOffset)
        }
        return $text
    }
}

Describe 'NSP-3: the install creates the perimeter, rather than asking for one' {

    It 'found the module, or this file proves nothing' {
        # Ruled 2026-09-10: the NSP is part of the stack. This is a single
        # solution, and it is removed when the migration is done.
        #
        # NSP-1's own note said the opposite - "the install must not create one"
        # - because a perimeter is usually a platform team's construct. The
        # ruling answers that: this product is temporary and self-contained, so
        # it owns its perimeter and takes it away with everything else.
        $script:nsp | Should -Not -BeNullOrEmpty
        $script:template | Should -Match "var nspName = 'vmf-nsp-"
    }

    It 'uses the AVM module, like every other resource here' {
        $script:template | Should -Match "br/public:avm/res/network/network-security-perimeter:\d+\.\d+\.\d+"
    }

    It 'ENFORCED, not Audit' {
        # Audit reports what WOULD be blocked and blocks nothing. It is a
        # setting that looks like protection and is not, and the rule was
        # measured working before this shipped.
        $script:nsp | Should -Match "accessMode: 'Enforced'"
        $script:nsp | Should -Not -Match "accessMode: '(Audit|Learning)'"
    }

    It 'admits THIS subscription, read from the deployment and never typed' {
        # A perimeter that admits a subscription somebody typed is a perimeter
        # that admits the wrong one the first time a parameter file is copied.
        $script:nsp | Should -Match "direction: 'Inbound'"
        $script:nsp | Should -Not -Match 'param .*[Ss]ubscription'
    }

    It 'and names it as a FULL RESOURCE ID, which is what ARM accepts' {
        # NSP-3 shipped `subscription().subscriptionId` - the bare GUID - and
        # every install failed at provision:
        #
        #   LinkedInvalidPropertyId: Property id 'cccc0c0c-...' at path
        #   'properties.subscriptions[0].id' is invalid. Expect fully qualified
        #   resource Id that start with '/subscriptions/{subscriptionId}'
        #
        # THE ORIGINAL TEST COULD NOT HAVE CAUGHT THIS. It asserted the
        # expression the template contained, so it agreed with the template and
        # both were wrong - the same shape as a check that restates the code
        # instead of the rule. What ARM accepts is the rule, so that is what is
        # asserted: the id must carry the /subscriptions/ prefix, and the bare
        # form is named and forbidden.
        $script:nsp | Should -Match 'id: subscription\(\)\.id'
        $script:nsp | Should -Not -Match 'id: subscription\(\)\.subscriptionId' -Because 'ARM refuses the bare GUID'
    }

    It 'and admits nothing else - no address prefixes, no service tags' {
        # An IP rule is the shape this cannot use: NSP-1 ruled it out because
        # the people who use this product are on laptops behind corporate NAT,
        # and a rule per person is not a model that survives a second person.
        $script:nsp | Should -Not -Match 'addressPrefixes'
        $script:nsp | Should -Not -Match 'serviceTags'
    }

    It 'associates the RUN STORE, and nothing else' {
        # STORE-LOGS-NSP-1 added the workspace for a time; it was taken
        # out on 2026-11-06 (STORE-LOGS-WORKSPACE-PERIMETER-1): the perimeter
        # refused the service's telemetry even when it carried the service's
        # managed identity. The store alone again; anything more is a finding.
        $script:nsp | Should -Match 'privateLinkResource: storeResourceId'
        $script:template | Should -Match "var storeResourceId = resourceId\('Microsoft\.Storage/storageAccounts', storeName\)"
        $script:nsp | Should -Not -Match 'logsResourceId'
        @([regex]::Matches($script:nsp, 'privateLinkResource:')).Count | Should -Be 1
    }

    It 'and the store exists before the association names it' {
        $script:nsp | Should -Match 'dependsOn: \[ store \]'
    }

    It 'the perimeter is in the stack, so the removal takes it away' {
        # It is a module in platform.bicep like everything else, not something
        # a hook creates on the side. `azd down` deletes the stack; a perimeter
        # left behind would be a resource nothing owns, holding an association
        # to a storage account that no longer exists.
        $script:template | Should -Match "name: 'vmf-nsp-deploy'"
        foreach ($hook in 'preprovision', 'postprovision', 'predown') {
            $text = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' "$hook.ps1") -Raw
            $text | Should -Not -Match 'az network perimeter' -Because "$hook must not create or remove it on the side"
        }
    }
}

Describe 'NSP-3: the precondition - nothing outside Azure reads the store' {
    # THE RULE THIS FILE EXISTS FOR.
    #
    # A subscription inbound rule admits what runs in the subscription. A laptop
    # is not in a subscription and a browser never will be. So every one of
    # these would break EVERY install in a subscription that carries the
    # policy, and the error would name a network rule rather than the line that
    # was added.
    #
    # Four changes cleared the way, and each is named below so a reader knows
    # what they would be undoing.

    It 'no tool or install hook calls the storage DATA plane' {
        # STORE-READ-1 part 2 took the person's and the pipeline's data roles.
        # PUBLISH-IN-1 moved the code upload into a Container Apps job.
        # FIND-COPY-1 took out the teardown hook's status read.
        $dataPlane = 'az storage (blob|container|file|fs) |Set-AzStorageBlob|Get-AzStorageBlob|New-AzStorageContainer|New-AzStorageContext'
        $bad = foreach ($dir in @('tools', (Join-Path 'infra' 'hooks'), 'infra')) {
            $root = Join-Path $script:repoRoot $dir
            if (-not (Test-Path $root)) { continue }
            foreach ($f in Get-ChildItem $root -Filter '*.ps1' -File) {
                # CODE ONLY. Deploy-VmfFacade.ps1 still says
                # `az storage blob upload` in a COMMENT, explaining the step
                # PUBLISH-IN-1 removed - and that history is worth keeping.
                $text = Script:Get-CodeOnly -Path $f.FullName
                # The publish job's entrypoint runs INSIDE Azure, which is the
                # whole point of PUBLISH-IN-1 - it is admitted by the rule.
                if ($f.FullName -like '*docker*') { continue }
                foreach ($m in [regex]::Matches($text, $dataPlane)) { "$($f.Name): $($m.Value.Trim())" }
            }
        }
        $bad -join '; ' | Should -BeNullOrEmpty -Because @'
a laptop is never admitted by a subscription inbound rule, so this call fails
on every install into a subscription that closes its storage accounts - and it
fails with a message about network rules that names nothing of ours. Read the
store through the service, the way the dashboard does, or do it from a job
inside Azure, the way the publish does.
'@
    }

    It 'the comment-stripping this file depends on really removes comments' {
        # A check that reads code with comments removed is only as good as the
        # removal. This is why the removal is done by the parser: a trailing
        # comment on a line of code is exactly what somebody writes when they
        # disable something, and it is what a line-based strip keeps.
        $probe = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-code-only-$([guid]::NewGuid()).ps1"
        @'
$kept = 'az storage blob upload'
$disabled = $null # az storage blob upload
# az storage blob upload
$alsoKept = "a hash # inside a string"
'@ | Set-Content $probe -Encoding utf8NoBOM
        try {
            $code = Script:Get-CodeOnly -Path $probe
            @([regex]::Matches($code, 'az storage blob upload')).Count |
                Should -Be 1 -Because 'only the one inside the string literal survives'
            $code | Should -Match 'a hash # inside a string' -Because 'a hash in a string is not a comment'
        }
        finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
    }

    It 'and no dashboard page reaches blob storage from the browser' {
        # STORE-READ-1. A browser is not in a subscription and cannot be
        # admitted by any rule this perimeter can carry.
        $bad = foreach ($f in Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Include '*.html', '*.js' -File -Recurse) {
            $text = Get-Content $f.FullName -Raw
            if ($text -match 'blob\.core\.windows\.net' -or $text -match 'storage\.azure\.com') { $f.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'the service reads the store; the browser reads the service'
    }

    It 'and the publish job that DOES read it runs inside Azure' {
        # The one thing that still writes to the store from a deploy, and it is
        # admitted because it runs as a Container Apps job in the subscription.
        # If this ever moved back to the laptop the perimeter would close on it.
        $publish = Script:Get-CodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1')
        $publish | Should -Match 'containerapp job start'
        $publish | Should -Not -Match 'az storage blob upload'
    }
}
