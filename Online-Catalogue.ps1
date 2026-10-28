#requires -Version 5.1
[CmdletBinding()]
param([string]$PreviewPath,[string]$InitialQuery='',[string]$AutomationReceipt,[switch]$AutomationAdd,[switch]$CloseAfterAutomation)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:appRoot=$PSScriptRoot
. (Join-Path $PSScriptRoot 'Catalogue\Catalogue.ps1')
Import-CatalogueEngine
$script:work=$null;$script:audio=$null;$script:page=0;$script:hasMore=$false;$script:query='';$script:provider='All sources'
$script:automationStage=0
$form=[Windows.Forms.Form]::new();$form.Text='PowerShell Orchestra - Online MIDI catalogue';$form.Size=[Drawing.Size]::new(1000,720);$form.MinimumSize=[Drawing.Size]::new(780,590);$form.StartPosition='CenterScreen'
$form.Font=[Drawing.Font]::new('Segoe UI',10);$form.BackColor=[Drawing.Color]::FromArgb(20,27,48);$form.ForeColor=[Drawing.Color]::White
$form.Icon=[Drawing.Icon]::new((Join-Path $PSScriptRoot 'PowerShell-Orchestra-Note.ico'))
$top=[Windows.Forms.Panel]::new();$top.Dock='Top';$top.Height=134;$form.Controls.Add($top)
$heading=[Windows.Forms.Label]::new();$heading.Text='Online MIDI catalogue';$heading.Font=[Drawing.Font]::new('Segoe UI',21,[Drawing.FontStyle]::Bold);$heading.SetBounds(20,15,900,40);$top.Controls.Add($heading)
$hint=[Windows.Forms.Label]::new();$hint.Text='Find an arrangement, hear it in Orchestra, then keep the ones you like.';$hint.SetBounds(23,59,900,25);$hint.ForeColor=[Drawing.Color]::LightSteelBlue;$top.Controls.Add($hint)
$searchBox=[Windows.Forms.TextBox]::new();$searchBox.SetBounds(22,96,465,28);$searchBox.Anchor='Top,Left,Right';$searchBox.AccessibleName='Song, artist, game or film';$top.Controls.Add($searchBox)
$searchBox.ForeColor=[Drawing.Color]::Black;$searchBox.BackColor=[Drawing.Color]::White
$sources=[Windows.Forms.ComboBox]::new();$sources.DropDownStyle='DropDownList';$sources.SetBounds(500,94,170,29);$sources.Anchor='Top,Right';[void]$sources.Items.AddRange(@('All sources','FreeMIDI','BitMidi'));$sources.SelectedIndex=0;$sources.AccessibleName='MIDI source';$top.Controls.Add($sources)
$sources.ForeColor=[Drawing.Color]::Black;$sources.BackColor=[Drawing.Color]::White
function New-CatalogueButton([string]$Text,[Windows.Forms.Control]$Parent,[int]$X,[int]$Y,[int]$Width=140){
    $button=[Windows.Forms.Button]::new();$button.Text=$Text;$button.SetBounds($X,$Y,$Width,34);$button.BackColor=[Drawing.Color]::FromArgb(44,57,85);$button.FlatStyle='Flat';$button.FlatAppearance.BorderSize=0;$Parent.Controls.Add($button);return $button
}
$search=New-CatalogueButton 'Search' $top 683 92 105;$search.Anchor='Top,Right'
$previous=New-CatalogueButton '<' $top 800 92 50;$previous.Anchor='Top,Right';$previous.Enabled=$false
$next=New-CatalogueButton '>' $top 862 92 50;$next.Anchor='Top,Right';$next.Enabled=$false
$cancel=New-CatalogueButton 'Cancel' $top 920 92 58;$cancel.Anchor='Top,Right';$cancel.Enabled=$false
$bottom=[Windows.Forms.Panel]::new();$bottom.Dock='Bottom';$bottom.Height=166;$form.Controls.Add($bottom)
$selection=[Windows.Forms.Label]::new();$selection.SetBounds(22,12,930,28);$selection.Anchor='Top,Left,Right';$selection.AutoEllipsis=$true;$selection.Text='Search for a song or artist to get started.';$bottom.Controls.Add($selection)
$preview=New-CatalogueButton 'Preview 30 seconds' $bottom 22 49 165;$preview.Enabled=$false
$stop=New-CatalogueButton 'Stop preview' $bottom 199 49 120;$stop.Enabled=$false
$add=New-CatalogueButton 'Add to My Songs' $bottom 331 49 168;$add.BackColor=[Drawing.Color]::FromArgb(26,117,177);$add.Enabled=$false
$open=New-CatalogueButton 'Open source' $bottom 511 49 135;$open.Enabled=$false
$progress=[Windows.Forms.ProgressBar]::new();$progress.SetBounds(22,95,930,7);$progress.Anchor='Top,Left,Right';$bottom.Controls.Add($progress)
$status=[Windows.Forms.Label]::new();$status.SetBounds(22,114,930,45);$status.Anchor='Top,Left,Right';$status.ForeColor=[Drawing.Color]::LightSteelBlue;$status.Text='Search results come from BitMidi and FreeMIDI. Previewing does not add a song.';$bottom.Controls.Add($status)
$list=[Windows.Forms.ListView]::new();$list.Dock='Fill';$list.View='Details';$list.FullRowSelect=$true;$list.MultiSelect=$false;$list.HideSelection=$false;$list.BackColor=[Drawing.Color]::FromArgb(15,21,38);$list.ForeColor=[Drawing.Color]::White;$list.BorderStyle='None';$list.AccessibleName='Online MIDI search results'
[void]$list.Columns.Add('Song / arrangement',370);[void]$list.Columns.Add('Artist',170);[void]$list.Columns.Add('Source',100);[void]$list.Columns.Add('Preview details',280)
$form.Controls.Add($list);$list.BringToFront()
function Stop-CataloguePreview {
    if($script:audio){$script:audio.Dispose();$script:audio=$null};$stop.Enabled=$false;$progress.Value=0
}
function Save-CatalogueWindow {
    if(-not $PreviewPath){return}
    $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
    try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}
