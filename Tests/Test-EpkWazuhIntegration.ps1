[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$folder = Join-Path $root 'Integrations/Wazuh'

# Two top-level decoder definitions are valid in a Wazuh decoder include.
# Wrap only for .NET's XML parser.
$decodersText = Get-Content -LiteralPath (Join-Path $folder 'epk_decoders.xml') -Raw -Encoding UTF8
[xml]$decoders = '<root>' + $decodersText + '</root>'
[xml]$rules = Get-Content -LiteralPath (Join-Path $folder 'epk_rules.xml') -Raw -Encoding UTF8
[xml]$agent = Get-Content -LiteralPath (Join-Path $folder 'windows-agent.localfile.xml') -Raw -Encoding UTF8

if (@($decoders.root.decoder).Count -ne 2) { throw 'Expected the EPK Wazuh decoder and its child.' }
if (@($rules.group.rule).Count -lt 3) { throw 'Expected EPK custom Wazuh rules.' }
if ([string]$agent.localfile.log_format -ne 'syslog') { throw 'EPK log collection must use syslog.' }
if ([string]$agent.localfile.location -notmatch 'Runtime\\Logs') { throw 'Invalid EPK log path example.' }

$ids = @($rules.group.rule | ForEach-Object { [int]$_.id })
if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Duplicate EPK Wazuh rule IDs.' }
if (@($ids | Where-Object { $_ -lt 100000 -or $_ -gt 120000 }).Count -gt 0) { throw 'Custom Wazuh IDs outside the allowed range.' }

$regex = [string]$decoders.root.decoder[1].regex.'#text'
if ([string]::IsNullOrWhiteSpace($regex)) { $regex = [string]$decoders.root.decoder[1].regex.InnerText }
$sample = '[2026-10-21 14:05:09] [ERR] [DOM-027] Domain join blocked by operator'
$match = [regex]::Match($sample, $regex)
if (-not $match.Success -or $match.Groups[1].Value -ne 'ERR' -or $match.Groups[2].Value -ne 'DOM-027') {
    throw 'EPK sample log does not match the decoder expression.'
}
if ([regex]::IsMatch('unrelated event', $regex)) { throw 'Decoder unexpectedly matches unrelated events.' }

Write-Host 'OK: Wazuh XML templates and sample EPK log structure.' -ForegroundColor Green
Write-Host 'NOTE: Wazuh decoder/rule behavior must also be verified with wazuh-logtest on a running manager.' -ForegroundColor Yellow
