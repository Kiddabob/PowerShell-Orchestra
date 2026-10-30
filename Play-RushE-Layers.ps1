#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $MidiFile,
    [string] $SongTitle = 'Rush E',
    [ValidateRange(0.1, 4.0)] [double] $Speed = 1,
    [ValidateRange(-36, 36)] [int] $Transpose = 0,
    [ValidateRange(0, 3600)] [double] $MaxSeconds = 0,
    [ValidateRange(0, 3600)] [double] $StopAfterSeconds = 0,
    [ValidateRange(0.01, 0.9)] [double] $Volume = 0.35,
    [ValidateRange(0,128)] [int] $MaxWindows = 0,
    [ValidateSet('Auto', 'OneScreen', 'AllScreens', 'ThreeScreens')] [string] $Screens = 'Auto',
    [ValidateRange(0,64)][int]$ScreenCount=0,
    [switch] $PrepareOnly,
    [switch] $TextDisplays,
    [ValidateSet('Console','Panels','Text')][string] $DisplayStyle='Console',
    [string] $ValidationReceipt,
    [string] $SessionDirectory,
    [int] $DisplayLayer = -1
)

$ErrorActionPreference = 'Stop'
if(-not $PSBoundParameters.ContainsKey('DisplayStyle')){
    $settings=Join-Path $PSScriptRoot 'player-settings.json'
    if(Test-Path -LiteralPath $settings){try{$savedStyle=(Get-Content -LiteralPath $settings -Raw|ConvertFrom-Json).DisplayStyle;if($savedStyle -in @('Console','Panels','Text')){$DisplayStyle=$savedStyle}}catch{}}
}
if(-not $PSBoundParameters.ContainsKey('ScreenCount')){
    $settings=Join-Path $PSScriptRoot 'player-settings.json'
    if(Test-Path -LiteralPath $settings){try{$saved=(Get-Content -LiteralPath $settings -Raw|ConvertFrom-Json).ScreenCount;if($null -ne $saved -and [int]$saved -ge 0 -and [int]$saved -le 64){$ScreenCount=[int]$saved}}catch{}}
}
if (-not $MidiFile) { $MidiFile = Join-Path $PSScriptRoot 'Rush E.mid' }
$utf8 = New-Object Text.UTF8Encoding $false
if (-not ('LayeredMusic.Midi' -as [type])) {
    # Compile once per source version; dozens of displays share this assembly
    # instead of each starting a separate C# compiler.
    $engineSource = Join-Path $PSScriptRoot 'LayeredAudio.cs'
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $engineHash = [BitConverter]::ToString($hasher.ComputeHash([IO.File]::ReadAllBytes($engineSource))).Replace('-','').Substring(0,16)
    } finally { $hasher.Dispose() }
    $engineFolder = Join-Path $PSScriptRoot 'Engine'
    [void][IO.Directory]::CreateDirectory($engineFolder)
    $engineAssembly = Join-Path $engineFolder ('LayeredAudio.{0}.dll' -f $engineHash)
    if (-not (Test-Path -LiteralPath $engineAssembly)) {
        Add-Type -Path $engineSource -OutputAssembly $engineAssembly -OutputType Library
    }
    Add-Type -Path $engineAssembly
}
[void][LayeredMusic.ConsoleTile]::SetProcessDPIAware()
[LayeredMusic.ConsoleTile]::SetIcon((Join-Path $PSScriptRoot 'PowerShell-Orchestra-Note.ico'))
. (Join-Path $PSScriptRoot 'ScreenLayout.ps1')

