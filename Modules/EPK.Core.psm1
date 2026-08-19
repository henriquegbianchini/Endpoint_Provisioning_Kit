function New-EpkPendingContainer {
    return [pscustomobject]@{
        Apps = @()
        Certificates = @()
        Hashes = @()
        Hostname = $null
        Domain = $null
    }
}

function Get-EpkItemCount {
    param($Value)
    if ($null -eq $Value) { return 0 }
    return @($Value).Count
}

function Get-EpkPendingTotal {
    param($Pending, [switch]$OnlyCorrectable)
    if (-not $Pending) { return 0 }
    $total = (Get-EpkItemCount $Pending.Apps) + (Get-EpkItemCount $Pending.Certificates)
    if (-not $OnlyCorrectable) { $total += (Get-EpkItemCount $Pending.Hashes) }
    if ($Pending.Hostname) { $total++ }
    return [int]$total
}

function Get-EpkPendingItems {
    param([Parameter(Mandatory)]$Context)

    $appsPending = @()
    $certsPending = @()
    $hashesPending = @()
    $hostnamePending = $null
    $domainInfo = $null

    try {
        $apps = Get-EpkAppStatus -Context $Context -Refresh
        foreach ($app in @($Context.Apps)) {
            $name = [string]$app.Name
            if (-not $apps.Contains($name)) { continue }
            $state = $apps[$name]
            if (-not $state) { continue }
            $needsInstall = -not [bool]$state.Installed
            $needsUpdate = ([bool]$state.Installed -and [bool]$state.Outdated -and [bool]$state.UpdateIfOutdated)
            if ($needsInstall -or $needsUpdate) {
                $reason = if ($needsUpdate) { 'UPDATE_PENDING' } else { 'MISSING' }
                $appsPending += [pscustomobject]@{
                    Id = [string]$app.Id
                    Name = $name
                    Reason = $reason
                    InstallerExists = [bool]$state.InstallerExists
                    InstallerPath = [string]$state.InstallerPath
                }
            }
        }
    } catch {
        Write-EpkLog -Context $Context -Area 'AUD' -Level 'ERR' -Message ("Failed to calculate pending apps: {0}" -f $_.Exception.Message)
    }

    try {
        $certs = Get-EpkCertificateStatus -Context $Context
        foreach ($key in @($certs.Keys)) {
            if (-not [bool]$certs[$key]) {
                $certsPending += [pscustomobject]@{ Name = [string]$key; Reason = 'MISSING' }
            }
        }
    } catch {
        Write-EpkLog -Context $Context -Area 'AUD' -Level 'ERR' -Message ("Failed to calculate pending certificates: {0}" -f $_.Exception.Message)
    }

    try {
        if ([bool]$Context.Settings.Runtime.ValidateHashes) {
            $hashes = Get-EpkHashStatus -Context $Context
            if ($Context.Session.PSObject.Properties.Name -notcontains 'HashStatusCache') { Add-Member -InputObject $Context.Session -NotePropertyName 'HashStatusCache' -NotePropertyValue $null -Force }
            $Context.Session.HashStatusCache = $hashes
            foreach ($key in @($hashes.Keys)) {
                $h = $hashes[$key]
                if ($h.State -ne 'OK' -and $h.State -ne 'MISSING_FILE') {
                    $hashesPending += [pscustomobject]@{
                        Id = [string]$key
                        AppName = [string]$h.AppName
                        State = [string]$h.State
                        Path = [string]$h.Path
                    }
                }
            }
        }
    } catch {
        Write-EpkLog -Context $Context -Area 'AUD' -Level 'ERR' -Message ("Failed to calculate pending hashes: {0}" -f $_.Exception.Message)
    }

    try {
        $desired = ''
        if (-not [string]::IsNullOrWhiteSpace($Context.Session.DesiredHost)) {
            $desired = [string]$Context.Session.DesiredHost
        } elseif (-not [string]::IsNullOrWhiteSpace($Context.Session.Sector) -and -not [string]::IsNullOrWhiteSpace($Context.Session.Asset)) {
            $desired = New-EpkHostname -Context $Context -Sector $Context.Session.Sector -Asset $Context.Session.Asset
        }

        if (-not [string]::IsNullOrWhiteSpace($desired) -and $env:COMPUTERNAME -ine $desired) {
            $hostnamePending = [pscustomobject]@{ Current = [string]$env:COMPUTERNAME; Desired = [string]$desired; Reason = 'DIFFERENT' }
        }
    } catch {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'WRN' -Message ("Hostname not calculated: {0}" -f $_.Exception.Message)
    }

    try {
        $domainInfo = Get-EpkDomainStatus -Context $Context
    } catch {}

    $result = [pscustomobject]@{
        Apps = @($appsPending)
        Certificates = @($certsPending)
        Hashes = @($hashesPending)
        Hostname = $hostnamePending
        Domain = $domainInfo
    }
    if ($Context.Session.PSObject.Properties.Name -notcontains 'PendingItems') { Add-Member -InputObject $Context.Session -NotePropertyName 'PendingItems' -NotePropertyValue $null -Force }
    $Context.Session.PendingItems = $result
    return $result
}

