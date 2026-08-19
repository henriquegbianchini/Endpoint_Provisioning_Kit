function Get-EpkJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$DefaultValue
    )

    if (-not (Test-Path $Path -PathType Leaf)) { return $DefaultValue }

    try {
        return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        Write-Warning "Invalid JSON: $Path. Using default."
        return $DefaultValue
    }
}

function Get-EpkRequiredJson {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file not found: $Path"
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        throw "Invalid JSON file: $Path. $($_.Exception.Message)"
    }
}

function Test-EpkPropertyExists {
    param($Object, [Parameter(Mandatory)][string]$Name)
    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Get-EpkObjectProperty {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if (Test-EpkPropertyExists -Object $Object -Name $Name) {
        $value = $Object.$Name
        if ($null -ne $value) { return $value }
    }

    return $DefaultValue
}

function Set-EpkObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Resolve-EpkPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $Root }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }

    return (Join-Path $Root $PathValue)
}

function Resolve-EpkConfigPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $BaseDirectory }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }

    $normalized = $PathValue -replace '/', '\'

    if ($normalized -match '^(Config|Installers|Certificates|Runtime|Assets|Modules|Tests)(\\|$)') {
        return (Join-Path $Root $PathValue)
    }

    return (Join-Path $BaseDirectory $PathValue)
}

function ConvertTo-EpkSafeName {
    param(
        [string]$Value,
        [string]$Fallback = 'default'
    )

    $safe = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = $Fallback
    }

    $safe = ($safe -replace '[^A-Za-z0-9_.-]', '_')
    $safe = ($safe -replace '_+', '_').Trim('_')

    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = $Fallback
    }

    return $safe
}

