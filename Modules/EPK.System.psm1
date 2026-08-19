function Get-EpkSystemInfo {
    $domain = 'N/D'
    $partOfDomain = $false

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $domain = [string]$cs.Domain
        $partOfDomain = [bool]$cs.PartOfDomain
    } catch {}

    $ip = 'N/D'
    try {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254*'
        })
        if ($ips.Count -gt 0) { $ip = [string]$ips[0].IPAddress }
    } catch {}

    return [pscustomobject]@{
        Hostname     = $env:COMPUTERNAME
        Domain       = $domain
        PartOfDomain = $partOfDomain
        IP           = $ip
        User         = "$env:USERDOMAIN\$env:USERNAME"
    }
}

function Get-EpkHardwareInfo {
    $info = [ordered]@{}

    try {
        $prod = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
        $serial = [string]$prod.IdentifyingNumber
        if ([string]::IsNullOrWhiteSpace($serial)) {
            $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
            $serial = [string]$bios.SerialNumber
        }
        $info.Serial = $serial
    } catch { $info.Serial = 'N/D' }

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $info.CPU = (($cpu.Name -replace '\(R\)|\(TM\)|\xAE|\u2122','') -replace '\s+',' ').Trim()
    } catch { $info.CPU = 'N/D' }

    try {
        $mem = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $total = ($mem | Measure-Object -Property Capacity -Sum).Sum
        $speed = ($mem | Where-Object { $_.Speed -gt 0 } | Select-Object -First 1 -ExpandProperty Speed)
        if ($speed) { $info.RAM = '{0:N0} GB @ {1} MHz' -f ($total / 1GB), $speed } else { $info.RAM = '{0:N0} GB' -f ($total / 1GB) }
    } catch { $info.RAM = 'N/D' }

    try {
        $disk = Get-PhysicalDisk -ErrorAction Stop | Sort-Object Size -Descending | Select-Object -First 1
        $info.Disk = '{0} ({1}, {2:N0} GB)' -f $disk.FriendlyName, $disk.MediaType, ($disk.Size / 1GB)
    } catch {
        try {
            $disk = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Sort-Object Size -Descending | Select-Object -First 1
            $info.Disk = '{0} ({1:N0} GB)' -f $disk.Model, ($disk.Size / 1GB)
        } catch {
            $info.Disk = 'N/D'
        }
    }

    return [pscustomobject]$info
}

function Test-EpkStructure {
    param([Parameter(Mandatory)]$Context)

    foreach ($key in @('Config','Modules','Installers','Certificates','Logs','Reports','Temp','Backup')) {
        if (-not $Context.Paths.Contains([object]$key)) { continue }
        $path = [string]$Context.Paths[$key]
        if (Test-Path $path -PathType Container) {
            Write-EpkLog -Context $Context -Area 'CORE' -Level 'OK' -Message "${key}: OK"
        } else {
            Write-EpkLog -Context $Context -Area 'CORE' -Level 'WRN' -Message "${key}: missing"
        }
    }
}

Export-ModuleMember -Function Get-EpkSystemInfo, Get-EpkHardwareInfo, Test-EpkStructure