function Write-EpkPendingSummary {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Pending
    )

    Show-EpkSection -Context $Context -Code 'AUD' -Title 'Pending items'
    $correctable = Get-EpkPendingTotal -Pending $Pending -OnlyCorrectable
    $total = Get-EpkPendingTotal -Pending $Pending

    if ($total -eq 0) {
        Write-EpkLog -Context $Context -Area 'AUD' -Level 'OK' -Message 'No pending items found'
    } else {
        Write-EpkLog -Context $Context -Area 'AUD' -Level 'WRN' -Message ("Pending items: {0}; automatically correctable: {1}" -f $total, $correctable)
    }

    foreach ($item in @($Pending.Apps)) {
        $level = 'ERR'
        if ([bool]$item.InstallerExists) { $level = 'WRN' }
        Write-EpkLog -Context $Context -Area 'APP' -Level $level -Message ("{0}: {1}; installer={2}" -f [string]$item.Name, [string]$item.Reason, [bool]$item.InstallerExists)
    }
    foreach ($item in @($Pending.Certificates)) {
        Write-EpkLog -Context $Context -Area 'CERT' -Level 'WRN' -Message ("{0}: certificate pending" -f [string]$item.Name)
    }
    foreach ($item in @($Pending.Hashes)) {
        Write-EpkLog -Context $Context -Area 'HASH' -Level 'WRN' -Message ("{0}: {1}; run UPDATEHASHES after checking the installer" -f [string]$item.AppName, [string]$item.State)
    }
    if ($Pending.Hostname) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'WRN' -Message ("Hostname mismatch: current={0}; desired={1}" -f [string]$Pending.Hostname.Current, [string]$Pending.Hostname.Desired)
    }
    if ($Pending.Domain) {
        $domainLevel = 'WRN'
        if ([string]$Pending.Domain.Status -eq 'OK') { $domainLevel = 'OK' }
        Write-EpkLog -Context $Context -Area 'DOM' -Level $domainLevel -Message ("Domain/workgroup: type={0}; joined={1}; current={2}; expected={3}; status={4}" -f [string]$Pending.Domain.TargetType, [bool]$Pending.Domain.PartOfDomain, [string]$Pending.Domain.Current, [string]$Pending.Domain.Expected, [string]$Pending.Domain.Status)
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'RUN' -Message $Pending.Domain.Note
    }
}

