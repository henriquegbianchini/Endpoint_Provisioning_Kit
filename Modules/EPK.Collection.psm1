function New-EpkEvidenceFilePath {
    param([Parameter(Mandatory)]$Context)

    if ([string]::IsNullOrWhiteSpace([string]$Context.Session.EvidenceFile)) {
        $mode = if ([string]::IsNullOrWhiteSpace([string]$Context.Session.Mode)) { 'SESSION' } else { [string]$Context.Session.Mode }
        $profileName = if ([string]::IsNullOrWhiteSpace([string]$Context.CompanyProfileName)) { 'default' } else { [string]$Context.CompanyProfileName }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $dir = [string]$Context.Paths.Evidence
        if ([string]::IsNullOrWhiteSpace($dir)) { $dir = [string]$Context.Paths.Reports }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Context.Session.EvidenceFile = Join-Path $dir ("EVIDENCE_{0}_{1}_{2}.zip" -f $profileName, $mode, $stamp)
    }
    return [string]$Context.Session.EvidenceFile
}

function Export-EpkInstallerMetadata {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Destination)

    $rows = New-Object System.Collections.ArrayList
    $hashes = Get-EpkHashStatus -Context $Context
    foreach ($app in @($Context.Apps)) {
        $id = [string]$app.Id
        $h = $hashes[$id]
        $hashRelativePath = ''
        $absolutePath = ''
        $exists = $false
        $algorithm = ''
        $expectedHash = ''
        $actualHash = ''
        $hashState = 'NOT_EVALUATED'
        $pathMatches = $false
        $fileSizeBytes = $null
        $lastWriteTimeUtc = ''
        if ($h) {
            $hashRelativePath = [string]$h.RelativePath
            $absolutePath = [string]$h.Path
            $exists = [bool]$h.Exists
            $algorithm = [string]$h.Algorithm
            $expectedHash = [string]$h.Expected
            $actualHash = [string]$h.Actual
            $hashState = [string]$h.State
            $pathMatches = [bool]$h.PathMatchesApp
            $fileSizeBytes = $h.FileSizeBytes
            $lastWriteTimeUtc = [string]$h.LastWriteTimeUtc
        }
        [void]$rows.Add([pscustomobject]@{
            AppId = $id
            AppName = [string]$app.Name
            InstallerRelativePath = [string]$app.Installer
            HashRelativePath = $hashRelativePath
            AbsolutePath = $absolutePath
            Exists = $exists
            Algorithm = $algorithm
            ExpectedHash = $expectedHash
            ActualHash = $actualHash
            HashState = $hashState
            PathMatchesAppsJson = $pathMatches
            FileSizeBytes = $fileSizeBytes
            LastWriteTimeUtc = $lastWriteTimeUtc
        })
    }
    $rows | Export-Csv -Path $Destination -NoTypeInformation -Encoding UTF8
}

function Export-EpkEvidencePackage {
    param([Parameter(Mandatory)]$Context)

    if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'CollectEvidencePackage') {
        if (-not [bool]$Context.Settings.Runtime.CollectEvidencePackage) { return $null }
    }

    Show-EpkSection -Context $Context -Code 'REP' -Title 'Technical evidence'
    $zipPath = New-EpkEvidenceFilePath -Context $Context
    $staging = Join-Path ([string]$Context.Paths.Temp) ("evidence_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    try {
        $manifest = [ordered]@{
            Product = [string]$Context.ProductName
            Version = [string]$Context.Settings.Version
            Company = [string]$Context.CompanyName
            CompanyProfile = [string]$Context.CompanyProfileName
            Mode = [string]$Context.Session.Mode
            GeneratedAt = (Get-Date).ToString('s')
            Machine = $env:COMPUTERNAME
            User = $env:USERNAME
            LogFile = [string]$Context.Session.LogFile
            TxtReport = [string]$Context.Session.ReportFile
            HtmlReport = [string]$Context.Session.HtmlFile
            EvidenceFile = [string]$zipPath
            HashValidationCompleted = ($Context.Session.PSObject.Properties.Name -contains 'HashValidationCompleted' -and [bool]$Context.Session.HashValidationCompleted)
            HashValidationStartedAt = [string]$Context.Session.HashValidationStartedAt
            HashValidationFinishedAt = [string]$Context.Session.HashValidationFinishedAt
        }
        ($manifest | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $staging 'manifest.json') -Encoding UTF8

        Export-EpkInstallerMetadata -Context $Context -Destination (Join-Path $staging 'installer_hash_metadata.csv')

        $configOut = Join-Path $staging 'Config'
        New-Item -ItemType Directory -Path $configOut -Force | Out-Null
        foreach ($name in @('company.json','settings.json','apps.json','hashes.json','menu.json','ui.json')) {
            $src = Join-Path ([string]$Context.Paths.Config) $name
            if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination (Join-Path $configOut $name) -Force }
        }

        $assetOut = Join-Path $staging 'Assets'
        New-Item -ItemType Directory -Path $assetOut -Force | Out-Null
        foreach ($name in @('theme.json','banner.txt')) {
            $src = Join-Path ([string]$Context.Paths.Assets) $name
            if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination (Join-Path $assetOut $name) -Force }
        }

        $logOut = Join-Path $staging 'Logs'
        New-Item -ItemType Directory -Path $logOut -Force | Out-Null
        if (-not [string]::IsNullOrWhiteSpace([string]$Context.Session.LogFile) -and (Test-Path -LiteralPath $Context.Session.LogFile -PathType Leaf)) {
            Copy-Item -LiteralPath $Context.Session.LogFile -Destination $logOut -Force
        }

        $reportOut = Join-Path $staging 'Reports'
        New-Item -ItemType Directory -Path $reportOut -Force | Out-Null
        foreach ($reportPath in @([string]$Context.Session.ReportFile, [string]$Context.Session.HtmlFile)) {
            if (-not [string]::IsNullOrWhiteSpace($reportPath) -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
                Copy-Item -LiteralPath $reportPath -Destination $reportOut -Force
            }
        }

        if (Test-Path -LiteralPath $zipPath -PathType Leaf) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -Force
        Write-EpkLog -Context $Context -Area 'REP' -Level 'OK' -Message ("Technical evidence generated: {0}" -f $zipPath)
        Add-EpkAction -Context $Context -Text ("Technical evidence generated: {0}" -f $zipPath)
        return $zipPath
    }
    catch {
        Write-EpkLog -Context $Context -Area 'REP' -Level 'ERR' -Message ("Failed to generate technical evidence: {0}" -f $_.Exception.Message)
        return $null
    }
    finally {
        try { if (Test-Path -LiteralPath $staging -PathType Container) { Remove-Item -LiteralPath $staging -Recurse -Force } } catch {}
    }
}

Export-ModuleMember -Function New-EpkEvidenceFilePath, Export-EpkInstallerMetadata, Export-EpkEvidencePackage
