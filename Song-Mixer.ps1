#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$MidiFile,[string]$SongTitle,[string]$PreviewPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'SongMix.ps1')
Import-OrchestraMixEngine $PSScriptRoot
$script:mixerRoot=$PSScriptRoot
$script:midiPath=(Resolve-Path -LiteralPath $MidiFile).ProviderPath
if(-not $SongTitle){$SongTitle=[IO.Path]::GetFileNameWithoutExtension($script:midiPath)}
$score=[LayeredMusic.Midi]::Read($script:midiPath,1,0,0,24)
$saved=Get-OrchestraSongMix $PSScriptRoot $script:midiPath
$form=[Windows.Forms.Form]::new();$form.Text='PowerShell Orchestra - Song mixer';$form.Size=[Drawing.Size]::new(780,670);$form.MinimumSize=[Drawing.Size]::new(650,480);$form.StartPosition='CenterScreen'
$form.BackColor=[Drawing.Color]::FromArgb(20,27,48);$form.ForeColor=[Drawing.Color]::White;$form.Font=[Drawing.Font]::new('Segoe UI',10)
$form.Icon=[Drawing.Icon]::new((Join-Path $PSScriptRoot 'PowerShell-Orchestra-Note.ico'))
$top=[Windows.Forms.Panel]::new();$top.Dock='Top';$top.Height=110;$form.Controls.Add($top)
$title=[Windows.Forms.Label]::new();$title.Text=$SongTitle;$title.Font=[Drawing.Font]::new('Segoe UI',18,[Drawing.FontStyle]::Bold);$title.SetBounds(20,17,720,37);$title.AutoEllipsis=$true;$title.Anchor='Top,Left,Right';$top.Controls.Add($title)
$hint=[Windows.Forms.Label]::new();$hint.Text='100% keeps the MIDI balance. Lower a part to quieten it; 0% mutes it.';$hint.SetBounds(22,62,720,40);$hint.Anchor='Top,Left,Right';$hint.ForeColor=[Drawing.Color]::LightSteelBlue;$top.Controls.Add($hint)
$bottom=[Windows.Forms.Panel]::new();$bottom.Dock='Bottom';$bottom.Height=100;$form.Controls.Add($bottom)
$status=[Windows.Forms.Label]::new();$status.SetBounds(22,7,720,28);$status.Anchor='Top,Left,Right';$status.Text='Changes apply to the next playback and stay saved for this song.';$bottom.Controls.Add($status)
function New-MixerButton([string]$Text,[int]$X,[int]$Width){$button=[Windows.Forms.Button]::new();$button.Text=$Text;$button.SetBounds($X,46,$Width,34);$button.BackColor=[Drawing.Color]::FromArgb(44,57,85);$button.FlatStyle='Flat';$button.FlatAppearance.BorderSize=0;$bottom.Controls.Add($button);return $button}
$save=New-MixerButton 'Save mix' 22 130;$play=New-MixerButton 'Save and play' 164 145;$reset=New-MixerButton 'Reset to MIDI balance' 321 190
$rows=[Windows.Forms.Panel]::new();$rows.Dock='Fill';$rows.AutoScroll=$true;$rows.BackColor=[Drawing.Color]::FromArgb(15,21,38);$form.Controls.Add($rows);$rows.BringToFront()
$script:sliders=New-Object Collections.Generic.List[object]
function Add-MixerSlider([string]$Name,[string]$Key,[int]$Value,[int]$Index){
    $row=[Windows.Forms.Panel]::new();$row.SetBounds(12,12+$Index*76,720,70);$row.Anchor='Top,Left,Right';$rows.Controls.Add($row)
    $label=[Windows.Forms.Label]::new();$label.Text=$Name;$label.SetBounds(10,5,680,24);$label.AutoEllipsis=$true;$label.Anchor='Top,Left,Right';$row.Controls.Add($label)
    $slider=[Windows.Forms.TrackBar]::new();$slider.Minimum=0;$slider.Maximum=100;$slider.Value=$Value;$slider.TickFrequency=10;$slider.SmallChange=1;$slider.LargeChange=10;$slider.SetBounds(10,30,610,35);$slider.Anchor='Top,Left,Right';$slider.Tag=$Key;$slider.AccessibleName=$Name+' volume';$row.Controls.Add($slider)
    $percent=[Windows.Forms.Label]::new();$percent.Text=$Value.ToString()+'%';$percent.SetBounds(635,34,70,25);$percent.Anchor='Top,Right';$row.Controls.Add($percent)
    $slider.Add_ValueChanged({param($sender,$eventArgs) $sender.Parent.Controls[2].Text=$sender.Value.ToString()+'%'})
    $script:sliders.Add($slider)
}
Add-MixerSlider 'MASTER' 'master' $saved.Master 0
$index=1
foreach($group in @($score.Notes|Group-Object MixId)){
    $note=$group.Group[0];$name=$note.Part+'  |  Track '+($note.Track+1)+' / Channel '+($note.Channel+1)
    if($note.Port -gt 0){$name+=' / Port '+($note.Port+1)}
    $value=if($saved.Parts.ContainsKey($group.Name)){$saved.Parts[$group.Name]}else{100}
    Add-MixerSlider $name $group.Name $value $index;$index++
}
$rows.AutoScrollMinSize=[Drawing.Size]::new(0,12+$index*76)
function Save-MixerControls {
    $settings=@{Master=$script:sliders[0].Value;Parts=@{}}
    foreach($slider in $script:sliders|Select-Object -Skip 1){$settings.Parts[[string]$slider.Tag]=$slider.Value}
    Save-OrchestraSongMix $script:mixerRoot $script:midiPath $settings
    $status.Text='Mix saved. It applies to the next playback, including song shortcuts.'
}
$save.Add_Click({try{Save-MixerControls}catch{$status.Text=$_.Exception.Message}})
$reset.Add_Click({foreach($slider in $script:sliders){$slider.Value=100};$status.Text='Sliders reset to the MIDI balance. Save to keep this change.'})
$play.Add_Click({try{
    Save-MixerControls
    $arguments='powershell.exe -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}" -MidiFile "{1}" -SongTitle "{2}"' -f (Join-Path $script:mixerRoot 'Play-RushE-Layers.ps1'),$script:midiPath,$title.Text
    [void](Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $arguments -WindowStyle Normal)
}catch{$status.Text=$_.Exception.Message}})
if($PreviewPath){$form.Show();[Windows.Forms.Application]::DoEvents();$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()};$form.Close()}
else{[void]$form.ShowDialog()}
$form.Dispose()
