function Get-EpkResumeCommand {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Mode = ''
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        $Mode = 'COMPLETE'
        if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'ResumeMode' -and -not [string]::IsNullOrWhiteSpace([string]$Context.Settings.Runtime.ResumeMode)) {
            $Mode = [string]$Context.Settings.Runtime.ResumeMode
        }
    }

    $script = Join-Path $Context.Root 'EndpointProvisioning.ps1'
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('-NoProfile')
    [void]$parts.Add('-ExecutionPolicy Bypass')
    [void]$parts.Add(('-File "{0}"' -f $script))
    [void]$parts.Add(('-Mode {0}' -f $Mode.ToUpperInvariant()))
    [void]$parts.Add(('-Config "{0}"' -f $Context.CompanyProfilePath))
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.MachineType)) { [void]$parts.Add(('-MachineType "{0}"' -f $Context.MachineType)) }
    [void]$parts.Add('-Silent')
    if (-not [string]::IsNullOrWhiteSpace($Context.Session.Sector)) { [void]$parts.Add(('-Sector "{0}"' -f $Context.Session.Sector)) }
    if (-not [string]::IsNullOrWhiteSpace($Context.Session.Asset)) { [void]$parts.Add(('-Asset "{0}"' -f $Context.Session.Asset)) }

    return ('powershell.exe {0}' -f ($parts -join ' '))
}

function Register-EpkResumeAfterReboot {
    param([Parameter(Mandatory)]$Context)

    if (Test-EpkReadOnlyMode -Context $Context) {
        Write-EpkLog -Context $Context -Area 'BOOT' -Level 'TODO' -Message 'Read-only mode: post-reboot resume would be registered'
        return $true
    }

    if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'ResumeAfterReboot' -and -not [bool]$Context.Settings.Runtime.ResumeAfterReboot) {
        Write-EpkLog -Context $Context -Area 'BOOT' -Level 'WRN' -Message 'Retomada pos-reboot desativada em settings.json'
        return $false
    }

    try {
        $cmd = Get-EpkResumeCommand -Context $Context
        $taskName = [string]$Context.TaskName
        $resumeCmd = Join-Path $Context.Paths.Temp 'epk_resume_after_reboot.cmd'
        $cmdLines = @(
            '@echo off',
            ('schtasks.exe /Delete /TN "{0}" /F >nul 2>nul' -f $taskName),
            $cmd
        )
        $cmdLines | Set-Content -Path $resumeCmd -Encoding ASCII -Force

        $taskRegistered = $false
        try {
            $tr = ('cmd.exe /c "{0}"' -f $resumeCmd)
            schtasks.exe /Create /TN $taskName /TR $tr /SC ONLOGON /RL HIGHEST /F | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $taskRegistered = $true
                Write-EpkLog -Context $Context -Area 'BOOT' -Level 'OK' -Message 'Retomada pos-reboot registrada como tarefa agendada elevada'
            } else {
                Write-EpkLog -Context $Context -Area 'BOOT' -Level 'WRN' -Message ("schtasks retornou codigo {0}; usando RunOnce" -f $LASTEXITCODE)
            }
        } catch {
            Write-EpkLog -Context $Context -Area 'BOOT' -Level 'WRN' -Message ("Scheduled task failed; falling back to RunOnce: {0}" -f $_.Exception.Message)
        }

        if (-not $taskRegistered) {
            $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name $taskName -Value ('cmd.exe /c "{0}"' -f $resumeCmd) -PropertyType String -Force | Out-Null
            Write-EpkLog -Context $Context -Area 'BOOT' -Level 'OK' -Message 'Retomada pos-reboot registrada no RunOnce'
        }

        Add-EpkAction -Context $Context -Text 'Retomada pos-reboot registrada'
        return $true
    }
    catch {
        Write-EpkLog -Context $Context -Area 'BOOT' -Level 'ERR' -Message ("Failed to register post-reboot resume: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-EpkAutoRebootIfNeeded {
    param([Parameter(Mandatory)]$Context)

    if (-not $Context.Session.RebootNeeded) { return $false }

    if (Test-EpkReadOnlyMode -Context $Context) {
        Write-EpkLog -Context $Context -Area 'BOOT' -Level 'TODO' -Message 'Read-only mode: reboot would be required, but no resume task or restart will be created'
        return $false
    }

    [void](Register-EpkResumeAfterReboot -Context $Context)

    $auto = $false
    if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'AutoRebootIfNeeded') { $auto = [bool]$Context.Settings.Runtime.AutoRebootIfNeeded }

    if (-not [bool]$Context.Session.AllowReboot) {
        Write-EpkLog -Context $Context -Area 'BOOT' -Level 'WRN' -Message 'Reboot required but not started automatically. Use -AllowReboot only when automatic reboot is authorized.'
        return $false
    }

    if (-not $auto) {
        Write-EpkLog -Context $Context -Area 'BOOT' -Level 'WRN' -Message 'Reboot necessario; reinicializacao automatica desativada em settings.json'
        return $false
    }

    $delay = 15
    if ($Context.Settings.Runtime.PSObject.Properties.Name -contains 'RebootDelaySeconds') { $delay = [int]$Context.Settings.Runtime.RebootDelaySeconds }
    if ($delay -lt 0) { $delay = 0 }

    if ($Context.Session.DryRun) {
        Write-EpkLog -Context $Context -Area 'BOOT' -Level 'TODO' -Message 'DryRun: machine would be automatically restarted'
        return $true
    }

    Write-EpkLog -Context $Context -Area 'BOOT' -Level 'WRN' -Message ("Rebooting in {0}s to complete installations" -f $delay)
    Add-EpkAction -Context $Context -Text 'Reboot automatico solicitado pelo EPK'
    shutdown.exe /r /t $delay /c "$($Context.DisplayName): reboot required to complete installations and validate again" | Out-Null
    return $true
}

Export-ModuleMember -Function Get-EpkResumeCommand, Register-EpkResumeAfterReboot, Invoke-EpkAutoRebootIfNeeded
