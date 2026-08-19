function Get-EpkSectorCodes {
    param([Parameter(Mandatory)]$Context)

    if ($Context.PSObject.Properties.Name -contains 'Departments' -and $Context.Departments) {
        return @($Context.Departments | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @()
}

function Test-EpkHostnameNeedsDepartment {
    param([Parameter(Mandatory)]$Context)
    $pattern = [string]$Context.HostnamePattern
    return ($pattern -match '\{SECTOR\}' -or $pattern -match '\{DEPARTMENT\}')
}

function Read-EpkSector {
    param([Parameter(Mandatory)]$Context)

    $valid = @(Get-EpkSectorCodes -Context $Context)
    $requiresDepartment = Test-EpkHostnameNeedsDepartment -Context $Context

    if (-not [string]::IsNullOrWhiteSpace($Context.Session.Sector)) {
        $sector = $Context.Session.Sector.Trim().ToUpperInvariant()
        if ($valid.Count -eq 0 -or $sector -in $valid) { return $sector }
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'ERR' -Message ("Invalid department parameter: {0}. Use: {1}" -f $sector, ($valid -join ', '))
        return ''
    }

    if (-not $requiresDepartment) {
        return ([string]$Context.DefaultDepartment).Trim().ToUpperInvariant()
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Context.DefaultDepartment)) {
        return ([string]$Context.DefaultDepartment).Trim().ToUpperInvariant()
    }

    if ($Context.Session.Silent) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'WRN' -Message 'Department not provided. Hostname skipped.'
        return ''
    }

    Write-Host ''
    Write-Host '+------+-----------------------------+' -ForegroundColor DarkGray
    Write-Host '| DEP  | DEPARTMENT                  |' -ForegroundColor Gray
    Write-Host '+------+-----------------------------+' -ForegroundColor DarkGray
    foreach ($item in @($valid)) {
        Write-Host ("| {0,-4} | {1,-27} |" -f $item, 'Department') -ForegroundColor Cyan
    }
    Write-Host '+------+-----------------------------+' -ForegroundColor DarkGray

    do {
        $sector = (Read-Host 'Department').Trim().ToUpperInvariant()
        if ($valid.Count -gt 0 -and $sector -notin $valid) {
            Write-EpkLog -Context $Context -Area 'HOST' -Level 'ERR' -Message ("Invalid department. Use: {0}" -f ($valid -join ', '))
        }
    } until ($valid.Count -eq 0 -or $sector -in $valid)

    return $sector
}

function Read-EpkAsset {
    param([Parameter(Mandatory)]$Context)

    $regex = [string]$Context.Settings.Validation.AssetRegex

    if (-not [string]::IsNullOrWhiteSpace($Context.Session.Asset)) {
        $asset = $Context.Session.Asset.Trim()
        if ($asset -match $regex) { return $asset }
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'ERR' -Message 'Invalid serial/asset parameter'
        return ''
    }

    if ($Context.Session.Silent) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'WRN' -Message 'Serial/asset not provided. Hostname skipped.'
        return ''
    }

    do {
        $asset = (Read-Host 'Serial or asset').Trim()
        if ($asset -notmatch $regex) {
            Write-EpkLog -Context $Context -Area 'HOST' -Level 'ERR' -Message ("Invalid serial/asset. Regex: {0}" -f $regex)
        }
    } until ($asset -match $regex)

    return $asset
}

function New-EpkHostname {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Sector = '',
        [Parameter(Mandatory)][string]$Asset
    )

    $pattern = [string]$Context.HostnamePattern
    $prefix = [string]$Context.HostnamePrefix
    $profile = [string]$Context.CompanyProfileName
    $company = [string]$Context.CompanyName
    $serial = ([string]$Asset).ToUpperInvariant()
    $machineType = ([string]$Context.MachineType).ToUpperInvariant()
    $department = ([string]$Sector).ToUpperInvariant()

    $name = $pattern.Replace('{PREFIX}', $prefix).
                     Replace('{TYPE}', $machineType).
                     Replace('{SERIAL}', $serial).
                     Replace('{ASSET}', $serial).
                     Replace('{SECTOR}', $department).
                     Replace('{DEPARTMENT}', $department).
                     Replace('{COMPANY}', $company).
                     Replace('{PROFILE}', $profile).ToUpperInvariant()

    $name = ($name -replace '[^A-Z0-9-]', '-')
    $name = ($name -replace '-+', '-').Trim('-')

    return $name
}

function Test-EpkHostnameLength {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Hostname
    )

    return ($Hostname.Length -le [int]$Context.HostnameMaxLength)
}

function Invoke-EpkHostname {
    param(
        [Parameter(Mandatory)]$Context,
        [switch]$PlanOnly
    )

    Show-EpkSection -Context $Context -Code 'HOST' -Title 'Hostname'

    $sector = Read-EpkSector -Context $Context
    $asset = Read-EpkAsset -Context $Context

    if ((Test-EpkHostnameNeedsDepartment -Context $Context) -and [string]::IsNullOrWhiteSpace($sector)) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'WRN' -Message 'Hostname skipped because department is required by pattern'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($asset)) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'WRN' -Message 'Hostname skipped'
        return $false
    }

    $Context.Session.Sector = $sector
    $Context.Session.Asset = $asset
    $Context.Session.MachineType = [string]$Context.MachineType

    $desired = New-EpkHostname -Context $Context -Sector $sector -Asset $asset
    if (-not (Test-EpkHostnameLength -Context $Context -Hostname $desired)) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'ERR' -Message ("Hostname longer than {0} characters: {1}" -f [int]$Context.HostnameMaxLength, $desired)
        if ($Context.Session.PSObject.Properties.Name -notcontains 'DesiredHostRejected') { Add-Member -InputObject $Context.Session -NotePropertyName 'DesiredHostRejected' -NotePropertyValue '' -Force }
        $Context.Session.DesiredHostRejected = $desired
        return $false
    }

    $Context.Session.DesiredHost = $desired

    Write-EpkLog -Context $Context -Area 'HOST' -Level 'RUN' -Message ("Current: {0}" -f $env:COMPUTERNAME)
    Write-EpkLog -Context $Context -Area 'HOST' -Level 'RUN' -Message ("Desired: {0}" -f $desired)

    if ($PlanOnly) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'TODO' -Message ("Plan only; calculated hostname {0}" -f $desired)
        return $true
    }

    if ($env:COMPUTERNAME -ieq $desired) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'OK' -Message 'Hostname OK'
        return $true
    }

    if (Test-EpkReadOnlyMode -Context $Context) {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'TODO' -Message ("Read-only mode; would be changed to {0}" -f $desired)
        return $true
    }

    try {
        Rename-Computer -NewName $desired -Force -ErrorAction Stop
        $Context.Session.RebootNeeded = $true
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'OK' -Message 'Hostname changed'
        Add-EpkAction -Context $Context -Text ("Hostname changed to {0}" -f $desired)
        return $true
    } catch {
        Write-EpkLog -Context $Context -Area 'HOST' -Level 'ERR' -Message 'Failed to change hostname'
        return $false
    }
}

Export-ModuleMember -Function Get-EpkSectorCodes, Test-EpkHostnameNeedsDepartment, Read-EpkSector, Read-EpkAsset, New-EpkHostname, Test-EpkHostnameLength, Invoke-EpkHostname
