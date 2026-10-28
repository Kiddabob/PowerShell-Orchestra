param([ValidateSet('Orchestra','GTA','Rush')][string[]]$Kinds=@('Orchestra','GTA','Rush'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
foreach($kind in $Kinds){
    $folder=if($kind -eq 'GTA'){Join-Path $PSScriptRoot 'PSGTA-IV'}else{$PSScriptRoot}
    $base=if($kind -eq 'GTA'){'PSGTA-IV'}elseif($kind -eq 'Rush'){'Rush-PS'}else{'PowerShell-Orchestra-Note'}
    $sizes=@(16,24,32,48,64,128,256);$images=New-Object 'Collections.Generic.List[byte[]]'
    foreach($size in $sizes){
        $bitmap=[Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g=[Drawing.Graphics]::FromImage($bitmap);$g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias;$g.ScaleTransform($size/256.0,$size/256.0);$g.Clear([Drawing.Color]::Transparent)
        $background=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255,20,27,48))
        if($kind -eq 'GTA'){$background.Color=[Drawing.Color]::FromArgb(255,18,18,20)}
        $shape=[Drawing.Drawing2D.GraphicsPath]::new();$shape.AddArc(6,6,48,48,180,90);$shape.AddArc(202,6,48,48,270,90);$shape.AddArc(202,202,48,48,0,90);$shape.AddArc(6,202,48,48,90,90);$shape.CloseFigure();$g.FillPath($background,$shape)
        $ink=[Drawing.SolidBrush]::new([Drawing.Color]::White)
        if($kind -eq 'GTA'){
            $font=[Drawing.Font]::new('Segoe UI',88,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
            $g.DrawString('IV',$font,$ink,28,52);$font.Dispose()
            $g.FillEllipse($ink,162,174,38,28);$g.FillRectangle($ink,189,107,11,80)
            [Drawing.PointF[]]$flag=@([Drawing.PointF]::new(189,107),[Drawing.PointF]::new(225,119),[Drawing.PointF]::new(225,139),[Drawing.PointF]::new(189,125));$g.FillPolygon($ink,$flag)
        }elseif($kind -eq 'Rush'){
            $accent=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255,70,224,213))
            $g.FillEllipse($accent,48,159,63,43);$g.FillRectangle($accent,94,66,17,116)
            $g.FillEllipse($ink,148,130,63,43);$g.FillRectangle($ink,194,38,17,115)
            [Drawing.PointF[]]$beam=@([Drawing.PointF]::new(94,66),[Drawing.PointF]::new(211,34),[Drawing.PointF]::new(211,63),[Drawing.PointF]::new(94,95));$g.FillPolygon($accent,$beam);$accent.Dispose()
        }else{
            # Classic Windows PowerShell console panel, with a music note and
            # the familiar underscore prompt, matching the owner's reference.
            $g.Clear([Drawing.Color]::Transparent)
            $shadow=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(100,0,25,65))
            [Drawing.PointF[]]$shadowPanel=@([Drawing.PointF]::new(49,45),[Drawing.PointF]::new(244,45),[Drawing.PointF]::new(213,218),[Drawing.PointF]::new(18,218));$g.FillPolygon($shadow,$shadowPanel)
            $blue=[Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.Point]::new(40,42),[Drawing.Point]::new(220,212),[Drawing.Color]::FromArgb(255,71,101,136),[Drawing.Color]::FromArgb(255,12,31,58))
            [Drawing.PointF[]]$panel=@([Drawing.PointF]::new(43,36),[Drawing.PointF]::new(239,36),[Drawing.PointF]::new(208,208),[Drawing.PointF]::new(12,208));$g.FillPolygon($blue,$panel)
            $border=[Drawing.Pen]::new([Drawing.Color]::FromArgb(255,177,196,215),6);$g.DrawPolygon($border,$panel)
            $gleam=[Drawing.Pen]::new([Drawing.Color]::FromArgb(100,255,255,255),2);$g.DrawLine($gleam,47,42,231,42)
            $g.FillEllipse($ink,63,134,43,30);$g.FillRectangle($ink,94,66,12,84)
            [Drawing.PointF[]]$flag=@([Drawing.PointF]::new(94,66),[Drawing.PointF]::new(134,84),[Drawing.PointF]::new(129,109),[Drawing.PointF]::new(106,96));$g.FillPolygon($ink,$flag)
            $g.FillRectangle($ink,131,160,51,11)
            $shadow.Dispose();$blue.Dispose();$border.Dispose();$gleam.Dispose()
        }
        if($size -eq 256){$bitmap.Save((Join-Path $folder ($base+'.png')),[Drawing.Imaging.ImageFormat]::Png)}
        $memory=[IO.MemoryStream]::new();$bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);$images.Add($memory.ToArray())
        $memory.Dispose();$ink.Dispose();$shape.Dispose();$background.Dispose();$g.Dispose();$bitmap.Dispose()
    }
    $writer=[IO.BinaryWriter]::new([IO.File]::Create((Join-Path $folder ($base+'.ico'))))
    try{
        $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count);$offset=6+16*$sizes.Count
        for($i=0;$i -lt $sizes.Count;$i++){
            $dimension=if($sizes[$i] -eq 256){0}else{$sizes[$i]}
            $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([uint16]1);$writer.Write([uint16]32)
            $writer.Write([uint32]$images[$i].Length);$writer.Write([uint32]$offset);$offset+=$images[$i].Length
        }
        foreach($image in $images){$writer.Write($image)}
    }finally{$writer.Dispose()}
}
Write-Output 'PowerShell Orchestra and PSGTA IV icons built.'