function Invoke-EpkFixMissingOnly {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Pending
    )

    Show-EpkSection -Context $Context -Code 'CORE' -Title 'Correcao somente do que falta'

    if (Test-EpkReadOnlyMode -Context $Context) {
        Write-EpkLog -Context $Context -Area 'CORE' -Level 'ERR' -Message 'Selective correction blocked because current mode is read-only'
        return
    }

    if ((Get-EpkItemCount $Pending.Hashes) -gt 0) {
        Write-EpkLog -Context $Context -Area 'HASH' -Level 'WRN' -Message 'Pending hash is not automatically fixed here; run UPDATEHASHES only after validating the real installers.'
    }

    if ((Get-EpkItemCount $Pending.Certificates) -gt 0) {
        [void](Invoke-EpkCertificates -Context $Context)
    }

    if ((Get-EpkItemCount $Pending.Apps) -gt 0) {
        foreach ($pendingApp in @($Pending.Apps)) {
            $app = @($Context.Apps | Where-Object { [string]$_.Id -eq [string]$pendingApp.Id } | Select-Object -First 1)
            if (@($app).Count -eq 0) { continue }
            if (-not [bool]$pendingApp.InstallerExists) {
                Write-EpkLog -Context $Context -Area 'APP' -Level 'ERR' -Message ("{0}: not fixed because the installer is missing" -f [string]$pendingApp.Name)
                continue
            }
            [void](Install-EpkApp -Context $Context -App $app[0])
        }
    }

    if ($Pending.Hostname) {
        [void](Invoke-EpkHostname -Context $Context)
    }

    Write-EpkLog -Context $Context -Area 'CORE' -Level 'OK' -Message 'Selective correction completed'
    if ([bool]$Context.Settings.Runtime.ValidateHashes) { [void](Invoke-EpkHashValidation -Context $Context) }
    $after = Get-EpkPendingItems -Context $Context
    Write-EpkPendingSummary -Context $Context -Pending $after
}

function Invoke-EpkPromptFixMissing {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Pending
    )

    $mode = ''
    try { $mode = ([string]$Context.Session.Mode).ToUpperInvariant() } catch { $mode = '' }
    if ($mode -notin @('COMPLETE','APPLY')) { return }
    if ($Context.Session.Silent -or $Context.Session.DryRun) { return }
    $enabled = $true
    if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'PromptFixMissingAfterAudit') { $enabled = [bool]$Context.Settings.Runtime.PromptFixMissingAfterAudit }
    if (-not $enabled) { return }

    $correctable = Get-EpkPendingTotal -Pending $Pending -OnlyCorrectable
    if ($correctable -eq 0) { return }

    $answer = Read-Host ("Fix only missing/correctable items now ({0} item/s)? [Y/N]" -f $correctable)
    if ($answer.Trim().ToUpperInvariant() -eq 'Y') {
        Invoke-EpkFixMissingOnly -Context $Context -Pending $Pending
    } else {
        Write-EpkLog -Context $Context -Area 'CORE' -Level 'WRN' -Message 'Selective correction not executed by operator choice'
    }
}

function Invoke-EpkChecklist {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'CORE' -Title 'Local checklist'
    Test-EpkStructure -Context $Context

    $apps = Get-EpkAppStatus -Context $Context -Refresh
    $installed = @($apps.Keys | Where-Object { $apps[$_].Installed }).Count
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'OK' -Message ("Apps detected: {0}/{1}" -f $installed, @($apps.Keys).Count)

    $certs = Get-EpkCertificateStatus -Context $Context
    $certOk = @($certs.Keys | Where-Object { $certs[$_] }).Count
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'OK' -Message ("Certificates: {0}/{1}" -f $certOk, @($certs.Keys).Count)

    if ([bool]$Context.Settings.Runtime.ValidateHashes) {
        $hashes = Get-EpkHashStatus -Context $Context
        $hashOk = @($hashes.Keys | Where-Object { $hashes[$_].State -eq 'OK' }).Count
        Write-EpkLog -Context $Context -Area 'CORE' -Level 'OK' -Message ("Hashes OK: {0}/{1}" -f $hashOk, @($hashes.Keys).Count)
    }
}

