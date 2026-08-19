function Get-EpkInstallerPath {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$App,
        [string]$InstallerOverride = ''
    )

    $candidates = New-Object System.Collections.ArrayList
    $relativeInstaller = if ([string]::IsNullOrWhiteSpace($InstallerOverride)) { [string]$App.Installer } else { [string]$InstallerOverride }
    if (-not [string]::IsNullOrWhiteSpace($relativeInstaller)) { [void]$candidates.Add($relativeInstaller) }

    if ([string]::IsNullOrWhiteSpace($InstallerOverride) -and ($App.PSObject.Properties.Name -contains 'InstallerAlternatives')) {
        foreach ($alt in @($App.InstallerAlternatives)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$alt)) { [void]$candidates.Add([string]$alt) }
        }
    }

    foreach ($candidate in @($candidates)) {
        $expected = Join-Path $Context.Paths.Installers $candidate
        if (Test-Path $expected -PathType Leaf) { return $expected }
    }

    $fallback = Join-Path $Context.Paths.Installers $relativeInstaller
    $fileName = Split-Path -Leaf $relativeInstaller
    if (Test-Path $Context.Paths.Installers -PathType Container) {
        $found = @(Get-ChildItem -Path $Context.Paths.Installers -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { return [string]$found[0].FullName }
    }

    return $fallback
}

function Get-EpkFileVersion {
    param([string]$Path)

    try {
        if (-not (Test-Path $Path -PathType Leaf)) { return '' }
        $item = Get-Item $Path -ErrorAction Stop
        $version = [string]$item.VersionInfo.ProductVersion
        if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$item.VersionInfo.FileVersion }
        return $version
    } catch { return '' }
}

function Convert-EpkVersionSafe {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }

    try {
        $clean = ($Version -replace '[^0-9\.]', '.').Trim('.')
        $parts = @($clean -split '\.' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 4)
        if ($parts.Count -eq 0) { return $null }

        while ($parts.Count -lt 2) { $parts += '0' }

        return [version]($parts -join '.')
    }
    catch {
        return $null
    }
}

function Test-EpkVersionNewer {
    param([string]$InstalledVersion, [string]$InstallerVersion)

    $installed = Convert-EpkVersionSafe -Version $InstalledVersion
    $installer = Convert-EpkVersionSafe -Version $InstallerVersion

    if (-not $installed -or -not $installer) { return $false }

    return ($installer -gt $installed)
}

function Get-EpkInstalledApp {
    param([Parameter(Mandatory)]$App)

    $names = @($App.Detection.RegistryDisplayNames)
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($name in $names) {
        try {
            $record = @(Get-ItemProperty $regPaths -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -and $_.DisplayName -like "*$name*"
            })
            if ($record.Count -gt 0) { return $record[0] }
        } catch {}
    }

    foreach ($svcName in @($App.Detection.Services)) {
        if ([string]::IsNullOrWhiteSpace($svcName)) { continue }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) { return [pscustomobject]@{ DisplayName=$App.Name; DisplayVersion=''; Source='Service' } }
    }

    foreach ($exe in @($App.Detection.Executables)) {
        if (Test-Path $exe -PathType Leaf) {
            $version = Get-EpkFileVersion -Path $exe
            return [pscustomobject]@{ DisplayName=$App.Name; DisplayVersion=$version; Source='Executable' }
        }
    }

    return $null
}

function Get-EpkAppStatus {
    param(
        [Parameter(Mandatory)]$Context,
        [switch]$Refresh
    )

    if ([bool]$Context.Settings.Runtime.CacheDetections -and -not $Refresh -and $Context.Session.PSObject.Properties.Name -contains 'AppStatusCache' -and $Context.Session.AppStatusCache) {
        return $Context.Session.AppStatusCache
    }

    $result = [ordered]@{}

    foreach ($app in @($Context.Apps)) {
        $installer = Get-EpkInstallerPath -Context $Context -App $app
        $record = Get-EpkInstalledApp -App $app
        $installerVersion = Get-EpkFileVersion -Path $installer
        $installedVersion = ''
        if ($record -and ($record.PSObject.Properties.Name -contains 'DisplayVersion')) { $installedVersion = [string]$record.DisplayVersion }

        $update = $false
        if ($app.PSObject.Properties.Name -contains 'UpdateIfOutdated') { $update = [bool]$app.UpdateIfOutdated }
        $outdated = $false
        if ($update -and $record -and (Test-Path $installer -PathType Leaf)) {
            $outdated = Test-EpkVersionNewer -InstalledVersion $installedVersion -InstallerVersion $installerVersion
        }

        $result[[string]$app.Name] = [pscustomobject]@{
            Name             = [string]$app.Name
            Id               = [string]$app.Id
            Installed        = ($null -ne $record)
            Outdated         = $outdated
            UpdateIfOutdated = $update
            InstallerExists  = (Test-Path $installer -PathType Leaf)
            InstallerPath    = $installer
            Type             = [string]$app.Type
            Arguments        = [string]$app.Arguments
            SuccessExitCodes = @($app.SuccessExitCodes)
        }
    }

    if ([bool]$Context.Settings.Runtime.CacheDetections) {
        if ($Context.Session.PSObject.Properties.Name -notcontains 'AppStatusCache') {
            Add-Member -InputObject $Context.Session -NotePropertyName 'AppStatusCache' -NotePropertyValue $null -Force
        }
        $Context.Session.AppStatusCache = $result
    }

    return $result
}


