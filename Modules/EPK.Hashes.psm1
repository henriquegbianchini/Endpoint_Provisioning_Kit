function Get-EpkHashesConfig {
    param([Parameter(Mandatory)]$Context)

    $path = [string]$Context.Paths.Hashes
    if (Test-Path $path -PathType Leaf) {
        try { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{ SchemaVersion='1.0.0'; AlgorithmDefault='SHA256'; Installers=[pscustomobject]@{} }
}

function Get-EpkHashDefaultAlgorithm {
    param([Parameter(Mandatory)]$Context, $HashConfig)

    $algorithm = ''
    try { $algorithm = [string]$HashConfig.AlgorithmDefault } catch {}
    if ([string]::IsNullOrWhiteSpace($algorithm)) {
        try { $algorithm = [string]$Context.Settings.Runtime.HashAlgorithm } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($algorithm)) { $algorithm = 'SHA256' }
    $algorithm = $algorithm.ToUpperInvariant()
    if ($algorithm -notin @('SHA1','SHA256','SHA384','SHA512','MD5')) { $algorithm = 'SHA256' }
    return $algorithm
}

function Get-EpkInstallerPathFromHashEntry {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)]$HashEntry
    )

    return (Get-EpkInstallerPath -Context $Context -App $App -InstallerOverride ([string]$HashEntry.ConfiguredPath))
}

function Normalize-EpkHashValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value -replace '[^a-fA-F0-9]', '').ToUpperInvariant())
}

function Test-EpkHashValueFormat {
    param([string]$Value, [string]$Algorithm = 'SHA256')

    $normalized = Normalize-EpkHashValue -Value $Value
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }

    switch ($Algorithm.ToUpperInvariant()) {
        'MD5' { return ($normalized -match '^[A-F0-9]{32}$') }
        'SHA1' { return ($normalized -match '^[A-F0-9]{40}$') }
        'SHA256' { return ($normalized -match '^[A-F0-9]{64}$') }
        'SHA384' { return ($normalized -match '^[A-F0-9]{96}$') }
        'SHA512' { return ($normalized -match '^[A-F0-9]{128}$') }
        default { return $false }
    }
}

function Get-EpkHashEntry {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$HashConfig,
        [Parameter(Mandatory)]$App
    )

    $appId = [string]$App.Id
    $appName = [string]$App.Name
    $algorithm = Get-EpkHashDefaultAlgorithm -Context $Context -HashConfig $HashConfig
    $expected = ''
    $configuredPath = [string]$App.Installer
    $required = $true

    $entry = $null
    try {
        if ($HashConfig.PSObject.Properties.Name -contains 'Installers' -and $HashConfig.Installers) {
            $prop = $HashConfig.Installers.PSObject.Properties | Where-Object { $_.Name -ieq $appId -or $_.Name -ieq $appName } | Select-Object -First 1
            if ($prop) { $entry = $prop.Value }
        }
    } catch {}

    if ($entry) {
        if ($entry -is [string]) {
            $expected = [string]$entry
        } else {
            foreach ($name in @('Sha256','SHA256','Hash','ExpectedHash')) {
                if ($entry.PSObject.Properties.Name -contains $name -and -not [string]::IsNullOrWhiteSpace([string]$entry.$name)) {
                    $expected = [string]$entry.$name
                    break
                }
            }
            if ($entry.PSObject.Properties.Name -contains 'Algorithm' -and -not [string]::IsNullOrWhiteSpace([string]$entry.Algorithm)) { $algorithm = ([string]$entry.Algorithm).ToUpperInvariant() }
            if ($algorithm -notin @('SHA1','SHA256','SHA384','SHA512','MD5')) { $algorithm = Get-EpkHashDefaultAlgorithm -Context $Context -HashConfig $HashConfig }
            if ($entry.PSObject.Properties.Name -contains 'Path' -and -not [string]::IsNullOrWhiteSpace([string]$entry.Path)) { $configuredPath = [string]$entry.Path }
            if ($entry.PSObject.Properties.Name -contains 'Required') { $required = [bool]$entry.Required }
        }
    } else {
        foreach ($key in @($appId, $appName)) {
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $prop = $HashConfig.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
            if ($prop) { $expected = [string]$prop.Value; break }
        }
    }

    return [pscustomobject]@{
        AppId = $appId
        AppName = $appName
        Algorithm = $algorithm
        Expected = (Normalize-EpkHashValue -Value $expected)
        ConfiguredPath = $configuredPath
        Required = $required
    }
}