function Read-Json([string] $Path) {
    for ($attempt=0; $attempt -lt 5; $attempt++) {
        try {
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
            try { $value = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            if ($null -eq $value) { throw 'Playback state write is in progress.' }
            return $value
        } catch { if ($attempt -ge 4) { throw }; Start-Sleep -Milliseconds 10 }
    }
}

function Write-Json([string] $Path, $Value) {
    # Readers retry during the very short write window.
    $text = $Value | ConvertTo-Json -Depth 8 -Compress
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    try { $writer.Write($text) } finally { $writer.Dispose() }
}

function Show-Notes($Events, [ref] $Index, [double] $Position) {
    while ($Index.Value -lt $Events.Count -and $Events[$Index.Value].TimeMs -le $Position) {
        $entry = $Events[$Index.Value]
        $stamp = [TimeSpan]::FromMilliseconds($entry.TimeMs).ToString('mm\:ss\.fff')
        $color = if ($entry.Action -eq 'ON') { 'Green' } else { 'DarkGray' }
        Write-Host ('{0} {1,-3} {2,-4} {3,5:N0}Hz {4,5:N0}ms {5}' -f $stamp, $entry.Action, $entry.Note, $entry.Hertz, $entry.DurationMs, $entry.Part) -ForegroundColor $color
        $Index.Value++
    }
}

function New-NoteEvents($Notes) {
    $events = New-Object Collections.Generic.List[object]
    foreach ($note in $Notes) {
        $duration = $note.EndMs - $note.StartMs
        $events.Add([PSCustomObject]@{ TimeMs=$note.StartMs; Action='ON'; Note=$note.Name; Hertz=$note.Hertz; DurationMs=$duration; Part=$note.Part })
        $events.Add([PSCustomObject]@{ TimeMs=$note.EndMs; Action='OFF'; Note=$note.Name; Hertz=$note.Hertz; DurationMs=$duration; Part=$note.Part })
    }
    $events.ToArray() | Sort-Object @{Expression={ [double]$_.TimeMs }}, @{Expression={ if ($_.Action -eq 'OFF') { 0 } else { 1 } }}
}

if($TextDisplays){$DisplayStyle='Text'}
if($DisplayLayer -ge 0 -and $DisplayStyle -ne 'Text'){
    $displayScript=if($DisplayStyle -eq 'Panels'){'Note-Display.ps1'}else{'Console-Display.ps1'}
    try{& (Join-Path $PSScriptRoot $displayScript) -SessionDirectory $SessionDirectory -DisplayLayer $DisplayLayer}
    catch{Write-Json (Join-Path $SessionDirectory ('error-'+$DisplayLayer+'.json')) @{Message=$_.Exception.Message;Stack=$_.ScriptStackTrace};throw}
    return
}
if ($DisplayLayer -ge 0) {
    $config = Read-Json (Join-Path $SessionDirectory 'session.json')
    $SongTitle = $config.SongTitle
    $cell = @($config.Cells | Where-Object { $_.Id -eq $DisplayLayer })[0]
    $events = @(Read-Json (Join-Path $SessionDirectory ('events-{0}.json' -f $DisplayLayer)))
    $Host.UI.RawUI.WindowTitle = 'PowerShell Orchestra | ' + $SongTitle + ' | ' + $cell.Title
    try {
        # Narrow scrollback for small tiles; native sizing below sets the actual rectangle.
        $raw = $Host.UI.RawUI
        $raw.WindowSize = New-Object Management.Automation.Host.Size 45, 10
        $raw.BufferSize = New-Object Management.Automation.Host.Size 45, 1000
    } catch { }
    $bounds = [LayeredMusic.ConsoleTile]::Place($cell.X, $cell.Y, $cell.Width, $cell.Height)
    Clear-Host
    Write-Host $cell.Title -ForegroundColor Cyan
    Write-Host 'Time      On/Off Note    Pitch   Length Part'
    Write-Host 'Waiting for the shared audio clock...'
    Write-Json (Join-Path $SessionDirectory ('ready-{0}.json' -f $DisplayLayer)) @{ Id=$DisplayLayer; Bounds=$bounds; Pid=$PID; TopMost=[LayeredMusic.ConsoleTile]::IsTopMost; IconApplied=[LayeredMusic.ConsoleTile]::HasCustomIcon }
    $index = 0
    $startupFocusAttempted=$false
    $startupFocusReleased=$false
    $healthTimer = [Diagnostics.Stopwatch]::StartNew()
    try { while ($true) {
        try { $state = Read-Json (Join-Path $SessionDirectory 'state.json') } catch { Start-Sleep -Milliseconds 30; continue }
        if ($state.Status -ne 'Preparing') {
            if(-not $startupFocusAttempted){$startupFocusReleased=[LayeredMusic.ConsoleTile]::ReleaseFocus();$startupFocusAttempted=$true}
            Show-Notes $events ([ref] $index) $state.PositionMs
        }
        if ($healthTimer.ElapsedMilliseconds -ge 500) {
            $clock = [TimeSpan]::FromMilliseconds($state.PositionMs).ToString('mm\:ss')
            $Host.UI.RawUI.WindowTitle = 'PowerShell Orchestra | ' + $SongTitle + ' | ' + $cell.Title + ' | ' + $clock
            Write-Json (Join-Path $SessionDirectory ('ready-{0}.json' -f $DisplayLayer)) @{ Id=$DisplayLayer; Bounds=$bounds; Pid=$PID; ShownEvents=$index; EventCount=$events.Count; FirstEventMs=$events[0].TimeMs; PositionMs=$state.PositionMs; TopMost=[LayeredMusic.ConsoleTile]::IsTopMost; Foreground=[LayeredMusic.ConsoleTile]::IsForeground; StartupFocusReleased=$startupFocusReleased; IconApplied=[LayeredMusic.ConsoleTile]::HasCustomIcon }
            $healthTimer.Restart()
        }
        if ($state.Status -in @('Complete', 'Stopped', 'Error')) { break }
        if (-not (Get-Process -Id $config.MasterPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 30
    } } catch {
        Write-Json (Join-Path $SessionDirectory ('error-{0}.json' -f $DisplayLayer)) @{ Message=$_.Exception.Message; Id=$DisplayLayer }
        throw
    }
    # The child PowerShell has no -NoExit, so its temporary console closes now.
    return
}

$Host.UI.RawUI.WindowTitle = 'PowerShell Orchestra | ' + $SongTitle + ' | MASTER'
[LayeredMusic.ConsoleTile]::Raise()
Write-Host ('PowerShell Orchestra - ' + $SongTitle) -ForegroundColor Cyan
Write-Host 'Reading the MIDI and preparing overlapping tones...'
$detectedMonitors = @(Get-PlayerScreens)
$monitors = @(Select-PlayerScreens $detectedMonitors $ScreenCount)
$screenBudget = Get-PlayerScreenBudget $monitors $MaxWindows $Screens
$score = [LayeredMusic.Midi]::Read((Resolve-Path -LiteralPath $MidiFile).ProviderPath, $Speed, $Transpose, $MaxSeconds, $screenBudget.Limit)
. (Join-Path $PSScriptRoot 'SongMix.ps1')
$songMix=Get-OrchestraSongMix $PSScriptRoot (Resolve-Path -LiteralPath $MidiFile).ProviderPath
Set-OrchestraScoreMix $score $songMix
$Volume*=$songMix.Master/100.0
$cells = @(New-PlayerScreenLayout $score $monitors $Screens $screenBudget.Explicit ($ScreenCount -gt 0))
$screensUsed = @($cells.Monitor | Select-Object -Unique).Count
$threeScreens = $screensUsed -eq 3

if ($PrepareOnly) {
    [PSCustomObject]@{ Notes=$score.Notes.Count; Windows=$cells.Count; IdealWindows=$score.IdealWindows; WindowLimit=$screenBudget.Limit; DurationSeconds=$score.DurationMs/1000;
        ThreeScreens=$threeScreens; ScreensUsed=$screensUsed; DetectedScreens=$detectedMonitors.Count; SelectedScreens=$monitors.Count; Cells=$cells; Monitors=$monitors } | ConvertTo-Json -Depth 8
    return
}

$sessionsRoot = Join-Path $PSScriptRoot 'Sessions'
[void][IO.Directory]::CreateDirectory($sessionsRoot)
$sessionPath = Join-Path $sessionsRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sessionPath)
$children = New-Object Collections.Generic.List[object]
$audio = $null
$position = 0.0
$status = 'Preparing'
$statePath = Join-Path $sessionPath 'state.json'
$artColor=''
if($DisplayStyle -eq 'Panels'){
    try{
        . (Join-Path $PSScriptRoot 'OrchestraLibrary.ps1')
        $midiPath=(Resolve-Path -LiteralPath $MidiFile).ProviderPath
        $song=@(Get-OrchestraSongs $PSScriptRoot | Where-Object { [string]::Equals($_.Midi,$midiPath,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
        if($song.Count -and (Test-Path -LiteralPath $song[0].Icon)){
            Add-Type -AssemblyName System.Drawing
            $original=[Drawing.Image]::FromFile($song[0].Icon)
            try{$sample=[Drawing.Bitmap]::new($original,32,32)}finally{$original.Dispose()}
            try{
                $red=0.0;$green=0.0;$blue=0.0;$weight=0.0
                for($x=7;$x -lt 25;$x++){for($y=7;$y -lt 25;$y++){
                    $pixel=$sample.GetPixel($x,$y);$range=([Math]::Max($pixel.R,[Math]::Max($pixel.G,$pixel.B))-[Math]::Min($pixel.R,[Math]::Min($pixel.G,$pixel.B)))
                    if($pixel.A -lt 128 -or $range -lt 20){continue};$w=$range/255.0;$red+=$pixel.R*$w;$green+=$pixel.G*$w;$blue+=$pixel.B*$w;$weight+=$w
                }}
                if($weight -gt 0){$artColor='#{0:X2}{1:X2}{2:X2}' -f [int]($red/$weight),[int]($green/$weight),[int]($blue/$weight)}
            }finally{$sample.Dispose()}
        }
    }catch{Write-Verbose ('Artwork colour unavailable: '+$_.Exception.Message)}
}
try {
    Write-Json $statePath @{ Status='Preparing'; PositionMs=0 }
    Write-Json (Join-Path $sessionPath 'session.json') @{ MasterPid=$PID; SongTitle=$SongTitle; Cells=$cells; DurationMs=$score.DurationMs; MasterIconApplied=[LayeredMusic.ConsoleTile]::HasCustomIcon; ArtworkColor=$artColor }
    foreach ($cell in $cells) {
        $sortedEvents = @(New-NoteEvents @($score.Notes | Where-Object { $_.Layer -eq $cell.Id }))
        Write-Json (Join-Path $sessionPath ('events-{0}.json' -f $cell.Id)) $sortedEvents
    }
    $wavePath = Join-Path $sessionPath 'tones.wav'
    [LayeredMusic.Synth]::Render($score, $wavePath, $Volume)
    $audio = New-Object LayeredMusic.Audio $wavePath
    Write-Host ('{0} notes / {1} live windows / {2:N1} seconds' -f $score.Notes.Count, $cells.Count, ($score.DurationMs/1000))
    if ($score.IdealWindows -gt $cells.Count) { Write-Host ('Combined {0} independent voices into {1} windows to respect the window limit.' -f $score.IdealWindows,$cells.Count) }
    Write-Host ('Layout: {0} screen(s) used from {1} detected; automatic window budget {2}.' -f $screensUsed,$detectedMonitors.Count,$screenBudget.Limit)
    Write-Host 'Starting displays; playback waits until every window is ready...'
    if($DisplayStyle -eq 'Panels'){& (Join-Path $PSScriptRoot 'Note-Display.ps1') -PrepareOnly}
    elseif($DisplayStyle -eq 'Console'){& (Join-Path $PSScriptRoot 'Console-Display.ps1') -PrepareOnly}
    foreach ($cell in $cells) {
        if($DisplayStyle -ne 'Panels'){
            $arguments = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -SessionDirectory "{1}" -DisplayLayer {2} -DisplayStyle {3}' -f $PSCommandPath, $sessionPath, $cell.Id,$DisplayStyle
            $child = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $arguments -WindowStyle Normal -PassThru
        }else{
            $arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -SessionDirectory "{1}" -DisplayLayer {2} -DisplayStyle Panels' -f $PSCommandPath,$sessionPath,$cell.Id
            $child=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
        }
        $children.Add($child)
    }
    $readyTimer = [Diagnostics.Stopwatch]::StartNew()
    $readyTimeout = [Math]::Max(30, 10 + $cells.Count * 1.5)
    while (@(Get-ChildItem -LiteralPath $sessionPath -Filter 'ready-*.json').Count -lt $cells.Count) {
        if ($readyTimer.Elapsed.TotalSeconds -gt $readyTimeout) { throw ('Some note windows did not become ready within {0:N0} seconds.' -f $readyTimeout) }
        if (@($children | Where-Object { $_.HasExited }).Count -gt 0) {
            $failure=@(Get-ChildItem -LiteralPath $sessionPath -Filter 'error-*.json'|Select-Object -First 1)
            if($failure.Count){$reason=Read-Json $failure[0].FullName;throw ('Note display startup failed: '+$reason.Message)}
            throw 'A note window closed before playback could start.'
        }
        Start-Sleep -Milliseconds 100
    }
    # Geometry is read back by each app window after it sizes itself.
    foreach ($cell in $cells) {
        $ready = Read-Json (Join-Path $sessionPath ('ready-{0}.json' -f $cell.Id))
        Write-Host ('Ready: {0} [{1}]' -f $cell.Title, ($ready.Bounds -join ', '))
    }
    Write-Host 'PLAYING - chords mixed into one audio stream. Ctrl+C here stops all parts.' -ForegroundColor Green
    $masterFocusReleased=[LayeredMusic.ConsoleTile]::ReleaseFocus()
    $status = 'Playing'
    $audio.Start()
    while (-not $audio.Done) {
        $displayErrors = @(Get-ChildItem -LiteralPath $sessionPath -Filter 'error-*.json')
        if ($displayErrors.Count -gt 0) {
            $displayError = Read-Json $displayErrors[0].FullName
            throw ('Note window failed: ' + $displayError.Message)
        }
        $position = $audio.Milliseconds
        Write-Json $statePath @{ Status='Playing'; PositionMs=$position }
        if ($StopAfterSeconds -gt 0 -and $position -ge $StopAfterSeconds*1000) { $status='Stopped'; break }
        Write-Progress -Activity ($SongTitle + ' - all layers') -Status ([TimeSpan]::FromMilliseconds($position).ToString('mm\:ss')) -PercentComplete ([Math]::Min(100, 100*$position/$score.DurationMs))
        Start-Sleep -Milliseconds 30
    }
    if ($status -eq 'Stopped') { Write-Host 'Preview stopped. Closing temporary note windows...' -ForegroundColor Cyan }
    else {
        $position = $score.DurationMs
        $status = 'Complete'
        Write-Host 'Song finished. Closing temporary note windows...' -ForegroundColor Cyan
    }
} catch {
    $status = 'Error'
    $validationError=$_.Exception.Message
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
} finally {
    if ($audio) { $audio.Dispose() }
    if ($status -eq 'Playing' -or $status -eq 'Preparing') { $status = 'Stopped' }
    Write-Json $statePath @{ Status=$status; PositionMs=$position }
    Write-Progress -Activity ($SongTitle + ' - all layers') -Completed
    # Give displays time to consume the final clock state and exit normally.
    $closeTimer = [Diagnostics.Stopwatch]::StartNew()
    while (@($children | Where-Object { -not $_.HasExited }).Count -gt 0 -and $closeTimer.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 100 }
    $remaining = @($children | Where-Object { -not $_.HasExited })
    if($ValidationReceipt){
        $displayReceipts=@(Get-ChildItem -LiteralPath $sessionPath -Filter 'ready-*.json'|ForEach-Object {try{Read-Json $_.FullName}catch{}})
        $displayFailures=@(Get-ChildItem -LiteralPath $sessionPath -Filter 'error-*.json'|ForEach-Object {try{Read-Json $_.FullName}catch{}})
        Write-Json $ValidationReceipt @{Status=$status;Error=$validationError;DisplayErrors=$displayFailures;PositionMs=$position;ExpectedWindows=$cells.Count;RemainingWindows=$remaining.Count;ScreensUsed=$screensUsed;Notes=$score.Notes.Count;MasterFocusReleased=$masterFocusReleased;MixMasterPercent=$songMix.Master;PartVolumes=$songMix.Parts;RenderedPeak=$score.PeakBeforeScaling;ReferencePeak=$score.ReferencePeak;Displays=$displayReceipts}
    }
    if ($remaining.Count -eq 0) {
        $resolvedSession = [IO.Path]::GetFullPath($sessionPath)
        $resolvedSessionsRoot = [IO.Path]::GetFullPath($sessionsRoot).TrimEnd('\') + '\'
        if (-not $resolvedSession.StartsWith($resolvedSessionsRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside the playback session folder.' }
        Remove-Item -LiteralPath $resolvedSession -Recurse -Force
        Write-Host 'Temporary windows closed; temporary playback data removed. Master stays open.'
        [LayeredMusic.ConsoleTile]::Raise()
    } else { Write-Host 'A display is still exiting; its temporary session data was retained for that process.' }
}
