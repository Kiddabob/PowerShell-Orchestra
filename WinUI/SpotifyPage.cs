using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using System.Text.Json;
namespace PowerShellOrchestra;
public partial class MainWindow
{
    TextBox spotifyQuery,spotifyTitle,spotifyArtist;
    TextBlock spotifyStatus;HyperlinkButton spotifyLink;
    Button spotifyMidi,spotifyAudio,spotifySearch;Expander spotifyFinder,spotifyBrowserExpander;
    WebView2 spotifyBrowser;Task spotifyBrowserInitialization;
    CoreWebView2Environment spotifyEnvironment;
    CancellationTokenSource spotifyMetadataCancellation;
    string spotifyTrack,spotifyAudioPath;bool updatingSpotify;

    UIElement BuildSpotifyFinder()
    {
        spotifyQuery=new TextBox{Header="Find a track on Spotify",PlaceholderText="Song and artist, or paste a Spotify song link",MaxLength=500};
        spotifySearch=Button("Search Spotify",async()=>await SearchSpotify(),true,"\uE721");
        var external=Button("Open search in browser",()=>{if(!string.IsNullOrWhiteSpace(spotifyQuery.Text))Backend.OpenUrl(SpotifyService.TrackUrl(spotifyQuery.Text)??SpotifyService.SearchUrl(spotifyQuery.Text));},false,"\uE774");
        spotifyQuery.KeyDown+=async(s,e)=>{if(e.Key==Windows.System.VirtualKey.Enter){e.Handled=true;await SearchSpotify();}};
        spotifyStatus=Text("Search Spotify, then select a song title. You can also paste Share → Copy song link from Spotify.");
        spotifyTitle=new TextBox{Header="Song title",MaxLength=160};spotifyArtist=new TextBox{Header="Artist (optional)",MaxLength=160};
        spotifyTitle.TextChanged+=(s,e)=>{if(!updatingSpotify){UpdateSpotifyActions();SuggestOutput();}};
        spotifyArtist.TextChanged+=(s,e)=>{if(!updatingSpotify){UpdateSpotifyActions();SuggestOutput();}};
        spotifyLink=new HyperlinkButton{Content="View selected song on Spotify",Visibility=Visibility.Collapsed,Padding=new Thickness(0)};
        spotifyLink.Click+=(s,e)=>{if(spotifyTrack!=null)Backend.OpenUrl(spotifyTrack);};
        spotifyMidi=Button("Find MIDI",async()=>await FindSpotifyMidi(),false,"\uE721");
        spotifyAudio=Button("Choose local audio for this track…",async()=>{try{var path=await PickFile(".mp3",".wav",".flac",".ogg");if(path!=null)AssociateSpotifyAudio(path);}catch(Exception e){await Error(e);}},false,"\uE8B7");
        var usePlaying=Button("Use currently playing song",async()=>await SelectCurrentlyPlaying(),false,"\uE8D6");
        spotifyBrowserExpander=new Expander{Header="Spotify web player",HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,VerticalContentAlignment=VerticalAlignment.Top,Visibility=Visibility.Collapsed};
        spotifyFinder=new Expander{Header="Spotify track finder",HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,VerticalContentAlignment=VerticalAlignment.Top,
            Content=Stack(Text("Use Spotify to identify a song, then find an existing MIDI or convert your own local audio file."),spotifyQuery,new ResponsivePanel{Children={spotifySearch,external}},spotifyStatus,spotifyTitle,spotifyArtist,spotifyLink,new ResponsivePanel{Children={spotifyMidi,spotifyAudio,usePlaying}},spotifyBrowserExpander)};
        UpdateSpotifyActions();return Card(spotifyFinder);
    }
    SpotifyReference CurrentSpotifyReference()=>spotifyTrack!=null&&!string.IsNullOrWhiteSpace(spotifyTitle.Text)?new(spotifyTrack,spotifyTitle.Text.Trim(),spotifyArtist.Text.Trim()):null;
    SpotifyReference AudioSpotifyReference()=>string.Equals(spotifyAudioPath,audioInput?.Text.Trim(),StringComparison.OrdinalIgnoreCase)?CurrentSpotifyReference():null;
    void UpdateSpotifyActions(){if(spotifyMidi==null)return;bool selected=CurrentSpotifyReference()!=null;spotifyMidi.IsEnabled=selected;spotifyAudio.IsEnabled=selected&&conversionCancellation==null;}
    void AssociateSpotifyAudio(string path){spotifyAudioPath=path;audioInput.Text=path;SuggestOutput();spotifyStatus.Text="Local recording selected for this track. Check the conversion options below.";}
    async Task FindSpotifyMidi()
    {
        var reference=CurrentSpotifyReference();if(reference==null)return;
        if(catalogueCancellation!=null){spotifyStatus.Text="The MIDI catalogue is busy. Finish or cancel that search first.";return;}
        string query=reference.Title; // Titles match more arrangements than artist + title.
        onlineQuery.Text=query;Tabs.SelectedIndex=1;await SearchOnline(0);
    }
    async Task SearchSpotify()
    {
        string query=spotifyQuery.Text.Trim();if(query.Length==0){spotifyStatus.Text="Enter a song and artist, or paste a Spotify song link.";return;}
        string track=SpotifyService.TrackUrl(query);
        if(track==null&&(query.Contains("://")||query.StartsWith("spotify:",StringComparison.OrdinalIgnoreCase))){spotifyStatus.Text="Use a full open.spotify.com/track/… song link, or enter a song and artist to search.";return;}
        spotifySearch.IsEnabled=false;
        try{
            if(track!=null)await SelectSpotifyTrack(track,"");
            spotifyBrowserExpander.Visibility=Visibility.Visible;spotifyBrowserExpander.IsExpanded=true;
            await EnsureSpotifyBrowser();
            spotifyBrowser.CoreWebView2.Navigate(track??SpotifyService.SearchUrl(query));
            if(track==null)spotifyStatus.Text="Select a song title, or play it and choose Use currently playing song. You can also paste its Spotify song link above.";
        }catch(OperationCanceledException){}catch(Exception e){spotifyStatus.Text="Spotify web player could not open. Use Open search in browser, then paste the song link here. "+e.Message;Backend.Log(e.ToString());}
        finally{spotifySearch.IsEnabled=true;}
    }
    Task EnsureSpotifyBrowser()=>spotifyBrowserInitialization??=InitializeSpotifyBrowser();
    async Task InitializeSpotifyBrowser()
    {
        try{
            spotifyBrowser=new WebView2{Height=500,HorizontalAlignment=HorizontalAlignment.Stretch};spotifyBrowserExpander.Content=spotifyBrowser;
            // Keep the existing published profile across app updates and separate
            // builds, preserving its cookies rather than copying credentials.
            string profile=Path.Combine(Backend.Root,"App","PowerShellOrchestra.exe.WebView2");
            spotifyEnvironment=await CoreWebView2Environment.CreateWithOptionsAsync(null,profile,new CoreWebView2EnvironmentOptions());
            await spotifyBrowser.EnsureCoreWebView2Async(spotifyEnvironment);if(closing){spotifyBrowser.Close();return;}
            var core=spotifyBrowser.CoreWebView2;
            core.Settings.AreDevToolsEnabled=false;core.Settings.IsStatusBarEnabled=false;
            await core.AddScriptToExecuteOnDocumentCreatedAsync(@"(()=>{if(location.hostname!=='open.spotify.com')return;document.addEventListener('click',e=>{if(!e.isTrusted)return;let a=e.target instanceof Element?e.target.closest('a[href*=""/track/""]'):null;if(a)window.chrome.webview.postMessage(a.href);},true);})();");
            core.WebMessageReceived+=async(s,e)=>{try{if(!closing&&Uri.TryCreate(e.Source,UriKind.Absolute,out var origin)&&origin.Scheme=="https"&&origin.Host=="open.spotify.com"){string selected=e.TryGetWebMessageAsString();if(SpotifyService.TrackUrl(selected)!=null)await SelectSpotifyTrack(selected,"");}}catch(Exception ex){Backend.Log(ex.Message);}};
            core.SourceChanged+=async(s,e)=>{try{if(!closing)await SelectSpotifyTrack(core.Source,core.DocumentTitle);}catch(Exception ex){Backend.Log(ex.ToString());}};
            core.DocumentTitleChanged+=(s,e)=>{if(!closing&&SpotifyService.TrackUrl(core.Source)==spotifyTrack)ApplySpotifyDocumentTitle(core.DocumentTitle);};
            core.NavigationStarting+=(s,e)=>{if(e.Uri!="about:blank"&&(!Uri.TryCreate(e.Uri,UriKind.Absolute,out var uri)||uri.Scheme!="https")){e.Cancel=true;spotifyStatus.Text="Use Spotify in this web player, or Open search in browser to use the Spotify app.";}};
            core.NewWindowRequested+=async(s,e)=>{
                e.Handled=true;if(!e.IsUserInitiated||!Uri.TryCreate(e.Uri,UriKind.Absolute,out var uri)||uri.Scheme!="https")return;
                var deferral=e.GetDeferral();Window popup=null;WebView2 view=null;
                try{
                    popup=new Window{Title="Spotify sign in"};view=new WebView2();popup.Content=view;popup.Activate();
                    await view.EnsureCoreWebView2Async(spotifyEnvironment);
                    var child=view;var window=popup;
                    child.CoreWebView2.WindowCloseRequested+=(sender,args)=>window.Close();
                    window.Closed+=(sender,args)=>child.Close();
                    e.NewWindow=child.CoreWebView2;e.Handled=true;
                }catch(Exception ex){Backend.Log("Spotify popup: "+ex.Message);if(popup!=null)popup.Close();spotifyStatus.Text="The Spotify sign-in window could not open. Try signing in within the web player.";}
                finally{deferral.Complete();}
            };
            core.NavigationCompleted+=(s,e)=>{if(!e.IsSuccess&&!closing)spotifyStatus.Text="Spotify could not load. Use Open search in browser, then paste the song link here.";};
        }catch{spotifyBrowser?.Close();spotifyBrowser=null;spotifyBrowserInitialization=null;throw;}
    }
    async Task SelectCurrentlyPlaying()
    {
        if(spotifyBrowser?.CoreWebView2==null){spotifyStatus.Text="Search Spotify and play a song first.";return;}
        try{
            string json=await spotifyBrowser.CoreWebView2.ExecuteScriptAsync(@"(()=>{if(location.hostname!=='open.spotify.com')return null;for(const selector of ['[data-testid=""now-playing-widget""]','[data-testid=""now-playing-bar""]','[data-testid=""now-playing-view""]']){const region=document.querySelector(selector);const link=region?.querySelector('a[href*=""/track/""]');if(link)return link.href;}return null;})()");
            string url=JsonSerializer.Deserialize<string>(json);if(SpotifyService.TrackUrl(url)==null){spotifyStatus.Text="Couldn't identify the playing song. In Spotify, use Share → Copy song link and paste it in the search box above.";return;}
            await SelectSpotifyTrack(url,"");
        }catch(Exception e){Backend.Log(e.Message);spotifyStatus.Text="Couldn't identify the playing song. Copy its Spotify song link and paste it above.";}
    }
    void ApplySpotifyDocumentTitle(string title)
    {
        var parsed=SpotifyService.DocumentTitle(title);if(parsed.Title.Length==0)return;
        // A late page-title event must not replace an artist the user entered.
        updatingSpotify=true;if(spotifyTitle.Text.Length==0)spotifyTitle.Text=parsed.Title;if(spotifyArtist.Text.Length==0)spotifyArtist.Text=parsed.Artist;updatingSpotify=false;UpdateSpotifyActions();SuggestOutput();
    }
    async Task SelectSpotifyTrack(string url,string documentTitle)
    {
        string track=SpotifyService.TrackUrl(url);if(track==null)return;
        if(track==spotifyTrack){ApplySpotifyDocumentTitle(documentTitle);return;}
        spotifyMetadataCancellation?.Cancel();spotifyMetadataCancellation?.Dispose();spotifyMetadataCancellation=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);var token=spotifyMetadataCancellation.Token;
        spotifyTrack=track;spotifyAudioPath=null;updatingSpotify=true;spotifyTitle.Text="";spotifyArtist.Text="";updatingSpotify=false;
        spotifyLink.Visibility=Visibility.Visible;UpdateSpotifyActions();SuggestOutput();spotifyStatus.Text="Reading the Spotify song title…";
        // DocumentTitle can still belong to the previous SPA route. Only use
        // subsequent title-change events; oEmbed identifies this exact track.
        try{string title=await SpotifyService.FetchTitle(track,token);if(!closing&&track==spotifyTrack){if(spotifyTitle.Text.Length==0)spotifyTitle.Text=title;spotifyStatus.Text="Track selected. Check the title and artist, then choose Find MIDI or your local audio.";}}
        catch(OperationCanceledException){}catch(Exception e){if(!closing&&track==spotifyTrack)spotifyStatus.Text="Could not read Spotify metadata. Enter the title and artist above to continue.";Backend.Log(e.Message);}
        UpdateSpotifyActions();
    }
    void CloseSpotify(){spotifyMetadataCancellation?.Cancel();spotifyMetadataCancellation?.Dispose();spotifyBrowser?.Close();}
}
