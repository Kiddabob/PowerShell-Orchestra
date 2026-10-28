#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$env:MSBuildEnableWorkloadResolver='false'
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
$project=Join-Path $PSScriptRoot 'PowerShellOrchestra.csproj'
$output=Join-Path (Split-Path -Parent $PSScriptRoot) 'App'
& dotnet publish $project -c Release -p:Platform=x64 -o $output --ignore-failed-sources -v minimal
if($LASTEXITCODE -ne 0){throw 'WinUI publish failed.'}
Write-Host ('Ready: '+(Join-Path $output 'PowerShellOrchestra.exe'))