function Get-EpkHashExpected {
    param(
        [Parameter(Mandatory)]$HashConfig,
        [Parameter(Mandatory)]$App
    )

    foreach ($key in @([string]$App.Id, [string]$App.Name)) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        try {
            if ($HashConfig.PSObject.Properties.Name -contains 'Installers' -and $HashConfig.Installers) {
                $prop = $HashConfig.Installers.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
                if ($prop) {
                    $entry = $prop.Value
                    if ($entry -is [string]) { return (Normalize-EpkHashValue -Value ([string]$entry)) }
                    foreach ($name in @('Sha256','SHA256','Hash','ExpectedHash')) {
                        if ($entry.PSObject.Properties.Name -contains $name) { return (Normalize-EpkHashValue -Value ([string]$entry.$name)) }
                    }
                }
            }
        } catch {}

        $legacy = $HashConfig.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
        if ($legacy) { return (Normalize-EpkHashValue -Value ([string]$legacy.Value)) }
    }

    return ''
}

function Get-EpkInstallerHashStatus {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$App,
        $HashConfig = $null
    )

    if (-not $HashConfig) { $HashConfig = Get-EpkHashesConfig -Context $Context }
    $entry = Get-EpkHashEntry -Context $Context -HashConfig $HashConfig -App $App
    $path = Get-EpkInstallerPathFromHashEntry -Context $Context -App $App -HashEntry $entry
    $exists = Test-Path $path -PathType Leaf
    $pathMatchesApp = (([string]$entry.ConfiguredPath).Replace('\','/') -ieq ([string]$App.Installer).Replace('\','/'))
    $actual = ''
    $state = 'UNKNOWN'
    $message = ''

    if (-not $exists) {
        $state = 'MISSING_FILE'
        $message = 'installer missing'
    } else {
        try {
            $actual = (Get-FileHash -Path $path -Algorithm $entry.Algorithm -ErrorAction Stop).Hash.ToUpperInvariant()
            if ([string]::IsNullOrWhiteSpace($entry.Expected)) {
                $state = 'MISSING_EXPECTED'
                $message = 'expected hash missing'
            } elseif (-not (Test-EpkHashValueFormat -Value $entry.Expected -Algorithm $entry.Algorithm)) {
                $state = 'INVALID_EXPECTED'
                $message = 'expected hash invalid'
            } elseif ($actual -ieq $entry.Expected) {
                $state = 'OK'
                $message = 'hash valid'
            } else {
                $state = 'MISMATCH'
                $message = 'hash mismatch'
            }
        } catch {
            $state = 'ERROR'
            $message = $_.Exception.Message
        }
    }

    $fileSize = $null
    $lastWriteUtc = $null
    if ($exists) {
        try {
            $fileInfo = Get-Item -LiteralPath $path -ErrorAction Stop
            $fileSize = [int64]$fileInfo.Length
            $lastWriteUtc = $fileInfo.LastWriteTimeUtc.ToString('s') + 'Z'
        } catch {}
    }

    return [pscustomobject]@{
        AppId = $entry.AppId
        AppName = $entry.AppName
        Path = $path
        RelativePath = $entry.ConfiguredPath
        Algorithm = $entry.Algorithm
        Expected = $entry.Expected
        Actual = $actual
        Exists = $exists
        Required = $entry.Required
        PathMatchesApp = $pathMatchesApp
        ConfiguredPath = $entry.ConfiguredPath
        AppInstaller = [string]$App.Installer
        FileSizeBytes = $fileSize
        LastWriteTimeUtc = $lastWriteUtc
        State = $state
        Message = $message
    }
}

function Get-EpkHashStatus {
    param([Parameter(Mandatory)]$Context)

    $hashConfig = Get-EpkHashesConfig -Context $Context
    $result = [ordered]@{}
    foreach ($app in @($Context.Apps)) {
        $status = Get-EpkInstallerHashStatus -Context $Context -App $app -HashConfig $hashConfig
        $result[$status.AppId] = $status
    }
    return $result
}


function Get-EpkHashCatalogInstallerIds {
    param($HashConfig)

    $ids = New-Object System.Collections.ArrayList
    if ($null -eq $HashConfig) { return @() }

    try {
        $installers = $null
        if ($HashConfig.PSObject.Properties.Name -contains 'Installers') {
            $installers = $HashConfig.Installers
        }
        if ($null -eq $installers) { return @() }

        if ($installers -is [System.Collections.IDictionary]) {
            foreach ($key in @($installers.Keys)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$key)) { [void]$ids.Add([string]$key) }
            }
        } else {
            foreach ($prop in @($installers.PSObject.Properties)) {
                if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Name)) { [void]$ids.Add([string]$prop.Name) }
            }
        }
    } catch {
        return @()
    }

    return @($ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
}

