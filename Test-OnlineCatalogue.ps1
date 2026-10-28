#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Catalogue\Catalogue.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$bit='<script>window.initStore ='+[Environment]::NewLine+'{"data":{"midis":{"one":{"name":"Test & melody.mid","url":"/test-mid","downloadUrl":"/uploads/12.mid"},"bad":{"name":"bad.mid","url":"https://other.example/","downloadUrl":"/uploads/13.mid"}}}}</script>'
$items=@(ConvertFrom-CatalogueResults $bit 'BitMidi')
Assert ($items.Count -eq 1 -and $items[0].Title -eq 'Test & melody') 'BitMidi parsing or source validation failed.'
$free='<h5 class=card-title><a href=download3-12-test title="Test">Test &amp; melody</a></h5><div class=card-text><a href="/artist-1-test">An Artist</a></div>'
$items=@(ConvertFrom-CatalogueResults ($free+$free) 'FreeMIDI')
Assert ($items.Count -eq 1 -and $items[0].Title -eq 'Test & melody' -and $items[0].Artist -eq 'An Artist') 'FreeMIDI title/artist parsing or duplicate result filtering failed.'
foreach($url in @('file:///C:/test.mid','https://bitmidi.com.evil.example/uploads/12.mid','https://freemidi.org:8443/getter-1')){
    $rejected=$false;try{$null=Assert-CatalogueUrl $url}catch{$rejected=$true};Assert $rejected ('Unexpected address accepted: '+$url)
}
'PASS: actual provider markup, entities, duplicate cards and source URL restrictions.'
$id=[Guid]::NewGuid().ToString('N');$fixture=Join-Path $PSScriptRoot ('Catalogue\test-'+$id)
[void][IO.Directory]::CreateDirectory($fixture)
$cacheFiles=New-Object Collections.Generic.List[string]
# The test substitutes response bytes, exercising the real validation/save path without network.
function Get-CatalogueResponse([string]$Url,[Net.CookieContainer]$Cookies,[string]$Referer){return ,$script:responseBytes}
function New-FixtureMidi([int]$Pitch){
    return ,[byte[]]@(77,84,104,100,0,0,0,6,0,0,0,1,1,224,77,84,114,107,0,0,0,13,0,144,$Pitch,100,131,96,128,$Pitch,0,0,255,47,0)
}
try{
    $item=[PSCustomObject]@{Provider='BitMidi';Title='CON';Artist='';SourceUrl=('https://bitmidi.com/orchestra-test-'+$id);DownloadUrl='https://bitmidi.com/uploads/12.mid'}
    $key=Get-CatalogueKey $item.SourceUrl;$cacheFiles.Add((Join-Path $PSScriptRoot ('Catalogue\MidiCache\'+$key+'.mid')))
    $cacheFiles.Add((Join-Path $PSScriptRoot ('Catalogue\MidiCache\'+$key+'.wav')))
    $script:responseBytes=New-FixtureMidi 60
    $entry=Get-OrchestraCatalogueMidi $item -RenderPreview
    $cacheFiles.Add($entry.Wave)
    Assert ($entry.Notes -eq 1 -and (Get-Item -LiteralPath $entry.Wave).Length -gt 1000) 'Preview did not render the validated MIDI.'
    $added=Add-OrchestraCatalogueSong $entry $fixture
    Assert (-not $added.AlreadyAdded -and [IO.Path]::GetFileName($added.Midi) -eq 'Song CON.mid') 'Reserved filename or first import failed.'
    $originalHash=(Get-FileHash -LiteralPath $added.Midi -Algorithm SHA256).Hash
    $again=Add-OrchestraCatalogueSong $entry $fixture
    Assert ($again.AlreadyAdded -and $again.Midi -eq $added.Midi) 'Identical MIDI was duplicated.'
    $source=Get-Content -LiteralPath ($added.Midi+'.source.json') -Raw|ConvertFrom-Json
    Assert ($source.SourceUrl -eq $item.SourceUrl -and $source.Sha256 -eq $originalHash) 'Source attribution or hash was lost.'
    . (Join-Path $PSScriptRoot 'OrchestraLibrary.ps1')
    $song=@(Get-OrchestraSongs $fixture)[0]
    Assert ($song.SourceUrl -eq $item.SourceUrl -and $song.CanDelete) 'Imported song did not enter My Songs with its source link.'
    $item2=$item.PSObject.Copy();$item2.SourceUrl+='-second';$key2=Get-CatalogueKey $item2.SourceUrl
    $cacheFiles.Add((Join-Path $PSScriptRoot ('Catalogue\MidiCache\'+$key2+'.mid')))
    $script:responseBytes=New-FixtureMidi 64
    $entry2=Get-OrchestraCatalogueMidi $item2
    $second=Add-OrchestraCatalogueSong $entry2 $fixture
    Assert (-not $second.AlreadyAdded -and $second.Midi -ne $added.Midi) 'Different arrangement with the same title was not retained.'
    Assert ((Get-FileHash -LiteralPath $added.Midi -Algorithm SHA256).Hash -eq $originalHash) 'Existing MIDI was overwritten.'
    'PASS: preview rendering, My Songs import, reserved names, exact duplicate detection, alternative arrangements, source attribution and no overwrites.'
    $bad=$item.PSObject.Copy();$bad.SourceUrl+='-bad';$badKey=Get-CatalogueKey $bad.SourceUrl
    $script:responseBytes=[Text.Encoding]::UTF8.GetBytes('<html>Download page, not MIDI</html>')
    $rejected=$false;try{$null=Get-OrchestraCatalogueMidi $bad}catch{$rejected=$true};Assert $rejected 'HTML masquerading as MIDI was accepted.'
    Assert (-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot ('Catalogue\MidiCache\'+$badKey+'.mid')))) 'Failed download entered the cache.'
    'PASS: a failed/non-MIDI download cannot enter the cache or song library.'
}finally{
    foreach($file in $cacheFiles){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}}
    $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Catalogue'))
    if([IO.Path]::GetDirectoryName($resolved) -eq $parent -and [IO.Path]::GetFileName($resolved) -eq ('test-'+$id)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