function Resolve-EpkAppArguments {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)][string]$Installer
    )

    $args = [string]$App.Arguments
    if (($App.PSObject.Properties.Name -contains 'OfficeConfiguration') -and -not [string]::IsNullOrWhiteSpace([string]$App.OfficeConfiguration)) {
        $configPath = Join-Path $Context.Paths.Installers ([string]$App.OfficeConfiguration)
        if (Test-Path $configPath -PathType Leaf) {
            $args = ('/configure "{0}"' -f $configPath)
        } else {
            Write-EpkLog -Context $Context -Area 'APP' -Level 'WRN' -Message ("{0}: OfficeConfig missing; using apps.json arguments" -f $App.Name)
        }
    }

    return $args
}

function Wait-EpkAppDetection {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$App
    )

    $timeout = 180
    $retry = 5
    if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'VerificationTimeoutSeconds') { $timeout = [int]$Context.Settings.Runtime.VerificationTimeoutSeconds }
    if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'VerificationRetrySeconds') { $retry = [int]$Context.Settings.Runtime.VerificationRetrySeconds }
    if ($timeout -lt 0) { $timeout = 0 }
    if ($retry -lt 1) { $retry = 5 }

    $deadline = (Get-Date).AddSeconds($timeout)
    do {
        $record = Get-EpkInstalledApp -App $App
        if ($record) { return $record }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds $retry }
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Start-EpkProcessWithTimeout {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ArgumentList = '',
        [int]$TimeoutSeconds = 1800
    )

    if ([string]::IsNullOrWhiteSpace($ArgumentList)) {
        $proc = Start-Process -FilePath $FilePath -PassThru -WindowStyle Hidden
    } else {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden
    }

    if ($TimeoutSeconds -le 0) {
        $proc.WaitForExit()
        return $proc
    }

    $completed = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw "Processo excedeu timeout de $TimeoutSeconds segundos: $FilePath"
    }

    return $proc
}