function Get-EpkStringArray {
    param($Value)

    return @(
        $Value |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Assert-EpkCompanyConfig {
    param(
        [Parameter(Mandatory)]$CompanyConfig,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$MachineType = ''
    )

    $errors = New-Object System.Collections.ArrayList

    $company = Get-EpkObjectProperty -Object $CompanyConfig -Name 'Company' -DefaultValue ([pscustomobject]@{})
    $hostname = Get-EpkObjectProperty -Object $CompanyConfig -Name 'Hostname' -DefaultValue ([pscustomobject]@{})
    $domain = Get-EpkObjectProperty -Object $CompanyConfig -Name 'Domain' -DefaultValue ([pscustomobject]@{})
    $security = Get-EpkObjectProperty -Object $CompanyConfig -Name 'Security' -DefaultValue ([pscustomobject]@{})
    $runtime = Get-EpkObjectProperty -Object $CompanyConfig -Name 'Runtime' -DefaultValue ([pscustomobject]@{})
    $apps = Get-EpkObjectProperty -Object $CompanyConfig -Name 'Apps' -DefaultValue ([pscustomobject]@{})
    $reports = Get-EpkObjectProperty -Object $CompanyConfig -Name 'Reports' -DefaultValue ([pscustomobject]@{})

    foreach ($item in @(
        @{ Object = $company; Name = 'Name'; Label = 'Company.Name' },
        @{ Object = $company; Name = 'HostnamePrefix'; Label = 'Company.HostnamePrefix' },
        @{ Object = $hostname; Name = 'Pattern'; Label = 'Hostname.Pattern' },
        @{ Object = $hostname; Name = 'DefaultMachineType'; Label = 'Hostname.DefaultMachineType' },
        @{ Object = $hostname; Name = 'AllowedTypes'; Label = 'Hostname.AllowedTypes' },
        @{ Object = $hostname; Name = 'MaxLength'; Label = 'Hostname.MaxLength' },
        @{ Object = $domain; Name = 'Enabled'; Label = 'Domain.Enabled' },
        @{ Object = $security; Name = 'AllowRootCertificateInstall'; Label = 'Security.AllowRootCertificateInstall' },
        @{ Object = $security; Name = 'RequireCertificateConfirmation'; Label = 'Security.RequireCertificateConfirmation' },
        @{ Object = $security; Name = 'AllowHashUpdateInOperationalModes'; Label = 'Security.AllowHashUpdateInOperationalModes' },
        @{ Object = $runtime; Name = 'AutoRebootIfNeeded'; Label = 'Runtime.AutoRebootIfNeeded' },
        @{ Object = $apps; Name = 'InstallDefaultApps'; Label = 'Apps.InstallDefaultApps' },
        @{ Object = $apps; Name = 'Catalog'; Label = 'Apps.Catalog' },
        @{ Object = $reports; Name = 'OutputPath'; Label = 'Reports.OutputPath' }
    )) {
        if (-not (Test-EpkPropertyExists -Object $item.Object -Name $item.Name)) {
            [void]$errors.Add("Missing required field: $($item.Label)")
        }
    }

    $allowedTypes = Get-EpkStringArray (Get-EpkObjectProperty -Object $hostname -Name 'AllowedTypes' -DefaultValue @())
    $allowedTypes = @($allowedTypes | ForEach-Object { $_.ToUpperInvariant() })

    $defaultType = ([string](Get-EpkObjectProperty -Object $hostname -Name 'DefaultMachineType' -DefaultValue '')).Trim().ToUpperInvariant()

    $selectedType = $defaultType
    if (-not [string]::IsNullOrWhiteSpace($MachineType)) {
        $selectedType = ([string]$MachineType).Trim().ToUpperInvariant()
    }

    if ($allowedTypes.Count -eq 0) {
        [void]$errors.Add('Hostname.AllowedTypes must contain at least one value')
    }

    if (-not [string]::IsNullOrWhiteSpace($defaultType) -and $defaultType -notin $allowedTypes) {
        [void]$errors.Add('Hostname.DefaultMachineType must be listed in Hostname.AllowedTypes')
    }

    if (-not [string]::IsNullOrWhiteSpace($selectedType) -and $selectedType -notin $allowedTypes) {
        [void]$errors.Add("Invalid MachineType '$selectedType'. Allowed values: $($allowedTypes -join ', ')")
    }

    $hostnamePrefix = ([string](Get-EpkObjectProperty -Object $company -Name 'HostnamePrefix' -DefaultValue '')).Trim()
    if (-not [string]::IsNullOrWhiteSpace($hostnamePrefix) -and $hostnamePrefix -notmatch '^[A-Za-z0-9-]+$') {
        [void]$errors.Add('Company.HostnamePrefix accepts only letters, numbers and hyphen')
    }

    $departments = Get-EpkStringArray (Get-EpkObjectProperty -Object $company -Name 'Departments' -DefaultValue @())
    $defaultDepartment = ([string](Get-EpkObjectProperty -Object $company -Name 'DefaultDepartment' -DefaultValue '')).Trim()
    $departmentNamesUpper = @($departments | ForEach-Object { $_.ToUpperInvariant() })

    if ($departments.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($defaultDepartment)) {
        if ($defaultDepartment.ToUpperInvariant() -notin $departmentNamesUpper) {
            [void]$errors.Add('Company.DefaultDepartment must be listed in Company.Departments')
        }
    }

    $pattern = [string](Get-EpkObjectProperty -Object $hostname -Name 'Pattern' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($pattern)) {
        if ($pattern -notmatch '\{PREFIX\}') {
            [void]$errors.Add('Hostname.Pattern should include {PREFIX}')
        }

        if ($pattern -notmatch '\{ASSET\}|\{SERIAL\}') {
            [void]$errors.Add('Hostname.Pattern should include {ASSET} or {SERIAL}')
        }

        $validTokens = @('PREFIX', 'TYPE', 'SERIAL', 'ASSET', 'SECTOR', 'DEPARTMENT', 'COMPANY', 'PROFILE')
        $tokens = [regex]::Matches($pattern, '\{([^}]+)\}') | ForEach-Object { $_.Groups[1].Value }

        foreach ($token in @($tokens)) {
            if ($token -notin $validTokens) {
                [void]$errors.Add("Hostname.Pattern has unsupported token {$token}")
            }
        }
    }

    try {
        $maxLength = [int](Get-EpkObjectProperty -Object $hostname -Name 'MaxLength' -DefaultValue 0)

        if ($maxLength -le 0 -or $maxLength -gt 15) {
            [void]$errors.Add('Hostname.MaxLength must be between 1 and 15')
        }
    }
    catch {
        [void]$errors.Add('Hostname.MaxLength must be numeric')
    }

    $domainEnabled = [bool](Get-EpkObjectProperty -Object $domain -Name 'Enabled' -DefaultValue $false)

    if ($domainEnabled) {
        $domainName = [string](Get-EpkObjectProperty -Object $domain -Name 'Name' -DefaultValue '')

        if ([string]::IsNullOrWhiteSpace($domainName)) {
            [void]$errors.Add('Domain.Name is required when Domain.Enabled=true')
        }
    }
    else {
        $workgroup = [string](Get-EpkObjectProperty -Object $domain -Name 'Workgroup' -DefaultValue '')

        if ([string]::IsNullOrWhiteSpace($workgroup)) {
            [void]$errors.Add('Domain.Workgroup is required when Domain.Enabled=false')
        }
    }

    $joinConfig = Get-EpkObjectProperty -Object $domain -Name 'Join' -DefaultValue ([pscustomobject]@{})
    $joinEnabled = [bool](Get-EpkObjectProperty -Object $joinConfig -Name 'Enabled' -DefaultValue $false)

    if ($joinEnabled -and -not $domainEnabled) {
        [void]$errors.Add('Domain.Join.Enabled requires Domain.Enabled=true')
    }

    if ($joinEnabled) {
        $domainNameForJoin = [string](Get-EpkObjectProperty -Object $domain -Name 'Name' -DefaultValue '')

        if ($domainNameForJoin -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]+\.[A-Za-z0-9-]+$') {
            [void]$errors.Add('Domain.Name must look like an AD DNS name when Domain.Join.Enabled=true')
        }

        if ($domainNameForJoin -match '(?i)(^|\.)example\.(invalid|com|org|net)$' -or $domainNameForJoin -match '(?i)\.invalid$') {
            [void]$errors.Add('Replace the example domain before enabling Domain.Join.Enabled')
        }

        $ou = [string](Get-EpkObjectProperty -Object $domain -Name 'OU' -DefaultValue '')

        if (-not [string]::IsNullOrWhiteSpace($ou) -and $ou -notmatch '^(OU|CN)=') {
            [void]$errors.Add('Domain.OU should start with OU= or CN= when provided')
        }
    }

    if ([bool](Get-EpkObjectProperty -Object $security -Name 'AllowHashUpdateInOperationalModes' -DefaultValue $false)) {
        [void]$errors.Add('Security.AllowHashUpdateInOperationalModes=true is blocked')
    }

    $allowRoot = [bool](Get-EpkObjectProperty -Object $security -Name 'AllowRootCertificateInstall' -DefaultValue $false)
    $requireCertConfirmation = [bool](Get-EpkObjectProperty -Object $security -Name 'RequireCertificateConfirmation' -DefaultValue $true)

    if ($allowRoot -and -not $requireCertConfirmation) {
        [void]$errors.Add('Root certificate installation requires Security.RequireCertificateConfirmation=true')
    }

    if ($errors.Count -gt 0) {
        throw ("Invalid company config {0}: {1}" -f $SourcePath, ($errors -join '; '))
    }
}

function New-EpkDefaultTheme {
    return [pscustomobject]@{
        Name = 'EPK Console'
        Version = '1.0.0'
        Description = 'Default visual theme for the EPK local preparation and audit console.'
        Style = 'clean-cmd'
        LineChar = '='
        SectionChar = '-'
        MenuBorderChar = '-'
        ConsoleColors = [pscustomobject]@{
            Accent = 'Cyan'
            Line = 'DarkCyan'
            Section = 'White'
            Title = 'Cyan'
            Subtitle = 'Gray'
            Text = 'Gray'
            Muted = 'DarkGray'
            Menu = 'Cyan'
            InputError = 'Red'
            OK = 'Green'
            RUN = 'Gray'
            TODO = 'Yellow'
            WRN = 'Yellow'
            ERR = 'Red'
        }
        Banner = [pscustomobject]@{
            UseBannerFile = $true
            File = 'banner.txt'
            FallbackTitle = 'EPK'
            FallbackSubtitle = 'Endpoint Provisioning Kit'
        }
        LogPresentation = [pscustomobject]@{
            ShowEventCode = $true
            TrimLongPathsOnScreen = $true
        }
    }
}

function New-EpkSession {
    return [pscustomobject]@{
        Mode = 'INIT'
        Silent = $false
        DryRun = $false
        AllowReboot = $false
        AllowDomainJoin = $false
        LogFile = $null
        ReportFile = $null
        HtmlFile = $null
        EvidenceFile = $null
        HashValidationStartedAt = $null
        HashValidationFinishedAt = $null
        StartTime = Get-Date
        DesiredHost = ''
        DesiredHostRejected = ''
        Sector = ''
        Asset = ''
        MachineType = ''
        RebootNeeded = $false
        Actions = (New-Object System.Collections.ArrayList)
        Counter = 0
        AppStatusCache = $null
        CertificateStatusCache = $null
        HashStatusCache = $null
        HashCatalogIssues = @()
        HashValidationCompleted = $false
        PendingItems = $null
    }
}

function Test-EpkReadOnlyMode {
    param([Parameter(Mandatory)]$Context)

    $mode = ''

    try {
        $mode = ([string]$Context.Session.Mode).ToUpperInvariant()
    }
    catch {
        $mode = ''
    }

    return ($mode -in @('AUDIT', 'REPORT', 'VALIDATE', 'DRYRUN', 'HASHES'))
}

function Initialize-EpkContext {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$CompanyProfileName = '',
        [string]$CompanyConfigPath = '',
        [string]$MachineType = ''
    )

    $configDir = Join-Path $Root 'Config'
    $assetsDir = Join-Path $Root 'Assets'
    $companyDir = Join-Path $configDir 'Companies'

    $settings = Get-EpkJson -Path (Join-Path $configDir 'settings.json') -DefaultValue ([pscustomobject]@{})
    $menu = @(Get-EpkJson -Path (Join-Path $configDir 'menu.json') -DefaultValue @())
    $ui = Get-EpkJson -Path (Join-Path $configDir 'ui.json') -DefaultValue ([pscustomobject]@{})
    $theme = Get-EpkJson -Path (Join-Path $assetsDir 'theme.json') -DefaultValue (New-EpkDefaultTheme)

    $profileName = ''
    $profilePath = ''

    if (-not [string]::IsNullOrWhiteSpace($CompanyConfigPath)) {
        $profilePath = Resolve-EpkPath -Root $Root -PathValue $CompanyConfigPath
        $profileName = [System.IO.Path]::GetFileNameWithoutExtension($profilePath)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CompanyProfileName)) {
        if ($CompanyProfileName -match '[\\/:*?"<>|]' -or $CompanyProfileName -match '\.\.') {
            throw "Invalid company profile name: $CompanyProfileName"
        }

        $profileName = ConvertTo-EpkSafeName -Value $CompanyProfileName -Fallback 'workgroup.example'
        $profilePath = Join-Path $companyDir ("{0}.json" -f $profileName)
    }
    else {
        $defaultConfig = [string](Get-EpkObjectProperty -Object $settings -Name 'DefaultCompanyConfig' -DefaultValue 'Config/company.json')
        $profilePath = Resolve-EpkPath -Root $Root -PathValue $defaultConfig
        $profileName = [System.IO.Path]::GetFileNameWithoutExtension($profilePath)
    }

    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw "Company config not found: $profilePath. Use -Config or -Company with an existing profile."
    }

    $profileName = ConvertTo-EpkSafeName -Value $profileName -Fallback 'company'
    $companyProfile = Get-EpkRequiredJson -Path $profilePath

    Assert-EpkCompanyConfig -CompanyConfig $companyProfile -SourcePath $profilePath -MachineType $MachineType

    $companyConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Company' -DefaultValue ([pscustomobject]@{})
    $brandingConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Branding' -DefaultValue ([pscustomobject]@{})
    $hostnameConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Hostname' -DefaultValue ([pscustomobject]@{})
    $domainConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Domain' -DefaultValue ([pscustomobject]@{})
    $networkConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Network' -DefaultValue ([pscustomobject]@{})
    $securityConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Security' -DefaultValue ([pscustomobject]@{})
    $runtimeConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Runtime' -DefaultValue ([pscustomobject]@{})
    $appsConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Apps' -DefaultValue ([pscustomobject]@{})
    $certificatesConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Certificates' -DefaultValue ([pscustomobject]@{})
    $reportsConfig = Get-EpkObjectProperty -Object $companyProfile -Name 'Reports' -DefaultValue ([pscustomobject]@{})

    $productName = [string](Get-EpkObjectProperty -Object $brandingConfig -Name 'ProductName' -DefaultValue (Get-EpkObjectProperty -Object $settings -Name 'ProductName' -DefaultValue 'Endpoint Provisioning Kit'))
    $displayName = [string](Get-EpkObjectProperty -Object $brandingConfig -Name 'DisplayName' -DefaultValue (Get-EpkObjectProperty -Object $settings -Name 'DisplayName' -DefaultValue 'Endpoint Provisioning Kit'))
    $reportTitle = [string](Get-EpkObjectProperty -Object $brandingConfig -Name 'ReportTitle' -DefaultValue (Get-EpkObjectProperty -Object $settings -Name 'ReportTitle' -DefaultValue 'Machine Preparation Report'))
    $companyName = [string](Get-EpkObjectProperty -Object $companyConfig -Name 'Name' -DefaultValue $profileName)
    $departments = Get-EpkStringArray (Get-EpkObjectProperty -Object $companyConfig -Name 'Departments' -DefaultValue @())
    $defaultDepartment = [string](Get-EpkObjectProperty -Object $companyConfig -Name 'DefaultDepartment' -DefaultValue '')

    $hostnamePrefix = [string](Get-EpkObjectProperty -Object $companyConfig -Name 'HostnamePrefix' -DefaultValue 'PC')
    $hostnamePattern = [string](Get-EpkObjectProperty -Object $hostnameConfig -Name 'Pattern' -DefaultValue '{PREFIX}-{TYPE}-{SERIAL}')
    $hostnameMaxLength = [int](Get-EpkObjectProperty -Object $hostnameConfig -Name 'MaxLength' -DefaultValue 15)

    $allowedTypes = @(
        Get-EpkStringArray (Get-EpkObjectProperty -Object $hostnameConfig -Name 'AllowedTypes' -DefaultValue @('NOTE', 'DESK', 'SRV')) |
            ForEach-Object { $_.ToUpperInvariant() }
    )

    $defaultMachineType = ([string](Get-EpkObjectProperty -Object $hostnameConfig -Name 'DefaultMachineType' -DefaultValue $allowedTypes[0])).Trim().ToUpperInvariant()

    $selectedMachineType = $defaultMachineType
    if (-not [string]::IsNullOrWhiteSpace($MachineType)) {
        $selectedMachineType = ([string]$MachineType).Trim().ToUpperInvariant()
    }

    $domainEnabled = [bool](Get-EpkObjectProperty -Object $domainConfig -Name 'Enabled' -DefaultValue $false)
    $domainName = [string](Get-EpkObjectProperty -Object $domainConfig -Name 'Name' -DefaultValue '')
    $domainOu = [string](Get-EpkObjectProperty -Object $domainConfig -Name 'OU' -DefaultValue '')
    $workgroup = [string](Get-EpkObjectProperty -Object $domainConfig -Name 'Workgroup' -DefaultValue 'WORKGROUP')

    if ([string]::IsNullOrWhiteSpace($workgroup)) {
        $workgroup = 'WORKGROUP'
    }

    $expectedDomain = $workgroup
    if ($domainEnabled) {
        $expectedDomain = $domainName
    }

    $taskName = [string](Get-EpkObjectProperty -Object $runtimeConfig -Name 'TaskName' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($taskName)) {
        $taskName = "EPK_Resume_$profileName"
    }

    $taskName = ConvertTo-EpkSafeName -Value $taskName -Fallback "EPK_Resume_$profileName"

    Set-EpkObjectProperty -Object $settings -Name 'Company' -Value $companyName
    Set-EpkObjectProperty -Object $settings -Name 'ProductName' -Value $productName
    Set-EpkObjectProperty -Object $settings -Name 'DisplayName' -Value $displayName
    Set-EpkObjectProperty -Object $settings -Name 'Domain' -Value $expectedDomain

    $settingsHostname = Get-EpkObjectProperty -Object $settings -Name 'Hostname' -DefaultValue ([pscustomobject]@{})
    Set-EpkObjectProperty -Object $settings -Name 'Hostname' -Value $settingsHostname
    Set-EpkObjectProperty -Object $settingsHostname -Name 'Prefix' -Value $hostnamePrefix
    Set-EpkObjectProperty -Object $settingsHostname -Name 'Pattern' -Value $hostnamePattern
    Set-EpkObjectProperty -Object $settingsHostname -Name 'AllowedTypes' -Value $allowedTypes
    Set-EpkObjectProperty -Object $settingsHostname -Name 'DefaultMachineType' -Value $defaultMachineType
    Set-EpkObjectProperty -Object $settingsHostname -Name 'MaxLength' -Value $hostnameMaxLength

    $settingsRuntime = Get-EpkObjectProperty -Object $settings -Name 'Runtime' -DefaultValue ([pscustomobject]@{})
    Set-EpkObjectProperty -Object $settings -Name 'Runtime' -Value $settingsRuntime

    foreach ($name in @('AutoRebootIfNeeded', 'RequireAllowRebootParameter', 'ResumeAfterReboot', 'RunDomainCheckInComplete', 'PromptFixMissingAfterAudit')) {
        $value = Get-EpkObjectProperty -Object $runtimeConfig -Name $name -DefaultValue $null

        if ($null -ne $value) {
            Set-EpkObjectProperty -Object $settingsRuntime -Name $name -Value ([bool]$value)
        }
    }

    $createResumeTask = Get-EpkObjectProperty -Object $runtimeConfig -Name 'CreateResumeTask' -DefaultValue $null
    if ($null -ne $createResumeTask) {
        Set-EpkObjectProperty -Object $settingsRuntime -Name 'ResumeAfterReboot' -Value ([bool]$createResumeTask)
    }

    Set-EpkObjectProperty -Object $settingsRuntime -Name 'ValidateHashes' -Value ([bool](Get-EpkObjectProperty -Object $securityConfig -Name 'RequireInstallerHashValidation' -DefaultValue $true))
    Set-EpkObjectProperty -Object $settingsRuntime -Name 'AutoGenerateHashCatalogOnOperationalModes' -Value $false
    Set-EpkObjectProperty -Object $settingsRuntime -Name 'AllowHashUpdateInOperationalModes' -Value $false
    Set-EpkObjectProperty -Object $settingsRuntime -Name 'GenerateHtmlReport' -Value ([bool](Get-EpkObjectProperty -Object $reportsConfig -Name 'GenerateHtml' -DefaultValue $true))
    Set-EpkObjectProperty -Object $settingsRuntime -Name 'GenerateTxtReport' -Value ([bool](Get-EpkObjectProperty -Object $reportsConfig -Name 'GenerateTxt' -DefaultValue $true))
    Set-EpkObjectProperty -Object $settingsRuntime -Name 'CollectEvidencePackage' -Value ([bool](Get-EpkObjectProperty -Object $reportsConfig -Name 'GenerateEvidenceZip' -DefaultValue $true))

    $settingsCertificates = Get-EpkObjectProperty -Object $settings -Name 'Certificates' -DefaultValue ([pscustomobject]@{})
    Set-EpkObjectProperty -Object $settings -Name 'Certificates' -Value $settingsCertificates
    Set-EpkObjectProperty -Object $settingsCertificates -Name 'StoreName' -Value ([string](Get-EpkObjectProperty -Object $certificatesConfig -Name 'StoreName' -DefaultValue (Get-EpkObjectProperty -Object $settingsCertificates -Name 'StoreName' -DefaultValue 'Root')))
    Set-EpkObjectProperty -Object $settingsCertificates -Name 'StoreLocation' -Value ([string](Get-EpkObjectProperty -Object $certificatesConfig -Name 'StoreLocation' -DefaultValue (Get-EpkObjectProperty -Object $settingsCertificates -Name 'StoreLocation' -DefaultValue 'LocalMachine')))
    Set-EpkObjectProperty -Object $settingsCertificates -Name 'RequireConfirmation' -Value ([bool](Get-EpkObjectProperty -Object $securityConfig -Name 'RequireCertificateConfirmation' -DefaultValue $true))
    Set-EpkObjectProperty -Object $settingsCertificates -Name 'AllowRootCertificateInstall' -Value ([bool](Get-EpkObjectProperty -Object $securityConfig -Name 'AllowRootCertificateInstall' -DefaultValue $false))

    $settingsPaths = Get-EpkObjectProperty -Object $settings -Name 'Paths' -DefaultValue ([pscustomobject]@{})
    $paths = [ordered]@{}

    foreach ($p in @($settingsPaths.PSObject.Properties)) {
        $paths[$p.Name] = Resolve-EpkPath -Root $Root -PathValue ([string]$p.Value)
    }

    $profileBaseDirectory = Split-Path -Parent $profilePath
    $reportsOutput = [string](Get-EpkObjectProperty -Object $reportsConfig -Name 'OutputPath' -DefaultValue 'Runtime/Reports')
    $certificatesPath = [string](Get-EpkObjectProperty -Object $certificatesConfig -Name 'Path' -DefaultValue 'Certificates')

    $paths['Reports'] = Resolve-EpkConfigPath -Root $Root -BaseDirectory $profileBaseDirectory -PathValue $reportsOutput
    $paths['Certificates'] = Resolve-EpkConfigPath -Root $Root -BaseDirectory $profileBaseDirectory -PathValue $certificatesPath

    $installDefaultApps = [bool](Get-EpkObjectProperty -Object $appsConfig -Name 'InstallDefaultApps' -DefaultValue $true)
    $apps = @()

    if ($installDefaultApps) {
        $catalogValue = [string](Get-EpkObjectProperty -Object $appsConfig -Name 'Catalog' -DefaultValue 'Config/apps.json')
        $catalogPath = Resolve-EpkConfigPath -Root $Root -BaseDirectory $profileBaseDirectory -PathValue $catalogValue
        $apps = @(Get-EpkRequiredJson -Path $catalogPath)

        $includeIds = Get-EpkStringArray (Get-EpkObjectProperty -Object $appsConfig -Name 'Include' -DefaultValue @())
        $excludeIds = Get-EpkStringArray (Get-EpkObjectProperty -Object $appsConfig -Name 'Exclude' -DefaultValue @())
        $legacyIds = Get-EpkStringArray (Get-EpkObjectProperty -Object $appsConfig -Name 'DefaultAppIds' -DefaultValue @())

        if ($includeIds.Count -eq 0 -and $legacyIds.Count -gt 0) {
            $includeIds = $legacyIds
        }

        if ($includeIds.Count -gt 0) {
            $apps = @($apps | Where-Object { ([string]$_.Id) -in $includeIds })
        }

        if ($excludeIds.Count -gt 0) {
            $apps = @($apps | Where-Object { ([string]$_.Id) -notin $excludeIds })
        }
    }

    $companyProfilePathForOutput = $profilePath -replace '\\', '/'

    return [pscustomobject]@{
        Root = $Root
        Settings = $settings
        CompanyProfile = $companyProfile
        CompanyProfileName = $profileName
        CompanyProfilePath = $companyProfilePathForOutput
        CompanyName = $companyName
        ProductName = $productName
        DisplayName = $displayName
        ReportTitle = $reportTitle
        HostnamePrefix = $hostnamePrefix
        HostnamePattern = $hostnamePattern
        HostnameAllowedTypes = $allowedTypes
        HostnameDefaultMachineType = $defaultMachineType
        HostnameMaxLength = $hostnameMaxLength
        MachineType = $selectedMachineType
        Departments = $departments
        DefaultDepartment = $defaultDepartment
        DomainEnabled = $domainEnabled
        DomainName = $domainName
        DomainOU = $domainOu
        Workgroup = $workgroup
        ExpectedDomain = $expectedDomain
        Network = $networkConfig
        Security = $securityConfig
        RuntimeProfile = $runtimeConfig
        AppsProfile = $appsConfig
        CertificatesProfile = $certificatesConfig
        ReportsProfile = $reportsConfig
        TaskName = $taskName
        Apps = $apps
        Menu = $menu
        UI = $ui
        Theme = $theme
        Paths = $paths
        Session = (New-EpkSession)
    }
}

function Initialize-EpkFolders {
    param([Parameter(Mandatory)]$Context)

    foreach ($key in @('Logs', 'Reports', 'Temp', 'Backup', 'Assets', 'Certificates', 'Installers', 'Evidence')) {
        if (-not $Context.Paths.Contains([object]$key)) {
            continue
        }

        $path = [string]$Context.Paths[$key]

        if (-not (Test-Path $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

Export-ModuleMember -Function Get-EpkJson, Get-EpkRequiredJson, Test-EpkPropertyExists, Get-EpkObjectProperty, Set-EpkObjectProperty, Resolve-EpkPath, Resolve-EpkConfigPath, ConvertTo-EpkSafeName, Get-EpkStringArray, Assert-EpkCompanyConfig, New-EpkDefaultTheme, New-EpkSession, Test-EpkReadOnlyMode, Initialize-EpkContext, Initialize-EpkFolders
