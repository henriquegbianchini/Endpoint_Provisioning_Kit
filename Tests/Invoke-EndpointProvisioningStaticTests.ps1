[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot

function Assert-EpkStatic {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Write-EpkStaticOk {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "OK: $Message" -ForegroundColor Green
}

$jsonFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Extension -ieq '.json' })
foreach ($file in $jsonFiles) {
    try {
        Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
        Write-EpkStaticOk "JSON parseable: $($file.FullName)"
    }
    catch {
        throw "Invalid JSON: $($file.FullName). $($_.Exception.Message)"
    }
}

$psFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors.Count -gt 0) {
        $errors | Format-List | Out-String | Write-Host
        throw "PowerShell parser error: $($file.FullName)"
    }

    Write-EpkStaticOk "PowerShell parseable: $($file.FullName)"
}

Import-Module (Join-Path $Root 'Modules/EPK.Config.psm1') -Force

$mainContext = Initialize-EpkContext -Root $Root -CompanyConfigPath 'Config/company.json' -MachineType 'NOTE'
Assert-EpkStatic -Condition (-not [bool]$mainContext.DomainEnabled) -Message 'Public profile must not require Active Directory'
Assert-EpkStatic -Condition (@($mainContext.Apps).Count -eq 0) -Message 'Public profile must not install applications by default'
Assert-EpkStatic -Condition ($mainContext.MachineType -eq 'NOTE') -Message 'MachineType NOTE was not applied'
Assert-EpkStatic -Condition ($mainContext.HostnameAllowedTypes -contains 'NOTE') -Message 'AllowedTypes does not contain NOTE'
Write-EpkStaticOk 'Public profile is local-safe'

$adProfile = Get-Content -LiteralPath (Join-Path $Root 'Config/Examples/active-directory.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-EpkStatic -Condition (-not [bool]$adProfile.Domain.Enabled) -Message 'AD example must ship disabled'
Assert-EpkStatic -Condition (-not [bool]$adProfile.Domain.Join.Enabled) -Message 'AD join example must ship disabled'
Assert-EpkStatic -Condition ([string]$adProfile.Domain.Name -match '\.invalid$') -Message 'AD example must use a reserved placeholder domain'
Write-EpkStaticOk 'AD example is inert by default'

foreach ($profilePath in @('Config/Examples/workgroup.example.json', 'Config/Examples/active-directory.example.json')) {
    $context = Initialize-EpkContext -Root $Root -CompanyConfigPath $profilePath -MachineType 'NOTE'
    Assert-EpkStatic -Condition ($context.MachineType -eq 'NOTE') -Message "MachineType NOTE not applied in $profilePath"
    Write-EpkStaticOk "Profile load: $profilePath"
}

$invalidBlocked = $false
try {
    Initialize-EpkContext -Root $Root -CompanyConfigPath 'Config/company.json' -MachineType 'INVALID' | Out-Null
}
catch {
    $invalidBlocked = $true
}
Assert-EpkStatic -Condition $invalidBlocked -Message 'Invalid MachineType was not blocked'
Write-EpkStaticOk 'Invalid MachineType blocked'

$privatePayloadExtensions = @('.exe', '.msi', '.msix', '.msixbundle', '.pfx', '.p12', '.pem', '.key', '.cer', '.crt')
$privatePayloads = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object { $_.Extension.ToLowerInvariant() -in $privatePayloadExtensions }
)
$privatePayloadNames = @($privatePayloads | ForEach-Object { $_.FullName })
Assert-EpkStatic -Condition ($privatePayloads.Count -eq 0) -Message ('Private/binary payloads found: ' + ($privatePayloadNames -join '; '))
Write-EpkStaticOk 'No installer or certificate payloads committed'

$gitIgnore = Get-Content -LiteralPath (Join-Path $Root '.gitignore') -Raw -Encoding UTF8
Assert-EpkStatic -Condition ($gitIgnore -match 'Config/company\.local\.json') -Message 'Local company profile is not ignored by Git'
Write-EpkStaticOk 'Environment-specific profile is ignored by Git'

if (Test-Path -LiteralPath (Join-Path $Root '.git') -PathType Container) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $diffCheck = & git -C $Root diff --check 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference

    if ($exitCode -ne 0) {
        throw "git diff --check failed: $(($diffCheck | Out-String).Trim())"
    }

    Write-EpkStaticOk 'git diff --check'
}

Write-Host 'Endpoint Provisioning Kit static tests completed successfully.' -ForegroundColor Green
