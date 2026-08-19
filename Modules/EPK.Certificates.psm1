function Get-EpkCertificateStoreInfo {
    param([Parameter(Mandatory)]$Context)

    $storeNameValue = if ($Context.Settings.Certificates.StoreName) { [string]$Context.Settings.Certificates.StoreName } else { 'Root' }
    $storeLocationValue = if ($Context.Settings.Certificates.StoreLocation) { [string]$Context.Settings.Certificates.StoreLocation } else { 'LocalMachine' }

    return [pscustomobject]@{
        StoreName = $storeNameValue
        StoreLocation = $storeLocationValue
        Label = ("{0}\{1}" -f $storeLocationValue, $storeNameValue)
        IsLocalMachineRoot = ($storeNameValue -ieq 'Root' -and $storeLocationValue -ieq 'LocalMachine')
    }
}

function Get-EpkCertificateStore {
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateSet('ReadOnly','ReadWrite')][string]$Mode = 'ReadOnly'
    )

    $storeInfo = Get-EpkCertificateStoreInfo -Context $Context
    $storeName = [System.Enum]::Parse([System.Security.Cryptography.X509Certificates.StoreName], $storeInfo.StoreName, $true)
    $storeLocation = [System.Enum]::Parse([System.Security.Cryptography.X509Certificates.StoreLocation], $storeInfo.StoreLocation, $true)

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, $storeLocation)
    $flags = if ($Mode -eq 'ReadWrite') {
        [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite
    } else {
        [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly
    }

    $store.Open($flags)
    return $store
}

function Get-EpkCertificateFiles {
    param([Parameter(Mandatory)]$Context)

    if (-not (Test-Path $Context.Paths.Certificates -PathType Container)) { return @() }
    return @(Get-ChildItem -Path $Context.Paths.Certificates -Filter '*.crt' -File -Recurse -ErrorAction SilentlyContinue)
}

function Get-EpkCertificateFromFile {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        $cert.Import($Path)
        return $cert
    } catch {
        return $null
    }
}

function Test-EpkCertificateAllowed {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Certificate
    )

    $allowed = @($Context.Settings.Certificates.AllowedSubjectContains)
    if ($allowed.Count -eq 0) { return $true }

    $text = "{0} {1}" -f $Certificate.Subject, $Certificate.Issuer
    foreach ($item in $allowed) {
        if ($text -match [regex]::Escape([string]$item)) { return $true }
    }

    return $false
}

function Test-EpkCertificateInstalled {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path
    )

    $cert = Get-EpkCertificateFromFile -Path $Path
    if (-not $cert) { return $false }

    $store = $null
    try {
        $store = Get-EpkCertificateStore -Context $Context -Mode ReadOnly
        $found = @($store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })
        return ($found.Count -gt 0)
    } catch {
        return $false
    } finally {
        if ($store) { $store.Close() }
        if ($cert) { $cert.Dispose() }
    }
}

