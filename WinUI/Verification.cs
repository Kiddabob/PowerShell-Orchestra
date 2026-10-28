using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Text.Json;
using Windows.Graphics.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
namespace PowerShellOrchestra;
public partial class MainWindow
{
    async Task Capture(string path){var bitmap=new RenderTargetBitmap();await bitmap.RenderAsync(Root);var pixels=await bitmap.GetPixelsAsync();using var stream=File.Open(path,FileMode.Create,FileAccess.ReadWrite);var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId,stream.AsRandomAccessStream());encoder.SetPixelData(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,(uint)bitmap.PixelWidth,(uint)bitmap.PixelHeight,96,96,pixels.ToArray());await encoder.FlushAsync();}
    async Task VerifyNativeApp()
    {
        var report=new Dictionary<string,object>();string folder=Path.Combine(Backend.Root,"WinUI","Verification");Directory.CreateDirectory(folder);var original=appearance;
        try{
            void Check(string name,bool value){report[name]=value;if(!value)throw new InvalidOperationException("Verification failed: "+name);}
            report["Framework"]="WinUI 3 / Windows App SDK";report["WindowVisible"]=appWindow.IsVisible;report["WindowBounds"]=appWindow.Size.ToString();
            Check("FourTabs",Tabs.TabItems.Count==4);Check("LibraryLoaded",songs.Count>0 && songCards.Children.Count==songs.Count);report["Songs"]=songs.Count;report["ScreenChoices"]=screenChoice.Items.Count-1;Check("ScreenSelectionAvailable",screenChoice.Items.Count>1);
            appearance=new AppearanceSettings{Theme="Light",Material="Solid",ReduceMotion="On"};SyncAppearanceControls();ApplyAppearance(false);await Task.Delay(350);Check("LightTheme",Root.ActualTheme==ElementTheme.Light);await Capture(Path.Combine(folder,"library-light.png"));
            Tabs.SelectedIndex=3;await Task.Delay(350);await Capture(Path.Combine(folder,"appearance-light.png"));
            var appearanceScroll=(ScrollViewer)((Grid)pages[3]).Children[0];var appearancePanel=(FrameworkElement)((Grid)appearanceScroll.Content).Children[0];var ap=appearancePanel.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point());report["AppearanceLayout"]=new{X=ap.X,Width=appearancePanel.ActualWidth,Viewport=Root.ActualWidth};Check("AppearanceWithinWindow",ap.X>=0&&ap.X+appearancePanel.ActualWidth<=Root.ActualWidth+1);
            appearance=new AppearanceSettings{Theme="Dark",Material="Solid",WindowsAccent=false,Accent="#D50000",ReduceMotion="On"};SyncAppearanceControls();ApplyAppearance(false);await Task.Delay(350);Check("DarkTheme",Root.ActualTheme==ElementTheme.Dark);Check("CustomAccent",Root.Resources["SystemAccentColor"] is Windows.UI.Color color && color.R==213 && color.G==0);await Capture(Path.Combine(folder,"appearance-dark.png"));
            appearance.Material="Mica";ApplyAppearance(false);Check("MicaSelected",SystemBackdrop is Microsoft.UI.Xaml.Media.MicaBackdrop);appearance.Material="Acrylic";ApplyAppearance(false);Check("AcrylicSelected",SystemBackdrop is TunableAcrylicBackdrop);
            await Task.Delay(150);Check("AcrylicControllerConnected",acrylicBackdrop?.Connected==true);
            double defaultTint=acrylicBackdrop.ActualTintOpacity,defaultLuminosity=acrylicBackdrop.ActualLuminosityOpacity;
            appearance.AcrylicCustom=true;appearance.AcrylicThemeTint=false;appearance.AcrylicTintColor="#80C0FF";appearance.AcrylicDarkness=50;appearance.AcrylicTintOpacity=34;appearance.AcrylicLuminosityOpacity=72;appearance.AcrylicPanelOpacity=55;appearance.AcrylicThemeFallback=false;appearance.AcrylicFallbackColor="#223344";SyncAppearanceControls();ApplyAppearance(false);
            Check("AcrylicTintOpacityApplied",Math.Abs(acrylicBackdrop.ActualTintOpacity-.34)<.00001);Check("AcrylicLuminosityApplied",Math.Abs(acrylicBackdrop.ActualLuminosityOpacity-.72)<.00001);Check("AcrylicDarknessApplied",acrylicBackdrop.ActualTint.R==64&&acrylicBackdrop.ActualTint.G==96&&acrylicBackdrop.ActualTint.B==128);Check("AcrylicFallbackApplied",acrylicBackdrop.ActualFallback.R==34&&acrylicBackdrop.ActualFallback.G==51);
            appearance.AcrylicKind="Thin";SyncAppearanceControls();ApplyAppearance(false);Check("AcrylicThinVariantApplied",acrylicBackdrop.ActualKind=="Thin");appearance.AcrylicKind="Base";SyncAppearanceControls();ApplyAppearance(false);
            var roundtrip=JsonSerializer.Deserialize<AppearanceSettings>(JsonSerializer.Serialize(appearance,Backend.Json),Backend.Json);Check("AcrylicSettingsPersistable",roundtrip.AcrylicCustom&&roundtrip.AcrylicPanelOpacity==55&&roundtrip.AcrylicTintOpacity==34);
            report["AcrylicControllerState"]=acrylicBackdrop.State;
            Root.Background=new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Black);await Task.Delay(750);await Capture(Path.Combine(folder,"acrylic-settings.png"));
            report["AcrylicSliderPosition"]=acrylicDarkness.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point()).Y;
            appearance.AcrylicCustom=false;SyncAppearanceControls();ApplyAppearance(false);Check("AcrylicDefaultsRestored",acrylicBackdrop.UsingWindowsDefaults&&Math.Abs(acrylicBackdrop.ActualTintOpacity-defaultTint)<.00001&&Math.Abs(acrylicBackdrop.ActualLuminosityOpacity-defaultLuminosity)<.00001);
            appearance.AcrylicCustom=true;appearance.AcrylicThemeTint=appearance.AcrylicThemeFallback=true;appearance.AcrylicDarkness=0;appearance.Theme="Light";SyncAppearanceControls();ApplyAppearance(false);await Task.Delay(150);var lightFallback=acrylicBackdrop.ActualFallback;
            appearance.Theme="Dark";SyncAppearanceControls();ApplyAppearance(false);await Task.Delay(150);var darkFallback=acrylicBackdrop.ActualFallback;Check("AcrylicFollowsTheme",lightFallback.R!=darkFallback.R||lightFallback.G!=darkFallback.G||lightFallback.B!=darkFallback.B);
            appearance.Material="Solid";ApplyAppearance(false);Tabs.SelectedIndex=2;await Task.Delay(350);await Capture(Path.Combine(folder,"converter-dark.png"));
            var converterScroll=(ScrollViewer)((Grid)pages[2]).Children[0];var converterPanel=(FrameworkElement)((Grid)converterScroll.Content).Children[0];var cp=converterPanel.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point());report["ConverterLayout"]=new{X=cp.X,Width=converterPanel.ActualWidth,Viewport=Root.ActualWidth};Check("ConverterWithinWindow",cp.X>=0&&cp.X+converterPanel.ActualWidth<=Root.ActualWidth+1);
            Tabs.SelectedIndex=1;await Task.Delay(150);onlineQuery.Text="sandstorm";await SearchOnline(0);Check("CatalogueSearch",onlineList.Items.Count>0);onlineList.SelectedIndex=0;await PreviewOnline();Check("CataloguePreview",previewAudio!=null);StopPreview();await Capture(Path.Combine(folder,"catalogue-dark.png"));
            report["CatalogueResults"]=onlineList.Items.Count;
            Check("ConverterReady",convertButton.IsEnabled && conversionMode.Items.Count==4 && vocalMode.Items.Count==4 && smoothingMode.Items.Count==3);
            if(Environment.GetCommandLineArgs().Contains("--verify-spotify")){
                Tabs.SelectedIndex=2;spotifyFinder.IsExpanded=true;await Task.Delay(500);
                string track="https://open.spotify.com/track/3IpJfjiEiIZ8b1GfAVmdUY";
                Check("SpotifyUrlValidation",SpotifyService.TrackUrl(track+"?si=test")==track && SpotifyService.TrackUrl("https://open.spotify.com.evil.test/track/3IpJfjiEiIZ8b1GfAVmdUY")==null);
                spotifyQuery.Text=track;await SearchSpotify();await Task.Delay(3000);
                Check("SpotifyBrowserInitialized",spotifyBrowser?.CoreWebView2!=null);
                Check("SpotifyMetadata",spotifyTrack==track && spotifyTitle.Text.Contains("Sandstorm",StringComparison.OrdinalIgnoreCase));
                spotifyArtist.Text="Darude";AssociateSpotifyAudio(@"C:\test\song.mp3");Check("SpotifyOutputNaming",Path.GetFileName(midiOutput.Text).StartsWith("Darude - Sandstorm"));
                audioInput.Text=@"C:\test\other.mp3";SuggestOutput();Check("SpotifyAssociationScoped",Path.GetFileName(midiOutput.Text).StartsWith("other -"));
                await FindSpotifyMidi();Check("SpotifyMidiHandoff",Tabs.SelectedIndex==1&&onlineQuery.Text.Contains("Sandstorm")&&onlineList.Items.Count>0);
                audioInput.Text="";midiOutput.Text="";customOutput=false;spotifyFinder.IsExpanded=false;
            }
            report["PageWidths"]=pages.Select(p=>p.ActualWidth).ToArray();
            report["RootWidth"]=Root.ActualWidth;
            report["PagePositions"]=pages.Select(p=>p.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point()).X).ToArray();
            foreach(int index in new[]{2,3}){var scroll=(ScrollViewer)((Grid)pages[index]).Children[0];var panel=(FrameworkElement)scroll.Content;report["Layout"+index]=new{Viewport=scroll.ViewportWidth,Extent=scroll.ExtentWidth,ScrollWidth=scroll.ActualWidth,ContentWidth=panel.ActualWidth,ContentX=panel.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point()).X,Desired=panel.DesiredSize.Width,ScrollX=scroll.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point()).X};}
            if(Environment.GetCommandLineArgs().Contains("--verify-converter")){
                string source=Path.Combine(folder,"converter-input.wav"),output=Path.Combine(folder,"converter-check.mid");
                if(File.Exists(output))File.Delete(output);
                audioInput.Text=source;customOutput=true;midiOutput.Text=output;smoothingMode.SelectedIndex=0;Tabs.SelectedIndex=2;
                await ConvertAudio();Check("ConvertedAudio",File.Exists(output)&&playConversion.IsEnabled);report["ConversionStatus"]=conversionStatus.Text;
                var score=LayeredMusic.Midi.Read(output,1,0,0);report["ConvertedNotes"]=score.Notes.Count;report["ConvertedDuration"]=score.DurationMs/1000;File.Delete(output);
                audioInput.Text="";midiOutput.Text="";customOutput=false;smoothingMode.SelectedIndex=1;playConversion.IsEnabled=false;
            }
            // Inspect persisted mixer settings without changing the user's mix.
            var mix=await Backend.Call<Mix>(new{Action="Mix",songs[0].Id},lifetime.Token);Check("MixerAvailable",mix.Parts.Count>0);
            var originalSize=appWindow.Size;double scale=Root.XamlRoot.RasterizationScale;
            appWindow.Resize(new Windows.Graphics.SizeInt32((int)(760*scale),(int)(760*scale)));await Task.Delay(300);
            Tabs.SelectedIndex=3;await Task.Delay(250);await Capture(Path.Combine(folder,"appearance-narrow.png"));
            var narrowPanel=(FrameworkElement)((Grid)appearanceScroll.Content).Children[0];var narrowPoint=narrowPanel.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point());Check("NarrowAppearanceFits",narrowPoint.X>=0&&narrowPoint.X+narrowPanel.ActualWidth<=Root.ActualWidth+1);
            Tabs.SelectedIndex=2;await Task.Delay(250);await Capture(Path.Combine(folder,"converter-narrow.png"));
            var narrowConverter=(FrameworkElement)((Grid)converterScroll.Content).Children[0];var narrowCP=narrowConverter.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point());Check("NarrowConverterFits",narrowCP.X>=0&&narrowCP.X+narrowConverter.ActualWidth<=Root.ActualWidth+1);
            appWindow.Resize(originalSize);await Task.Delay(250);
            report["Ok"]=true;
        }catch(Exception e){report["Ok"]=false;report["Error"]=e.ToString();Backend.Log(e.ToString());}
        finally{appearance=original;SyncAppearanceControls();ApplyAppearance(false);Tabs.SelectedIndex=0;File.WriteAllText(Path.Combine(folder,"native-check.json"),JsonSerializer.Serialize(report,Backend.Json));}
    }
}