function Install-EpkApp {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$App
    )

    if ($Context.Session.PSObject.Properties.Name -contains 'AppStatusCache') { $Context.Session.AppStatusCache = $null }
    $installer = Get-EpkInstallerPath -Context $Context -App $App
    if (-not (Test-Path $installer -PathType Leaf)) {
        Write-EpkLog -Context $Context -Area 'APP' -Level 'ERR' -Message ("{0}: installer missing" -f $App.Name)
        return $false
    }

    if ([bool]$Context.Settings.Runtime.ValidateHashes -and [bool]$Context.Settings.Runtime.BlockInstallOnHashError) {
        $hashStatus = $null
        if ($Context.Session.PSObject.Properties.Name -contains 'HashStatusCache' -and $Context.Session.HashStatusCache) {
            $hashStatus = $Context.Session.HashStatusCache[[string]$App.Id]
        }
        if (-not $hashStatus) { $hashStatus = Get-EpkInstallerHashStatus -Context $Context -App $App }
        if ($hashStatus.Exists -and (-not $hashStatus.PathMatchesApp)) {
            Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message ("{0}: installation blocked because hash path differs from apps.json" -f $App.Name)
            return $false
        }
        if ($hashStatus.Exists -and $hashStatus.State -ne 'OK') {
            Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message ("{0}: installation blocked by hash {1}" -f $App.Name, $hashStatus.State)
            return $false
        }
    }

    if (Test-EpkReadOnlyMode -Context $Context) {
        Write-EpkLog -Context $Context -Area 'APP' -Level 'TODO' -Message ("{0}: read-only mode; would be installed" -f $App.Name)
        return $true
    }

    Write-EpkLog -Context $Context -Area 'APP' -Level 'RUN' -Message ("{0}: installing" -f $App.Name)

    try {
        $type = ([string]$App.Type).ToUpper()
        $args = Resolve-EpkAppArguments -Context $Context -App $App -Installer $installer
        $proc = $null

        switch ($type) {
            'MSI' {
                $argLine = "/i `"$installer`" $args"
                $proc = Start-EpkProcessWithTimeout -FilePath 'msiexec.exe' -ArgumentList $argLine -TimeoutSeconds ([int]$Context.Settings.Runtime.InstallTimeoutSeconds)
            }
            'MSIX' {
                $argLine = "/Online /Add-ProvisionedAppxPackage /PackagePath:`"$installer`" /SkipLicense"
                $proc = Start-EpkProcessWithTimeout -FilePath 'dism.exe' -ArgumentList $argLine -TimeoutSeconds ([int]$Context.Settings.Runtime.InstallTimeoutSeconds)
            }
            default {
                $proc = Start-EpkProcessWithTimeout -FilePath $installer -ArgumentList $args -TimeoutSeconds ([int]$Context.Settings.Runtime.InstallTimeoutSeconds)
            }
        }

        $exitCode = if ($proc) { $proc.ExitCode } else { 0 }
        $successCodes = @($App.SuccessExitCodes)
        if ($successCodes.Count -eq 0) { $successCodes = @(0,3010) }

        $rebootCodes = @()
        if ($App.PSObject.Properties.Name -contains 'RebootExitCodes') { $rebootCodes = @($App.RebootExitCodes) }
        if ($rebootCodes.Count -eq 0) { $rebootCodes = @(3010,1641) }
        if ($exitCode -in $rebootCodes) {
            $Context.Session.RebootNeeded = $true
            Write-EpkLog -Context $Context -Area 'APP' -Level 'WRN' -Message ("{0}: installer requested reboot, exit code {1}" -f $App.Name, $exitCode)
        }

        $delay = [int]$Context.Settings.Runtime.PostInstallDelaySeconds
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }

        $verify = Wait-EpkAppDetection -Context $Context -App $App
        if (($exitCode -in $successCodes) -and $verify) {
            Write-EpkLog -Context $Context -Area 'APP' -Level 'OK' -Message ("{0}: installed and validated" -f $App.Name)
            Add-EpkAction -Context $Context -Text ("App installed: {0}" -f $App.Name)
            if ($Context.Session.PSObject.Properties.Name -contains 'AppStatusCache') { $Context.Session.AppStatusCache = $null }
            return $true
        }

        if (($exitCode -in $successCodes) -and $Context.Session.RebootNeeded) {
            Write-EpkLog -Context $Context -Area 'APP' -Level 'WRN' -Message ("{0}: installed; final validation will run again after reboot" -f $App.Name)
            Add-EpkAction -Context $Context -Text ("App installed with pending reboot: {0}" -f $App.Name)
            if ($Context.Session.PSObject.Properties.Name -contains 'AppStatusCache') { $Context.Session.AppStatusCache = $null }
            return $true
        }

        if (($exitCode -in $successCodes) -and -not $verify) {
            Write-EpkLog -Context $Context -Area 'APP' -Level 'WRN' -Message ("{0}: installer returned success, but detection has not confirmed yet" -f $App.Name)
            if ($Context.Session.PSObject.Properties.Name -contains 'AppStatusCache') { $Context.Session.AppStatusCache = $null }
            return $false
        }

        Write-EpkLog -Context $Context -Area 'APP' -Level 'WRN' -Message ("{0}: failure or pending validation, exit code {1}" -f $App.Name, $exitCode)
        return $false
    }
    catch {
        Write-EpkLog -Context $Context -Area 'APP' -Level 'ERR' -Message ("{0}: {1}" -f $App.Name, $_.Exception.Message)
        return $false
    }
}

function Invoke-EpkApps {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'APP' -Title 'Applications'

    if ([bool]$Context.Settings.Runtime.ValidateHashes) {
        $alreadyValidated = ($Context.Session.PSObject.Properties.Name -contains 'HashValidationCompleted' -and [bool]$Context.Session.HashValidationCompleted)
        if (-not $alreadyValidated) { [void](Invoke-EpkHashValidation -Context $Context) }
        if (-not (Test-EpkHashPolicy -Context $Context)) {
            Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message 'Hash policy blocked application installation'
            return
        }
    }

    $status = Get-EpkAppStatus -Context $Context

    foreach ($app in @($Context.Apps)) {
        $name = [string]$app.Name
        $state = $status[$name]

        if ($state.Installed -and -not ($state.Outdated -and $state.UpdateIfOutdated)) {
            Write-EpkLog -Context $Context -Area 'APP' -Level 'OK' -Message "${name}: OK"
            continue
        }

        if ($state.Installed -and $state.Outdated -and $state.UpdateIfOutdated) {
            Write-EpkLog -Context $Context -Area 'APP' -Level 'WRN' -Message "${name}: update pending"
            [void](Install-EpkApp -Context $Context -App $app)
            continue
        }

        if (-not $state.InstallerExists) {
            Write-EpkLog -Context $Context -Area 'APP' -Level 'ERR' -Message "${name}: pending without installer"
            continue
        }

        [void](Install-EpkApp -Context $Context -App $app)
    }
}

Export-ModuleMember -Function Get-EpkInstallerPath, Get-EpkFileVersion, Convert-EpkVersionSafe, Test-EpkVersionNewer, Resolve-EpkAppArguments, Wait-EpkAppDetection, Start-EpkProcessWithTimeout, Get-EpkInstalledApp, Get-EpkAppStatus, Install-EpkApp, Invoke-EpkApps
