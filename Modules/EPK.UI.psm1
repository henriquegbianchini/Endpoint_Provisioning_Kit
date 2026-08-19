function Get-EpkThemeColor {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = 'Gray'
    )

    try {
        $value = $Context.Theme.ConsoleColors.$Name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    catch {}

    return $Default
}

function Get-EpkThemeValue {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    try {
        $value = $Context.Theme.$Name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    catch {}

    return $Default
}

function Write-EpkLine {
    param(
        [int]$Width = 72,
        [string]$Char = '=',
        [string]$Color = 'DarkCyan'
    )

    if ([string]::IsNullOrEmpty($Char)) { $Char = '=' }
    Write-Host (($Char.Substring(0, 1)) * $Width) -ForegroundColor $Color
}

function Format-EpkText {
    param([string]$Text, [int]$Length)

    $value = [string]$Text
    if ($value.Length -gt $Length) {
        return ($value.Substring(0, [Math]::Max(0, $Length - 3)) + '...')
    }
    return $value.PadRight($Length)
}

function Get-EpkBannerText {
    param([Parameter(Mandatory)]$Context)

    $useFile = $true
    $bannerFile = 'banner.txt'

    try { $useFile = [bool]$Context.Theme.Banner.UseBannerFile } catch {}
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$Context.Theme.Banner.File)) {
            $bannerFile = [string]$Context.Theme.Banner.File
        }
    } catch {}

    $candidate = Join-Path $Context.Paths.Assets $bannerFile
    if ($useFile -and (Test-Path $candidate -PathType Leaf)) {
        return @(Get-Content -Path $candidate -Encoding UTF8)
    }

    $title = if ($Context.DisplayName) { [string]$Context.DisplayName } elseif ($Context.UI.Title) { [string]$Context.UI.Title } else { 'EPK' }
    $subtitle = if ($Context.ProductName) { [string]$Context.ProductName } elseif ($Context.UI.Subtitle) { [string]$Context.UI.Subtitle } else { 'Endpoint Provisioning Kit' }

    try {
        if ([string]::IsNullOrWhiteSpace($title) -and -not [string]::IsNullOrWhiteSpace([string]$Context.Theme.Banner.FallbackTitle)) { $title = [string]$Context.Theme.Banner.FallbackTitle }
        if ([string]::IsNullOrWhiteSpace($subtitle) -and -not [string]::IsNullOrWhiteSpace([string]$Context.Theme.Banner.FallbackSubtitle)) { $subtitle = [string]$Context.Theme.Banner.FallbackSubtitle }
    } catch {}

    return @($title, $subtitle)
}

function Show-EpkBanner {
    param([Parameter(Mandatory)]$Context)

    if ($Context.Session.Silent) { return }

    Clear-Host
    $width = if ($Context.UI.LineWidth) { [int]$Context.UI.LineWidth } else { 72 }
    $lineChar = Get-EpkThemeValue -Context $Context -Name 'LineChar' -Default '='
    $lineColor = Get-EpkThemeColor -Context $Context -Name 'Line' -Default 'DarkCyan'
    $titleColor = Get-EpkThemeColor -Context $Context -Name 'Title' -Default 'Cyan'
    $textColor = Get-EpkThemeColor -Context $Context -Name 'Text' -Default 'Gray'
    $mutedColor = Get-EpkThemeColor -Context $Context -Name 'Muted' -Default 'DarkGray'

    Write-Host ''
    Write-EpkLine -Width $width -Char $lineChar -Color $lineColor

    foreach ($line in @(Get-EpkBannerText -Context $Context)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-Host ('  {0}' -f $line) -ForegroundColor $titleColor
        }
    }

    Write-EpkLine -Width $width -Char $lineChar -Color $lineColor
    Write-Host ("  Product : {0}" -f $Context.ProductName) -ForegroundColor $textColor
    Write-Host ("  Company : {0}" -f $Context.CompanyName) -ForegroundColor $textColor
    Write-Host ("  Profile : {0}" -f $Context.CompanyProfileName) -ForegroundColor $textColor
    if ($Context.DomainEnabled) {
        Write-Host ("  Domain  : {0}" -f $Context.DomainName) -ForegroundColor $textColor
    } else {
        Write-Host ("  Workgrp : {0}" -f $Context.Workgroup) -ForegroundColor $textColor
    }
    Write-Host ("  Version : {0}" -f $Context.Settings.Version) -ForegroundColor $textColor
    Write-Host ("  Theme   : {0}" -f $Context.Theme.Name) -ForegroundColor $mutedColor
    Write-Host ("  Host    : {0}" -f $env:COMPUTERNAME) -ForegroundColor $textColor
    Write-EpkLine -Width $width -Char $lineChar -Color $lineColor
    Write-Host ''
}

