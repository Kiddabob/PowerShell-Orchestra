#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SongMix.ps1')
Import-OrchestraMixEngine $PSScriptRoot
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$root=Join-Path $PSScriptRoot ('Mixes\test-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
function Write-TestMidi([string]$Path,[byte[][]]$Tracks){
    $w=[IO.BinaryWriter]::new([IO.File]::Create($Path))
    try{$w.Write([byte[]]@(77,84,104,100,0,0,0,6,0,1,0,$Tracks.Count,1,224));foreach($track in $Tracks){$w.Write([byte[]]@(77,84,114,107,0,0,($track.Length -shr 8),($track.Length -band 255)));$w.Write($track)}}finally{$w.Dispose()}
}
function Get-Rms([byte[]]$Wave,[double]$Start,[double]$End){$sum=0.;$a=[int]($Start*22050);$b=[int]($End*22050);for($i=$a;$i -lt $b;$i++){$sample=[BitConverter]::ToInt16($Wave,44+2*$i);$sum+=[double]$sample*$sample};[Math]::Sqrt($sum/($b-$a))}
function Get-Tone([byte[]]$Wave,[double]$Hz){$re=0.;$im=0.;for($i=2205;$i -lt 6615;$i++){$v=[BitConverter]::ToInt16($Wave,44+2*$i);$phase=2*[Math]::PI*$Hz*$i/22050;$re+=$v*[Math]::Cos($phase);$im+=$v*[Math]::Sin($phase)};[Math]::Sqrt($re*$re+$im*$im)/4410}
try{
    $path=Join-Path $root 'controllers.mid'
    [byte[]]$track=@(0,176,7,127,0,176,11,127,0,144,69,127,131,96,176,11,32,131,96,176,11,127,131,96,176,7,32,130,32,176,11,32,129,64,176,121,0,131,96,176,7,127,131,96,128,69,0,0,255,47,0)
    [byte[]]$otherChannel=@(0,145,81,127,150,64,129,81,0,0,255,47,0)
    [byte[]]$otherPort=@(0,255,33,1,1,0,144,81,127,150,64,128,81,0,0,255,47,0)
    Write-TestMidi $path @($track,$otherChannel,$otherPort)
    $sourceHash=Get-OrchestraMidiHash $path
    $source=[LayeredMusic.Midi]::Read($path,1,0,0)
    Assert ($source.Volumes[1].Count -eq 1 -and $source.Volumes[16].Count -eq 1) 'Controllers leaked between channels or ports.'
    $score=[LayeredMusic.Score]::new();$score.DurationMs=3000;$score.Volumes=$source.Volumes;$score.Notes.Add(($source.Notes|Where-Object {$_.Track -eq 0}|Select-Object -First 1))
    $wav=Join-Path $root 'controllers.wav';[LayeredMusic.Synth]::Render($score,$wav,.35);$wave=[IO.File]::ReadAllBytes($wav)
    $full=Get-Rms $wave .1 .3
    foreach($range in @(@(.6,.8),@(1.6,1.8),@(2.1,2.3))){$ratio=(Get-Rms $wave $range[0] $range[1])/$full;Assert ([Math]::Abs($ratio-32/127.) -lt .015) 'CC7/CC11 or controller reset gain is wrong.'}
    Assert ([Math]::Abs((Get-Rms $wave 1.1 1.3)/$full-1) -lt .01) 'Expression restoration failed.'
    Assert ([Math]::Abs((Get-Rms $wave 2.6 2.8)/$full-1) -lt .01) 'Channel volume restoration failed.'
    'PASS: audible CC7/CC11 changes during held notes, controller reset, and channel/port isolation.'
    $velocity=[LayeredMusic.Score]::new();$velocity.DurationMs=1000
    foreach($i in 0..1){$n=[LayeredMusic.Note]::new();$n.Pitch=69;$n.Velocity=if($i){63}else{127};$n.StartMs=$i*500;$n.EndMs=($i+1)*500;$velocity.Notes.Add($n)}
    [LayeredMusic.Synth]::Render($velocity,$wav,.35);$wave=[IO.File]::ReadAllBytes($wav)
    Assert ([Math]::Abs((Get-Rms $wave .6 .8)/(Get-Rms $wave .1 .3)-63/127.) -lt .01) 'Soft velocities are still being boosted.'
    'PASS: soft note velocity keeps its intended relative level.'
    $chord=[LayeredMusic.Score]::new();$chord.DurationMs=1000
    foreach($i in 0..1){$n=[LayeredMusic.Note]::new();$n.Track=$i;$n.Pitch=69+$i*12;$n.Velocity=127;$n.StartMs=0;$n.EndMs=1000;$chord.Notes.Add($n)}
    [LayeredMusic.Synth]::Render($chord,$wav,.35);$before=[IO.File]::ReadAllBytes($wav)
    $chord.PartGains['0:0:0']=0;[LayeredMusic.Synth]::Render($chord,$wav,.35);$after=[IO.File]::ReadAllBytes($wav)
    Assert ((Get-Tone $after 440) -lt 1) 'Muted part remains audible.'
    Assert ([Math]::Abs((Get-Tone $after 880)/(Get-Tone $before 880)-1) -lt .002) 'Muting a part changed the volume of the other part.'
    'PASS: part mute and fixed mix headroom leave other instruments at the same level.'
    Save-OrchestraSongMix $root $path @{Master=40;Parts=@{'0:0:0'=55}}
    $settings=Get-OrchestraSongMix $root $path;Set-OrchestraScoreMix $score $settings
    Assert ($settings.Master -eq 40 -and [Math]::Abs($score.PartGains['0:0:0']-.55) -lt .0001) 'Saved per-song mix did not round-trip.'
    Assert ((Get-OrchestraMidiHash $path) -eq $sourceHash) 'Mixer modified the original MIDI.'
    $rejected=$false;try{Save-OrchestraSongMix $root $path @{Master=101;Parts=@{}}}catch{$rejected=$true};Assert $rejected 'Out-of-range volume was accepted.'
    'PASS: saved master/part settings, range validation and unchanged original MIDI.'
}finally{
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Mixes'))
    if([IO.Path]::GetDirectoryName($resolved) -eq $parent -and [IO.Path]::GetFileName($resolved) -match '^test-[a-f0-9]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