function Remove-CatalogueJob {
    if(-not $script:jobFolder){return}
    $parent=[IO.Path]::GetFullPath((Join-Path $script:appRoot 'Catalogue\Jobs'));$target=[IO.Path]::GetFullPath($script:jobFolder)
    if([IO.Path]::GetDirectoryName($target) -eq $parent -and [IO.Path]::GetFileName($target) -match '^[a-f0-9]{32}$' -and (Test-Path -LiteralPath $target)){Remove-Item -LiteralPath $target -Recurse -Force}
    $script:jobFolder=$null
}
function Update-CatalogueButtons {
    $selected=$list.SelectedItems.Count -eq 1;$idle=$null -eq $script:work
    $preview.Enabled=$selected -and $idle;$add.Enabled=$selected -and $idle;$open.Enabled=$selected
    if($selected -and $list.SelectedItems[0].Tag.Saved){$add.Enabled=$false}
    $search.Enabled=$idle;$sources.Enabled=$idle;$searchBox.Enabled=$idle;$cancel.Enabled=-not $idle
    $previous.Enabled=$idle -and $script:page -gt 0;$next.Enabled=$idle -and $script:hasMore
}
function Start-CatalogueWork($Request){
    Stop-CataloguePreview
    $script:jobFolder=Join-Path (Join-Path $script:appRoot 'Catalogue\Jobs') ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($script:jobFolder)
    Save-CatalogueJson (Join-Path $script:jobFolder 'input.json') $Request
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -JobDirectory "{1}"' -f (Join-Path $script:appRoot 'Catalogue\Worker.ps1'),$script:jobFolder
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $script:action=$Request.Action;$script:pendingRow=if($list.SelectedItems.Count){$list.SelectedItems[0]}else{$null}
    try{$script:work=[Diagnostics.Process]::Start($info)}catch{Remove-CatalogueJob;throw}
    $status.Text=if($Request.Action -eq 'Search'){'Searching '+$Request.Provider+' for "'+$Request.Query+'"...'}elseif($Request.Action -eq 'Preview'){'Downloading and preparing an Orchestra-tone preview...'}else{'Checking the MIDI and adding it to My Songs...'}
    $progress.Style='Marquee';Update-CatalogueButtons
}
function Start-CatalogueSearch([int]$Page=0){
    if($script:work){return}
    $query=$searchBox.Text.Trim();if($query.Length -lt 2){$status.Text='Enter at least two characters, such as a song title or artist.';return}
    $script:query=$query;$script:provider=[string]$sources.SelectedItem;$script:page=$Page
    try{Start-CatalogueWork @{Action='Search';Query=$query;Provider=$script:provider;Page=$Page}}catch{$status.Text=$_.Exception.Message}
}
$search.Add_Click({Start-CatalogueSearch})
$searchBox.Add_KeyDown({param($sender,$eventArgs) if($eventArgs.KeyCode -eq 'Enter'){$eventArgs.SuppressKeyPress=$true;Start-CatalogueSearch}})
$previous.Add_Click({Start-CatalogueSearch ($script:page-1)});$next.Add_Click({Start-CatalogueSearch ($script:page+1)})
$list.Add_SelectedIndexChanged({Stop-CataloguePreview;if($list.SelectedItems.Count){$item=$list.SelectedItems[0].Tag;$selection.Text=$item.Title+'  |  '+$item.Provider};Update-CatalogueButtons})
$preview.Add_Click({if($list.SelectedItems.Count -and -not $script:work){Start-CatalogueWork @{Action='Preview';Item=$list.SelectedItems[0].Tag}}})
$list.Add_DoubleClick({if($preview.Enabled){$preview.PerformClick()}})
$stop.Add_Click({Stop-CataloguePreview;$status.Text='Preview stopped. Add the song to keep it for offline playback.'})
$add.Add_Click({if($list.SelectedItems.Count -and -not $script:work){Start-CatalogueWork @{Action='Add';Item=$list.SelectedItems[0].Tag}}})
$open.Add_Click({if($list.SelectedItems.Count){$url=[string]$list.SelectedItems[0].Tag.SourceUrl;[void](Assert-CatalogueUrl $url);[void](Start-Process $url)}})
$cancel.Add_Click({if($script:work){if(-not $script:work.HasExited){$script:work.Kill();[void]$script:work.WaitForExit(3000)};$script:work.Dispose();$script:work=$null;Remove-CatalogueJob;$progress.Style='Continuous';$progress.Value=0;$status.Text='Catalogue request cancelled.';Update-CatalogueButtons}})
$timer=[Windows.Forms.Timer]::new();$timer.Interval=100
$timer.Add_Tick({
    if($script:audio){if($script:audio.Done){Stop-CataloguePreview;$status.Text='Preview finished. Add the song to My Songs if you like this arrangement.'}else{$progress.Value=[Math]::Min(100,[int](100*$script:audio.Milliseconds/[Math]::Max(1,$script:previewDuration)))}}
    if(-not $script:work -or -not $script:work.HasExited){return}
    try{
        $response=Get-Content -LiteralPath (Join-Path $script:jobFolder 'result.json') -Raw|ConvertFrom-Json
        if(-not $response.Ok){throw $response.Error}
        $result=$response.Result
        $progress.Style='Continuous';$progress.Value=0
        if($script:action -eq 'Search'){
            $list.BeginUpdate();$list.Items.Clear()
            foreach($item in @($result.Items)){
                $row=[Windows.Forms.ListViewItem]::new([string]$item.Title);[void]$row.SubItems.Add([string]$item.Artist);[void]$row.SubItems.Add([string]$item.Provider);[void]$row.SubItems.Add('');$row.Tag=$item;[void]$list.Items.Add($row)
            };$list.EndUpdate();$script:hasMore=$result.HasMore
            $status.Text=('{0} arrangements / page {1}. Select one to preview or add.' -f $list.Items.Count,($script:page+1))
            if($list.Items.Count -eq 0){$status.Text='No matching songs found. Try fewer words or another source.'}
            if(@($result.Warnings).Count){$status.Text+=' '+($result.Warnings -join ' ')}
        }elseif($script:action -eq 'Preview'){
            $script:previewDuration=[Math]::Min(30,$result.Duration)*1000
            $script:audio=[LayeredMusic.Audio]::new($result.Wave);$script:audio.Start();$stop.Enabled=$true
            $details=('{0:mm\:ss} / {1} parts / {2:N0} notes' -f [TimeSpan]::FromSeconds($result.Duration),$result.Parts,$result.Notes)
            $script:pendingRow.SubItems[3].Text=$details;$status.Text='Previewing the first 30 seconds with Orchestra tones. '+$details
        }else{
            $script:pendingRow.Tag|Add-Member -NotePropertyName Saved -NotePropertyValue $true -Force
            $script:pendingRow.SubItems[3].Text='In My Songs'
            $status.Text=if($result.AlreadyAdded){'Already in My Songs: '+$result.Title}else{'Added to My Songs: '+$result.Title+'. Ready for offline playback.'}
        }
        if($AutomationReceipt){
            if($script:action -eq 'Search' -and $list.Items.Count){$script:automationStage=1}
            elseif($script:action -eq 'Preview'){$script:automationStage=2}
            elseif($script:action -eq 'Add'){$script:automationStage=3;Save-CatalogueJson $AutomationReceipt @{Ok=$true;SearchResults=$list.Items.Count;Midi=$result.Midi;AlreadyAdded=$result.AlreadyAdded;Stage='Added';SourceSelected=[string]$sources.SelectedItem};Save-CatalogueWindow;if($CloseAfterAutomation){$form.Close()}}
        }
    }catch{
        $status.Text='Could not complete request: '+$_.Exception.Message;$progress.Style='Continuous';$progress.Value=0
        if($AutomationReceipt){Save-CatalogueJson $AutomationReceipt @{Ok=$false;Error=$_.Exception.Message};if($CloseAfterAutomation){$form.Close()}}
    }finally{
        if($script:work){$script:work.Dispose();$script:work=$null};Remove-CatalogueJob;Update-CatalogueButtons
    }
    if($AutomationReceipt -and $script:automationStage -eq 1){$list.Items[0].Selected=$true;$preview.PerformClick();$script:automationStage=0}
    elseif($AutomationReceipt -and $script:automationStage -eq 2){
        if($AutomationAdd){$add.PerformClick();$script:automationStage=0}
        else{Save-CatalogueJson $AutomationReceipt @{Ok=$true;SearchResults=$list.Items.Count;Stage='Preview';Details=$script:pendingRow.SubItems[3].Text};Save-CatalogueWindow;if($CloseAfterAutomation){$form.Close()}}
    }
})
$form.Add_FormClosing({$timer.Stop();Stop-CataloguePreview;if($script:work){if(-not $script:work.HasExited){$script:work.Kill();[void]$script:work.WaitForExit(3000)};$script:work.Dispose();$script:work=$null};Remove-CatalogueJob})
if($InitialQuery){$searchBox.Text=$InitialQuery;$form.Add_Shown({Start-CatalogueSearch})}
if($PreviewPath -and -not $AutomationReceipt){
    $form.Show();[Windows.Forms.Application]::DoEvents();$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
    try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()};$form.Close()
}else{$timer.Start();[void]$form.ShowDialog()}
$timer.Dispose();$form.Dispose()
