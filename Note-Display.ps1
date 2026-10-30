#requires -Version 5.1
[CmdletBinding()]
param([string]$SessionDirectory,[int]$DisplayLayer=-1,[switch]$PrepareOnly,[string]$PreviewPath,[int]$PreviewWidth=900,[int]$PreviewHeight=600,[string]$PreviewBand='Mid',[string]$PreviewSong='Darude - Sandstorm',[double]$PreviewPosition=5040,[string]$PreviewArtworkColor='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DisplayClock.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if(-not ('OrchestraVisual.LayerForm' -as [type])){
    $source=Join-Path $PSScriptRoot 'NoteVisualizer.cs';$hash=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($hash.ComputeHash([IO.File]::ReadAllBytes($source))).Replace('-','').Substring(0,16)}finally{$hash.Dispose()}
    $runtime=if($PSVersionTable.PSEdition -eq 'Core'){'Core'}else{'Desktop'}
    $assembly=Join-Path $PSScriptRoot ('Engine\NoteVisualizer.'+$key+'.'+$runtime+'.dll')
    if(-not(Test-Path -LiteralPath $assembly)){Add-Type -Path $source -OutputAssembly $assembly -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll'}
    Add-Type -Path $assembly
}
if($PrepareOnly){return}
[Windows.Forms.Application]::EnableVisualStyles()
function Read-DisplayJson([string]$Path){
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=[IO.StreamReader]::new($stream)
    try{$value=$reader.ReadToEnd()|ConvertFrom-Json;return $value}finally{$reader.Dispose()}
}
$form=New-Object OrchestraVisual.LayerForm
$form.Icon=[Drawing.Icon]::new((Join-Path $PSScriptRoot 'PowerShell-Orchestra-Note.ico'))
$marks=New-Object 'Collections.Generic.List[OrchestraVisual.Mark]'
if($PreviewPath){
    $form.Song=$PreviewSong;$form.Part=$PreviewBand+' / Synth lead / voice 1';$form.Band=$PreviewBand;$form.Duration=245000
    if($PreviewArtworkColor -match '^#[0-9A-Fa-f]{6}$'){$form.ArtworkColor=[Drawing.ColorTranslator]::FromHtml($PreviewArtworkColor)}
    $form.Size=New-Object Drawing.Size $PreviewWidth,$PreviewHeight
    for($i=0;$i -lt 45;$i++){$n=New-Object OrchestraVisual.Mark;$n.Start=$i*160;$n.End=$n.Start+120;$n.Pitch=64+@(0,0,0,3,0,0,5,3)[$i%8];$n.Name=@('E4','E4','E4','G4','E4','E4','A4','G4')[$i%8];$n.Hz=440*[Math]::Pow(2,($n.Pitch-69)/12);$marks.Add($n)}
}else{
    $config=Read-DisplayJson (Join-Path $SessionDirectory 'session.json')
    $cell=@($config.Cells|Where-Object {$_.Id -eq $DisplayLayer})[0]
    $events=@(Read-DisplayJson (Join-Path $SessionDirectory ('events-'+$DisplayLayer+'.json')))
    $form.Song=$config.SongTitle;$form.Part=$cell.Title;$form.Band=$cell.Band;$form.Duration=$config.DurationMs
    if($config.ArtworkColor -match '^#[0-9A-Fa-f]{6}$'){$form.ArtworkColor=[Drawing.ColorTranslator]::FromHtml($config.ArtworkColor)}
    # Arrange occupied monitors side by side for the scanner, skipping unused
    # desktop gaps while preserving a shared coordinate for all rows on a screen.
    $screens=@(foreach($group in @($config.Cells|Group-Object Monitor)){
        $minX=($group.Group|Measure-Object -Property X -Minimum).Minimum
        $minY=($group.Group|Measure-Object -Property Y -Minimum).Minimum
        $maxX=($group.Group|ForEach-Object {[int]$_.X+[int]$_.Width}|Measure-Object -Maximum).Maximum
        [pscustomobject]@{Monitor=$group.Name;X=[int]$minX;Y=[int]$minY;Width=[int]($maxX-$minX)}
    })
    $screens=@($screens | Sort-Object X,Y)
    $cursor=0;$offset=0
    foreach($screen in $screens){if($screen.Monitor -eq $cell.Monitor){$offset=$cursor-$screen.X};$cursor+=$screen.Width}
    if($cursor -gt 0){$form.ScannerLeft=0;$form.ScannerWidth=$cursor;$form.ScannerOffset=$offset}
    $form.SetBounds($cell.X,$cell.Y,$cell.Width,$cell.Height)
    foreach($entry in $events|Where-Object {$_.Action -eq 'ON'}){
        $n=New-Object OrchestraVisual.Mark;$n.Start=$entry.TimeMs;$n.End=$entry.TimeMs+$entry.DurationMs;$n.Name=$entry.Note;$n.Hz=$entry.Hertz;$n.Pitch=[int][Math]::Round(69+12*[Math]::Log($entry.Hertz/440,2));$n.Part=$entry.Part;$marks.Add($n)
    }
}
$form.Notes=$marks.ToArray();$form.Build();$form.Advance(0)
if($PreviewPath){
    $form.Show();$form.Advance($PreviewPosition);[Windows.Forms.Application]::DoEvents()
    $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
    try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
    $form.Close();$form.Dispose();return
}
function Write-DisplayReceipt {
    $receipt=@{Id=$DisplayLayer;Pid=$PID;Mode='Visual';Bounds=@($form.Left,$form.Top,$form.Width,$form.Height);TopMost=$form.TopMost;Foreground=[LayeredMusic.ConsoleTile]::IsForegroundWindow($form.Handle);StartupFocusReleased=$startupFocusReleased;IconApplied=($null -ne $form.Icon);ShownEvents=$form.ShownEvents;PositionMs=$form.Position;EventCount=$events.Count}
    [IO.File]::WriteAllText((Join-Path $SessionDirectory ('ready-'+$DisplayLayer+'.json')),($receipt|ConvertTo-Json -Compress))
}
$startupFocusAttempted=$false;$startupFocusReleased=$false
$timer=New-Object Windows.Forms.Timer;$timer.Interval=if($form.Song -match '(?i)\bknight[\s_\-]*rider\b'){33}else{50}
$health=[Diagnostics.Stopwatch]::StartNew()
$timer.Add_Tick({
    try{
        try{$state=Read-DisplayJson (Join-Path $SessionDirectory 'state.json')}catch{return}
        if($state.Status -ne 'Preparing'){
            if(-not $startupFocusAttempted){$script:startupFocusReleased=[LayeredMusic.ConsoleTile]::ReleaseFocus($form.Handle);$script:startupFocusAttempted=$true}
            $form.Advance((Get-OrchestraDisplayPosition $state))
        }
        if($health.ElapsedMilliseconds -gt 500){Write-DisplayReceipt;$health.Restart();if(-not(Get-Process -Id $config.MasterPid -ErrorAction SilentlyContinue)){$form.Close()}}
        if($state.Status -in @('Complete','Stopped','Error')){$form.Close()}
    }catch{
        [IO.File]::WriteAllText((Join-Path $SessionDirectory ('error-'+$DisplayLayer+'.json')),(@{Message=$_.Exception.Message}|ConvertTo-Json));$form.Close()
    }
})
$form.Add_Shown({$form.Activate();Write-DisplayReceipt;$timer.Start()})
$form.Add_FormClosed({$timer.Stop()})
[void]$form.ShowDialog();$timer.Dispose();$form.Dispose()
