function Get-EpkDomainJoinSettings {
    param([Parameter(Mandatory)]$Context)

    $domainConfig = $null
    try { $domainConfig = $Context.CompanyProfile.Domain } catch { $domainConfig = $null }
    $joinConfig = Get-EpkObjectProperty -Object $domainConfig -Name 'Join' -DefaultValue ([pscustomobject]@{})

    return [pscustomobject]@{
        Enabled = [bool](Get-EpkObjectProperty -Object $joinConfig -Name 'Enabled' -DefaultValue $false)
        PromptForCredential = [bool](Get-EpkObjectProperty -Object $joinConfig -Name 'PromptForCredential' -DefaultValue $true)
        UseDesiredHostname = [bool](Get-EpkObjectProperty -Object $joinConfig -Name 'UseDesiredHostname' -DefaultValue $true)
        AllowRejoinFromDifferentDomain = [bool](Get-EpkObjectProperty -Object $joinConfig -Name 'AllowRejoinFromDifferentDomain' -DefaultValue $false)
        RenameWhenAlreadyJoined = [bool](Get-EpkObjectProperty -Object $joinConfig -Name 'RenameWhenAlreadyJoined' -DefaultValue $true)
    }
}

function Test-EpkDomainJoinEnabled {
    param([Parameter(Mandatory)]$Context)

    if (-not [bool]$Context.DomainEnabled) { return $false }

    $join = Get-EpkDomainJoinSettings -Context $Context
    if (-not [bool]$join.Enabled) { return $false }

    try { return [bool]$Context.Session.AllowDomainJoin } catch { return $false }
}

function Get-EpkDomainStatus {
    param([Parameter(Mandatory)]$Context)

    $sys = Get-EpkSystemInfo

    if ([bool]$Context.DomainEnabled) {
        $expectedDomain = [string]$Context.DomainName
        $status = 'NOT_JOINED'
        $message = ("Machine is not joined to an AD domain; current workgroup={0}; expected domain={1}" -f [string]$sys.Domain, $expectedDomain)
        $note = 'EPK audits domain membership. Joining also requires Domain.Join.Enabled=true and the -AllowDomainJoin runtime switch.'

        if ([bool]$sys.PartOfDomain -and ([string]$sys.Domain -ieq $expectedDomain)) {
            $status = 'OK'
            $message = ("Joined to expected AD domain: {0}" -f [string]$sys.Domain)
        } elseif ([bool]$sys.PartOfDomain) {
            $status = 'DIFFERENT_DOMAIN'
            $message = ("Joined to a different AD domain: current={0}; expected={1}" -f [string]$sys.Domain, $expectedDomain)
        }

        return [pscustomobject]@{
            Status = $status
            Current = [string]$sys.Domain
            Expected = $expectedDomain
            TargetType = 'DOMAIN'
            PartOfDomain = [bool]$sys.PartOfDomain
            Message = $message
            Note = $note
        }
    }

    $expectedWorkgroup = [string]$Context.Workgroup
    $status = 'OK'
    $message = ("Machine is in expected workgroup: {0}" -f [string]$sys.Domain)

    if ([bool]$sys.PartOfDomain) {
        $status = 'JOINED_TO_DOMAIN'
        $message = ("Machine is joined to AD domain {0}; expected workgroup={1}" -f [string]$sys.Domain, $expectedWorkgroup)
    } elseif ([string]$sys.Domain -ine $expectedWorkgroup) {
        $status = 'DIFFERENT_WORKGROUP'
        $message = ("Machine workgroup differs: current={0}; expected={1}" -f [string]$sys.Domain, $expectedWorkgroup)
    }

    return [pscustomobject]@{
        Status = $status
        Current = [string]$sys.Domain
        Expected = $expectedWorkgroup
        TargetType = 'WORKGROUP'
        PartOfDomain = [bool]$sys.PartOfDomain
        Message = $message
        Note = 'EPK audits workgroup/domain state only. Workgroup changes are not executed automatically.'
    }
}

function Invoke-EpkDomainCheck {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'DOM' -Title 'Domain/workgroup audit'
    $status = Get-EpkDomainStatus -Context $Context

    Write-EpkLog -Context $Context -Area 'DOM' -Level 'RUN' -Message ("Detected domain/workgroup: {0}; joinedToAD={1}" -f [string]$status.Current, [bool]$status.PartOfDomain)
    Write-EpkLog -Context $Context -Area 'DOM' -Level 'RUN' -Message ("Expected {0}: {1}" -f [string]$status.TargetType, [string]$status.Expected)

    if ([string]$status.Status -eq 'OK') {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'OK' -Message $status.Message
        return $true
    }

    Write-EpkLog -Context $Context -Area 'DOM' -Level 'WRN' -Message $status.Message
    Write-EpkLog -Context $Context -Area 'DOM' -Level 'RUN' -Message $status.Note
    return $false
}

