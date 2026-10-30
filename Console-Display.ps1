#requires -Version 5.1
[CmdletBinding()]
param([string]$SessionDirectory,[int]$DisplayLayer=-1,[switch]$PrepareOnly,[string]$PreviewPath,[int]$Columns=92,[int]$Rows=30)
$ErrorActionPreference='Stop'
if(-not('OrchestraConsole.Canvas' -as [type])){
    $source=Join-Path $PSScriptRoot 'ConsoleVisualizer.cs';$hash=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($hash.ComputeHash([IO.File]::ReadAllBytes($source))).Replace('-','').Substring(0,16)}finally{$hash.Dispose()}
    $runtime=if($PSVersionTable.PSEdition -eq 'Core'){'Core'}else{'Desktop'}
    $assembly=Join-Path $PSScriptRoot ('Engine\ConsoleVisualizer.'+$key+'.'+$runtime+'.dll')
    if(-not(Test-Path -LiteralPath $assembly)){Add-Type -Path $source -OutputAssembly $assembly}
    Add-Type -Path $assembly
}
if($PrepareOnly){return}
$canvas=New-Object OrchestraConsole.Canvas
$marks=New-Object 'Collections.Generic.List[OrchestraConsole.Mark]'
if($PreviewPath){
    $canvas.Song='Darude - Sandstorm';$canvas.Part='Synth lead / voice 1';$canvas.Band='Mid';$canvas.Duration=245000
    for($i=0;$i -lt 45;$i++){$n=New-Object OrchestraConsole.Mark;$n.Start=$i*160;$n.End=$n.Start+120;$n.Pitch=64+@(0,0,0,3,0,0,5,3)[$i%8];$n.Name=@('E4','E4','E4','G4','E4','E4','A4','G4')[$i%8];$n.Hz=440*[Math]::Pow(2,($n.Pitch-69)/12);$n.Part='Synth lead';$marks.Add($n)}
}else{
    $config=Read-Json (Join-Path $SessionDirectory 'session.json')
    $cell=@($config.Cells|Where-Object {$_.Id -eq $DisplayLayer})[0]
    $events=@(Read-Json (Join-Path $SessionDirectory ('events-'+$DisplayLayer+'.json')))
    $canvas.Song=$config.SongTitle;$canvas.Part=$cell.Title;$canvas.Band=$cell.Band;$canvas.Duration=$config.DurationMs
    $screens=@(foreach($group in @($config.Cells|Group-Object Monitor)){
        $minX=($group.Group|Measure-Object X -Minimum).Minimum;$minY=($group.Group|Measure-Object Y -Minimum).Minimum
        $maxX=($group.Group|ForEach-Object {[int]$_.X+[int]$_.Width}|Measure-Object -Maximum).Maximum
        [pscustomobject]@{Monitor=$group.Name;X=[int]$minX;Y=[int]$minY;Width=[int]($maxX-$minX)}
    })
    $cursor=0;$offset=0
    foreach($screen in @($screens|Sort-Object X,Y)){if($screen.Monitor -eq $cell.Monitor){$offset=$cursor-$screen.X};$cursor+=$screen.Width}
    $canvas.ScannerWidth=$cursor;$canvas.ScannerOffset=$offset;$canvas.WindowX=[int]$cell.X;$canvas.WindowWidth=[int]$cell.Width
    foreach($entry in $events|Where-Object {$_.Action -eq 'ON'}){$n=New-Object OrchestraConsole.Mark;$n.Start=$entry.TimeMs;$n.End=$entry.TimeMs+$entry.DurationMs;$n.Name=$entry.Note;$n.Hz=$entry.Hertz;$n.Pitch=[int][Math]::Round(69+12*[Math]::Log($entry.Hertz/440,2));$n.Part=$entry.Part;$marks.Add($n)}
}
$canvas.Notes=$marks.ToArray();$canvas.Build()
if($PreviewPath){
    Add-Type -AssemblyName System.Drawing
    $frame=$canvas.Compose($Columns,$Rows,5040);$bitmap=[Drawing.Bitmap]::new(($Columns*9+24),($Rows*18+24));$graphics=[Drawing.Graphics]::FromImage($bitmap);$graphics.Clear([Drawing.Color]::Black)
    $font=[Drawing.Font]::new('Consolas',14,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
    $palette=@('Black','DarkBlue','DarkGreen','DarkCyan','DarkRed','DarkMagenta','DarkGoldenrod','LightGray','Gray','Blue','Lime','Cyan','Red','Magenta','Yellow','White')
    try{for($row=0;$row -lt $Rows;$row++){for($col=0;$col -lt $Columns;$col++){$item=$frame[$row*$Columns+$col];$background=($item.Color -shr 4) -band 15;if($background){$fill=[Drawing.SolidBrush]::new([Drawing.Color]::FromName($palette[$background]));try{$graphics.FillRectangle($fill,($col*9+12),($row*18+12),9,18)}finally{$fill.Dispose()}};if($item.Character -eq ' '){continue};$brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromName($palette[$item.Color -band 15]));try{$graphics.DrawString([string]$item.Character,$font,$brush,($col*9+12),($row*18+12))}finally{$brush.Dispose()}}};$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)}finally{$font.Dispose();$graphics.Dispose();$bitmap.Dispose()}
    return
}
$Host.UI.RawUI.WindowTitle='PowerShell Orchestra | '+$canvas.Song+' | '+$canvas.Part
[Console]::BackgroundColor='Black';[Console]::ForegroundColor='Gray';[Console]::Clear();[Console]::CursorVisible=$false
try{[Console]::SetBufferSize([Math]::Max(512,[Console]::WindowWidth),[Math]::Max(512,[Console]::WindowHeight))}catch{}
$bounds=[LayeredMusic.ConsoleTile]::Place($cell.X,$cell.Y,$cell.Width,$cell.Height)
$canvas.Paint(0)
function Write-ConsoleReceipt {
    Write-Json (Join-Path $SessionDirectory ('ready-'+$DisplayLayer+'.json')) @{Id=$DisplayLayer;Pid=$PID;Mode='ConsoleFlair';Bounds=$bounds;TopMost=[LayeredMusic.ConsoleTile]::IsTopMost;Foreground=[LayeredMusic.ConsoleTile]::IsForeground;StartupFocusReleased=$startupFocusReleased;IconApplied=[LayeredMusic.ConsoleTile]::HasCustomIcon;PositionMs=$canvas.Position;ShownEvents=$canvas.ShownEvents;EventCount=$events.Count;Frames=$canvas.Frames;Columns=$canvas.Width;Rows=$canvas.Height}
}
$startupFocusReleased=$false
$startupFocusAttempted=$false
Write-ConsoleReceipt
$health=[Diagnostics.Stopwatch]::StartNew()
try{while($true){
    try{$state=Read-Json (Join-Path $SessionDirectory 'state.json')}catch{Start-Sleep -Milliseconds 60;continue}
    if($state.Status -ne 'Preparing'){
        if(-not $startupFocusAttempted){$startupFocusReleased=[LayeredMusic.ConsoleTile]::ReleaseFocus();$startupFocusAttempted=$true}
        $canvas.Paint([double]$state.PositionMs)
    }
    if($health.ElapsedMilliseconds -ge 500){$Host.UI.RawUI.WindowTitle='PowerShell Orchestra | '+$canvas.Song+' | '+$canvas.Part+' | '+[TimeSpan]::FromMilliseconds($canvas.Position).ToString('mm\:ss');Write-ConsoleReceipt;$health.Restart();if(-not(Get-Process -Id $config.MasterPid -ErrorAction SilentlyContinue)){break}}
    if($state.Status -in @('Complete','Stopped','Error')){break}
    Start-Sleep -Milliseconds 80
}}finally{[Console]::CursorVisible=$true}