function Install-EpkCertificate {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$CertFile
    )

    $cert = Get-EpkCertificateFromFile -Path $CertFile.FullName
    if (-not $cert) {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'ERR' -Message ("{0}: invalid" -f $CertFile.Name)
        return $false
    }

    $storeInfo = Get-EpkCertificateStoreInfo -Context $Context
    Write-EpkLog -Context $Context -Area 'CERT' -Level 'RUN' -Message ("{0}: thumbprint={1}; store={2}; path={3}" -f $CertFile.Name, $cert.Thumbprint, $storeInfo.Label, $CertFile.FullName)

    if (Test-EpkCertificateInstalled -Context $Context -Path $CertFile.FullName) {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'OK' -Message ("{0}: OK" -f $CertFile.Name)
        $cert.Dispose()
        return $true
    }

    if (-not (Test-EpkCertificateAllowed -Context $Context -Certificate $cert)) {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'ERR' -Message ("{0}: subject/issuer not allowed" -f $CertFile.Name)
        $cert.Dispose()
        return $false
    }

    if (Test-EpkReadOnlyMode -Context $Context) {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'TODO' -Message ("{0}: read-only mode; would be installed in {1}" -f $CertFile.Name, $storeInfo.Label)
        $cert.Dispose()
        return $true
    }

    if ($storeInfo.IsLocalMachineRoot) {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'WRN' -Message ("Root certificate installation requested: {0}; thumbprint={1}" -f $CertFile.Name, $cert.Thumbprint)

        $allowRoot = $false
        if ($Context.Settings.Certificates.PSObject.Properties.Name -contains 'AllowRootCertificateInstall') {
            $allowRoot = [bool]$Context.Settings.Certificates.AllowRootCertificateInstall
        }
        if (-not $allowRoot) {
            Write-EpkLog -Context $Context -Area 'CERT' -Level 'ERR' -Message 'Root certificate installation blocked by policy. Set AllowRootCertificateInstall=true only after validating the certificate.'
            $cert.Dispose()
            return $false
        }
        if (-not [bool]$Context.Settings.Certificates.RequireConfirmation) {
            Write-EpkLog -Context $Context -Area 'CERT' -Level 'ERR' -Message 'Root certificate installation requires RequireConfirmation=true.'
            $cert.Dispose()
            return $false
        }
    }

    if ([bool]$Context.Settings.Certificates.RequireConfirmation) {
        if ($Context.Session.Silent) {
            Write-EpkLog -Context $Context -Area 'CERT' -Level 'ERR' -Message ("{0}: confirmation required; silent installation blocked" -f $CertFile.Name)
            $cert.Dispose()
            return $false
        }

        $ans = Read-Host ("Install certificate {0} in {1}? Thumbprint {2} [Y/N]" -f $CertFile.Name, $storeInfo.Label, $cert.Thumbprint)
        if ($ans.Trim().ToUpper() -ne 'Y') {
            Write-EpkLog -Context $Context -Area 'CERT' -Level 'WRN' -Message ("{0}: skipped" -f $CertFile.Name)
            $cert.Dispose()
            return $false
        }
    }

    $store = $null
    try {
        $store = Get-EpkCertificateStore -Context $Context -Mode ReadWrite
        $store.Add($cert)

        Write-EpkLog -Context $Context -Area 'CERT' -Level 'OK' -Message ("{0}: installed" -f $CertFile.Name)
        Add-EpkAction -Context $Context -Text ("Certificate installed: {0}" -f $CertFile.Name)
        if ($Context.Session.PSObject.Properties.Name -contains 'CertificateStatusCache') { $Context.Session.CertificateStatusCache = $null }
        return $true
    } catch {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'ERR' -Message ("{0}: {1}" -f $CertFile.Name, $_.Exception.Message)
        return $false
    } finally {
        if ($store) { $store.Close() }
        if ($cert) { $cert.Dispose() }
    }
}

function Get-EpkCertificateStatus {
    param(
        [Parameter(Mandatory)]$Context,
        [switch]$Refresh
    )

    if ([bool]$Context.Settings.Runtime.CacheDetections -and -not $Refresh -and $Context.Session.PSObject.Properties.Name -contains 'CertificateStatusCache' -and $Context.Session.CertificateStatusCache) {
        return $Context.Session.CertificateStatusCache
    }

    $status = [ordered]@{}
    foreach ($cert in @(Get-EpkCertificateFiles -Context $Context)) {
        $status[$cert.Name] = Test-EpkCertificateInstalled -Context $Context -Path $cert.FullName
    }

    if ([bool]$Context.Settings.Runtime.CacheDetections) {
        if ($Context.Session.PSObject.Properties.Name -notcontains 'CertificateStatusCache') {
            Add-Member -InputObject $Context.Session -NotePropertyName 'CertificateStatusCache' -NotePropertyValue $null -Force
        }
        $Context.Session.CertificateStatusCache = $status
    }

    return $status
}

function Invoke-EpkCertificates {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'CERT' -Title 'Certificates'

    $installEnabled = $true
    if ($Context.PSObject.Properties.Name -contains 'CertificatesProfile' -and $Context.CertificatesProfile.PSObject.Properties.Name -contains 'Install') {
        $installEnabled = [bool]$Context.CertificatesProfile.Install
    }
    if (-not $installEnabled) {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'RUN' -Message 'Certificate installation disabled by company config'
        return
    }

    $certs = @(Get-EpkCertificateFiles -Context $Context)

    if ($certs.Count -eq 0) {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'WRN' -Message 'No certificate files found'
        return
    }

    foreach ($cert in $certs) {
        [void](Install-EpkCertificate -Context $Context -CertFile $cert)
    }
}

Export-ModuleMember -Function Get-EpkCertificateStoreInfo, Get-EpkCertificateStore, Get-EpkCertificateFiles, Get-EpkCertificateFromFile, Test-EpkCertificateAllowed, Test-EpkCertificateInstalled, Install-EpkCertificate, Get-EpkCertificateStatus, Invoke-EpkCertificates
