function Start-EpkSession {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Mode,
        [switch]$Silent,
        [switch]$DryRun,
        [string]$Sector = '',
        [string]$Asset = '',
        [string]$MachineType = '',
        [switch]$AllowReboot,
        [switch]$AllowDomainJoin
    )

    Initialize-EpkFolders -Context $Context

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $profileName = 'default'
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$Context.CompanyProfileName)) { $profileName = [string]$Context.CompanyProfileName }
    } catch {}
    $Context.Session = New-EpkSession
    $Context.Session.Mode = $Mode
    $Context.Session.Silent = [bool]$Silent
    $Context.Session.DryRun = [bool]$DryRun
    $Context.Session.AllowReboot = [bool]$AllowReboot
    $Context.Session.AllowDomainJoin = [bool]$AllowDomainJoin
    $Context.Session.Sector = $Sector
    $Context.Session.Asset = $Asset
    $Context.Session.MachineType = $MachineType
    $Context.Session.LogFile = Join-Path $Context.Paths.Logs ("{0}_{1}_{2}.log" -f $profileName, $Mode, $stamp)
    $Context.Session.ReportFile = Join-Path $Context.Paths.Reports ("{0}_{1}_{2}.txt" -f $profileName, $Mode, $stamp)
    $Context.Session.HtmlFile = Join-Path $Context.Paths.Reports ("{0}_{1}_{2}.html" -f $profileName, $Mode, $stamp)

    New-Item -ItemType File -Path $Context.Session.LogFile -Force | Out-Null
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'RUN' -Message "Session started: $Mode"
}

function Add-EpkAction {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Text
    )

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $Context.Session.Actions.Add($Text) | Out-Null
    }
}

function Get-EpkLogColor {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Level
    )

    try {
        $value = $Context.Theme.ConsoleColors.$Level
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    catch {}

    switch ($Level) {
        'OK'   { return 'Green' }
        'WRN'  { return 'Yellow' }
        'ERR'  { return 'Red' }
        'TODO' { return 'Yellow' }
        default { return 'Gray' }
    }
}

function Write-EpkLog {
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateSet('OK','RUN','TODO','WRN','ERR')][string]$Level = 'RUN',
        [string]$Area = 'CORE',
        [Parameter(Mandatory)][string]$Message
    )

    $Context.Session.Counter++
    $eventCode = '{0}-{1:D3}' -f $Area, $Context.Session.Counter
    $fileLine = '[{0}] [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $eventCode, $Message

    if (-not [string]::IsNullOrWhiteSpace($Context.Session.LogFile)) {
        try {
            Add-Content -Path $Context.Session.LogFile -Value $fileLine -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # Logging failures must not stop provisioning.
        }
    }

    if (-not $Context.Session.Silent) {
        $screenMessage = $Message -replace ' ([A-Za-z]:\\|\\\\).*$', ''
        $line = '  {0,-4} {1,-9} {2}' -f $Level, $eventCode, $screenMessage
        Write-Host $line -ForegroundColor (Get-EpkLogColor -Context $Context -Level $Level)
    }
}

Export-ModuleMember -Function Start-EpkSession, Add-EpkAction, Get-EpkLogColor, Write-EpkLog
