#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$JobDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Catalogue.ps1')
$jobs=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Jobs'))
$job=[IO.Path]::GetFullPath($JobDirectory)
if([IO.Path]::GetDirectoryName($job) -ne $jobs -or [IO.Path]::GetFileName($job) -notmatch '^[a-f0-9]{32}$'){throw 'Unexpected catalogue job directory.'}
try{
    $jobRequest=Get-Content -LiteralPath (Join-Path $job 'input.json') -Raw|ConvertFrom-Json
    if($jobRequest.Action -eq 'Search'){$result=Search-OrchestraCatalogue $jobRequest.Query $jobRequest.Provider $jobRequest.Page}
    elseif($jobRequest.Action -in @('Preview','Add')){
        $result=Get-OrchestraCatalogueMidi $jobRequest.Item -RenderPreview:($jobRequest.Action -eq 'Preview')
        if($jobRequest.Action -eq 'Add'){$result=Add-OrchestraCatalogueSong $result}
    }else{throw 'Unknown catalogue action.'}
    Save-CatalogueJson (Join-Path $job 'result.json') @{Ok=$true;Result=$result}
}catch{Save-CatalogueJson (Join-Path $job 'result.json') @{Ok=$false;Error=$_.Exception.Message}}