function Show-EpkSection {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Title
    )

    $width = if ($Context.UI.LineWidth) { [int]$Context.UI.LineWidth } else { 72 }
    $sectionChar = Get-EpkThemeValue -Context $Context -Name 'SectionChar' -Default '-'
    $sectionColor = Get-EpkThemeColor -Context $Context -Name 'Section' -Default 'White'
    $lineColor = Get-EpkThemeColor -Context $Context -Name 'Line' -Default 'DarkCyan'

    Write-Host ''
    Write-Host ("[{0}] {1}" -f $Code, $Title.ToUpper()) -ForegroundColor $sectionColor
    Write-EpkLine -Width $width -Char $sectionChar -Color $lineColor
}

function Show-EpkMenu {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'MENU' -Title 'Execution menu'

    $mutedColor = Get-EpkThemeColor -Context $Context -Name 'Muted' -Default 'DarkGray'
    $textColor = Get-EpkThemeColor -Context $Context -Name 'Text' -Default 'Gray'
    $menuColor = Get-EpkThemeColor -Context $Context -Name 'Menu' -Default 'Cyan'
    $accentColor = Get-EpkThemeColor -Context $Context -Name 'Accent' -Default 'Cyan'
    $errorColor = Get-EpkThemeColor -Context $Context -Name 'InputError' -Default 'Red'

    $titleWidth = 24
    $modeWidth = 14
    $descWidth = 58

    try {
        if ($Context.Theme.PSObject.Properties.Name -contains 'MenuStyle' -and $Context.Theme.MenuStyle) {
            if ($Context.Theme.MenuStyle.PSObject.Properties.Name -contains 'TitleWidth') { $titleWidth = [int]$Context.Theme.MenuStyle.TitleWidth }
            if ($Context.Theme.MenuStyle.PSObject.Properties.Name -contains 'ModeWidth') { $modeWidth = [int]$Context.Theme.MenuStyle.ModeWidth }
            if ($Context.Theme.MenuStyle.PSObject.Properties.Name -contains 'DescriptionWidth') { $descWidth = [int]$Context.Theme.MenuStyle.DescriptionWidth }
        }
    } catch {}

    $top = '+----+' + ('-' * ($titleWidth + 2)) + '+' + ('-' * ($modeWidth + 2)) + '+' + ('-' * ($descWidth + 2)) + '+'
    $sep = '+----+' + ('-' * ($titleWidth + 2)) + '+' + ('-' * ($modeWidth + 2)) + '+' + ('-' * ($descWidth + 2)) + '+'
    $bot = '+----+' + ('-' * ($titleWidth + 2)) + '+' + ('-' * ($modeWidth + 2)) + '+' + ('-' * ($descWidth + 2)) + '+'

    Write-Host $top -ForegroundColor $mutedColor
    Write-Host ('| {0,-2} | {1} | {2} | {3} |' -f 'ID', (Format-EpkText -Text 'Operation' -Length $titleWidth), (Format-EpkText -Text 'Mode' -Length $modeWidth), (Format-EpkText -Text 'Operational summary' -Length $descWidth)) -ForegroundColor $textColor
    Write-Host $sep -ForegroundColor $mutedColor

    foreach ($item in @($Context.Menu)) {
        $title = Format-EpkText -Text $item.Title -Length $titleWidth
        $mode  = Format-EpkText -Text $item.Mode -Length $modeWidth
        $desc  = Format-EpkText -Text $item.Description -Length $descWidth
        Write-Host ('| {0,-2} | {1} | {2} | {3} |' -f $item.Id, $title, $mode, $desc) -ForegroundColor $menuColor
    }

    Write-Host $bot -ForegroundColor $mutedColor
    Write-Host ''
    Write-Host 'Quick summary:' -ForegroundColor $accentColor
    Write-Host '  1 = validates integrity and prepares the endpoint.' -ForegroundColor $textColor
    Write-Host '  3 = validates integrity and simulates without changing Windows.' -ForegroundColor $textColor
    Write-Host '  2/5/6 = audit and read-only validation; 4 = manual SHA-256 catalog generation.' -ForegroundColor $textColor

    $valid = @($Context.Menu | ForEach-Object { [string]$_.Id })
    do {
        Write-Host ''
        $choice = Read-Host 'Option'
        if ($choice -notin $valid) {
            Write-Host '  ERR  Invalid option.' -ForegroundColor $errorColor
        }
    } until ($choice -in $valid)

    return ($Context.Menu | Where-Object { [string]$_.Id -eq [string]$choice } | Select-Object -First 1)
}

Export-ModuleMember -Function Get-EpkThemeColor, Get-EpkThemeValue, Write-EpkLine, Format-EpkText, Get-EpkBannerText, Show-EpkBanner, Show-EpkSection, Show-EpkMenu
