function Test-HerdrFirewallFilterExposesSmb {
    [CmdletBinding()]
    param(
        [object]$Protocol,
        [object[]]$LocalPort,
        [string[]]$Program,
        [string[]]$Service,
        [string[]]$Owner = @()
    )
    $isTcp = $Protocol -in @('TCP', 6)
    $isAnyProtocol = [string]$Protocol -eq 'Any'
    if (-not $isTcp -and -not $isAnyProtocol) { return $false }
    if ($isAnyProtocol -and @($Owner | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        return $false
    }
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

function Test-HerdrIpAddressInCidr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Address,
        [Parameter(Mandatory)] [string]$Cidr
    )
    try {
        $candidateParts = $Address -split '/', 2
        $networkParts = $Cidr -split '/', 2
        $candidateIp = [Net.IPAddress]::Parse($candidateParts[0])
        $networkIp = [Net.IPAddress]::Parse($networkParts[0])
        if ($candidateIp.AddressFamily -ne $networkIp.AddressFamily) { return $false }
        $bitLength = $networkIp.GetAddressBytes().Length * 8
        $candidatePrefix = if ($candidateParts.Count -eq 2) { [int]$candidateParts[1] } else { $bitLength }
        $networkPrefix = if ($networkParts.Count -eq 2) { [int]$networkParts[1] } else { $bitLength }
        if ($candidatePrefix -lt $networkPrefix -or $candidatePrefix -gt $bitLength -or $networkPrefix -gt $bitLength) {
            return $false
        }
        $candidateBytes = $candidateIp.GetAddressBytes()
        $networkBytes = $networkIp.GetAddressBytes()
        for ($bit = 0; $bit -lt $networkPrefix; $bit++) {
            $mask = 1 -shl (7 - ($bit % 8))
            $byteIndex = $bit -shr 3
            if (($candidateBytes[$byteIndex] -band $mask) -ne ($networkBytes[$byteIndex] -band $mask)) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Test-HerdrFirewallAddressScopeIsTailnetOnly {
    [CmdletBinding()]
    param(
        [object[]]$Address,
        [string[]]$TailnetCidr = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')
    )
    $addresses = @($Address | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($addresses.Count -eq 0 -or 'Any' -in $addresses) { return $false }
    foreach ($candidate in $addresses) {
        if (@($TailnetCidr | Where-Object { Test-HerdrIpAddressInCidr -Address $candidate -Cidr $_ }).Count -eq 0) {
            return $false
        }
    }
    return $true
}
