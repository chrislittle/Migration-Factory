# REPORT-GAP-1: the customer report says what the scan could not read.
#
# The engine records a KEY; the words live here, so the report reads as a
# report and not as a log line. The page has the same words
# (assessment-report.js, notReadHtml).
#
# SCAN-PARTIAL-SUBS-1: a subscription whose sizes were not read is named, with
# Azure's words and how to fix it. Its machines are held, so the line "every
# thing else here is not affected" is not said when one is in the list.

function ConvertTo-VmfNotReadReportHtml {
    <#
    .SYNOPSIS
        The report section for an assessment's notRead list, as HTML. An empty
        string when the scan read everything. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$NotRead)

    $items = @($NotRead | Where-Object { $_ -and $_.PSObject.Properties['subject'] -and [string]$_.subject })
    if (-not $items.Count) { return '' }
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }
    $field = { param($o, [string]$n) if ($o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $hasSizes = [bool]@($items | Where-Object { [string]$_.subject -eq 'sizes' }).Count

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('<h2>What this scan could not read</h2>')
    if ($hasSizes) {
        $null = $sb.AppendLine('<p>The scan finished without these. The machines of a subscription in this list are held until a new assessment reads it.</p><ul>')
    }
    else {
        $null = $sb.AppendLine('<p>The scan finished without these. Everything else here is not affected.</p><ul>')
    }
    foreach ($item in $items) {
        $words = switch ([string]$item.subject) {
            'acceleratedNetworking' {
                'Accelerated networking. This report does not say whether it is on for any machine.'
            }
            # CLUSTER-DETECT-1: the hints that a machine may be a cluster node.
            'clusterHints' {
                'Cluster hints. This report does not say whether a machine may be a cluster node, so no machine is called standalone.'
            }
            # SCAN-PARTIAL-SUBS-1: which subscription, why, and how to fix it.
            'sizes' {
                $count = [int](& $field $item 'machineCount')
                $held = if ($count -eq 1) { '1 machine is held.' } else { "$count machines are held." }
                # Resolve-VmfOperationError already puts the code in front of
                # Azure's words, so the code is said once.
                $code = [string](& $field $item 'errorCode'); $detail = [string](& $field $item 'detail')
                $said = if ($code -and $detail -and -not $detail.Contains($code)) { "$code - $detail" } elseif ($detail) { $detail } else { $code }
                $fix = switch ([string](& $field $item 'reason')) {
                    'permission' {
                        "Azure refused the read. On the Admin page, give the product access to this subscription with the $(& $enc (& $field $item 'requiredRole')) role. That role holds $(& $enc (& $field $item 'requiredAction')). Then start a new assessment."
                    }
                    'subscriptionNotFound' {
                        'Azure cannot find this subscription. Make sure that it exists and that the product has access to it on the Admin page. Then start a new assessment.'
                    }
                    default {
                        'The product tries the read again when a failure is temporary, so this failure stayed. Read what Azure said and correct the cause. Then start a new assessment.'
                    }
                }
                "Sizes in $(& $enc (& $field $item 'location')) for subscription $(& $enc (& $field $item 'subscriptionId')). $held Azure said: $(& $enc $said) $fix"
            }
            default { "The scan could not read this: $(& $enc $item.subject)" }
        }
        $null = $sb.AppendLine("<li>$words</li>")
    }
    $null = $sb.AppendLine('</ul>')
    $sb.ToString()
}