function Test-EpkHashCatalogAlignment {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$HashConfig
    )

    $issues = New-Object System.Collections.ArrayList
    $appIds = New-Object System.Collections.ArrayList

    foreach ($app in @($Context.Apps)) {
        $id = ''
        try { $id = [string]$app.Id } catch { $id = '' }
        if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$appIds.Add($id) }
    }

    $appIdList = @($appIds | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $hashIdList = @(Get-EpkHashCatalogInstallerIds -HashConfig $HashConfig)

    foreach ($appId in $appIdList) {
        if (-not (@($hashIdList) -contains $appId)) {
            [void]$issues.Add([pscustomobject]@{
                Type = 'APP_WITHOUT_HASH_ENTRY'
                Id = $appId
                Message = 'Application exists in apps.json but has no entry in hashes.json'
            })
        }
    }

    foreach ($hashId in $hashIdList) {
        if (-not (@($appIdList) -contains $hashId)) {
            [void]$issues.Add([pscustomobject]@{
                Type = 'HASH_WITHOUT_APP'
                Id = $hashId
                Message = 'Entry exists in hashes.json but does not exist in apps.json'
            })
        }
    }

    return @($issues)
}

function Invoke-EpkHashValidation {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'HASH' -Title 'Installer integrity'
    $Context.Session.HashValidationStartedAt = (Get-Date).ToString('s')
    $hashConfigForCatalog = Get-EpkHashesConfig -Context $Context
    $catalogIssues = @()
    try {
        $catalogIssues = @(Test-EpkHashCatalogAlignment -Context $Context -HashConfig $hashConfigForCatalog)
    } catch {
        Write-EpkLog -Context $Context -Area 'HASH' -Level 'WRN' -Message ("Catalog alignment check skipped: {0}" -f $_.Exception.Message)
    }
    if ($Context.Session.PSObject.Properties.Name -notcontains 'HashCatalogIssues') { Add-Member -InputObject $Context.Session -NotePropertyName 'HashCatalogIssues' -NotePropertyValue @() -Force }
    $Context.Session.HashCatalogIssues = @($catalogIssues)
    foreach ($issue in @($catalogIssues)) { Write-EpkLog -Context $Context -Area 'HASH' -Level 'WRN' -Message ("Catalog: {0} - {1}" -f $issue.Id, $issue.Message) }
    $strict = [bool]$Context.Settings.Runtime.StrictHashes
    $status = Get-EpkHashStatus -Context $Context

    if ($Context.Session.PSObject.Properties.Name -notcontains 'HashStatusCache') {
        Add-Member -InputObject $Context.Session -NotePropertyName 'HashStatusCache' -NotePropertyValue $null -Force
    }
    if ($Context.Session.PSObject.Properties.Name -notcontains 'HashValidationCompleted') {
        Add-Member -InputObject $Context.Session -NotePropertyName 'HashValidationCompleted' -NotePropertyValue $false -Force
    }
    $Context.Session.HashStatusCache = $status
    $Context.Session.HashValidationCompleted = $true
    $Context.Session.HashValidationFinishedAt = (Get-Date).ToString('s')

    foreach ($key in @($status.Keys)) {
        $item = $status[$key]
        $shortActual = if ([string]::IsNullOrWhiteSpace($item.Actual)) { '' } else { $item.Actual.Substring(0, [Math]::Min(12, $item.Actual.Length)) }
        switch ($item.State) {
            'OK' { Write-EpkLog -Context $Context -Area 'HASH' -Level 'OK' -Message ("{0}: OK {1}" -f $item.AppName, $item.Algorithm) }
            'MISSING_FILE' { Write-EpkLog -Context $Context -Area 'HASH' -Level 'WRN' -Message ("{0}: installer missing" -f $item.AppName) }
            'MISSING_EXPECTED' {
                $level = if ($strict) { 'ERR' } else { 'WRN' }
                $suffix = if ($shortActual) { " atual=$shortActual..." } else { '' }
                Write-EpkLog -Context $Context -Area 'HASH' -Level $level -Message ("{0}: expected hash missing{1}" -f $item.AppName, $suffix)
            }
            'INVALID_EXPECTED' { Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message ("{0}: expected hash is invalid" -f $item.AppName) }
            'MISMATCH' { Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message ("{0}: hash divergente" -f $item.AppName) }
            default { Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message ("{0}: {1}" -f $item.AppName, $item.Message) }
        }
        if (-not $item.PathMatchesApp) {
            Write-EpkLog -Context $Context -Area 'HASH' -Level 'WRN' -Message ("{0}: Hash path differs from apps.json ({1} <> {2})" -f $item.AppName, $item.ConfiguredPath, $item.AppInstaller)
        }
    }

    Add-EpkAction -Context $Context -Text 'Installer SHA-256 validation completed'
    return $status
}

