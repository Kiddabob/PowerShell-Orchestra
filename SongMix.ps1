# Saved mixes identify the MIDI contents and its track/port/channel parts.
function Get-OrchestraMidiHash([string]$Path){
    $hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
    try{[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$hash.Dispose()}
}
function Import-OrchestraMixEngine([string]$Root){
    if('LayeredMusic.Midi' -as [type]){return}
    $key=(Get-OrchestraMidiHash (Join-Path $Root 'LayeredAudio.cs')).Substring(0,16).ToUpperInvariant()
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'Engine'))
    $assembly=Join-Path $Root ('Engine\LayeredAudio.'+$key+'.dll')
    if(-not(Test-Path -LiteralPath $assembly)){Add-Type -Path (Join-Path $Root 'LayeredAudio.cs') -OutputAssembly $assembly}
    Add-Type -Path $assembly
}
function Get-OrchestraSongMix([string]$Root,[string]$MidiFile){
    $key=Get-OrchestraMidiHash $MidiFile
    $result=@{Master=100;Parts=@{};MidiHash=$key}
    $path=Join-Path $Root ('Mixes\'+$key+'.json')
    if(Test-Path -LiteralPath $path){try{
        $saved=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        if($saved.MidiHash -eq $key){
            $result.Master=[int][Math]::Max(0,[Math]::Min(100,[double]$saved.Master))
            foreach($part in $saved.Parts.PSObject.Properties){if($part.Name -match '^\d+:\d+:\d+$'){$result.Parts[$part.Name]=[int][Math]::Max(0,[Math]::Min(100,[double]$part.Value))}}
        }
    }catch{}}
    return $result
}
function Set-OrchestraScoreMix($Score,$Settings){
    $Score.PartGains.Clear()
    foreach($key in $Settings.Parts.Keys){$Score.PartGains[$key]=[Math]::Max(0.0,[Math]::Min(1.0,[double]$Settings.Parts[$key]/100.0))}
}
function Save-OrchestraSongMix([string]$Root,[string]$MidiFile,$Settings){
    $key=Get-OrchestraMidiHash $MidiFile
    $master=[double]$Settings.Master
    if([double]::IsNaN($master) -or [double]::IsInfinity($master) -or $master -lt 0 -or $master -gt 100){throw 'Master volume must be between 0 and 100 percent.'}
    $parts=@{}
    foreach($part in $Settings.Parts.Keys){$value=[double]$Settings.Parts[$part];if($part -notmatch '^\d+:\d+:\d+$' -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 100){throw 'Part volume must be between 0 and 100 percent.'};$parts[$part]=[int]$value}
    $folder=Join-Path $Root 'Mixes';[void][IO.Directory]::CreateDirectory($folder)
    $path=Join-Path $folder ($key+'.json');$temporary=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temporary,(@{MidiHash=$key;Master=[int]$master;Parts=$parts}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $path -Force}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
