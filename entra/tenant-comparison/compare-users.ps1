#!/usr/bin/env pwsh

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceTenant = ''
$sourceCloud = 'AzureCloud'
$sourceAccount = ''
$skipLogin = $false
$outputFile = "tenant-user-sync-report_{0}.md" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
$secondaries = [System.Collections.Generic.List[string]]::new()

function Show-Usage {
    @"
Usage: $($MyInvocation.MyCommand.Name) --source-tenant <tenant-id> --secondary <tenant-id[:cloud[:account]]> [options]

Compare users in one source Entra tenant with users in one or more secondary tenants.
Users are matched by the local part of their userPrincipalName, case-insensitively.

Required:
  -s, --source-tenant <id>       Source tenant ID or domain
  -t, --secondary <descriptor>   Secondary tenant descriptor; repeat this option

Options:
      --source-cloud <name>      Source Azure cloud (default: $sourceCloud)
      --source-account <name>    Account to use when logging into the source tenant
      --skip-login               Skip az login and use the existing Azure CLI session
  -o, --output <file>            Markdown report path (default: $outputFile)
  -h, --help                     Show this help

Descriptor format:
  <tenant-id>[:<cloud>[:<account>]]

Examples:
  ./$($MyInvocation.MyCommand.Name) --source-tenant source.example.com `
    --secondary secondary.example.com:AzureCloud:admin@bar.com
  ./$($MyInvocation.MyCommand.Name) -s source-tenant-id -t gov-tenant-id:AzureUSGovernment -o report.md

The script runs 'az login' for each tenant. Omit an account when the Azure CLI
can select the correct cached account or your login method does not require one.
"@
}

function Stop-WithError {
    param([Parameter(Mandatory)][string] $Message)
    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Description
    )

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $jsonText = (& $script:azExecutable @Arguments 2> $stderrFile | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $details = (Get-Content -LiteralPath $stderrFile -Raw).Trim()
            if (-not $details) { $details = $jsonText }
            Stop-WithError "$Description failed. $details"
        }
        if (-not $jsonText) {
            Stop-WithError "$Description returned no JSON."
        }
        return ($jsonText | ConvertFrom-Json)
    }
    finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AzText {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Description
    )

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $text = (& $script:azExecutable @Arguments 2> $stderrFile | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $details = (Get-Content -LiteralPath $stderrFile -Raw).Trim()
            if (-not $details) { $details = $text }
            Stop-WithError "$Description failed. $details"
        }
        return $text
    }
    finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AzLogin {
    param(
        [Parameter(Mandatory)][string] $Tenant,
        [Parameter(Mandatory)][string] $Cloud,
        [AllowEmptyString()][string] $Account
    )

    Write-Host "Logging into tenant '$Tenant' in cloud '$Cloud'..."
    & $script:azExecutable cloud set --name $Cloud --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Unable to select Azure cloud '$Cloud'."
    }

    if ($script:skipLogin) {
        return
    }

    $loginArguments = @('login', '--tenant', $Tenant, '--allow-no-subscriptions', '--only-show-errors', '--output', 'none')
    if ($Account) {
        $loginArguments += @('--username', $Account)
    }
    & $script:azExecutable @loginArguments
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Unable to log into tenant '$Tenant' in cloud '$Cloud'."
    }
}

function Get-Users {
    param(
        [Parameter(Mandatory)][string] $Tenant,
        [Parameter(Mandatory)][string] $Cloud
    )

    $graphEndpoint = Invoke-AzText @('cloud', 'show', '--query', 'endpoints.microsoftGraphResourceId', '--output', 'tsv', '--only-show-errors') "Reading Microsoft Graph endpoint for cloud '$Cloud'"
    if (-not $graphEndpoint) {
        Stop-WithError "No Microsoft Graph endpoint found for cloud '$Cloud'."
    }

    $graphBase = $graphEndpoint.TrimEnd('/')
    $nextUrl = "$graphBase/v1.0/users?`$select=id,displayName,userPrincipalName&`$top=999"
    $users = [System.Collections.Generic.List[object]]::new()

    while ($nextUrl) {
        $page = Invoke-AzJson @('rest', '--method', 'get', '--url', $nextUrl, '--output', 'json', '--only-show-errors') "Reading users from tenant '$Tenant'"
        if (-not $page.PSObject.Properties['value']) {
            Stop-WithError "Unexpected Microsoft Graph response while reading tenant '$Tenant'."
        }
        foreach ($user in @($page.value)) {
            [void] $users.Add($user)
        }
        $nextLinkProperty = $page.PSObject.Properties['@odata.nextLink']
        $nextUrl = if ($nextLinkProperty) { [string] $nextLinkProperty.Value } else { '' }
    }

    return $users.ToArray()
}

function Get-LocalPart {
    param([AllowNull()][string] $UserPrincipalName)
    if (-not $UserPrincipalName -or $UserPrincipalName.IndexOf('@') -lt 1) {
        return $null
    }
    return $UserPrincipalName.Split('@', 2)[0].ToLowerInvariant()
}

function ConvertTo-MarkdownCell {
    param([AllowNull()][string] $Value)
    if ($null -eq $Value -or $Value.Length -eq 0) {
        return 'N/A'
    }
    return $Value.Replace('|', '\|')
}

$arguments = @($args)
for ($index = 0; $index -lt $arguments.Count; $index++) {
    $option = $arguments[$index]
    switch ($option) {
        { $_ -in '-s', '--source-tenant' } {
            if ($index + 1 -ge $arguments.Count) { Stop-WithError "$option requires a value" }
            $sourceTenant = $arguments[++$index]
            continue
        }
        '--source-cloud' {
            if ($index + 1 -ge $arguments.Count) { Stop-WithError "$option requires a value" }
            $sourceCloud = $arguments[++$index]
            continue
        }
        '--source-account' {
            if ($index + 1 -ge $arguments.Count) { Stop-WithError "$option requires a value" }
            $sourceAccount = $arguments[++$index]
            continue
        }
        '--skip-login' {
            $skipLogin = $true
            continue
        }
        { $_ -in '-t', '--secondary' } {
            if ($index + 1 -ge $arguments.Count) { Stop-WithError "$option requires a value" }
            $secondaries.Add($arguments[++$index])
            continue
        }
        { $_ -in '-o', '--output' } {
            if ($index + 1 -ge $arguments.Count) { Stop-WithError "$option requires a value" }
            $outputFile = $arguments[++$index]
            continue
        }
        { $_ -in '-h', '--help' } {
            Show-Usage
            exit 0
        }
        default {
            Stop-WithError "Unknown option '$option'"
        }
    }
}

if (-not $sourceTenant) { Show-Usage; Stop-WithError '--source-tenant is required' }
if ($secondaries.Count -eq 0) { Show-Usage; Stop-WithError 'At least one --secondary is required' }
$azCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCommand) { Stop-WithError 'Azure CLI (az) not found in PATH' }
$azPowerShellLauncher = Join-Path (Split-Path -Parent $azCommand.Source) 'azps.ps1'
$script:azExecutable = if ($azCommand.Source -like '*.cmd' -and (Test-Path -LiteralPath $azPowerShellLauncher)) {
    $azPowerShellLauncher
}
else {
    $azCommand.Source
}

$sourceUsers = @()
$sourceKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
Invoke-AzLogin $sourceTenant $sourceCloud $sourceAccount
$sourceUsers = @(Get-Users $sourceTenant $sourceCloud)
foreach ($user in $sourceUsers) {
    $localPart = Get-LocalPart ([string] $user.userPrincipalName)
    if ($localPart) { [void] $sourceKeys.Add($localPart) }
}

$report = [System.Text.StringBuilder]::new()
[void] $report.AppendLine('# Entra Tenant User Synchronization Report')
[void] $report.AppendLine()
[void] $report.AppendLine("**Generated:** $(Get-Date)  ")
[void] $report.AppendLine("**Source tenant:** $sourceTenant  ")
[void] $report.AppendLine("**Source cloud:** $sourceCloud  ")
[void] $report.AppendLine()
$totalMissing = 0

foreach ($descriptor in $secondaries) {
    $parts = $descriptor.Split(':', 3)
    $secondaryTenant = $parts[0]
    $secondaryCloud = if ($parts.Count -ge 2 -and $parts[1]) { $parts[1] } else { 'AzureCloud' }
    $secondaryAccount = if ($parts.Count -eq 3) { $parts[2] } else { '' }
    if (-not $secondaryTenant) { Stop-WithError "Invalid secondary descriptor '$descriptor'" }

    Invoke-AzLogin $secondaryTenant $secondaryCloud $secondaryAccount
    $secondaryUsers = @(Get-Users $secondaryTenant $secondaryCloud)
    $missingUsers = @($secondaryUsers | Where-Object {
        $localPart = Get-LocalPart ([string] $_.userPrincipalName)
        $localPart -and -not $sourceKeys.Contains($localPart)
    } | Sort-Object userPrincipalName)
    $totalMissing += $missingUsers.Count

    [void] $report.AppendLine("## Secondary Tenant: $secondaryTenant")
    [void] $report.AppendLine()
    [void] $report.AppendLine("**Cloud:** $secondaryCloud  ")
    [void] $report.AppendLine("**Users missing from source:** $($missingUsers.Count)")
    [void] $report.AppendLine()
    if ($missingUsers.Count -eq 0) {
        [void] $report.AppendLine('No secondary-only users found.')
    }
    else {
        [void] $report.AppendLine('| Display name | Secondary UPN | Object ID |')
        [void] $report.AppendLine('|--------------|---------------|-----------|')
        foreach ($user in $missingUsers) {
            $displayName = ConvertTo-MarkdownCell ([string] $user.displayName)
            [void] $report.AppendLine("| $displayName | $($user.userPrincipalName) | $($user.id) |")
        }
    }
    [void] $report.AppendLine()
}

[void] $report.AppendLine("**Total secondary-only users:** $totalMissing")
$report.ToString() | Set-Content -LiteralPath $outputFile -Encoding utf8
Write-Host "Report saved to $outputFile"
