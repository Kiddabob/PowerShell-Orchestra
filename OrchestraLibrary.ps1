function Get-OrchestraSongs([string]$Root) {
    $songs=New-Object Collections.Generic.List[object]
    $songs.Add([PSCustomObject]@{Id='rush-e';Title='Rush E';Midi=(Join-Path $Root 'Rush E.mid');Icon=(Join-Path $Root 'Rush-PS.png');Theme='Virtuosic piano and fast motion, with restrained red and gold accents.'})
    $songs.Add([PSCustomObject]@{Id='tetris';Title='Tetris Medley';Midi=(Join-Path $Root 'TetriPS\Tetris-Medley-Orchestra.mid');Icon=(Join-Path $Root 'TetriPS\TetriPS.png');Theme='Tetris-inspired album art, with recognisable four-block tetromino shapes and a restrained palette.'})
    $songs.Add([PSCustomObject]@{Id='gta-iv';Title='GTA IV - Soviet Connection';Midi=(Join-Path $Root 'PSGTA-IV\Soviet-Connection.mid');Icon=(Join-Path $Root 'PSGTA-IV\PSGTA-IV.png');Theme='Cinematic Liberty City-inspired skyline in muted monochrome and warm bronze.'})
    foreach($relative in @('Library','Converter\Converted')) {
        $folder=Join-Path $Root $relative
        if(-not(Test-Path -LiteralPath $folder)){continue}
        foreach($file in Get-ChildItem -LiteralPath $folder -File | Where-Object {$_.Extension -in @('.mid','.midi')} | Sort-Object Name) {
            $hasher=[Security.Cryptography.SHA256]::Create()
            try{$key=[BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($relative+'\'+$file.Name).ToLowerInvariant()))).Replace('-','').Substring(0,16)}finally{$hasher.Dispose()}
            $songs.Add([PSCustomObject]@{Id=('midi-'+$key);Title=$file.BaseName;Midi=$file.FullName;Icon=(Join-Path $Root 'PowerShell-Orchestra-Note.png');Theme='A distinctive music-inspired illustration that suits the song title, with a strong central symbol.'})
        }
    }
    $iconMap=@{}
    $mapPath=Join-Path $Root 'LibraryIcons\song-icons.json'
    if(Test-Path -LiteralPath $mapPath){
        try{(Get-Content -LiteralPath $mapPath -Raw|ConvertFrom-Json).PSObject.Properties|ForEach-Object {$iconMap[$_.Name]=$_.Value}}catch{}
    }
    $titleMap=@{};$titlePath=Join-Path $Root 'LibraryIcons\song-titles.json'
    if(Test-Path -LiteralPath $titlePath){try{(Get-Content -LiteralPath $titlePath -Raw|ConvertFrom-Json).PSObject.Properties|ForEach-Object {$titleMap[$_.Name]=$_.Value}}catch{}}
    foreach($song in $songs){
        if($titleMap.ContainsKey($song.Id) -and -not [string]::IsNullOrWhiteSpace([string]$titleMap[$song.Id])){$song.Title=[string]$titleMap[$song.Id]}
        $song | Add-Member -NotePropertyName CanDelete -NotePropertyValue ($song.Id -like 'midi-*')
        $sourceUrl='';$sourcePath=$song.Midi+'.source.json'
        if(Test-Path -LiteralPath $sourcePath){try{
            $source=Get-Content -LiteralPath $sourcePath -Raw|ConvertFrom-Json
            $uri=$null
            if([Uri]::TryCreate([string]$source.SourceUrl,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -eq 'https' -and $uri.Host -in @('bitmidi.com','freemidi.org') -and (Test-Path -LiteralPath $song.Midi)){
                # A replacement MIDI must not inherit the old file's attribution.
                $sha=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($song.Midi)
                try{$digest=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$sha.Dispose()}
                if($source.Sha256 -eq $digest){$sourceUrl=$uri.AbsoluteUri}
            }
        }catch{}}
        $song|Add-Member -NotePropertyName SourceUrl -NotePropertyValue $sourceUrl
        if($iconMap.ContainsKey($song.Id)){$custom=Join-Path $Root ('LibraryIcons\'+$iconMap[$song.Id]);if(Test-Path -LiteralPath $custom){$song.Icon=$custom}}
        if(Test-Path -LiteralPath $song.Midi){$song}
    }
}

function Set-OrchestraSongTitle([string]$Root,$Song,[string]$Title) {
    $title=$Title.Trim()
    if([string]::IsNullOrWhiteSpace($title) -or $title.Length -gt 160 -or $title -match '[\x00-\x1f]'){throw 'Enter a song name between 1 and 160 characters.'}
    $folder=Join-Path $Root 'LibraryIcons';[void][IO.Directory]::CreateDirectory($folder)
    $path=Join-Path $folder 'song-titles.json';$map=@{}
    if(Test-Path -LiteralPath $path){(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).PSObject.Properties|ForEach-Object {$map[$_.Name]=$_.Value}}
    $map[$Song.Id]=$title
    $temp=Join-Path $folder ('.song-titles-'+[Guid]::NewGuid().ToString('N')+'.tmp');$backup=$temp+'.bak'
    try{
        [IO.File]::WriteAllText($temp,($map|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,$backup);Remove-Item -LiteralPath $backup}else{[IO.File]::Move($temp,$path)}
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp}}
}

function Get-OrchestraRemovableMidiPath([string]$Root,$Song) {
    if(-not $Song.CanDelete){throw 'Bundled songs are kept with their launchers. Delete is available for imports and conversions.'}
    $path=[IO.Path]::GetFullPath($Song.Midi)
    $parent=[IO.Path]::GetDirectoryName($path)
    $allowed=@([IO.Path]::GetFullPath((Join-Path $Root 'Library')),[IO.Path]::GetFullPath((Join-Path $Root 'Converter\Converted')))
    if($parent -notin $allowed -or [IO.Path]::GetExtension($path) -notin @('.mid','.midi')){throw 'Only a MIDI inside this app''s library or conversion folder can be deleted.'}
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'The library MIDI no longer exists. Refresh the list.'}
    foreach($entry in @($path,$parent)){
        if((Get-Item -LiteralPath $entry).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked files or folders cannot be deleted by the library.'}
    }
    return $path
}

function Remove-OrchestraSong([string]$Root,$Song) {
    $path=Get-OrchestraRemovableMidiPath $Root $Song
    if([IO.DriveInfo]::new([IO.Path]::GetPathRoot($path)).DriveType -ne [IO.DriveType]::Fixed){throw 'Use File Explorer to remove MIDI on a network or removable drive; this app requires a local Recycle Bin.'}
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    # Keep the artwork mapping so replacing a conversion of the same name
    # can reuse its chosen icon. No source audio is in this deletion path.
}

function Get-OrchestraIconPrompt($Song) {
    'Create one square album-art-inspired image for the PowerShell Orchestra song library. Song and artist: "'+$Song.Title+'". Consider the specific recording, artist, era, musical mood and associated album or single artwork; avoid interpreting the title literally. If uncertain, use a tasteful music-inspired interpretation without inventing facts. Additional context: '+$Song.Theme+' Create original artwork with a clear central focal point, in a muted, low-saturation palette and a soft matte finish. Avoid neon, excessive glow, text and borders. Fill the square image edge to edge; the app will crop it and add its own frame. Return one image directly.'
}

function New-OrchestraFramedArtwork([Drawing.Image]$Source) {
    $result=[Drawing.Bitmap]::new(512,512,[Drawing.Imaging.PixelFormat]::Format32bppArgb);$g=[Drawing.Graphics]::FromImage($result)
    try {
        $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias;$g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic;$g.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality;$g.Clear([Drawing.Color]::Transparent)
        $outline=[Drawing.PointF[]]@([Drawing.PointF]::new(82,66),[Drawing.PointF]::new(484,66),[Drawing.PointF]::new(424,424),[Drawing.PointF]::new(20,424))
        $shadow=[Drawing.PointF[]]@([Drawing.PointF]::new(88,73),[Drawing.PointF]::new(490,73),[Drawing.PointF]::new(430,431),[Drawing.PointF]::new(26,431))
        $brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(180,5,21,46));try{$g.FillPolygon($brush,$shadow)}finally{$brush.Dispose()}
        $brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255,14,36,65));try{$g.FillPolygon($brush,$outline)}finally{$brush.Dispose()}
        $inside=[Drawing.PointF[]]@([Drawing.PointF]::new(89,72),[Drawing.PointF]::new(477,72),[Drawing.PointF]::new(419,417),[Drawing.PointF]::new(28,417))
        $clip=[Drawing.Drawing2D.GraphicsPath]::new();$clip.AddPolygon($inside);$g.SetClip($clip)
        $side=[Math]::Min($Source.Width,$Source.Height);$crop=[Drawing.RectangleF]::new(($Source.Width-$side)/2,($Source.Height-$side)/2,$side,$side)
        $dest=[Drawing.PointF[]]@($inside[0],$inside[1],$inside[3]);$g.DrawImage($Source,$dest,$crop,[Drawing.GraphicsUnit]::Pixel)
        $shine=[Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.Point]::new(0,72),[Drawing.Point]::new(0,417),[Drawing.Color]::FromArgb(45,180,211,244),[Drawing.Color]::FromArgb(0,180,211,244));try{$g.FillPolygon($shine,$inside)}finally{$shine.Dispose()}
        $g.ResetClip();$clip.Dispose();$pen=[Drawing.Pen]::new([Drawing.Color]::FromArgb(255,166,192,218),7);$pen.LineJoin=[Drawing.Drawing2D.LineJoin]::Miter
        try{$g.DrawPolygon($pen,$outline)}finally{$pen.Dispose()};return $result
    }catch{$result.Dispose();throw}finally{$g.Dispose()}
}

function Save-OrchestraSongIcon([string]$Root,$Song,[string]$ImagePath,[bool]$FrameArtwork=$false) {
    $folder=Join-Path $Root 'LibraryIcons';[void][IO.Directory]::CreateDirectory($folder)
    $filename=$Song.Id+'-'+[Guid]::NewGuid().ToString('N')+'.png'
    $destination=Join-Path $folder $filename
    if([IO.Path]::GetExtension($ImagePath) -eq '.ico'){
        $icon=[Drawing.Icon]::new($ImagePath);$bitmap=$icon.ToBitmap();$icon.Dispose()
    }else{$source=[Drawing.Image]::FromFile($ImagePath);try{$bitmap=[Drawing.Bitmap]::new($source)}finally{$source.Dispose()}}
    try{if($FrameArtwork){$framed=New-OrchestraFramedArtwork $bitmap;try{$framed.Save($destination,[Drawing.Imaging.ImageFormat]::Png)}finally{$framed.Dispose()}}else{$bitmap.Save($destination,[Drawing.Imaging.ImageFormat]::Png)}}finally{$bitmap.Dispose()}
    $map=@{};$mapPath=Join-Path $folder 'song-icons.json'
    if(Test-Path -LiteralPath $mapPath){(Get-Content -LiteralPath $mapPath -Raw|ConvertFrom-Json).PSObject.Properties|ForEach-Object {$map[$_.Name]=$_.Value}}
    $map[$Song.Id]=$filename
    $encoding=New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($mapPath,($map|ConvertTo-Json),$encoding)
    return $destination
}
