using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using System.Text.Json;
namespace PowerShellOrchestra;
public partial class MainWindow
{
    TextBox audioInput,midiOutput;ComboBox conversionMode,vocalMode,smoothingMode;CheckBox convertPreview;NumberBox previewStart;Button convertButton,cancelConversion,playConversion;ProgressBar conversionProgress;TextBlock conversionStatus;
    CancellationTokenSource conversionCancellation;string convertedFile;bool customOutput;Button audioBrowse,midiSave;
    Grid BuildConverter()
    {
        var panel=new StackPanel{Spacing=18,MaxWidth=900,Margin=new Thickness(30,24,30,30),HorizontalAlignment=HorizontalAlignment.Stretch};panel.Children.Add(Heading("Audio to MIDI"));panel.Children.Add(Text("Turn a recording into an arrangement for PowerShell Orchestra. Processing stays on this PC."));
        audioInput=new TextBox{Header="Audio file",PlaceholderText="Choose an MP3, WAV, FLAC or OGG"};var browse=Button("Browse…",async()=>{try{var path=await PickFile(".mp3",".wav",".flac",".ogg");if(path!=null){audioInput.Text=path;SuggestOutput();}}catch(Exception e){await Error(e);}},false,"\uE8B7");
        midiOutput=new TextBox{Header="MIDI output"};var save=Button("Save as…",async()=>{try{var path=await SaveFile(Path.GetFileNameWithoutExtension(midiOutput.Text),".mid");if(path!=null){midiOutput.Text=path;customOutput=true;}}catch(Exception e){await Error(e);}},false,"\uE74E");
        audioBrowse=browse;midiSave=save;
        panel.Children.Add(BuildSpotifyFinder());panel.Children.Add(Card(Stack(audioInput,browse,midiOutput,save)));
        conversionMode=Choices("Balanced arrangement","Simple arrangement","Detailed transcription","Isolated instrument");vocalMode=Choices("Autotune-style melody","Stable sung notes","Detailed vocal pitch","Omit vocal lead");smoothingMode=Choices("Gentle","Balanced","Firm");smoothingMode.SelectedIndex=1;
        panel.Children.Add(Card(Stack(Setting("Conversion style","Balanced keeps source rhythm, hooks and restrained harmony.",conversionMode),Setting("Vocal lead","Turn the sung melody into held notes.",vocalMode),Setting("Vocal smoothing","Gentle keeps more brief melody changes.",smoothingMode))));
        convertPreview=new CheckBox{Content="Convert a 30-second preview first"};previewStart=new NumberBox{Header="Start at (seconds)",Minimum=0,Maximum=86400,Value=0,Width=180,SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Compact,IsEnabled=false};convertPreview.Checked+=(s,e)=>{previewStart.IsEnabled=true;SuggestOutput();};convertPreview.Unchecked+=(s,e)=>{previewStart.IsEnabled=false;SuggestOutput();};previewStart.ValueChanged+=(s,e)=>SuggestOutput();
        panel.Children.Add(Card(Stack(convertPreview,previewStart,Text("A preview helps judge the interpretation before converting a full song. Original audio is preserved."))));
        convertButton=Button("Convert",async()=>await ConvertAudio(),true,"\uE8AB");cancelConversion=Button("Cancel conversion",()=>conversionCancellation?.Cancel());cancelConversion.IsEnabled=false;playConversion=Button("Play MIDI",()=>Backend.LaunchSong(convertedFile,Path.GetFileNameWithoutExtension(convertedFile)),false,"\uE768");playConversion.IsEnabled=false;
        panel.Children.Add(new ResponsivePanel{Children={convertButton,cancelConversion,playConversion}});conversionProgress=new ProgressBar{Minimum=0,Maximum=100};conversionStatus=Text("Ready. Audio and generated files stay on this PC.");panel.Children.Add(conversionProgress);panel.Children.Add(conversionStatus);
        void Modes(){vocalMode.IsEnabled=conversionMode.SelectedIndex!=3;smoothingMode.IsEnabled=conversionMode.SelectedIndex!=3&&vocalMode.SelectedIndex==0;SuggestOutput();}
        conversionMode.SelectionChanged+=(s,e)=>Modes();vocalMode.SelectionChanged+=(s,e)=>Modes();smoothingMode.SelectionChanged+=(s,e)=>SuggestOutput();audioInput.LostFocus+=(s,e)=>SuggestOutput();midiOutput.TextChanged+=(s,e)=>{if(!suggestingOutput)customOutput=true;};
        return CenteredPage(panel);
    }
    bool suggestingOutput;
    void SuggestOutput()
    {
        if(customOutput||conversionCancellation!=null||string.IsNullOrWhiteSpace(audioInput.Text)||conversionMode==null)return;
        var reference=AudioSpotifyReference();
        string name=(reference==null?Path.GetFileNameWithoutExtension(audioInput.Text):SpotifyService.FileTitle(reference))+" - "+new[]{"Balanced Arrangement","Simple Arrangement","Orchestra","Instrument"}[conversionMode.SelectedIndex];
        if(conversionMode.SelectedIndex!=3){name+=vocalMode.SelectedIndex switch{1=>" - Filtered Vocals",2=>" - Detailed Vocals",3=>" - No Vocal Lead",_=>smoothingMode.SelectedIndex switch{0=>" - Gentle Vocals",2=>" - Firm Vocals",_=>""}};}
        if(convertPreview?.IsChecked==true)name+="-preview-"+(int)previewStart.Value+"s";
        string folder=Path.Combine(Backend.Root,"Converter","Converted");string path=Path.Combine(folder,name+".mid");int number=2;while(File.Exists(path))path=Path.Combine(folder,name+" ("+(number++)+").mid");suggestingOutput=true;midiOutput.Text=path;suggestingOutput=false;
    }
    async Task ConvertAudio()
    {
        if(conversionCancellation!=null)return;
        string source=audioInput.Text.Trim(),output=midiOutput.Text.Trim(),python=Path.Combine(Backend.Root,@"Converter\.venv\Scripts\python.exe");
        if(!File.Exists(source)){conversionStatus.Text="Choose an existing audio file.";return;}if(File.Exists(output)){conversionStatus.Text="That MIDI already exists. Choose another output name.";return;}if(string.IsNullOrWhiteSpace(output)){conversionStatus.Text="Choose a MIDI output path.";return;}if(!File.Exists(python)){conversionStatus.Text="The converter runtime is missing. Run Setup-Converter.ps1 first.";return;}
        string folder=Path.Combine(Backend.Root,"Converter",".jobs",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);string progress=Path.Combine(folder,"progress.json");
        conversionCancellation=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);convertButton.IsEnabled=false;cancelConversion.IsEnabled=true;playConversion.IsEnabled=false;conversionProgress.Value=0;conversionStatus.Text="Starting local conversion…";
        audioInput.IsReadOnly=midiOutput.IsReadOnly=true;conversionMode.IsEnabled=vocalMode.IsEnabled=smoothingMode.IsEnabled=convertPreview.IsEnabled=previewStart.IsEnabled=false;
        audioBrowse.IsEnabled=midiSave.IsEnabled=false;UpdateSpotifyActions();
        var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(250)};timer.Tick+=(s,e)=>{try{if(File.Exists(progress)){using var stream=new FileStream(progress,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);using var reader=new StreamReader(stream);using var data=JsonDocument.Parse(reader.ReadToEnd());conversionStatus.Text=data.RootElement.GetProperty("message").GetString();conversionProgress.Value=Math.Clamp(data.RootElement.GetProperty("percent").GetDouble(),0,100);}}catch{}};timer.Start();
        try{
            var info=new ProcessStartInfo(python){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
            string[] args={"-u",Path.Combine(Backend.Root,"Converter","transcribe.py"),source,output,"--mode",new[]{"balanced","arrange","mix","solo"}[conversionMode.SelectedIndex],"--vocals",new[]{"tuned","stable","detailed","omit"}[vocalMode.SelectedIndex],"--vocal-smoothing",new[]{"gentle","balanced","firm"}[smoothingMode.SelectedIndex],"--max-seconds",convertPreview.IsChecked==true?"30":"0","--start-seconds",convertPreview.IsChecked==true?((int)previewStart.Value).ToString():"0","--progress-file",progress,"--work-dir",folder};foreach(string arg in args)info.ArgumentList.Add(arg);
            using var process=Process.Start(info);var stderr=process.StandardError.ReadToEndAsync();var stdout=process.StandardOutput.ReadToEndAsync();using var registration=conversionCancellation.Token.Register(()=>{try{if(!process.HasExited)process.Kill(true);}catch{}});await process.WaitForExitAsync(conversionCancellation.Token);string error=await stderr,result=await stdout;if(process.ExitCode!=0)throw new InvalidOperationException(error.Trim());
            using var json=JsonDocument.Parse(result);convertedFile=output;playConversion.IsEnabled=true;conversionProgress.Value=100;conversionStatus.Text=$"Converted {json.RootElement.GetProperty("notes").GetInt32():N0} notes across {json.RootElement.GetProperty("tracks").GetInt32()} parts. MIDI saved and ready to play.";
            await RefreshSongs();
        }catch(OperationCanceledException){conversionStatus.Text="Conversion cancelled.";}catch(Exception e){conversionStatus.Text=e.Message;Backend.Log(e.ToString());}
        finally{timer.Stop();conversionCancellation.Dispose();conversionCancellation=null;convertButton.IsEnabled=true;cancelConversion.IsEnabled=false;audioInput.IsReadOnly=midiOutput.IsReadOnly=false;audioBrowse.IsEnabled=midiSave.IsEnabled=true;conversionMode.IsEnabled=convertPreview.IsEnabled=true;vocalMode.IsEnabled=conversionMode.SelectedIndex!=3;smoothingMode.IsEnabled=vocalMode.IsEnabled&&vocalMode.SelectedIndex==0;previewStart.IsEnabled=convertPreview.IsChecked==true;UpdateSpotifyActions();try{Directory.Delete(folder,true);}catch{}}
    }
}
