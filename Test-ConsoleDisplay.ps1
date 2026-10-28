#requires -Version 5.1
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Console-Display.ps1') -PrepareOnly
$canvas=New-Object OrchestraConsole.Canvas;$canvas.Song='Test';$canvas.Part='Chord voice';$canvas.Duration=2000
$marks=New-Object 'Collections.Generic.List[OrchestraConsole.Mark]'
foreach($pitch in @(60,64)){$n=New-Object OrchestraConsole.Mark;$n.Start=0;$n.End=1000;$n.Pitch=$pitch;$n.Name=if($pitch -eq 60){'C4'}else{'E4'};$n.Hz=440*[Math]::Pow(2,($pitch-69)/12);$n.Part='Piano';$marks.Add($n)}
$n=New-Object OrchestraConsole.Mark;$n.Start=1500;$n.End=1800;$n.Pitch=62;$n.Name='D4';$n.Hz=293.665;$n.Part='Piano';$marks.Add($n)
$canvas.Notes=$marks.ToArray();$canvas.Build()
$rows=$canvas.TextPreview(75,19,500)
if($rows.Count -ne 19 -or $rows[1] -notlike 'PS Orchestra>*' -or $rows[3] -notlike '*C4 + E4*'){throw 'Console identity or chord display failed.'}
if($canvas.ShownEvents -ne 2){throw 'Initial live event count failed.'}
$frame=$canvas.Compose(75,19,500)
if(@($frame|Where-Object {$_.Character -eq '>' -and $_.Color -eq 0xB0}).Count -eq 0){throw 'Upcoming notes lack a bright filled bar and onset marker.'}
if(@($frame|Where-Object {$_.Character -eq '#' -and $_.Color -eq 0xF0}).Count -eq 0){throw 'Sounding notes lack a distinct white bar.'}
if($rows[5] -notlike '*NEXT +1.8s*'){throw 'Upcoming-note horizon label missing.'}
$frame=$canvas.Compose(75,19,1200)
if(@($frame|Where-Object {$_.Character -eq '=' -and $_.Color -eq 3}).Count -eq 0){throw 'Played notes did not fade into the trail.'}
foreach($band in @('Low','Mid','High')){
    $canvas.Band=$band;$frame=$canvas.Compose(75,19,500)
    $background=@{Low=0xD0;Mid=0xB0;High=0xE0}[$band]
    if(@($frame|Where-Object {$_.Character -eq '>' -and $_.Color -eq $background}).Count -eq 0){throw "Upcoming bars lost the $band register colour."}
}
$canvas.Band='Mid'
$rows=$canvas.TextPreview(140,45,1600)
if($canvas.ShownEvents -ne 5 -or $rows[3] -notlike '*D4*'){throw 'Audio clock filtering failed.'}
foreach($size in @(@(36,10),@(92,30),@(240,100))){$frame=$canvas.Compose($size[0],$size[1],500);if($frame.Count -ne $size[0]*$size[1]){throw 'Resize frame size failed.'};if(@($frame|Where-Object {$_.Character -eq '#'}).Count -eq 0){throw 'Active note markers missing.'}}
'PASS: genuine console frame, chord labels, chronological events, note activity and small/large resize layouts.'
'PASS: upcoming notes have filled register-colour bars, sounding notes are white, and played notes have dim trails.'