function Invoke-EpkAudit {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'AUD' -Title 'Local audit'
    $sys = Get-EpkSystemInfo
    $hw = Get-EpkHardwareInfo

    Write-EpkLog -Context $Context -Area 'AUD' -Level 'OK' -Message ("Hostname: {0}" -f $sys.Hostname)
    $domain = Get-EpkDomainStatus -Context $Context
    $domainLevel = if ([string]$domain.Status -eq 'OK') { 'OK' } else { 'WRN' }
    Write-EpkLog -Context $Context -Area 'AUD' -Level $domainLevel -Message $domain.Message
    Write-EpkLog -Context $Context -Area 'AUD' -Level 'OK' -Message ("IP: {0}" -f $sys.IP)
    Write-EpkLog -Context $Context -Area 'AUD' -Level 'OK' -Message ("Serial: {0}" -f $hw.Serial)
    Write-EpkLog -Context $Context -Area 'AUD' -Level 'OK' -Message ("CPU: {0}" -f $hw.CPU)
    Write-EpkLog -Context $Context -Area 'AUD' -Level 'OK' -Message ("RAM: {0}" -f $hw.RAM)
    Write-EpkLog -Context $Context -Area 'AUD' -Level 'OK' -Message ("Disk: {0}" -f $hw.Disk)

    Invoke-EpkChecklist -Context $Context
    $pending = Get-EpkPendingItems -Context $Context
    Write-EpkPendingSummary -Context $Context -Pending $pending
    Invoke-EpkPromptFixMissing -Context $Context -Pending $pending
}

function Invoke-EpkValidate {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'CORE' -Title 'Read-only validation'
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'RUN' -Message 'VALIDATE mode active: no changes will be applied'

    Test-EpkStructure -Context $Context
    Invoke-EpkWindowsValidation -Context $Context
    Invoke-EpkCertificates -Context $Context

    if ([bool]$Context.Settings.Runtime.ValidateHashes) {
        [void](Invoke-EpkHashValidation -Context $Context)
        if (-not (Test-EpkHashPolicy -Context $Context)) {
            Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message 'Hash policy failed validation. Run UPDATEHASHES only after manually approving the real installers.'
        }
    }

    $pending = Get-EpkPendingItems -Context $Context
    Write-EpkPendingSummary -Context $Context -Pending $pending
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'OK' -Message 'Read-only validation completed'
}

function Invoke-EpkDryRun {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'CORE' -Title 'Dry run'
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'TODO' -Message 'Dry run active: no real changes will be applied'
    Invoke-EpkComplete -Context $Context
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'OK' -Message 'Dry run completed'
}

function Invoke-EpkComplete {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'CORE' -Title 'Prepare endpoint'
    Write-EpkLog -Context $Context -Area 'CORE' -Level 'RUN' -Message 'Local preparation started'

    Invoke-EpkChecklist -Context $Context
    Invoke-EpkWindowsValidation -Context $Context

    if ([bool]$Context.Settings.Runtime.CreateBackupBeforeComplete) {
        [void](Invoke-EpkBackup -Context $Context)
    }

    if ([bool]$Context.Settings.Runtime.ValidateHashes) {
        $alreadyValidated = ($Context.Session.PSObject.Properties.Name -contains 'HashValidationCompleted' -and [bool]$Context.Session.HashValidationCompleted)
        if (-not $alreadyValidated) { [void](Invoke-EpkHashValidation -Context $Context) }
        if (-not (Test-EpkHashPolicy -Context $Context)) {
            Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message 'Hash policy blocked installation'
            throw 'Hash policy blocked operational mode. Run UPDATEHASHES only after manually approving the real installers.'
        }
    }

    Invoke-EpkCertificates -Context $Context
    Invoke-EpkApps -Context $Context

    $domainJoinEnabled = $false
    try { $domainJoinEnabled = [bool](Test-EpkDomainJoinEnabled -Context $Context) } catch { $domainJoinEnabled = $false }

    if ($domainJoinEnabled) {
        [void](Invoke-EpkHostname -Context $Context -PlanOnly)
        [void](Invoke-EpkDomainApply -Context $Context)
    } else {
        [void](Invoke-EpkHostname -Context $Context)

        $runDomain = $false
        if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'RunDomainCheckInComplete') { $runDomain = [bool]$Context.Settings.Runtime.RunDomainCheckInComplete }
        if ($runDomain) { [void](Invoke-EpkDomainCheck -Context $Context) }
    }

    Invoke-EpkAudit -Context $Context
}

Export-ModuleMember -Function New-EpkPendingContainer, Get-EpkItemCount, Get-EpkPendingTotal, Get-EpkPendingItems, Write-EpkPendingSummary, Invoke-EpkFixMissingOnly, Invoke-EpkPromptFixMissing, Invoke-EpkChecklist, Invoke-EpkAudit, Invoke-EpkValidate, Invoke-EpkDryRun, Invoke-EpkComplete
