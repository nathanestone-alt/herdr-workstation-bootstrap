function Test-HerdrFirewallFilterExposesSmb {
    [CmdletBinding()]
    param(
        [object]$Protocol,
        [object[]]$LocalPort,
        [string[]]$Program,
        [string[]]$Service
    )
    if ($Protocol -notin @('TCP', 6)) { return $false }
    foreach ($portExpression in @($LocalPort)) {
        $text = [string]$portExpression
        if ($text -eq '445') { return $true }
        if ($text -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le 445 -and [int]$Matches[2] -ge 445) {
            return $true
        }
    }
    $hasAnyPort = @($LocalPort | Where-Object { [string]$_ -eq 'Any' }).Count -gt 0
    $programCanReachSmb = @($Program | Where-Object { $_ -in @('Any', 'System') }).Count -gt 0
    $serviceCanReachSmb = @($Service | Where-Object { $_ -in @('Any', 'LanmanServer') }).Count -gt 0
    return $hasAnyPort -and $programCanReachSmb -and $serviceCanReachSmb
}
