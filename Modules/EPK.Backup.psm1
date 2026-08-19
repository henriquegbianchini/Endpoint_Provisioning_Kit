function Invoke-EpkBackupRotation {
    param([Parameter(Mandatory)]$Context)

    $max = [int]$Context.Settings.Runtime.MaxBackups
    if ($max -le 0) { return }

    $dirs = @(Get-ChildItem -Path $Context.Paths.Backup -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($dirs.Count -le $max) { return }

    $dirs | Select-Object -Skip $max | ForEach-Object {
        try { Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
    }
}

function Invoke-EpkBackup {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'BKP' -Title 'Local backup'

    if ($Context.Session.DryRun) {
        Write-EpkLog -Context $Context -Area 'BKP' -Level 'TODO' -Message 'Backup would be created'
        return $null
    }

    Invoke-EpkBackupRotation -Context $Context

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupDir = Join-Path $Context.Paths.Backup $stamp
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    try {
        $sysOut = & systeminfo 2>&1
        $sysOut | Out-File -FilePath (Join-Path $backupDir 'systeminfo.txt') -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { Write-EpkLog -Context $Context -Area 'BKP' -Level 'WRN' -Message 'systeminfo returned a warning' }
    } catch {
        Write-EpkLog -Context $Context -Area 'BKP' -Level 'WRN' -Message 'systeminfo failed'
    }
    try { Get-Service | Select-Object Name,Status,DisplayName | Export-Csv -Path (Join-Path $backupDir 'services.csv') -NoTypeInformation -Encoding UTF8 } catch {}
    try {
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Select-Object DisplayName,DisplayVersion,Publisher,InstallDate |
            Export-Csv -Path (Join-Path $backupDir 'installed_apps.csv') -NoTypeInformation -Encoding UTF8
    } catch {}
    try {
        Get-ChildItem Cert:\LocalMachine\Root |
            Select-Object Subject,Issuer,Thumbprint,NotAfter |
            Export-Csv -Path (Join-Path $backupDir 'certificates_root.csv') -NoTypeInformation -Encoding UTF8
    } catch {}

    Write-EpkLog -Context $Context -Area 'BKP' -Level 'OK' -Message 'Backup created'
    Add-EpkAction -Context $Context -Text "Backup criado: $backupDir"
    return $backupDir
}

Export-ModuleMember -Function Invoke-EpkBackupRotation, Invoke-EpkBackup
