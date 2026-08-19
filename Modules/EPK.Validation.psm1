function Test-EpkAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-EpkWindowsValidation {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'WIN' -Title 'Local Windows validation'

    if (Test-EpkAdmin) {
        Write-EpkLog -Context $Context -Area 'WIN' -Level 'OK' -Message 'PowerShell Admin: OK'
    } else {
        Write-EpkLog -Context $Context -Area 'WIN' -Level 'ERR' -Message 'PowerShell Admin: required'
    }

    $caption = ''
    $supported = $false

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $caption = [string]$os.Caption

        foreach ($edition in @($Context.Settings.Validation.SupportedWindowsEditions)) {
            if ($caption -match [regex]::Escape([string]$edition)) { $supported = $true }
        }

        $level = if ($supported) { 'OK' } elseif ([bool]$Context.Settings.Runtime.BlockOnUnsupportedEdition) { 'ERR' } else { 'WRN' }
        Write-EpkLog -Context $Context -Area 'WIN' -Level $level -Message ("Edition: {0}" -f $caption)
        Write-EpkLog -Context $Context -Area 'WIN' -Level 'OK' -Message ("Build: {0}" -f $os.BuildNumber)
        Write-EpkLog -Context $Context -Area 'WIN' -Level 'OK' -Message ("Architecture: {0}" -f $os.OSArchitecture)
    } catch {
        Write-EpkLog -Context $Context -Area 'WIN' -Level 'WRN' -Message 'System: not queried'
    }

    if (-not [string]::IsNullOrWhiteSpace($caption) -and -not $supported -and [bool]$Context.Settings.Runtime.BlockOnUnsupportedEdition) {
        throw "Unsupported Windows edition: $caption"
    }

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $level = if ($tpm.TpmPresent) { 'OK' } else { 'WRN' }
        Write-EpkLog -Context $Context -Area 'WIN' -Level $level -Message ("TPM: Present={0}; Ready={1}" -f $tpm.TpmPresent, $tpm.TpmReady)
    } catch {
        Write-EpkLog -Context $Context -Area 'WIN' -Level 'WRN' -Message 'TPM: not queried'
    }

    Add-EpkAction -Context $Context -Text 'Local Windows validation completed'
}

Export-ModuleMember -Function Test-EpkAdmin, Invoke-EpkWindowsValidation
