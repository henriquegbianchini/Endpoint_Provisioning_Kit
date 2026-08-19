function Get-EpkCachedAppStatus {
    param([Parameter(Mandatory)]$Context)
    return (Get-EpkAppStatus -Context $Context -Refresh)
}

function Get-EpkCachedCertificateStatus {
    param([Parameter(Mandatory)]$Context)
    return (Get-EpkCertificateStatus -Context $Context)
}

function Export-EpkReport {
    param(
        [Parameter(Mandatory)]$Context,
        [switch]$Quiet
    )

    if (-not $Quiet) { Show-EpkSection -Context $Context -Code 'REP' -Title 'Report' }

    $sys = Get-EpkSystemInfo
    $hw = Get-EpkHardwareInfo
    $apps = Get-EpkCachedAppStatus -Context $Context
    $certs = Get-EpkCachedCertificateStatus -Context $Context
    $hashes = Get-EpkHashStatus -Context $Context
    $domain = Get-EpkDomainStatus -Context $Context
    if ($Context.Session.PSObject.Properties.Name -notcontains 'HashStatusCache') {
        Add-Member -InputObject $Context.Session -NotePropertyName 'HashStatusCache' -NotePropertyValue $null -Force
    }
    $Context.Session.HashStatusCache = $hashes
    if ($Context.Session.PSObject.Properties.Name -contains 'EvidenceFile') {
        if ([string]::IsNullOrWhiteSpace([string]$Context.Session.EvidenceFile)) {
            $evidenceDir = [string]$Context.Paths.Evidence
            if ([string]::IsNullOrWhiteSpace($evidenceDir)) { $evidenceDir = [string]$Context.Paths.Reports }
            $profileName = if ([string]::IsNullOrWhiteSpace([string]$Context.CompanyProfileName)) { 'default' } else { [string]$Context.CompanyProfileName }
            $Context.Session.EvidenceFile = Join-Path $evidenceDir ("EVIDENCE_{0}_{1}_{2}.zip" -f $profileName, $Context.Session.Mode, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        }
    }
    $duration = New-TimeSpan -Start $Context.Session.StartTime -End (Get-Date)

    $appOk = @($apps.Keys | Where-Object { $apps[$_].Installed }).Count
    $appTotal = @($apps.Keys).Count
    $certOk = @($certs.Keys | Where-Object { $certs[$_] }).Count
    $certTotal = @($certs.Keys).Count
    $hashOk = @($hashes.Keys | Where-Object { $hashes[$_].State -eq 'OK' }).Count
    $hashTotal = @($hashes.Keys).Count
    $hashValidationCompleted = ($Context.Session.PSObject.Properties.Name -contains 'HashValidationCompleted' -and [bool]$Context.Session.HashValidationCompleted)
    $hashStatusEvaluated = ($hashTotal -gt 0)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('============================================================')
    [void]$lines.Add([string]$Context.ReportTitle)
    [void]$lines.Add('============================================================')
    [void]$lines.Add("Mode              : $($Context.Session.Mode)")
    [void]$lines.Add("Generated at      : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
    [void]$lines.Add("Duration          : $($duration.ToString())")
    [void]$lines.Add("Version           : $($Context.Settings.Version)")
    [void]$lines.Add("Product           : $($Context.ProductName)")
    [void]$lines.Add("Company           : $($Context.CompanyName)")
    [void]$lines.Add("Company profile   : $($Context.CompanyProfileName)")
    [void]$lines.Add("Expected target   : $($domain.TargetType) $($domain.Expected)")
    [void]$lines.Add('')
    [void]$lines.Add('SUMMARY')
    [void]$lines.Add("Apps              : $appOk/$appTotal")
    [void]$lines.Add("Certificates      : $certOk/$certTotal")
    [void]$lines.Add("Hashes            : $hashOk/$hashTotal")
    [void]$lines.Add("Hashes at start   : $hashValidationCompleted")
    [void]$lines.Add("Hash start at     : $($Context.Session.HashValidationStartedAt)")
    [void]$lines.Add("Hash finished at  : $($Context.Session.HashValidationFinishedAt)")
    [void]$lines.Add("Hashes at end     : $hashStatusEvaluated")
    [void]$lines.Add("Validate hashes   : $($Context.Settings.Runtime.ValidateHashes)")
    [void]$lines.Add("Block by hash     : $($Context.Settings.Runtime.BlockInstallOnHashError)")
    [void]$lines.Add("Reboot required   : $($Context.Session.RebootNeeded)")
    [void]$lines.Add("Technical evidence: $($Context.Session.EvidenceFile)")
    [void]$lines.Add('')
    [void]$lines.Add('SYSTEM')
    [void]$lines.Add("Hostname          : $($sys.Hostname)")
    if ([string]::IsNullOrWhiteSpace($Context.Session.DesiredHost) -and $Context.Session.Mode -in @('COMPLETE','APPLY','HOSTNAME')) {
        [void]$lines.Add("Hostname status   : NOT CONFIGURED / SKIPPED")
    }
    if ($Context.Session.PSObject.Properties.Name -contains 'DesiredHostRejected' -and -not [string]::IsNullOrWhiteSpace($Context.Session.DesiredHostRejected)) {
        [void]$lines.Add("Rejected hostname: $($Context.Session.DesiredHostRejected)")
    }
    if ($Context.Session.DesiredHost) { $lines.Add("Desired hostname : $($Context.Session.DesiredHost)") }
    [void]$lines.Add("Domain/workgroup  : $($sys.Domain)")
    [void]$lines.Add("Part of AD domain : $($sys.PartOfDomain)")
    [void]$lines.Add("Expected target   : $($domain.TargetType) $($domain.Expected)")
    [void]$lines.Add("Target status     : $($domain.Status)")
    [void]$lines.Add("IP                : $($sys.IP)")
    [void]$lines.Add("User              : $($sys.User)")
    [void]$lines.Add('')
    [void]$lines.Add('HARDWARE')
    [void]$lines.Add("Serial            : $($hw.Serial)")
    [void]$lines.Add("CPU               : $($hw.CPU)")
    [void]$lines.Add("RAM               : $($hw.RAM)")
    [void]$lines.Add("Disk              : $($hw.Disk)")
    [void]$lines.Add('')
    [void]$lines.Add('APPLICATIONS')
    foreach ($key in @($apps.Keys)) {
        $status = if ($apps[$key].Installed) { 'OK' } else { 'PENDING' }
        [void]$lines.Add(("{0,-18}: {1}" -f $key, $status))
    }
    [void]$lines.Add('')
    [void]$lines.Add('HASHES')
    foreach ($key in @($hashes.Keys)) {
        $item = $hashes[$key]
        $actualShort = if ([string]::IsNullOrWhiteSpace($item.Actual)) { '-' } else { $item.Actual.Substring(0, [Math]::Min(12, $item.Actual.Length)) + '...' }
        $expectedShort = if ([string]::IsNullOrWhiteSpace($item.Expected)) { '-' } else { $item.Expected.Substring(0, [Math]::Min(12, $item.Expected.Length)) + '...' }
        $pathNote = if ($item.PathMatchesApp) { '' } else { ' | PATH_DIFFERS_FROM_APPS_JSON' }
        [void]$lines.Add(("{0,-18}: {1} | {2} | expected={3} | current={4}{5}" -f $item.AppName, $item.State, $item.Algorithm, $expectedShort, $actualShort, $pathNote))
        [void]$lines.Add(("{0,-18}  path: {1}" -f '', $item.Path))
        [void]$lines.Add(("{0,-18}  size: {1}; modifiedUTC: {2}" -f '', $item.FileSizeBytes, $item.LastWriteTimeUtc))
    }
    [void]$lines.Add('')
    if ($Context.Session.PSObject.Properties.Name -contains 'HashCatalogIssues' -and @($Context.Session.HashCatalogIssues).Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('HASH CATALOG ALIGNMENT')
        foreach ($issue in @($Context.Session.HashCatalogIssues)) {
            [void]$lines.Add(("{0}: {1} - {2}" -f [string]$issue.Type, [string]$issue.Id, [string]$issue.Message))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('CERTIFICATES')
    if ($certTotal -eq 0) {
        [void]$lines.Add('No certificate files found')
    } else {
        foreach ($key in @($certs.Keys)) {
            $status = if ($certs[$key]) { 'OK' } else { 'PENDING' }
            [void]$lines.Add(("{0}: {1}" -f $key, $status))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('PENDING ITEMS')
    $pending = $null
    if ($Context.Session.PSObject.Properties.Name -contains 'PendingItems') { $pending = $Context.Session.PendingItems }
    if ($pending) {
        $pendingTotal = @($pending.Apps).Count + @($pending.Certificates).Count
        if ($pending.Hostname) { $pendingTotal++ }
        [void]$lines.Add(("Correctable total: {0}" -f $pendingTotal))
        foreach ($p in @($pending.Apps)) { [void]$lines.Add(("APP  - {0}: {1}; installer={2}" -f [string]$p.Name, [string]$p.Reason, [bool]$p.InstallerExists)) }
        foreach ($p in @($pending.Certificates)) { [void]$lines.Add(("CERT - {0}: {1}" -f [string]$p.Name, [string]$p.Reason)) }
        if (@($pending.Hashes).Count -gt 0) { [void]$lines.Add(("Hash alerts     : {0}" -f @($pending.Hashes).Count)) }
        foreach ($p in @($pending.Hashes)) { [void]$lines.Add(("HASH - {0}: {1}" -f [string]$p.AppName, [string]$p.State)) }
        if ($pending.Hostname) { [void]$lines.Add(("HOST - current={0}; desired={1}" -f [string]$pending.Hostname.Current, [string]$pending.Hostname.Desired)) }
    } else {
        [void]$lines.Add('Pending items were not calculated in this session')
    }
    [void]$lines.Add('')
    [void]$lines.Add('ACTIONS')
    if ($Context.Session.Actions.Count -eq 0) {
        [void]$lines.Add('No action registered')
    } else {
        foreach ($action in @($Context.Session.Actions)) { $lines.Add("- $action") }
    }
    [void]$lines.Add('')
    [void]$lines.Add("Log               : $($Context.Session.LogFile)")
    [void]$lines.Add('============================================================')

    if ([bool]$Context.Settings.Runtime.GenerateTxtReport) {
        $lines | Set-Content -Path $Context.Session.ReportFile -Encoding UTF8
        if (-not $Quiet) { Write-EpkLog -Context $Context -Area 'REP' -Level 'OK' -Message 'TXT generated' }
    }

    if ([bool]$Context.Settings.Runtime.GenerateHtmlReport) {
        $safe = [System.Net.WebUtility]::HtmlEncode(($lines -join "`r`n"))
        $logText = [System.Net.WebUtility]::HtmlEncode($Context.Session.LogFile)
        $htmlTitle = [System.Net.WebUtility]::HtmlEncode([string]$Context.ReportTitle)
        $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$htmlTitle</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#0f172a;color:#e5e7eb;padding:32px}
.card{max-width:1100px;margin:auto;background:#111827;border:1px solid #334155;border-radius:18px;padding:28px}
h1{color:#38bdf8;margin-top:0}
pre{white-space:pre-wrap;background:#020617;border-radius:12px;padding:18px}
.log{background:#1e293b;border-radius:10px;padding:10px 14px;color:#cbd5e1}
</style>
</head>
<body>
<div class="card">
<h1>$htmlTitle</h1>
<p class="log"><strong>Log:</strong> $logText</p>
<pre>$safe</pre>
</div>
</body>
</html>
"@
        $html | Set-Content -Path $Context.Session.HtmlFile -Encoding UTF8
        if (-not $Quiet) { Write-EpkLog -Context $Context -Area 'REP' -Level 'OK' -Message 'HTML generated' }
    }

    return $Context.Session.ReportFile
}

function Show-EpkSummary {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'REP' -Title 'Final summary'

    $apps = Get-EpkCachedAppStatus -Context $Context
    $certs = Get-EpkCachedCertificateStatus -Context $Context
    $hashes = Get-EpkHashStatus -Context $Context
    if ($Context.Session.PSObject.Properties.Name -contains 'HashStatusCache') { $Context.Session.HashStatusCache = $hashes }
    $appOk = @($apps.Keys | Where-Object { $apps[$_].Installed }).Count
    $appTotal = @($apps.Keys).Count
    $certOk = @($certs.Keys | Where-Object { $certs[$_] }).Count
    $certTotal = @($certs.Keys).Count
    $hashOk = @($hashes.Keys | Where-Object { $hashes[$_].State -eq 'OK' }).Count
    $hashTotal = @($hashes.Keys).Count

    Write-EpkLog -Context $Context -Area 'REP' -Level 'OK' -Message "Apps: $appOk/$appTotal"
    Write-EpkLog -Context $Context -Area 'REP' -Level 'OK' -Message "Certificates: $certOk/$certTotal"
    Write-EpkLog -Context $Context -Area 'REP' -Level 'OK' -Message "Hashes: $hashOk/$hashTotal"
    $level = if ($Context.Session.RebootNeeded) { 'WRN' } else { 'OK' }
    Write-EpkLog -Context $Context -Area 'REP' -Level $level -Message ("Reboot: {0}" -f $Context.Session.RebootNeeded)
    if ($Context.Session.PSObject.Properties.Name -contains 'EvidenceFile' -and -not [string]::IsNullOrWhiteSpace([string]$Context.Session.EvidenceFile)) {
        Write-EpkLog -Context $Context -Area 'REP' -Level 'OK' -Message ("Evidence: {0}" -f $Context.Session.EvidenceFile)
    }
}

function Open-EpkReportPrompt {
    param([Parameter(Mandatory)]$Context)

    if ($Context.Session.Silent) { return }
    if (-not [bool]$Context.Settings.Runtime.OpenReportFileAtEnd) { return }

    $target = $null
    if (Test-Path $Context.Session.HtmlFile -PathType Leaf) {
        $target = $Context.Session.HtmlFile
    } elseif (Test-Path $Context.Session.ReportFile -PathType Leaf) {
        $target = $Context.Session.ReportFile
    }

    if (-not $target) { return }

    $open = Read-Host 'Open report? [Y/N]'
    if ($open.Trim().ToUpper() -eq 'Y') {
        Start-Process $target
    }
}

Export-ModuleMember -Function Get-EpkCachedAppStatus, Get-EpkCachedCertificateStatus, Export-EpkReport, Show-EpkSummary, Open-EpkReportPrompt
