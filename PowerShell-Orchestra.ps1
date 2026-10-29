#requires -Version 5.1
[CmdletBinding()]
param([string]$PreviewPath,[int]$PreviewWidth=860,[int]$PreviewHeight=720,[switch]$PreviewIconOptions,[switch]$Legacy)
$ErrorActionPreference='Stop'
$native=Join-Path $PSScriptRoot 'App\PowerShellOrchestra.exe'
if(-not $Legacy -and -not $PreviewPath -and (Test-Path -LiteralPath $native)){
    [void](Start-Process -FilePath $native -WorkingDirectory $PSScriptRoot -WindowStyle Normal)
    return
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:orchestraRoot=$PSScriptRoot
$script:displayStyle='Console'
$styleSettings=Join-Path $PSScriptRoot 'player-settings.json'
if(Test-Path -LiteralPath $styleSettings){try{$savedStyle=(Get-Content -LiteralPath $styleSettings -Raw|ConvertFrom-Json).DisplayStyle;if($savedStyle -in @('Console','Panels','Text')){$script:displayStyle=$savedStyle}}catch{}}
. (Join-Path $PSScriptRoot 'OrchestraLibrary.ps1')
$form=New-Object Windows.Forms.Form
$form.Text='PowerShell Orchestra';$form.Size=New-Object Drawing.Size 860,720
if($PreviewPath){$form.Size=New-Object Drawing.Size $PreviewWidth,$PreviewHeight}
$form.MinimumSize=New-Object Drawing.Size 570,500;$form.StartPosition='CenterScreen'
$form.BackColor=[Drawing.Color]::FromArgb(20,27,48);$form.ForeColor=[Drawing.Color]::White
$form.Icon=[Drawing.Icon]::new((Join-Path $PSScriptRoot 'PowerShell-Orchestra-Note.ico'))
$form.Font=New-Object Drawing.Font 'Segoe UI',10
$header=New-Object Windows.Forms.Panel;$header.Dock='Top';$header.Height=178;$form.Controls.Add($header)
$heading=New-Object Windows.Forms.Label;$heading.Text='PowerShell Orchestra';$heading.Font=New-Object Drawing.Font 'Segoe UI',22,([Drawing.FontStyle]::Bold)
$heading.Location=New-Object Drawing.Point 22,17;$heading.Size=New-Object Drawing.Size 760,43;$header.Controls.Add($heading)
$intro=New-Object Windows.Forms.Label;$intro.Text='Your songs. Live notes. A grid that grows with your library.';$intro.Location=New-Object Drawing.Point 25,65;$intro.Size=New-Object Drawing.Size 750,25;$intro.ForeColor=[Drawing.Color]::LightSteelBlue;$header.Controls.Add($intro)
$toolbar=New-Object Windows.Forms.FlowLayoutPanel;$toolbar.Location=New-Object Drawing.Point 22,99;$toolbar.Size=New-Object Drawing.Size 780,72;$toolbar.Anchor='Top,Left,Right';$header.Controls.Add($toolbar)
$toolbar.Width=[Math]::Max(1,$header.ClientSize.Width-44)
$footer=New-Object Windows.Forms.Label;$footer.Dock='Bottom';$footer.Height=50;$footer.Padding=New-Object Windows.Forms.Padding 20,7,20,7
$footer.Text='Screens and note-window counts adapt at each playback launch.';$footer.ForeColor=[Drawing.Color]::LightSteelBlue;$form.Controls.Add($footer)
$grid=New-Object Windows.Forms.Panel;$grid.Dock='Fill';$grid.AutoScroll=$true
$grid.BackColor=[Drawing.Color]::FromArgb(15,21,38);$form.Controls.Add($grid);$grid.BringToFront()
$tooltips=New-Object Windows.Forms.ToolTip
function Align-OrchestraCards {
    if($script:aligningCards -or $script:buildingCards -or $grid.ClientSize.Width -le 0){return}
    $script:aligningCards=$true
    $scrollY=-$grid.AutoScrollPosition.Y
    try{
        $grid.SuspendLayout()
        $grid.AutoScrollPosition=[Drawing.Point]::Empty
        # Compute the scrollbar before laying out, so it cannot shift a row off centre.
        $width=$grid.Width
        $columns=[Math]::Max(1,[Math]::Floor(($width-28)/254))
        $rows=[Math]::Ceiling($grid.Controls.Count/$columns)
        $height=28+$rows*270
        if($height -gt $grid.ClientSize.Height){$width-=[Windows.Forms.SystemInformation]::VerticalScrollBarWidth}
        $columns=[int][Math]::Max(1,[Math]::Floor(($width-28)/254))
        $rows=[int][Math]::Ceiling($grid.Controls.Count/$columns)
        for($row=0;$row -lt $rows;$row++){
            $count=[Math]::Min($columns,$grid.Controls.Count-$row*$columns)
            $left=[int][Math]::Floor(($width-($count*236+($count-1)*18))/2)
            for($column=0;$column -lt $count;$column++){
                $grid.Controls[$row*$columns+$column].Location=[Drawing.Point]::new($left+$column*254,23+$row*270)
            }
        }
        $grid.AutoScrollMinSize=[Drawing.Size]::new(0,(28+$rows*270))
        $grid.ResumeLayout($true)
        $grid.AutoScrollPosition=[Drawing.Point]::new(0,$scrollY)
    }finally{$script:aligningCards=$false}
}
$grid.Add_ClientSizeChanged({Align-OrchestraCards})
function Start-OrchestraSong($Song){
    $player=Join-Path $script:orchestraRoot 'Play-RushE-Layers.ps1'
    $arguments='powershell.exe -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}" -MidiFile "{1}" -SongTitle "{2}" -DisplayStyle {3}' -f $player,$Song.Midi,$Song.Title,$script:displayStyle
    [void](Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $arguments -WindowStyle Normal)
}
function Add-ToolbarButton([string]$Text,$Action){
    $button=New-Object Windows.Forms.Button;$button.Text=$Text;$button.AutoSize=$true;$button.Height=30;$button.Padding=New-Object Windows.Forms.Padding 10,0,10,0
    $button.BackColor=[Drawing.Color]::FromArgb(44,57,85);$button.FlatStyle='Flat';$button.FlatAppearance.BorderSize=0
    $button.Add_Click($Action);$toolbar.Controls.Add($button)
}
function Refresh-OrchestraLibrary {
    $script:buildingCards=$true
    $grid.SuspendLayout()
    foreach($card in @($grid.Controls)){
        foreach($control in @($card.Controls)){if($control -is [Windows.Forms.PictureBox]){if($control.Image){$control.Image.Dispose()};if($control.ContextMenuStrip){$control.ContextMenuStrip.Dispose()}}}
        $card.Dispose()
    }
    $grid.Controls.Clear()
    $songs=@(Get-OrchestraSongs $script:orchestraRoot)
    foreach($song in $songs){
        $card=New-Object Windows.Forms.Panel;$card.Size=New-Object Drawing.Size 236,252;$card.Margin=New-Object Windows.Forms.Padding 9
        $card.BackColor=[Drawing.Color]::FromArgb(35,46,70)
        $picture=New-Object Windows.Forms.PictureBox;$picture.Location=New-Object Drawing.Point 50,12;$picture.Size=New-Object Drawing.Size 136,136;$picture.SizeMode='Zoom'
        try{
            if([IO.Path]::GetExtension($song.Icon) -eq '.ico'){$icon=[Drawing.Icon]::new($song.Icon);$picture.Image=$icon.ToBitmap();$icon.Dispose()}
            else{$source=[Drawing.Image]::FromFile($song.Icon);try{$picture.Image=[Drawing.Bitmap]::new($source)}finally{$source.Dispose()}}
        }catch{$picture.Image=$form.Icon.ToBitmap()}
        $card.Controls.Add($picture)
        $title=New-Object Windows.Forms.Label;$title.Text=$song.Title;$title.Location=New-Object Drawing.Point 12,157;$title.Size=New-Object Drawing.Size 212,42
        $title.Font=New-Object Drawing.Font 'Segoe UI',11,([Drawing.FontStyle]::Bold);$title.TextAlign='MiddleCenter';$card.Controls.Add($title)
        $play=New-Object Windows.Forms.Button;$play.Text='Play';$play.Tag=$song;$play.Location=New-Object Drawing.Point 12,205;$play.Size=New-Object Drawing.Size 212,34
        $play.BackColor=[Drawing.Color]::FromArgb(26,117,177);$play.FlatStyle='Flat';$play.FlatAppearance.BorderSize=0
        $play.Add_Click({param($sender,$eventArgs) Start-OrchestraSong $sender.Tag});$card.Controls.Add($play)
        $play.Width=101
        $mixer=New-Object Windows.Forms.Button;$mixer.Text='Mixer';$mixer.Tag=$song;$mixer.Location=New-Object Drawing.Point 123,205;$mixer.Size=New-Object Drawing.Size 101,34
        $mixer.BackColor=[Drawing.Color]::FromArgb(44,57,85);$mixer.FlatStyle='Flat';$mixer.FlatAppearance.BorderSize=0;$mixer.AccessibleName='Mix volumes for '+$song.Title
        $mixer.Add_Click({param($sender,$eventArgs)
            $path=Join-Path $script:orchestraRoot 'Song-Mixer.ps1'
            $arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -MidiFile "{1}" -SongTitle "{2}"' -f $path,$sender.Tag.Midi,$sender.Tag.Title
            [void](Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden)
        });$card.Controls.Add($mixer)
        if($song.CanDelete){
            $play.Width=68;$mixer.Left=89;$mixer.Width=68
            $delete=New-Object Windows.Forms.Button;$delete.Text='Delete';$delete.Tag=$song
            $delete.Location=New-Object Drawing.Point 166,205;$delete.Size=New-Object Drawing.Size 58,34
            $delete.BackColor=[Drawing.Color]::FromArgb(119,48,61);$delete.FlatStyle='Flat';$delete.FlatAppearance.BorderSize=0
            $delete.AccessibleName='Delete '+$song.Title;$tooltips.SetToolTip($delete,'Delete MIDI - move to Recycle Bin')
            $delete.Add_Click({param($sender,$eventArgs)
                $songToDelete=$sender.Tag
                try{
                    $path=Get-OrchestraRemovableMidiPath $script:orchestraRoot $songToDelete
                    $message='Move "'+$songToDelete.Title+'" to the Recycle Bin?'+[Environment]::NewLine+[Environment]::NewLine+$path+[Environment]::NewLine+[Environment]::NewLine+'Your original audio stays unchanged. You can convert it again afterward.'
                    if([Windows.Forms.MessageBox]::Show($form,$message,'Delete library MIDI','YesNo','Question','Button2') -eq 'Yes'){
                        Remove-OrchestraSong $script:orchestraRoot $songToDelete
                        $footer.Text='MIDI moved to the Recycle Bin. Ready for a replacement conversion.'
                        Refresh-OrchestraLibrary
                    }
                }catch{[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Could not delete MIDI','OK','Warning')}
            });$card.Controls.Add($delete)
        }
        $menu=New-Object Windows.Forms.ContextMenuStrip
        $menu.BackColor=[Drawing.Color]::FromArgb(35,46,70);$menu.ForeColor=[Drawing.Color]::White
        $generate=New-Object Windows.Forms.ToolStripMenuItem;$generate.Text='Generate icon';$generate.Tag=$song
        $generate.ToolTipText='Opens ChatGPT with this song''s prompt. Send it there, then download and use the image.'
        $generate.Add_Click({param($sender,$eventArgs)
            try{
                $prompt=Get-OrchestraIconPrompt $sender.Tag
                [Windows.Forms.Clipboard]::SetText($prompt)
                [void](Start-Process ('https://chatgpt.com/?q='+[Uri]::EscapeDataString($prompt)))
                $footer.Text='ChatGPT opened with the song prompt. Download the artwork, then choose Use artwork with Orchestra frame.'
            }catch{$footer.Text='Could not open ChatGPT: '+$_.Exception.Message}
        });[void]$menu.Items.Add($generate)
        $framed=New-Object Windows.Forms.ToolStripMenuItem;$framed.Text='Use artwork with Orchestra frame...';$framed.Tag=$song
        $framed.Add_Click({param($sender,$eventArgs)
            $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Artwork images|*.png;*.jpg;*.jpeg;*.ico'
            if($dialog.ShowDialog($form) -eq 'OK'){
                try{[void](Save-OrchestraSongIcon $script:orchestraRoot $sender.Tag $dialog.FileName $true);$footer.Text='Song image updated.';Refresh-OrchestraLibrary}
                catch{[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Could not use image','OK','Warning')}
            };$dialog.Dispose()
        });[void]$menu.Items.Add($framed)
        $use=New-Object Windows.Forms.ToolStripMenuItem;$use.Text='Use custom icon...';$use.Tag=$song
        $use.Add_Click({param($sender,$eventArgs)
            $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Icon images|*.png;*.jpg;*.jpeg;*.ico'
            if($dialog.ShowDialog($form) -eq 'OK'){
                try{[void](Save-OrchestraSongIcon $script:orchestraRoot $sender.Tag $dialog.FileName);$footer.Text='Song image updated.';Refresh-OrchestraLibrary}
                catch{[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Could not use image','OK','Warning')}
            };$dialog.Dispose()
        });[void]$menu.Items.Add($use)
        $picture.ContextMenuStrip=$menu;$picture.TabStop=$true;$picture.AccessibleName=$song.Title+' icon options'
        if($song.SourceUrl){
            $sourceItem=New-Object Windows.Forms.ToolStripMenuItem;$sourceItem.Text='Open MIDI source';$sourceItem.Tag=$song.SourceUrl
            $sourceItem.Add_Click({param($sender,$eventArgs) [void](Start-Process ([string]$sender.Tag))});[void]$menu.Items.Add($sourceItem)
        }
        $pencil=New-Object Windows.Forms.Button;$pencil.Text=[string][char]0x270E
        $pencil.Font=New-Object Drawing.Font 'Segoe UI Symbol',15
        $pencil.Location=New-Object Drawing.Point 105,0;$pencil.Size=New-Object Drawing.Size 31,31
        $pencil.BackColor=[Drawing.Color]::FromArgb(26,117,177);$pencil.ForeColor=[Drawing.Color]::White
        $pencil.FlatStyle='Flat';$pencil.FlatAppearance.BorderSize=0;$pencil.Visible=$false
        $pencil.AccessibleName='Generate icon or use custom icon';$tooltips.SetToolTip($pencil,'Generate icon / Use custom icon')
        $picture.Controls.Add($pencil)
        $picture.Add_MouseEnter({param($sender,$eventArgs) $sender.Controls[0].Visible=$true})
        $picture.Add_Enter({param($sender,$eventArgs) $sender.Controls[0].Visible=$true})
        $picture.Add_MouseLeave({param($sender,$eventArgs)
            if(-not $sender.ClientRectangle.Contains($sender.PointToClient([Windows.Forms.Cursor]::Position))){$sender.Controls[0].Visible=$false}
        })
        $pencil.Add_MouseLeave({param($sender,$eventArgs)
            if(-not $sender.Parent.ClientRectangle.Contains($sender.Parent.PointToClient([Windows.Forms.Cursor]::Position))){$sender.Visible=$false}
        })
        $pencil.Add_Click({param($sender,$eventArgs) $sender.Parent.ContextMenuStrip.Show($sender,[Drawing.Point]::new(0,$sender.Height))})
        $picture.Add_KeyDown({param($sender,$eventArgs)
            if($eventArgs.KeyCode -in @('Enter','Space')){$sender.ContextMenuStrip.Show($sender,[Drawing.Point]::new(105,31));$eventArgs.Handled=$true}
        })
        $grid.Controls.Add($card)
    }
    $grid.ResumeLayout($true)
    $script:buildingCards=$false
    Align-OrchestraCards
    $script:songSignature=Get-OrchestraLibrarySignature
}
function Get-OrchestraLibrarySignature {
    @((Get-OrchestraSongs $script:orchestraRoot)|ForEach-Object {$_.Id+'|'+$_.Icon}) -join ';'
}
Add-ToolbarButton 'Online MIDI...' {
    $catalogue=Join-Path $script:orchestraRoot 'Online-Catalogue.ps1'
    [void](Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $catalogue) -WindowStyle Hidden)
}
Add-ToolbarButton 'Add MIDI...' {
    $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='MIDI files|*.mid;*.midi'
    if($dialog.ShowDialog($form) -eq 'OK'){
        $folder=Join-Path $script:orchestraRoot 'Library';[void][IO.Directory]::CreateDirectory($folder)
        $name=[IO.Path]::GetFileNameWithoutExtension($dialog.FileName);$destination=Join-Path $folder ($name+'.mid');$number=2
        while(Test-Path -LiteralPath $destination){$destination=Join-Path $folder ('{0}-{1}.mid' -f $name,$number);$number++}
        Copy-Item -LiteralPath $dialog.FileName -Destination $destination;Refresh-OrchestraLibrary
    };$dialog.Dispose()
}
Add-ToolbarButton 'Convert audio...' {
    $converter=Join-Path $script:orchestraRoot 'Converter\Convert-Audio.ps1'
    [void](Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $converter) -WindowStyle Hidden)
}
Add-ToolbarButton 'Refresh' {Refresh-OrchestraLibrary}
$styleMenu=New-Object Windows.Forms.ContextMenuStrip
$styleButton=New-Object Windows.Forms.Button;$styleButton.Text='Player: '+$script:displayStyle;$styleButton.AutoSize=$true;$styleButton.Height=30;$styleButton.Padding=New-Object Windows.Forms.Padding 10,0,10,0
$styleButton.BackColor=[Drawing.Color]::FromArgb(44,57,85);$styleButton.FlatStyle='Flat';$styleButton.FlatAppearance.BorderSize=0
foreach($choice in @(@('Console','PowerShell console flair'),@('Panels','Graphical panels'),@('Text','Plain console log'))){
    $item=New-Object Windows.Forms.ToolStripMenuItem;$item.Tag=$choice[0];$item.Text=$choice[1];$item.Checked=$choice[0] -eq $script:displayStyle
    $item.Add_Click({param($sender,$eventArgs)
        $script:displayStyle=[string]$sender.Tag;$styleButton.Text='Player: '+$script:displayStyle
        foreach($entry in $styleMenu.Items){$entry.Checked=$entry.Tag -eq $script:displayStyle}
        [IO.File]::WriteAllText((Join-Path $script:orchestraRoot 'player-settings.json'),(@{DisplayStyle=$script:displayStyle}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        $footer.Text='Player style saved. It applies to the next song you launch.'
    });[void]$styleMenu.Items.Add($item)
}
$styleButton.Add_Click({$styleMenu.Show($styleButton,[Drawing.Point]::new(0,$styleButton.Height))});$toolbar.Controls.Add($styleButton)
$refreshTimer=New-Object Windows.Forms.Timer;$refreshTimer.Interval=3000
$refreshTimer.Add_Tick({if((Get-OrchestraLibrarySignature) -ne $script:songSignature){Refresh-OrchestraLibrary}})
$form.Add_FormClosed({$refreshTimer.Stop()})
Refresh-OrchestraLibrary
if($PreviewPath){
    $form.Show();$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
    if($PreviewIconOptions -and $grid.Controls.Count){$grid.Controls[0].Controls[0].Controls[0].Visible=$true}
    $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
    try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
    [PSCustomObject]@{SongTiles=$grid.Controls.Count;Scrollable=$grid.AutoScroll;ScrollBarVisible=$grid.VerticalScroll.Visible;ContentHeight=$grid.DisplayRectangle.Height;ViewportHeight=$grid.ClientSize.Height;ViewportWidth=$grid.ClientSize.Width;Cards=@($grid.Controls|ForEach-Object {@{X=$_.Left;Y=$_.Top;Width=$_.Width;Height=$_.Height;PencilVisible=$_.Controls[0].Controls[0].Visible;IconMenu=@($_.Controls[0].ContextMenuStrip.Items|ForEach-Object {$_.Text})}});CustomIcon=($null -ne $form.Icon);Title=$form.Text}|ConvertTo-Json -Depth 5
    $form.Close()
}else{$refreshTimer.Start();[void]$form.ShowDialog()}
$refreshTimer.Dispose();$styleMenu.Dispose();$tooltips.Dispose();$form.Dispose()
