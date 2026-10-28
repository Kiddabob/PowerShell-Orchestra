#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'LayeredAudio.cs')
. (Join-Path $PSScriptRoot 'ScreenLayout.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('layered-music-check-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Write-Midi([string] $Path, [byte[][]] $Tracks) {
    $writer = New-Object IO.BinaryWriter ([IO.File]::Create($Path))
    try {
        $writer.Write([byte[]]@(77,84,104,100,0,0,0,6,0,1,0,$Tracks.Count,1,224))
        foreach ($track in $Tracks) {
            $size = $track.Length
            $writer.Write([byte[]]@(77,84,114,107,0,0,($size -shr 8),($size -band 255)))
            $writer.Write($track)
        }
    } finally { $writer.Dispose() }
}
try {
    # Exercise the actual display helpers without starting the player.
    $tokens=$null; $parseErrors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Play-RushE-Layers.ps1'), [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'PowerShell player has parse errors.'
    foreach ($name in @('New-NoteEvents','Show-Notes','Write-Json','Read-Json')) {
        $helper = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([ScriptBlock]::Create($helper.Extent.Text))
    }
    $displayNotes = foreach ($start in @(4000,0)) {
        $note=New-Object LayeredMusic.Note
        $note.Pitch=64; $note.StartMs=$start; $note.EndMs=$start+62.5
        $note
    }
    $displayEvents = @(New-NoteEvents $displayNotes)
    Assert ($displayEvents.Count -eq 4 -and $displayEvents[0].TimeMs -eq 0 -and $displayEvents[0].Action -eq 'ON' -and $displayEvents[3].TimeMs -eq 4062.5) 'Live events are not sorted chronologically.'
    $cursor=0
    Show-Notes $displayEvents ([ref]$cursor) 100
    Assert ($cursor -eq 2) 'Live display did not show exactly the notes reached by the audio clock.'
    Write-Output 'PASS: chronological live note events and audio-position filtering.'
    $encodingPath=Join-Path $testRoot 'cross-script-json.json'
    & {param($path) Write-Json $path @{Note='F#4';Label=('m'+[char]0x00E9+'lodie')}} $encodingPath
    $encoded=Read-Json $encodingPath
    Assert ($encoded.Note -eq 'F#4' -and $encoded.Label -eq ('m'+[char]0x00E9+'lodie')) 'Cross-script JSON receipt encoding failed.'
    Write-Output 'PASS: display readiness JSON is self-contained across script scopes.'

    # A note released under sustain continues until pedal-up at tick 960.
    $sustainPath = Join-Path $testRoot 'sustain.mid'
    [byte[]]$sustainTrack = @(0,176,64,127,0,144,60,100,131,96,128,60,0,131,96,176,64,0,0,255,47,0)
    Write-Midi $sustainPath -Tracks (,$sustainTrack)
    $sustainScore = [LayeredMusic.Midi]::Read($sustainPath,1,0,0)
    Assert ($sustainScore.Notes.Count -eq 1 -and $sustainScore.Notes[0].EndMs -eq 1000) 'Sustain pedal duration failed.'
    Write-Output 'PASS: sustain holds a released note until pedal-up.'
    $portsPath = Join-Path $testRoot 'separate-ports.mid'
    [byte[]]$portZero = @(0,255,33,1,0,0,176,64,127,0,144,60,100,131,96,128,60,0,131,96,255,47,0)
    [byte[]]$portOne = @(0,255,33,1,1,0,176,64,0,0,144,64,100,131,96,128,64,0,131,96,255,47,0)
    Write-Midi $portsPath -Tracks @($portZero,$portOne)
    $portsScore=[LayeredMusic.Midi]::Read($portsPath,1,0,0)
    Assert (@($portsScore.Notes | Where-Object { $_.Track -eq 0 -and $_.EndMs -eq 1000 }).Count -eq 1 -and @($portsScore.Notes | Where-Object { $_.Track -eq 1 -and $_.EndMs -eq 500 }).Count -eq 1) 'Sustain controls leaked between MIDI ports.'
    Write-Output 'PASS: multi-port orchestra sustain controls remain independent.'
    $voicesPath=Join-Path $testRoot 'same-register-chord.mid'
    [byte[]]$chordTrack=@(0,144,60,100,0,64,100,0,67,100,131,96,128,60,0,0,64,0,0,67,0,0,255,47,0)
    Write-Midi $voicesPath -Tracks (,$chordTrack)
    $voicesScore=[LayeredMusic.Midi]::Read($voicesPath,1,0,0)
    Assert ($voicesScore.Layers.Count -eq 3 -and @($voicesScore.Notes.Layer | Sort-Object -Unique).Count -eq 3) 'Simultaneous same-register chord notes did not receive separate windows.'
    Write-Output 'PASS: simultaneous notes in one chord get independent voice windows.'

    # Four source tracks, each with simultaneous low/mid/high notes: 12 parts.
    $manyPath = Join-Path $testRoot 'twelve-parts.mid'
    $tracks = New-Object 'Collections.Generic.List[byte[]]'
    for ($ch=0; $ch -lt 4; $ch++) {
        $tracks.Add([byte[]]@(0,(144+$ch),48,100,0,60,100,0,72,100,131,96,(128+$ch),48,0,0,60,0,0,72,0,0,255,47,0))
    }
    Write-Midi $manyPath $tracks.ToArray()
    $manyScore = [LayeredMusic.Midi]::Read($manyPath,1,0,0)
    Assert ($manyScore.Layers.Count -eq 12 -and $manyScore.Notes.Count -eq 12) 'Dynamic part count or running status failed.'
    Assert (@($manyScore.Notes | Where-Object { $_.StartMs -eq 0 -and $_.EndMs -eq 500 }).Count -eq 12) 'Chord durations failed.'
    Write-Output 'PASS: 12 parts, simultaneous chords, running status and full note durations.'
    $limitedScore=[LayeredMusic.Midi]::Read($manyPath,1,0,0,3)
    Assert ($limitedScore.IdealWindows -eq 12 -and $limitedScore.Layers.Count -eq 3 -and $limitedScore.Notes.Count -eq 12) 'Window-budget grouping lost notes or ignored the limit.'
    foreach ($layer in $limitedScore.Layers) {
        $bandNotes=@($limitedScore.Notes | Where-Object Layer -eq $layer.Id)
        Assert ($layer.CombinedVoices -eq 4 -and $bandNotes.Count -eq 4) 'Merged voice count is incorrect.'
        $bands=@($bandNotes | ForEach-Object { if ($_.Pitch -lt 60) { 'Low' } elseif ($_.Pitch -lt 72) { 'Mid' } else { 'High' } } | Sort-Object -Unique)
        Assert ($bands.Count -eq 1 -and $bands[0] -eq $layer.Band) 'Grouping mixed different registers.'
    }
    Write-Output 'PASS: excessive voice windows combine within their register without dropping chord notes.'
    # Three populated registers occupy High/Mid/Low rows on one screen,
    # even when an older shortcut explicitly requests three-screen mode.
    $threePath = Join-Path $testRoot 'three-parts.mid'
    Write-Midi $threePath -Tracks (,$tracks[0])
    foreach ($mode in @('Auto','ThreeScreens')) {
        $smallText = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Play-RushE-Layers.ps1') -MidiFile $threePath -Screens $mode -ScreenCount 0 -PrepareOnly
        if ($LASTEXITCODE -ne 0) { throw 'Three-part layout preparation failed.' }
        $smallJson = $smallText -join "`n"
        $small = $smallJson.Substring($smallJson.IndexOf('{')) | ConvertFrom-Json
        Assert ($small.Windows -eq 3 -and -not $small.ThreeScreens) 'Three parts must use one screen.'
        Assert (@($small.Cells.Monitor | Select-Object -Unique).Count -eq 1) 'Three parts were spread across monitors.'
        $ordered = @($small.Cells | Sort-Object Y)
        Assert (($ordered.Band -join ',') -eq 'High,Mid,Low') 'Rows must run High, Mid, Low from top to bottom.'
        $monitor = @($small.Monitors | Where-Object Device -eq $ordered[0].Monitor)[0]
        Assert (($ordered.Height | Measure-Object -Sum).Sum -eq $monitor.Height) 'Three rows do not fill the screen height.'
        foreach ($cell in $ordered) {
            Assert ($cell.X -eq $monitor.X -and $cell.Width -eq $monitor.Width -and [Math]::Abs($cell.Height-$monitor.Height/3.0) -le 1) 'Three-row dimensions are incorrect.'
        }
    }
    Write-Output 'PASS: three parts use full-width High/Mid/Low rows on one screen in both launch modes.'
    $layoutText = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Play-RushE-Layers.ps1') -MidiFile $manyPath -ScreenCount 0 -PrepareOnly
    if ($LASTEXITCODE -ne 0) { throw 'Layout preparation failed.' }
    $layoutJson = ($layoutText -join "`n")
    $layout = $layoutJson.Substring($layoutJson.IndexOf('{')) | ConvertFrom-Json
    Assert ($layout.Windows -eq 12) 'Layout lost parts above nine.'
    if ($layout.Monitors.Count -ge 3) {
        Assert $layout.ThreeScreens 'Automatic three-screen selection failed above nine parts.'
        Assert (@($layout.Cells.Monitor | Select-Object -Unique).Count -eq 3) 'Three-screen distribution failed.'
        foreach ($band in @('Low','Mid','High')) {
            Assert (@($layout.Cells | Where-Object Band -eq $band | Select-Object -ExpandProperty Monitor -Unique).Count -eq 1) 'Register split across incorrect monitors.'
        }
    }
    foreach ($cell in $layout.Cells) {
        $monitor = @($layout.Monitors | Where-Object Device -eq $cell.Monitor)[0]
        Assert ($cell.X -ge $monitor.X -and $cell.Y -ge $monitor.Y -and ($cell.X+$cell.Width) -le ($monitor.X+$monitor.Width) -and ($cell.Y+$cell.Height) -le ($monitor.Y+$monitor.Height)) 'A tile is outside its monitor work area.'
    }
    Write-Output 'PASS: adaptive grid above nine parts, register-to-monitor mapping and screen bounds.'
    # Model different devices without changing the user's actual display settings.
    foreach($screenCount in 1..6) {
        $virtual=@(for($i=0;$i -lt $screenCount;$i++){
            [PSCustomObject]@{Device=('Virtual-'+$i);Primary=($i -eq [Math]::Floor($screenCount/2));X=($i-2)*1920;Y=($i%2)*120;Width=1920;Height=1080;Scale=1}
        })
        $budget=Get-PlayerScreenBudget $virtual 0 'Auto'
        foreach($requested in 1..($screenCount+1)){
            $selected=@(Select-PlayerScreens $virtual $requested)
            Assert ($selected.Count -eq [Math]::Min($requested,$screenCount)) 'Explicit screen count was not clamped to connected displays.'
            Assert (@($selected|Where-Object Primary).Count -eq 1) 'Explicit screen selection omitted the primary display.'
        }
        if($screenCount -ge 2){
            $selected=@(Select-PlayerScreens $virtual 2);$sparse=[LayeredMusic.Midi]::Read($threePath,1,0,0)
            $explicitCells=@(New-PlayerScreenLayout $sparse $selected 'Auto' $false $true)
            Assert (@($explicitCells.Monitor|Sort-Object -Unique).Count -eq 2) 'Explicit dual-screen choice was ignored for a three-part song.'
        }
        $deviceScore=[LayeredMusic.Midi]::Read($manyPath,1,0,0,$budget.Limit)
        $deviceCells=@(New-PlayerScreenLayout $deviceScore $virtual 'Auto' $false)
        Assert ($deviceCells.Count -le $budget.Limit -and $deviceScore.Notes.Count -eq 12) 'Device window budget dropped notes or exceeded its limit.'
        Assert (@($deviceCells.Monitor | Select-Object -Unique).Count -eq $screenCount) 'Available monitors were not filled for a populated large layout.'
        Assert (@($deviceCells.Id | Sort-Object -Unique).Count -eq $deviceScore.Layers.Count) 'A part was duplicated or omitted.'
        foreach($monitor in $virtual) {
            $onScreen=@($deviceCells | Where-Object Monitor -eq $monitor.Device)
            $area=0
            foreach($cell in $onScreen) {
                Assert ($cell.X -ge $monitor.X -and $cell.Y -ge $monitor.Y -and $cell.X+$cell.Width -le $monitor.X+$monitor.Width -and $cell.Y+$cell.Height -le $monitor.Y+$monitor.Height) 'Device tile extends outside the usable screen.'
                $area+=$cell.Width*$cell.Height
            }
            Assert ($area -eq $monitor.Width*$monitor.Height) 'A screen grid does not fill its usable area.'
            if($screenCount -ne 3){
                foreach($pair in @(@('High','Mid'),@('Mid','Low'),@('High','Low'))){
                    $upper=@($onScreen|Where-Object Band -eq $pair[0]);$lower=@($onScreen|Where-Object Band -eq $pair[1])
                    if($upper.Count -and $lower.Count){$bottom=($upper|ForEach-Object {$_.Y+$_.Height}|Measure-Object -Maximum).Maximum;$top=($lower.Y|Measure-Object -Minimum).Minimum;Assert ($bottom -le $top) 'Register rows overlap or have the wrong vertical order.'}
                }
                foreach($row in $onScreen|Group-Object Y){Assert (@($row.Group.Band|Sort-Object -Unique).Count -eq 1) 'A row mixes different registers.'}
                if($screenCount -le 2){Assert (@($onScreen.Band|Sort-Object -Unique).Count -eq 3) 'A register was needlessly confined to one monitor.'}
            }
            for($a=0;$a -lt $onScreen.Count;$a++){for($b=$a+1;$b -lt $onScreen.Count;$b++){
                $one=$onScreen[$a];$two=$onScreen[$b]
                Assert (-not($one.X -lt $two.X+$two.Width -and $two.X -lt $one.X+$one.Width -and $one.Y -lt $two.Y+$two.Height -and $two.Y -lt $one.Y+$one.Height)) 'Two device tiles overlap.'
            }}
        }
    }
    Write-Output 'PASS: 1-6-screen automatic budgets, full screen coverage, negative coordinates and non-overlapping grids.'
    Write-Output 'PASS: selected screen counts, primary display inclusion, disconnected-screen clamping and explicit dual-screen layouts.'
    Write-Output 'PASS: High/Mid/Low rows on one/two screens, all available bands spread across both screens, and dedicated registers only for three screens.'

    # Verify the audio contains both pitches, not merely a monophonic projection.
    $chord = New-Object LayeredMusic.Score
    $chord.DurationMs = 1000
    foreach ($pitch in @(60,64,67)) {
        $n = New-Object LayeredMusic.Note
        $n.Pitch=$pitch; $n.Velocity=100; $n.StartMs=0; $n.EndMs=1000
        $chord.Notes.Add($n)
    }
    $wavePath = Join-Path $testRoot 'chord.wav'
    [LayeredMusic.Synth]::Render($chord,$wavePath,0.35)
    $wave = [IO.File]::ReadAllBytes($wavePath)
    Assert ($wave.Length -eq 44144) 'Rendered WAV duration or header failed.'
    $peak = 0
    $energies = @()
    foreach ($pitch in @(60,64,67)) {
        $frequency = 440*[Math]::Pow(2,($pitch-69)/12.0)
        $real=0.0; $imaginary=0.0
        for ($sample=2205; $sample -lt 19845; $sample++) {
            $value = [BitConverter]::ToInt16($wave,44+2*$sample)
            $peak = [Math]::Max($peak,[Math]::Abs([int]$value))
            $phase = 2*[Math]::PI*$frequency*$sample/22050
            $real += $value*[Math]::Cos($phase); $imaginary += $value*[Math]::Sin($phase)
        }
        $energies += [Math]::Sqrt($real*$real+$imaginary*$imaginary)/17640
    }
    Assert (@($energies | Where-Object { $_ -gt 500 }).Count -eq 3) 'A chord pitch is missing from the rendered waveform.'
    Assert ($peak -le 11469) 'Mixed waveform exceeded the requested volume ceiling.'
    Write-Output 'PASS: all three chord frequencies are present, with no sample clipping.'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTestRoot) -notlike 'layered-music-check-*') { throw 'Unexpected temporary test path; refusing cleanup.' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
