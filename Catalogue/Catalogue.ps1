#requires -Version 5.1
# Public pages are parsed as data; no downloaded script is executed.
$script:catalogueRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $script:catalogueRoot 'SongMix.ps1')
function Get-CatalogueKey([string]$Text){
    $hash=[Security.Cryptography.SHA256]::Create()
    try{[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Get-CatalogueFileHash([string]$Path){
    $hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
    try{[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$hash.Dispose()}
}
function Save-CatalogueJson([string]$Path,$Value){
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $Path -Force}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Assert-CatalogueUrl([string]$Url){
    $uri=$null
    if(-not [Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -notin @('bitmidi.com','www.bitmidi.com','freemidi.org','www.freemidi.org') -or -not $uri.IsDefaultPort -or $uri.UserInfo){throw 'Unexpected catalogue source URL.'}
    $uri
}
function Get-CatalogueResponse([string]$Url,[Net.CookieContainer]$Cookies,[string]$Referer){
    [void](Assert-CatalogueUrl $Url)
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for($redirect=0;$redirect -lt 5;$redirect++){
        $request=[Net.HttpWebRequest]::Create($Url);$request.UserAgent='PowerShell-Orchestra/1.0 (personal MIDI catalogue)'
        $request.Timeout=15000;$request.ReadWriteTimeout=15000;$request.AllowAutoRedirect=$false
        $request.AutomaticDecompression=[Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        if($Cookies){$request.CookieContainer=$Cookies};if($Referer){$request.Referer=$Referer}
        $response=$request.GetResponse()
        try{
            if([int]$response.StatusCode -in @(301,302,303,307,308)){$Url=([Uri]::new([Uri]$Url,$response.Headers['Location'])).AbsoluteUri;[void](Assert-CatalogueUrl $Url);continue}
            $stream=$response.GetResponseStream();$memory=[IO.MemoryStream]::new();$buffer=New-Object byte[] 16384
            try{while(($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0){if($memory.Length+$read -gt 4194304){throw 'Source response exceeds the 4 MB catalogue limit.'};$memory.Write($buffer,0,$read)};return ,$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
        }finally{$response.Dispose()}
    }
    throw 'The source redirected too many times.'
}
function Get-CatalogueText([string]$Url,[Net.CookieContainer]$Cookies){[Text.Encoding]::UTF8.GetString((Get-CatalogueResponse $Url $Cookies))}
function ConvertFrom-CatalogueText([string]$Html){[Net.WebUtility]::HtmlDecode(([regex]::Replace($Html,'<[^>]+>',' '))).Trim() -replace '\s+',' '}
function Get-CatalogueAttribute([string]$Html,[string]$Name){
    $pattern='(?is)\b'+[regex]::Escape($Name)+'\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))'
    $match=[regex]::Match($Html,$pattern)
    foreach($index in 1..3){if($match.Groups[$index].Success){return [Net.WebUtility]::HtmlDecode($match.Groups[$index].Value)}}
    return ''
}
function ConvertFrom-CatalogueResults([string]$Html,[string]$Provider){
    $items=New-Object Collections.Generic.List[object];$seen=@{}
    if($Provider -eq 'BitMidi'){
        $json=[regex]::Match($Html,'(?s)window\.initStore\s*=\s*(\{[^\r\n]+\})').Groups[1].Value
        if(-not $json){throw 'BitMidi changed its results page. Use Open Source or try FreeMIDI.'}
        $data=$json|ConvertFrom-Json
        foreach($property in $data.data.midis.PSObject.Properties){
            $entry=$property.Value
            if($entry.url -notmatch '^/[a-zA-Z0-9_-]+$' -or $entry.downloadUrl -notmatch '^/uploads/\d+\.mid$'){continue}
            $items.Add([PSCustomObject]@{Provider='BitMidi';Title=($entry.name -replace '(?i)\.midi?$','');Artist='';SourceUrl=('https://bitmidi.com'+$entry.url);DownloadUrl=('https://bitmidi.com'+$entry.downloadUrl)})
        }
    }else{
        foreach($card in [regex]::Matches($Html,'(?is)<h5\b[^>]*>(?<title>.*?)</h5>\s*<div\b[^>]*class\s*=\s*["'']?card-text["'']?[^>]*>(?<artist>.*?)</div>')){
            $href=Get-CatalogueAttribute $card.Groups['title'].Value 'href'
            if($href -notmatch '^/?download[23]?-(\d+)-[a-zA-Z0-9_-]+$'){continue};$id=$Matches[1]
            if($seen.ContainsKey($id)){continue};$seen[$id]=$true
            $items.Add([PSCustomObject]@{Provider='FreeMIDI';Title=(ConvertFrom-CatalogueText $card.Groups['title'].Value);Artist=(ConvertFrom-CatalogueText $card.Groups['artist'].Value);SourceUrl=('https://freemidi.org/'+$href.TrimStart('/'));DownloadUrl=('https://freemidi.org/getter-'+$id)})
        }
        if($items.Count -eq 0 -and $Html -notmatch '(?i)(no results|no songs|not found|<h2>\s*(Songs|Artists)|Search Results)'){throw 'FreeMIDI returned an unexpected page. Try BitMidi or Open Source.'}
    }
    $items.ToArray()
}
function Search-OrchestraCatalogue([string]$Query,[string]$Provider='All sources',[int]$Page=0){
    $Query=$Query.Trim();if($Query.Length -lt 2 -or $Query.Length -gt 160){throw 'Enter between 2 and 160 characters to search.'}
    if($Page -lt 0 -or $Page -gt 99){throw 'Invalid catalogue page.'}
    $folder=Join-Path $PSScriptRoot 'SearchCache';[void][IO.Directory]::CreateDirectory($folder)
    $results=New-Object Collections.Generic.List[object];$warnings=New-Object Collections.Generic.List[string];$hasMore=$false
    $providers=if($Provider -eq 'All sources'){@('FreeMIDI','BitMidi')}else{@($Provider)}
    foreach($source in $providers){
        if($source -notin @('BitMidi','FreeMIDI')){throw 'Unknown catalogue source.'}
        # FreeMIDI returns its matching songs together; do not repeat them on later pages.
        if($source -eq 'FreeMIDI' -and $Page -gt 0){continue}
        $cache=Join-Path $folder ((Get-CatalogueKey ($source+'|'+$Query.ToLowerInvariant()+'|'+$Page))+'.json')
        $saved=$null;if(Test-Path -LiteralPath $cache){try{$saved=Get-Content -LiteralPath $cache -Raw|ConvertFrom-Json}catch{}}
        try{
            if($saved -and (Get-Item -LiteralPath $cache).LastWriteTime -gt (Get-Date).AddMinutes(-10)){$payload=$saved}
            else{
                $url=if($source -eq 'BitMidi'){'https://bitmidi.com/search?q='+[Uri]::EscapeDataString($Query)+'&page='+$Page}else{'https://freemidi.org/search?q='+[Uri]::EscapeDataString($Query)}
                $html=Get-CatalogueText $url
                $items=@(ConvertFrom-CatalogueResults $html $source)
                $more=$source -eq 'BitMidi' -and $html -match ('[?&](?:amp;)?page='+($Page+1)+'(?:["''&]|$)')
                $payload=[PSCustomObject]@{Items=$items;HasMore=$more};Save-CatalogueJson $cache $payload
            }
        }catch{
            if($saved){$payload=$saved;$warnings.Add($source+' is unavailable; showing cached results.')}
            else{$warnings.Add($source+' is unavailable. Try its website or search again later.');continue}
        }
        foreach($item in @($payload.Items)){$results.Add($item)};$hasMore=$hasMore -or $payload.HasMore
    }
    [PSCustomObject]@{Items=$results.ToArray();Warnings=$warnings.ToArray();HasMore=$hasMore;Page=$Page;Query=$Query}
}
function Import-CatalogueEngine {
    if('LayeredMusic.Midi' -as [type]){return}
    [void][IO.Directory]::CreateDirectory((Join-Path $script:catalogueRoot 'Engine'))
    $source=Join-Path $script:catalogueRoot 'LayeredAudio.cs'
    # Use the player's byte-based cache key, including the source's line endings.
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($hasher.ComputeHash([IO.File]::ReadAllBytes($source))).Replace('-','').Substring(0,16)}finally{$hasher.Dispose()}
    $assembly=Join-Path $script:catalogueRoot ('Engine\LayeredAudio.'+$key+'.dll')
    if(-not(Test-Path -LiteralPath $assembly)){Add-Type -Path $source -OutputAssembly $assembly}
    Add-Type -Path $assembly
}
function Get-OrchestraCatalogueMidi($Item,[switch]$RenderPreview){
    [void](Assert-CatalogueUrl $Item.SourceUrl);[void](Assert-CatalogueUrl $Item.DownloadUrl)
    $source=[Uri]$Item.SourceUrl;$download=[Uri]$Item.DownloadUrl
    if(($Item.Provider -eq 'BitMidi' -and ($source.Host -ne 'bitmidi.com' -or $download.Host -ne 'bitmidi.com' -or $download.AbsolutePath -notmatch '^/uploads/\d+\.mid$')) -or
       ($Item.Provider -eq 'FreeMIDI' -and ($source.Host -ne 'freemidi.org' -or $download.Host -ne 'freemidi.org' -or $download.AbsolutePath -notmatch '^/getter-\d+$')) -or
       $Item.Provider -notin @('FreeMIDI','BitMidi')){throw 'Unexpected MIDI download address.'}
    $folder=Join-Path $PSScriptRoot 'MidiCache';[void][IO.Directory]::CreateDirectory($folder)
    $key=Get-CatalogueKey $Item.SourceUrl;$path=Join-Path $folder ($key+'.mid')
    if(-not(Test-Path -LiteralPath $path)){
        $cookies=[Net.CookieContainer]::new()
        if($Item.Provider -eq 'FreeMIDI'){$null=Get-CatalogueText $Item.SourceUrl $cookies}
        $bytes=Get-CatalogueResponse $Item.DownloadUrl $cookies $Item.SourceUrl
        if($bytes.Length -lt 14 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -ne 'MThd'){throw 'The source did not return a MIDI file. Open Source to check its download page.'}
        $temporary=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
        try{[IO.File]::WriteAllBytes($temporary,$bytes);Import-CatalogueEngine;$check=[LayeredMusic.Midi]::Read($temporary,1,0,0,8)
            if($check.Notes.Count -eq 0){throw 'This MIDI has no playable pitched notes.'}
            if($check.Notes.Count -gt 250000 -or $check.DurationMs -gt 3600000){throw 'This MIDI exceeds the catalogue preview size limit.'}
            Move-Item -LiteralPath $temporary -Destination $path -Force
        }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    }
    Import-CatalogueEngine;$score=[LayeredMusic.Midi]::Read($path,1,0,0,8)
    $mix=Get-OrchestraSongMix $script:catalogueRoot $path
    $mixSignature=[string]$mix.Master+'|'+((@($mix.Parts.Keys|Sort-Object|ForEach-Object {$_+'='+$mix.Parts[$_]})) -join ';')
    $engineKey=(Get-CatalogueFileHash (Join-Path $script:catalogueRoot 'LayeredAudio.cs')).Substring(0,16)
    $wave=Join-Path $folder ($key+'.'+$engineKey+'.'+(Get-CatalogueKey $mixSignature).Substring(0,16)+'.wav')
    if($RenderPreview -and -not(Test-Path -LiteralPath $wave)){$preview=[LayeredMusic.Midi]::Read($path,1,0,30,8);Set-OrchestraScoreMix $preview $mix;[LayeredMusic.Synth]::Render($preview,$wave,(.25*$mix.Master/100.0))}
    [PSCustomObject]@{Midi=$path;Wave=$wave;Duration=[Math]::Round($score.DurationMs/1000,1);Notes=$score.Notes.Count;Parts=@($score.Notes.Part|Sort-Object -Unique).Count;Sha256=(Get-CatalogueFileHash $path);Item=$Item}
}
function Add-OrchestraCatalogueSong($Entry,[string]$Root=$script:catalogueRoot){
    $cacheRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'MidiCache'))
    $cache=[IO.Path]::GetFullPath($Entry.Midi)
    if([IO.Path]::GetDirectoryName($cache) -ne $cacheRoot -or [IO.Path]::GetFileName($cache) -notmatch '^[a-f0-9]{64}\.mid$'){throw 'Only a validated catalogue MIDI can be added.'}
    $hash=Get-CatalogueFileHash $cache
    $folders=@($Root,(Join-Path $Root 'Library'),(Join-Path $Root 'Converter\Converted'),(Join-Path $Root 'TetriPS'),(Join-Path $Root 'PSGTA-IV'))
    foreach($folder in $folders){if(Test-Path -LiteralPath $folder){foreach($file in Get-ChildItem -LiteralPath $folder -File|Where-Object {$_.Extension -in @('.mid','.midi')}){
        if((Get-CatalogueFileHash $file.FullName) -eq $hash){return [PSCustomObject]@{Midi=$file.FullName;AlreadyAdded=$true;Title=$file.BaseName}}
    }}}
    $name=if($Entry.Item.Artist){$Entry.Item.Artist+' - '+$Entry.Item.Title}else{$Entry.Item.Title}
    $name=($name -replace '[\x00-\x1f<>:"/\\|?*]',' ').Trim().TrimEnd('.')
    if($name.Length -gt 100){$name=$name.Substring(0,100).Trim().TrimEnd('.')}
    if(-not $name -or $name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){$name='Song '+$name}
    $folder=Join-Path $Root 'Library';[void][IO.Directory]::CreateDirectory($folder)
    $path=Join-Path $folder ($name+'.mid');$number=2
    while(Test-Path -LiteralPath $path){$path=Join-Path $folder ($name+' ('+$number+').mid');$number++}
    $writer=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    try{$bytes=[IO.File]::ReadAllBytes($cache);$writer.Write($bytes,0,$bytes.Length)}finally{$writer.Dispose()}
    Save-CatalogueJson ($path+'.source.json') @{Provider=$Entry.Item.Provider;SourceUrl=$Entry.Item.SourceUrl;Title=$Entry.Item.Title;Artist=$Entry.Item.Artist;Sha256=$hash;AddedUtc=[DateTime]::UtcNow.ToString('o');Duration=$Entry.Duration;Notes=$Entry.Notes;Parts=$Entry.Parts}
    [PSCustomObject]@{Midi=$path;AlreadyAdded=$false;Title=[IO.Path]::GetFileNameWithoutExtension($path)}
}