function Invoke-EpkDomainApply {
    param([Parameter(Mandatory)]$Context)

    Show-EpkSection -Context $Context -Code 'DOM' -Title 'Domain apply'

    $status = Get-EpkDomainStatus -Context $Context
    $join = Get-EpkDomainJoinSettings -Context $Context

    if (-not [bool]$Context.DomainEnabled) {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'RUN' -Message 'Domain.Enabled=false. Running audit only.'
        return (Invoke-EpkDomainCheck -Context $Context)
    }

    if (-not [bool]$join.Enabled) {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'RUN' -Message 'Domain.Join.Enabled=false. Running audit only.'
        return (Invoke-EpkDomainCheck -Context $Context)
    }

    $allowDomainJoin = $false
    try { $allowDomainJoin = [bool]$Context.Session.AllowDomainJoin } catch {}
    if (-not $allowDomainJoin) {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'WRN' -Message 'Domain join is configured but not authorized for this run. Use -AllowDomainJoin explicitly.'
        return (Invoke-EpkDomainCheck -Context $Context)
    }

    $desiredHost = ''
    try { $desiredHost = [string]$Context.Session.DesiredHost } catch { $desiredHost = '' }
    $newName = ''
    if ([bool]$join.UseDesiredHostname -and -not [string]::IsNullOrWhiteSpace($desiredHost) -and $env:COMPUTERNAME -ine $desiredHost) {
        $newName = $desiredHost
    }

    if (Test-EpkReadOnlyMode -Context $Context) {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'TODO' -Message ("Read-only mode; would join domain {0}" -f [string]$Context.DomainName)
        if (-not [string]::IsNullOrWhiteSpace($newName)) {
            Write-EpkLog -Context $Context -Area 'HOST' -Level 'TODO' -Message ("Read-only mode; domain join would use hostname {0}" -f $newName)
        }
        return $true
    }

    if ([string]$status.Status -eq 'OK') {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'OK' -Message $status.Message
        if (-not [string]::IsNullOrWhiteSpace($newName) -and [bool]$join.RenameWhenAlreadyJoined) {
            try {
                Rename-Computer -NewName $newName -Force -ErrorAction Stop
                $Context.Session.RebootNeeded = $true
                Add-EpkAction -Context $Context -Text ("Hostname changed to {0}" -f $newName)
                Write-EpkLog -Context $Context -Area 'HOST' -Level 'OK' -Message ("Hostname changed to {0}; reboot required" -f $newName)
            } catch {
                Write-EpkLog -Context $Context -Area 'HOST' -Level 'ERR' -Message ("Failed to rename domain-joined computer: {0}" -f $_.Exception.Message)
                return $false
            }
        }
        return $true
    }

    if ([string]$status.Status -eq 'DIFFERENT_DOMAIN' -and -not [bool]$join.AllowRejoinFromDifferentDomain) {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'ERR' -Message 'Machine is joined to a different domain. Rejoin blocked by Domain.Join.AllowRejoinFromDifferentDomain=false.'
        return $false
    }

    if ($Context.Session.Silent) {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'ERR' -Message 'Silent mode cannot prompt for domain credentials. Domain join skipped.'
        return $false
    }

    $credential = $null
    if ([bool]$join.PromptForCredential) {
        $credential = Get-Credential -Message ("Domain credential allowed to join computers to {0}" -f [string]$Context.DomainName)
    }

    $params = @{
        DomainName = [string]$Context.DomainName
        Force = $true
        ErrorAction = 'Stop'
    }
    if ($credential) { $params['Credential'] = $credential }
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.DomainOU)) { $params['OUPath'] = [string]$Context.DomainOU }
    if (-not [string]::IsNullOrWhiteSpace($newName)) { $params['NewName'] = $newName }

    try {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'RUN' -Message ("Joining domain {0}" -f [string]$Context.DomainName)
        if ($params.ContainsKey('OUPath')) { Write-EpkLog -Context $Context -Area 'DOM' -Level 'RUN' -Message ("Target OU: {0}" -f [string]$params['OUPath']) }
        if ($params.ContainsKey('NewName')) { Write-EpkLog -Context $Context -Area 'HOST' -Level 'RUN' -Message ("Domain join will set hostname: {0}" -f [string]$params['NewName']) }
        Add-Computer @params
        $Context.Session.RebootNeeded = $true
        Add-EpkAction -Context $Context -Text ("Joined domain {0}" -f [string]$Context.DomainName)
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'OK' -Message 'Domain join command completed; reboot required'
        return $true
    } catch {
        Write-EpkLog -Context $Context -Area 'DOM' -Level 'ERR' -Message ("Domain join failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

Export-ModuleMember -Function Get-EpkDomainJoinSettings, Test-EpkDomainJoinEnabled, Get-EpkDomainStatus, Invoke-EpkDomainCheck, Invoke-EpkDomainApply
