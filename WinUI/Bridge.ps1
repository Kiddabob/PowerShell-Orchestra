#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RequestPath,[Parameter(Mandatory=$true)][string]$ResponsePath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'OrchestraLibrary.ps1')
. (Join-Path $root 'SongMix.ps1')
function Get-BridgeSong([string]$Id){$song=Get-OrchestraSongs $root|Where-Object Id -eq $Id|Select-Object -First 1;if(-not $song){throw 'The song is no longer in the library. Refresh My Songs.'};$song}
try{
    $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
    switch($request.Action){
        'Songs' {$result=@(Get-OrchestraSongs $root)}
        'Displays' {Add-Type -AssemblyName System.Windows.Forms;$result=@{Count=[Windows.Forms.Screen]::AllScreens.Count}}
        'Delete' {$song=Get-BridgeSong $request.Id;Remove-OrchestraSong $root $song;$result=@{Deleted=$true}}
        'Rename' {Set-OrchestraSongTitle $root (Get-BridgeSong $request.Id) $request.Title;$result=@{Saved=$true}}
        'IconPrompt' {$result=@{Prompt=(Get-OrchestraIconPrompt (Get-BridgeSong $request.Id))}}
        'SaveIcon' {Add-Type -AssemblyName System.Drawing;$result=@{Icon=(Save-OrchestraSongIcon $root (Get-BridgeSong $request.Id) $request.Path)}}
        'Import' {
            Import-OrchestraMixEngine $root;$null=[LayeredMusic.Midi]::Read($request.Path,1,0,0,24)
            $folder=Join-Path $root 'Library';[void][IO.Directory]::CreateDirectory($folder)
            $name=[IO.Path]::GetFileNameWithoutExtension($request.Path);$path=Join-Path $folder ($name+'.mid');$number=2
            while(Test-Path -LiteralPath $path){$path=Join-Path $folder ($name+' ('+$number+').mid');$number++}
            Copy-Item -LiteralPath $request.Path -Destination $path;$result=@{Path=$path}
        }
        'Mix' {
            $song=Get-BridgeSong $request.Id;Import-OrchestraMixEngine $root;$score=[LayeredMusic.Midi]::Read($song.Midi,1,0,0,24)
            $mix=Get-OrchestraSongMix $root $song.Midi
            $parts=@(foreach($group in $score.Notes|Group-Object MixId){$note=$group.Group[0];@{Id=$group.Name;Name=($note.Part+' / Channel '+($note.Channel+1));Level=$(if($mix.Parts.ContainsKey($group.Name)){$mix.Parts[$group.Name]}else{100})}})
            $result=@{Master=$mix.Master;Parts=$parts}
        }
        'SaveMix' {
            $parts=@{};foreach($part in $request.Parts.PSObject.Properties){$parts[$part.Name]=$part.Value}
            Save-OrchestraSongMix $root (Get-BridgeSong $request.Id).Midi @{Master=$request.Master;Parts=$parts};$result=@{Saved=$true}
        }
        {$_ -in @('Search','Preview','Add')} {
            . (Join-Path $root 'Catalogue\Catalogue.ps1')
            if($request.Action -eq 'Search'){$result=Search-OrchestraCatalogue $request.Query $request.Provider $request.Page}
            else{$entry=Get-OrchestraCatalogueMidi $request.Item -RenderPreview:($request.Action -eq 'Preview');$result=if($request.Action -eq 'Add'){Add-OrchestraCatalogueSong $entry}else{$entry}}
        }
        default {throw 'Unknown Orchestra action.'}
    }
    $response=@{Ok=$true;Result=$result}
}catch{$response=@{Ok=$false;Error=$_.Exception.Message}}
[IO.File]::WriteAllText($ResponsePath,($response|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
