#requires -Version 5.1
[CmdletBinding()]
param([string]$InputFile,[string]$OutputFile,[switch]$AutoConvert,[switch]$CloseAfterConversion,[string]$PreviewPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:converterRoot=$PSScriptRoot
$script:job=$null;$script:convertedFile=$null
$form=New-Object Windows.Forms.Form
$form.Text='PowerShell Orchestra - Audio to MIDI'
$form.Size=New-Object Drawing.Size 720,590
$form.MinimumSize=$form.Size;$form.MaximumSize=$form.Size
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font 'Segoe UI',10
$form.BackColor=[Drawing.Color]::WhiteSmoke
$orchestraIcon=Join-Path (Split-Path -Parent $PSScriptRoot) 'PowerShell-Orchestra-Note.ico'
if(Test-Path -LiteralPath $orchestraIcon){$form.Icon=[Drawing.Icon]::new($orchestraIcon)}
function Add-Label([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=24){
    $control=New-Object Windows.Forms.Label;$control.Text=$Text;$control.Location=New-Object Drawing.Point $X,$Y;$control.Size=New-Object Drawing.Size $Width,$Height;$form.Controls.Add($control);return $control
}
$heading=Add-Label 'Audio to MIDI' 22 18 650 32
$heading.Font=New-Object Drawing.Font 'Segoe UI',17,([Drawing.FontStyle]::Bold)
[void](Add-Label 'Convert audio locally into notes for PowerShell Orchestra.' 22 57 660)
[void](Add-Label 'Audio file' 22 97 120)
$inputBox=New-Object Windows.Forms.TextBox;$inputBox.Location=New-Object Drawing.Point 22,122;$inputBox.Size=New-Object Drawing.Size 548,28;$form.Controls.Add($inputBox)
$browse=New-Object Windows.Forms.Button;$browse.Text='Browse...';$browse.Location=New-Object Drawing.Point 582,120;$browse.Size=New-Object Drawing.Size 96,30;$form.Controls.Add($browse)
[void](Add-Label 'MIDI output' 22 163 120)
$outputBox=New-Object Windows.Forms.TextBox;$outputBox.Location=New-Object Drawing.Point 22,188;$outputBox.Size=New-Object Drawing.Size 548,28;$form.Controls.Add($outputBox)
$save=New-Object Windows.Forms.Button;$save.Text='Save as...';$save.Location=New-Object Drawing.Point 582,186;$save.Size=New-Object Drawing.Size 96,30;$form.Controls.Add($save)
[void](Add-Label 'Conversion style' 22 226 125)
$mode=New-Object Windows.Forms.ComboBox;$mode.DropDownStyle='DropDownList';$mode.Location=New-Object Drawing.Point 150,223;$mode.Size=New-Object Drawing.Size 528,28
[void]$mode.Items.Add('Balanced arrangement - richer source rhythm, hooks and harmony')
[void]$mode.Items.Add('Simple arrangement - clear lead, bass and restrained chords')
[void]$mode.Items.Add('Detailed transcription - capture more of the recording')
[void]$mode.Items.Add('Isolated instrument - direct chord transcription (faster)')
$mode.SelectedIndex=0;$form.Controls.Add($mode)
[void](Add-Label 'Vocal lead' 22 264 125)
$vocal=New-Object Windows.Forms.ComboBox;$vocal.DropDownStyle='DropDownList';$vocal.Location=New-Object Drawing.Point 150,261;$vocal.Size=New-Object Drawing.Size 528,28
[void]$vocal.Items.Add('Autotune-style melody - hold notes and smooth sung variations')
[void]$vocal.Items.Add('Stable sung notes - filter uncertain vocal inflections')
[void]$vocal.Items.Add('Detailed vocal pitch - retain more passing pitch changes')
[void]$vocal.Items.Add('Omit vocal lead - keep the instrumental arrangement')
$vocal.SelectedIndex=0;$form.Controls.Add($vocal)
[void](Add-Label 'Smoothing' 22 302 125)
$smoothing=New-Object Windows.Forms.ComboBox;$smoothing.DropDownStyle='DropDownList';$smoothing.Location=New-Object Drawing.Point 150,299;$smoothing.Size=New-Object Drawing.Size 528,28
[void]$smoothing.Items.Add('Gentle - retain more short melody changes')
[void]$smoothing.Items.Add('Balanced - smooth scoops and vibrato')
[void]$smoothing.Items.Add('Firm - favour longer held notes')
$smoothing.SelectedIndex=1;$form.Controls.Add($smoothing)
$preview=New-Object Windows.Forms.CheckBox;$preview.Text='Convert a 30-second preview first';$preview.Location=New-Object Drawing.Point 22,339;$preview.Size=New-Object Drawing.Size 360,28;$form.Controls.Add($preview)
[void](Add-Label 'Start at (sec)' 400 343 110)
$previewStart=New-Object Windows.Forms.NumericUpDown;$previewStart.Location=New-Object Drawing.Point 520,339;$previewStart.Size=New-Object Drawing.Size 158,28
$previewStart.Maximum=86400;$previewStart.Enabled=$false;$form.Controls.Add($previewStart)
$preview.Add_CheckedChanged({$previewStart.Enabled=$preview.Checked})
$tip=Add-Label 'Autotune-style melody keeps steady vocal notes. Try Gentle smoothing to retain more short melody changes.' 22 375 660 42
$tip.ForeColor=[Drawing.Color]::DimGray
$convert=New-Object Windows.Forms.Button;$convert.Text='Convert';$convert.Location=New-Object Drawing.Point 22,425;$convert.Size=New-Object Drawing.Size 130,36;$form.Controls.Add($convert)
$play=New-Object Windows.Forms.Button;$play.Text='Play MIDI';$play.Location=New-Object Drawing.Point 164,425;$play.Size=New-Object Drawing.Size 130,36;$play.Enabled=$false;$form.Controls.Add($play)
$cancel=New-Object Windows.Forms.Button;$cancel.Text='Cancel conversion';$cancel.Location=New-Object Drawing.Point 306,425;$cancel.Size=New-Object Drawing.Size 156,36;$cancel.Enabled=$false;$form.Controls.Add($cancel)
$progress=New-Object Windows.Forms.ProgressBar;$progress.Location=New-Object Drawing.Point 22,475;$progress.Size=New-Object Drawing.Size 656,12;$form.Controls.Add($progress)
$status=Add-Label 'Ready. MP3, WAV, FLAC and OGG. Audio stays on this PC.' 22 498 660 46

function Remove-ConversionWork {
    if($script:workFolder){
        $parent=[IO.Path]::GetFullPath((Join-Path $script:converterRoot '.jobs'))
        $target=[IO.Path]::GetFullPath($script:workFolder)
        if([IO.Path]::GetDirectoryName($target) -eq $parent -and [IO.Path]::GetFileName($target) -match '^[a-f0-9]{32}$'){
            if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Recurse -Force}
        }
        $script:workFolder=$null
    }
}

function Set-AudioInput([string]$Path){
    $inputBox.Text=$Path
    $folder=Join-Path $script:converterRoot 'Converted';[void][IO.Directory]::CreateDirectory($folder)
    $suffix=@('Balanced Arrangement','Simple Arrangement','Orchestra','Instrument')[$mode.SelectedIndex]
    $base=[IO.Path]::GetFileNameWithoutExtension($Path)+' - '+$suffix
    if($mode.SelectedIndex -ne 3 -and $vocal.SelectedIndex -eq 3){$base+=' - No Vocal Lead'}
    elseif($mode.SelectedIndex -ne 3 -and $vocal.SelectedIndex -eq 2){$base+=' - Detailed Vocals'}
    elseif($mode.SelectedIndex -ne 3 -and $vocal.SelectedIndex -eq 1){$base+=' - Filtered Vocals'}
    elseif($mode.SelectedIndex -ne 3 -and $vocal.SelectedIndex -eq 0 -and $smoothing.SelectedIndex -ne 1){$base+=' - '+@('Gentle','Balanced','Firm')[$smoothing.SelectedIndex]+' Vocals'}
    $destination=Join-Path $folder ($base+'.mid');$number=2
    while(Test-Path -LiteralPath $destination){$destination=Join-Path $folder ('{0}-{1}.mid' -f $base,$number);$number++}
    $outputBox.Text=$destination
    $script:suggestedOutput=$destination
}
$mode.Add_SelectedIndexChanged({
    $vocal.Enabled=$mode.SelectedIndex -ne 3
    $smoothing.Enabled=$mode.SelectedIndex -ne 3 -and $vocal.SelectedIndex -eq 0
    if($inputBox.Text -and $outputBox.Text -eq $script:suggestedOutput){Set-AudioInput $inputBox.Text}
    $tip.Text=if($mode.SelectedIndex -eq 0){'Balanced keeps source rhythm and backing hooks with voiced harmony. Start with a preview to judge the interpretation.'}elseif($mode.SelectedIndex -eq 1){'Simple reduces the music to a clear lead, bass and restrained chords.'}elseif($mode.SelectedIndex -eq 2){'Detailed transcription captures more notes and may contain extra guesses. Use a preview to compare.'}else{'For a single instrument such as solo piano or guitar. Preserves overlapping notes and chords.'}
})
$vocal.Add_SelectedIndexChanged({
    $smoothing.Enabled=$mode.SelectedIndex -ne 3 -and $vocal.SelectedIndex -eq 0
    if($inputBox.Text -and $outputBox.Text -eq $script:suggestedOutput){Set-AudioInput $inputBox.Text}
    $tip.Text=if($vocal.SelectedIndex -eq 0){'Autotune-style melody keeps the vocal tune as steady MIDI notes, smoothing vibrato and short scoops. Clear note changes remain.'}elseif($vocal.SelectedIndex -eq 1){'Stable vocals favour confident sung pitches and can omit uncertain short notes. The richer backing remains.'}elseif($vocal.SelectedIndex -eq 2){'Detailed vocals include more passing pitch changes and may admit speech-like inflections.'}else{'Omit drops the transcribed vocal melody track, leaving bass, harmony and backing hooks.'}
})
$smoothing.Add_SelectedIndexChanged({
    if($inputBox.Text -and $outputBox.Text -eq $script:suggestedOutput){Set-AudioInput $inputBox.Text}
    $tip.Text=@('Gentle keeps more brief pitch changes while still using held MIDI notes.','Balanced smooths short scoops and vibrato while retaining clear pitch changes.','Firm favours longer holds and can merge short melody details.')[$smoothing.SelectedIndex]
})
function Start-Conversion {
    if($script:job){return}
    try{
        $source=$inputBox.Text.Trim();$destination=$outputBox.Text.Trim()
        if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Choose an existing audio file.'}
        if(-not $destination){throw 'Choose a MIDI output path.'}
        if(Test-Path -LiteralPath $destination){throw 'That MIDI already exists. Choose a different output name.'}
        $python=Join-Path $script:converterRoot '.venv\Scripts\python.exe'
        if(-not(Test-Path -LiteralPath $python)){throw 'Converter runtime is missing. Run Setup-Converter.ps1 first.'}
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$python
        $script:workFolder=Join-Path (Join-Path $script:converterRoot '.jobs') ([Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:workFolder)
        $script:progressFile=Join-Path $script:workFolder 'progress.json'
        $recordingMode=@('balanced','arrange','mix','solo')[$mode.SelectedIndex]
        $vocalPolicy=@('tuned','stable','detailed','omit')[$vocal.SelectedIndex]
        $vocalSmoothing=@('gentle','balanced','firm')[$smoothing.SelectedIndex]
        $seconds=if($preview.Checked){30}else{0}
        $startSeconds=if($preview.Checked){[int]$previewStart.Value}else{0}
        if($preview.Checked){$destination=Join-Path ([IO.Path]::GetDirectoryName($destination)) ([IO.Path]::GetFileNameWithoutExtension($destination)+'-preview-'+$startSeconds+'s.mid');if(Test-Path -LiteralPath $destination){throw 'That preview MIDI already exists. Choose a different output name.'}}
        $info.Arguments='-u "{0}" "{1}" "{2}" --mode {3} --max-seconds {4} --progress-file "{5}" --work-dir "{6}" --start-seconds {7} --vocals {8} --vocal-smoothing {9}' -f (Join-Path $script:converterRoot 'transcribe.py'),$source,$destination,$recordingMode,$seconds,$script:progressFile,$script:workFolder,$startSeconds,$vocalPolicy,$vocalSmoothing
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $script:job=[Diagnostics.Process]::Start($info)
        $script:outputTask=$script:job.StandardOutput.ReadToEndAsync();$script:errorTask=$script:job.StandardError.ReadToEndAsync()
        $script:convertedFile=$destination
        $convert.Enabled=$false;$browse.Enabled=$false;$save.Enabled=$false;$play.Enabled=$false;$cancel.Enabled=$true
        $inputBox.ReadOnly=$true;$outputBox.ReadOnly=$true
        $mode.Enabled=$false;$vocal.Enabled=$false;$smoothing.Enabled=$false;$preview.Enabled=$false;$previewStart.Enabled=$false
        $progress.Style='Continuous';$progress.Value=0;$status.Text='Starting local conversion. Full songs can take several minutes...'
    }catch{Remove-ConversionWork;[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'PowerShell Orchestra','OK','Warning')}
}
$browse.Add_Click({$dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Audio files|*.mp3;*.wav;*.flac;*.ogg';if($dialog.ShowDialog($form) -eq 'OK'){Set-AudioInput $dialog.FileName};$dialog.Dispose()})
$save.Add_Click({$dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.Filter='MIDI file|*.mid';$dialog.FileName=[IO.Path]::GetFileName($outputBox.Text);if($dialog.ShowDialog($form) -eq 'OK'){$outputBox.Text=$dialog.FileName};$dialog.Dispose()})
$convert.Add_Click({Start-Conversion})
$cancel.Add_Click({if($script:job -and -not $script:job.HasExited){$script:job.Kill();$status.Text='Cancelling conversion...'}})
$play.Add_Click({
    $player=Join-Path (Split-Path -Parent $script:converterRoot) 'Play-RushE-Layers.ps1'
    $title=[IO.Path]::GetFileNameWithoutExtension($script:convertedFile)
    $arguments='powershell.exe -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}" -MidiFile "{1}" -SongTitle "{2}"' -f $player,$script:convertedFile,$title
    [void](Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $arguments -WindowStyle Normal)
})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=200
$timer.Add_Tick({
    if($script:job -and $script:progressFile -and (Test-Path -LiteralPath $script:progressFile)){
        try{$state=Get-Content -LiteralPath $script:progressFile -Raw|ConvertFrom-Json;$status.Text=$state.message;$progress.Value=[Math]::Max(0,[Math]::Min(100,[int]$state.percent))}catch{}
    }
    if($script:job -and $script:job.HasExited -and $script:outputTask.IsCompleted -and $script:errorTask.IsCompleted){
        $stdout=$script:outputTask.Result;$stderr=$script:errorTask.Result;$exitCode=$script:job.ExitCode
        $script:job.Dispose();$script:job=$null
        $convert.Enabled=$true;$browse.Enabled=$true;$save.Enabled=$true;$cancel.Enabled=$false;$inputBox.ReadOnly=$false;$outputBox.ReadOnly=$false
        $mode.Enabled=$true;$vocal.Enabled=$mode.SelectedIndex -ne 3;$preview.Enabled=$true;$previewStart.Enabled=$preview.Checked;Remove-ConversionWork
        $smoothing.Enabled=$mode.SelectedIndex -ne 3 -and $vocal.SelectedIndex -eq 0
        $progress.Style='Continuous'
        if($exitCode -eq 0){
            try{$result=$stdout | ConvertFrom-Json;$status.Text=('Converted {0} notes across {1} parts / {2:N1} seconds. Ready to play.' -f $result.notes,$result.tracks,$result.seconds);$play.Enabled=$true;$progress.Value=100
                if($CloseAfterConversion){$form.Close()}
            }catch{$status.Text='Conversion returned an unexpected response.'}
        }else{$status.Text='Conversion did not finish.';[void][Windows.Forms.MessageBox]::Show($form,$stderr,'Conversion result','OK','Information')}
    }
})
$form.Add_FormClosing({if($script:job -and -not $script:job.HasExited){$script:job.Kill();[void]$script:job.WaitForExit(3000)};Remove-ConversionWork;$timer.Stop()})
if($InputFile){Set-AudioInput $InputFile}
if($OutputFile){$outputBox.Text=$OutputFile}
if($AutoConvert){$form.Add_Shown({Start-Conversion})}
if($PreviewPath){
    $form.Show();$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
    $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
    try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
    $form.Close()
}else{$timer.Start();[void]$form.ShowDialog()}
$timer.Dispose();$form.Dispose()
