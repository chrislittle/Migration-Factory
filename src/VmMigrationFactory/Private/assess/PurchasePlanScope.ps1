# NO-PLAN-SCOPE-1 (1.0), 2026-11-03: the product does not move any third-party
# image. A machine with a Marketplace purchase plan is
# outside the scope of this tool. The rule is "has a plan", never "the
# publisher is not Microsoft": the endorsed distributions' standard images
# carry no plan and stay in scope, and their editions sold with a plan (Ubuntu
# Pro, RHEL BYOS, the SUSE offers whose name ends in -llc) are out of scope
# for 1.0, because no edition with a plan was ever tested (ruling, the
# same day, after the sweep of every supported publisher's images in the item).
#
# One rule, used by the scan (Get-VmfAssessmentRecord) and by Checking
# (Get-VmfWorkloadScopeStop, Add-VmfDiskEncryptionFacts), so the two cannot
# disagree. A network virtual appliance, a storage appliance and a machine in a
# managed application keep their own reason: each says more than "a plan".

function ConvertTo-VmfPurchasePlan {
    <#
    .SYNOPSIS
        A Marketplace purchase plan, from a machine's Plan or a disk's
        purchasePlan, as @{ name; publisher; product }. $null when there is
        none. Pure.
    .DESCRIPTION
        Azure names the fields name, publisher and product on a machine and on
        a disk, in either case. Any one of them, not blank, is a plan.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Plan)
    if (-not $Plan) { return $null }
    $get = { param($n) if ($Plan -is [System.Collections.IDictionary]) { $Plan[$n] } elseif ($Plan.PSObject.Properties[$n]) { $Plan.$n } else { $null } }
    $name = ([string](& $get 'name')).Trim(); $publisher = ([string](& $get 'publisher')).Trim(); $product = ([string](& $get 'product')).Trim()
    if (-not $name -and -not $publisher -and -not $product) { return $null }
    [ordered]@{ name = $name; publisher = $publisher; product = $product }
}

function Get-VmfPurchasePlanEvidence {
    <#
    .SYNOPSIS
        The evidence that a machine or a disk has a Marketplace purchase plan,
        or $null when it has none. Pure.
    .OUTPUTS
        @{ Evidence = @( @{ field; value } ); Words = "plan.publisher 'x', plan.product 'y', plan.name 'z'" }
        Only the fields Azure gave are named.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Plan)
    $p = ConvertTo-VmfPurchasePlan -Plan $Plan
    if (-not $p) { return $null }
    $evidence = @(foreach ($n in 'publisher', 'product', 'name') {
            if ($p[$n]) { @{ field = "plan.$n"; value = $p[$n] } }
        })
    @{ Evidence = $evidence; Words = (@($evidence | ForEach-Object { "$($_.field) '$($_.value)'" }) -join ', ') }
}
