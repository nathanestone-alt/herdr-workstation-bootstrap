$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrFirewallPolicy.ps1')

$cases = @(
    @{ Name = 'explicit 445'; Expected = $true; Protocol = 'TCP'; Port = @('445'); Program = @('spoolsv.exe'); Service = @('Spooler') },
    @{ Name = 'range including 445'; Expected = $true; Protocol = 6; Port = @('400-500'); Program = @('app.exe'); Service = @('Other') },
    @{ Name = 'broad System rule'; Expected = $true; Protocol = 'TCP'; Port = @('Any'); Program = @('System'); Service = @('Any') },
    @{ Name = 'broad LanmanServer rule'; Expected = $true; Protocol = 'TCP'; Port = @('Any'); Program = @('Any'); Service = @('LanmanServer') },
    @{ Name = 'program-scoped unrelated rule'; Expected = $false; Protocol = 'TCP'; Port = @('Any'); Program = @('spoolsv.exe'); Service = @('Any') },
    @{ Name = 'service-scoped unrelated System rule'; Expected = $false; Protocol = 'TCP'; Port = @('Any'); Program = @('System'); Service = @('WFD') },
    @{ Name = 'UDP Any System'; Expected = $false; Protocol = 'UDP'; Port = @('Any'); Program = @('System'); Service = @('Any') }
)
foreach ($case in $cases) {
    $actual = Test-HerdrFirewallFilterExposesSmb -Protocol $case.Protocol -LocalPort $case.Port -Program $case.Program -Service $case.Service
    if ($actual -ne $case.Expected) {
        throw "Firewall fixture '$($case.Name)' expected $($case.Expected), received $actual."
    }
}
Write-Host 'Firewall SMB exposure policy tests passed.'