function Test-EpkHashPolicy {
    param([Parameter(Mandatory)]$Context)

    if (-not [bool]$Context.Settings.Runtime.BlockInstallOnHashError) { return $true }

    $status = $null
    if ($Context.Session.PSObject.Properties.Name -contains 'HashStatusCache' -and $Context.Session.HashStatusCache) {
        $status = $Context.Session.HashStatusCache
    } else {
        $status = Get-EpkHashStatus -Context $Context
    }

    foreach ($key in @($status.Keys)) {
        $item = $status[$key]
        if (-not $item.Exists) { continue }
        if (-not $item.PathMatchesApp) {
            Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message ("{0}: hash path differs from apps.json and blocked installation" -f $item.AppName)
            return $false
        }
        if ($item.State -ne 'OK') {
            Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message ("{0}: {1} blocked installation" -f $item.AppName, $item.State)
            return $false
        }
    }

    return $true
}

function Update-EpkHashesFile {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'HASH' -Title 'Hash catalog update'

    $hashConfig = Get-EpkHashesConfig -Context $Context
    $algorithm = Get-EpkHashDefaultAlgorithm -Context $Context -HashConfig $hashConfig
    $installers = [ordered]@{}
    $updatedCount = 0
    $missingCount = 0
    $preservedCount = 0

    foreach ($app in @($Context.Apps)) {
        $existingEntry = Get-EpkHashEntry -Context $Context -HashConfig $hashConfig -App $app
        $path = Get-EpkInstallerPath -Context $Context -App $app
        $hash = ''
        $lastUpdated = ''
        $fileSize = $null
        $lastWriteUtc = $null
        $hashSource = 'Waiting for the real installer and UPDATEHASHES.'

        if (Test-Path $path -PathType Leaf) {
            try {
                $file = Get-Item -LiteralPath $path -ErrorAction Stop
                $hash = (Get-FileHash -Path $path -Algorithm $algorithm -ErrorAction Stop).Hash.ToUpperInvariant()
                $fileSize = [int64]$file.Length
                $lastWriteUtc = $file.LastWriteTimeUtc.ToString('s') + 'Z'
                $lastUpdated = (Get-Date).ToString('s')
                $hashSource = 'Calculated locally by Get-FileHash and approved by the operator in this execution.'
                $updatedCount++
                Write-EpkLog -Context $Context -Area 'HASH' -Level 'OK' -Message ("{0}: hash updated ({1})" -f $app.Name, $algorithm)
            } catch {
                Write-EpkLog -Context $Context -Area 'HASH' -Level 'ERR' -Message ("{0}: {1}" -f $app.Name, $_.Exception.Message)
                $hash = [string]$existingEntry.Expected
                if (-not [string]::IsNullOrWhiteSpace($hash)) {
                    $preservedCount++
                    $hashSource = 'Previous hash preserved because recalculation failed.'
                }
            }
        } else {
            $hash = [string]$existingEntry.Expected
            if ([string]::IsNullOrWhiteSpace($hash)) {
                $missingCount++
                Write-EpkLog -Context $Context -Area 'HASH' -Level 'WRN' -Message ("{0}: installer missing; hash remains empty" -f $app.Name)
            } else {
                $preservedCount++
                $hashSource = 'Previous hash preserved because the installer was not present in this execution.'
                Write-EpkLog -Context $Context -Area 'HASH' -Level 'WRN' -Message ("{0}: installer missing; previous hash preserved" -f $app.Name)
            }
        }

        $installers[[string]$app.Id] = [ordered]@{
            Name = [string]$app.Name
            Path = [string]$app.Installer
            Algorithm = $algorithm
            Sha256 = (Normalize-EpkHashValue -Value $hash)
            Required = [bool]$existingEntry.Required
            FileName = [System.IO.Path]::GetFileName([string]$app.Installer)
            FileSizeBytes = $fileSize
            LastWriteTimeUtc = $lastWriteUtc
            LastUpdated = $lastUpdated
            HashSource = $hashSource
        }
    }

    $policy = [ordered]@{
        ValidateAtStart = $true
        StrictHashesRecommended = $true
        BlockInstallOnHashErrorRecommended = $true
        Behavior = 'An existing installer with a missing, invalid, mismatched hash or divergent path blocks installation when BlockInstallOnHashError=true.'
        Approval = 'UPDATEHASHES/GENERATEHASHES approves only the files present in Installers at execution time.'
    }
    try {
        if ($hashConfig.PSObject.Properties.Name -contains 'Policy' -and $hashConfig.Policy) {
            foreach ($prop in @($hashConfig.Policy.PSObject.Properties)) {
                $policy[[string]$prop.Name] = $prop.Value
            }
        }
    } catch {}

    $output = [ordered]@{
        SchemaVersion = '1.0.0'
        GeneratedBy = [string]$Context.DisplayName
        GeneratedAt = (Get-Date).ToString('s')
        AlgorithmDefault = $algorithm
        Policy = $policy
        Summary = [ordered]@{
            Updated = $updatedCount
            MissingWithoutHash = $missingCount
            PreservedExisting = $preservedCount
        }
        Installers = $installers
    }

    $json = $output | ConvertTo-Json -Depth 8
    $json | Set-Content -Path ([string]$Context.Paths.Hashes) -Encoding UTF8

    if ($Context.Session.PSObject.Properties.Name -contains 'HashStatusCache') { $Context.Session.HashStatusCache = $null }
    if ($Context.Session.PSObject.Properties.Name -contains 'HashValidationCompleted') { $Context.Session.HashValidationCompleted = $false }

    Write-EpkLog -Context $Context -Area 'HASH' -Level 'OK' -Message ("Catalog updated: {0} hash(es) calculated, {1} missing, {2} preserved" -f $updatedCount, $missingCount, $preservedCount)
    Add-EpkAction -Context $Context -Text 'Config/hashes.json updated with hashes of present installers'
    return $Context.Paths.Hashes
}

function Update-EpkHashCatalog {
    param([Parameter(Mandatory)]$Context)
    return (Update-EpkHashesFile -Context $Context)
}

Export-ModuleMember -Function Get-EpkHashCatalogInstallerIds, Test-EpkHashCatalogAlignment, Get-EpkHashesConfig, Get-EpkHashDefaultAlgorithm, Get-EpkInstallerPathFromHashEntry, Normalize-EpkHashValue, Test-EpkHashValueFormat, Get-EpkHashEntry, Get-EpkHashExpected, Get-EpkInstallerHashStatus, Get-EpkHashStatus, Invoke-EpkHashValidation, Test-EpkHashPolicy, Update-EpkHashesFile, Update-EpkHashCatalog
