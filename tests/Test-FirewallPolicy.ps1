$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrFirewallPolicy.ps1')

$cases = @(
    @{ Name = 'explicit 445'; Expected = $true; Protocol = 'TCP'; Port = @('445'); Program = @('spoolsv.exe'); Service = @('Spooler'); Owner = @() },
    @{ Name = 'range including 445'; Expected = $true; Protocol = 6; Port = @('400-500'); Program = @('app.exe'); Service = @('Other'); Owner = @() },
    @{ Name = 'broad System rule'; Expected = $true; Protocol = 'TCP'; Port = @('Any'); Program = @('System'); Service = @('Any'); Owner = @() },
    @{ Name = 'broad LanmanServer rule'; Expected = $true; Protocol = 'TCP'; Port = @('Any'); Program = @('Any'); Service = @('LanmanServer'); Owner = @() },
    @{ Name = 'unscoped Any protocol'; Expected = $true; Protocol = 'Any'; Port = @('Any'); Program = @('Any'); Service = @('Any'); Owner = @() },
    @{ Name = 'owner-scoped Any protocol'; Expected = $false; Protocol = 'Any'; Port = @('Any'); Program = @('Any'); Service = @('Any'); Owner = @('S-1-5-21-1') },
    @{ Name = 'program-scoped unrelated rule'; Expected = $false; Protocol = 'TCP'; Port = @('Any'); Program = @('spoolsv.exe'); Service = @('Any'); Owner = @() },
    @{ Name = 'service-scoped unrelated System rule'; Expected = $false; Protocol = 'TCP'; Port = @('Any'); Program = @('System'); Service = @('WFD'); Owner = @() },
    @{ Name = 'UDP Any System'; Expected = $false; Protocol = 'UDP'; Port = @('Any'); Program = @('System'); Service = @('Any'); Owner = @() }
)
foreach ($case in $cases) {
    $actual = Test-HerdrFirewallFilterExposesSmb -Protocol $case.Protocol -LocalPort $case.Port -Program $case.Program -Service $case.Service -Owner $case.Owner
    if ($actual -ne $case.Expected) {
        throw "Firewall fixture '$($case.Name)' expected $($case.Expected), received $actual."
    }
}
if (-not (Test-HerdrFirewallAddressScopeIsTailnetOnly -Address @('100.122.212.104'))) {
    throw 'A Tailscale IPv4 host address must be accepted as tailnet-confined.'
}
if (-not (Test-HerdrFirewallAddressScopeIsTailnetOnly -Address @('fd7a:115c:a1e0::d537:d468'))) {
    throw 'A Tailscale IPv6 host address must be accepted as tailnet-confined.'
}
if (Test-HerdrFirewallAddressScopeIsTailnetOnly -Address @('Any')) {
    throw 'An Any address scope must not be accepted as tailnet-confined.'
}
if (Test-HerdrFirewallAddressScopeIsTailnetOnly -Address @('192.168.1.0/24')) {
    throw 'A LAN subnet must not be accepted as tailnet-confined.'
}
Write-Host 'Firewall SMB exposure policy tests passed.'
