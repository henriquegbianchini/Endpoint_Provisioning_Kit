<#
.SYNOPSIS
    Endpoint Provisioning Kit
.DESCRIPTION
    Generic modular orchestrator with environment-specific behavior driven by JSON configuration.
#>

param(
    [switch]$Silent,
    [Alias('GenerateHashes','UpdateHashes')]
    [switch]$UpdateHashCatalog,
    [ValidateSet('COMPLETE','APPLY','AUDIT','REPORT','VALIDATE','DRYRUN','HASHES','UPDATEHASHES','GENERATEHASHES','EXIT')]
    [string]$Mode,
    [string]$Sector,
    [string]$Asset,
    [string]$Company,
    [string]$Config,
    [string]$MachineType,
    [switch]$AllowReboot,
    [switch]$AllowDomainJoin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}


function Test-EpkStartupAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-EpkStartupAdmin)) {
    Write-Host '[ERROR] Run as Administrator or start with EndpointProvisioning.bat.' -ForegroundColor Red
    try { Read-Host 'Press ENTER to exit' | Out-Null } catch {}
    exit 740
}

$EpkRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$ModuleRoot = Join-Path $EpkRoot 'Modules'

$ModuleOrder = @(
    'EPK.Config.psm1',
    'EPK.Logging.psm1',
    'EPK.UI.psm1',
    'EPK.System.psm1',
    'EPK.Validation.psm1',
    'EPK.Apps.psm1',
    'EPK.Certificates.psm1',
    'EPK.Hostname.psm1',
    'EPK.Domain.psm1',
    'EPK.Backup.psm1',
    'EPK.Hashes.psm1',
    'EPK.Resume.psm1',
    'EPK.Reports.psm1',
    'EPK.Collection.psm1',
    'EPK.Core.psm1'
)

foreach ($module in $ModuleOrder) {
    $modulePath = Join-Path $ModuleRoot $module
    if (-not (Test-Path -LiteralPath $modulePath)) { throw "Missing module: $modulePath" }
    try {
        Import-Module $modulePath -Force -ErrorAction Stop
    } catch {
        throw ("Failed to import module {0}: {1}" -f $module, $_.Exception.Message)
    }
}

$Context = Initialize-EpkContext -Root $EpkRoot -CompanyProfileName $Company -CompanyConfigPath $Config -MachineType $MachineType
Initialize-EpkFolders -Context $Context

try {
    if ([string]::IsNullOrWhiteSpace($Mode) -and [bool]$UpdateHashCatalog) {
        $Mode = 'UPDATEHASHES'
    } elseif ([bool]$UpdateHashCatalog) {
        $requestedMode = ([string]$Mode).ToUpperInvariant()
        if ($requestedMode -notin @('UPDATEHASHES','GENERATEHASHES')) {
            throw 'Hash catalog updates are allowed only in UPDATEHASHES or GENERATEHASHES modes.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        $Context.Session.Silent = [bool]$Silent
        Show-EpkBanner -Context $Context
        $selected = Show-EpkMenu -Context $Context
        $Mode = [string]$selected.Mode
        if ($Mode.ToUpper() -eq 'EXIT') { exit 0 }
    }

    $Mode = $Mode.ToUpperInvariant()
    if ($Mode -eq 'EXIT') { exit 0 }

    Start-EpkSession -Context $Context -Mode $Mode -Silent:$Silent -DryRun:($Mode -eq 'DRYRUN') -Sector $Sector -Asset $Asset -MachineType $Context.MachineType -AllowReboot:$AllowReboot -AllowDomainJoin:$AllowDomainJoin
    Show-EpkBanner -Context $Context

    $hashUpdateModes = @('UPDATEHASHES','GENERATEHASHES')
    $shouldUpdateHashCatalog = ($Mode -in $hashUpdateModes)

    if ($shouldUpdateHashCatalog) {
        Write-EpkLog -Context $Context -Area 'HASH' -Level 'RUN' -Message 'Hash catalog update requested by operator'
        [void](Update-EpkHashesFile -Context $Context)
    }

    $hashStartModes = @('COMPLETE','APPLY','AUDIT','REPORT','VALIDATE','DRYRUN','HASHES')
    if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'HashValidationAtStartModes') {
        $hashStartModes = @($Context.Settings.Runtime.HashValidationAtStartModes | Where-Object { $_ -notin $hashUpdateModes })
    }
    if ([bool]$Context.Settings.Runtime.ValidateHashes -and (($Mode -in $hashStartModes) -or $shouldUpdateHashCatalog)) {
        [void](Invoke-EpkHashValidation -Context $Context)
    }

    switch ($Mode.ToUpper()) {
        'COMPLETE'       { Invoke-EpkComplete -Context $Context }
        'APPLY'          { Invoke-EpkComplete -Context $Context }
        'AUDIT'          { Invoke-EpkAudit -Context $Context }
        'REPORT'         { Invoke-EpkAudit -Context $Context }
        'VALIDATE'       { Invoke-EpkValidate -Context $Context }
        'HASHES'         { if (-not ($Context.Session.PSObject.Properties.Name -contains 'HashValidationCompleted' -and [bool]$Context.Session.HashValidationCompleted)) { [void](Invoke-EpkHashValidation -Context $Context) } }
        'UPDATEHASHES'   { Write-EpkLog -Context $Context -Area 'HASH' -Level 'OK' -Message 'Hash catalog updated and validated' }
        'GENERATEHASHES' { Write-EpkLog -Context $Context -Area 'HASH' -Level 'OK' -Message 'Hash catalog generated and validated' }
        'DRYRUN'         { Invoke-EpkDryRun -Context $Context }
        default          { throw "Invalid mode: $Mode" }
    }

    [void](Export-EpkReport -Context $Context)
    $evidencePath = Export-EpkEvidencePackage -Context $Context
    if ($evidencePath) { [void](Export-EpkReport -Context $Context -Quiet) }
    Show-EpkSummary -Context $Context
    Open-EpkReportPrompt -Context $Context

    if ($Context.Session.RebootNeeded) {
        Write-EpkLog -Context $Context -Area 'CORE' -Level 'WRN' -Message 'Reboot required to complete changes'
        [void](Invoke-EpkAutoRebootIfNeeded -Context $Context)
    }

    Write-EpkLog -Context $Context -Area 'CORE' -Level 'OK' -Message 'Finished'
}
catch {
    if ([string]::IsNullOrWhiteSpace($Context.Session.LogFile)) {
        Start-EpkSession -Context $Context -Mode 'ERROR' -Silent:$Silent
    }
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'ERR' -Message "Fatal error: $($_.Exception.Message)"
    if ($_.InvocationInfo) {
        Write-EpkLog -Context $Context -Area 'CORE' -Level 'ERR' -Message ("Source: {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
        Write-EpkLog -Context $Context -Area 'CORE' -Level 'ERR' -Message ("Line: {0}" -f ($_.InvocationInfo.Line.Trim()))
    }
    try { [void](Export-EpkReport -Context $Context) } catch {
        Write-EpkLog -Context $Context -Area 'REP' -Level 'ERR' -Message ("Failed to create error report: {0}" -f $_.Exception.Message)
    }
    exit 1
}
