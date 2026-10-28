using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
namespace PowerShellOrchestra;
public partial class MainWindow
{
    TextBox onlineQuery;ComboBox onlineSource;ListView onlineList;TextBlock onlineStatus,onlineDetail;Button onlineSearch,onlinePreview,onlineAdd,onlineStop,onlinePrevious,onlineNext,onlineCancel;ProgressBar onlineProgress;
    int onlinePage;bool moreOnline;CancellationTokenSource catalogueCancellation;LayeredMusic.Audio previewAudio;DispatcherTimer previewClock=new(){Interval=TimeSpan.FromMilliseconds(100)};double previewDuration;
    Grid BuildCatalogue()
    {
        var page=PageGrid();onlineQuery=new TextBox{PlaceholderText="Song, artist, game or film",MinWidth=250,MaxLength=160};onlineSource=Choices("All sources","FreeMIDI","BitMidi");onlineSearch=Button("Search",async()=>await SearchOnline(0),true,"\uE721");
        onlinePrevious=Button("Previous",async()=>await SearchOnline(onlinePage-1));onlineNext=Button("Next",async()=>await SearchOnline(onlinePage+1));onlinePrevious.IsEnabled=onlineNext.IsEnabled=false;onlineCancel=Button("Cancel",()=>catalogueCancellation?.Cancel());onlineCancel.IsEnabled=false;
        var searchRow=new ResponsivePanel{Children={onlineQuery,onlineSource,onlineSearch,onlinePrevious,onlineNext,onlineCancel}};
        onlineQuery.KeyDown+=async(s,e)=>{if(e.Key==Windows.System.VirtualKey.Enter && onlineSearch.IsEnabled){e.Handled=true;await SearchOnline(0);}};
        page.Children.Add(Stack(Heading("Online MIDI"),Text("Discover an arrangement. Hear it in Orchestra. Keep the ones you like."),searchRow));
        onlineList=new ListView{SelectionMode=ListViewSelectionMode.Single,HorizontalContentAlignment=HorizontalAlignment.Stretch};onlineList.SelectionChanged+=(s,e)=>{StopPreview();UpdateOnlineButtons();if(onlineList.SelectedItem is ListViewItem row && row.Tag is OnlineSong song)onlineDetail.Text=song.Title+" • "+song.Provider;};onlineList.DoubleTapped+=async(s,e)=>{if(onlinePreview.IsEnabled)await PreviewOnline();};Grid.SetRow(onlineList,1);page.Children.Add(onlineList);
        onlinePreview=Button("Preview 30 seconds",async()=>await PreviewOnline(),true,"\uE768");onlineStop=Button("Stop preview",()=>StopPreview(),false,"\uE71A");onlineAdd=Button("Add to My Songs",async()=>await AddOnline(),false,"\uE710");var source=Button("Open source",()=>{if(SelectedOnline() is OnlineSong song)Backend.OpenUrl(song.SourceUrl);},false,"\uE774");
        onlineDetail=Text("Search for a song to get started.");onlineStatus=Text("Sources: BitMidi and FreeMIDI. Previews stay separate from My Songs.");onlineProgress=new ProgressBar{Minimum=0,Maximum=100};
        var actions=new ResponsivePanel{Children={onlinePreview,onlineStop,onlineAdd,source}};var bottom=Stack(onlineDetail,actions,onlineProgress,onlineStatus);Grid.SetRow(bottom,2);page.Children.Add(bottom);
        onlineList.SelectionChanged+=(s,e)=>source.IsEnabled=SelectedOnline()!=null;source.IsEnabled=false;UpdateOnlineButtons();
        previewClock.Tick+=(s,e)=>{if(previewAudio==null)return;if(previewAudio.Done){StopPreview();onlineStatus.Text="Preview finished. Add this arrangement to keep it for offline playback.";}else onlineProgress.Value=Math.Min(100,previewAudio.Milliseconds/Math.Max(1,previewDuration)*100);};
        return page;
    }
    OnlineSong SelectedOnline()=>(onlineList.SelectedItem as ListViewItem)?.Tag as OnlineSong;
    void UpdateOnlineButtons(){bool idle=catalogueCancellation==null,selected=SelectedOnline()!=null;onlineSearch.IsEnabled=idle;onlineQuery.IsEnabled=idle;onlineSource.IsEnabled=idle;onlinePreview.IsEnabled=onlineAdd.IsEnabled=idle&&selected;onlineCancel.IsEnabled=!idle;onlinePrevious.IsEnabled=idle&&onlinePage>0;onlineNext.IsEnabled=idle&&moreOnline;onlineStop.IsEnabled=previewAudio!=null;}
    void StopPreview(){previewClock.Stop();previewAudio?.Dispose();previewAudio=null;if(onlineStop!=null)onlineStop.IsEnabled=false;if(onlineProgress!=null){onlineProgress.Value=0;onlineProgress.IsIndeterminate=false;}}
    async Task OnlineWork(Func<CancellationToken,Task> work)
    {
        if(catalogueCancellation!=null)return;StopPreview();catalogueCancellation=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);UpdateOnlineButtons();onlineProgress.IsIndeterminate=true;
        try{await work(catalogueCancellation.Token);}catch(OperationCanceledException){onlineStatus.Text="Catalogue request cancelled.";}catch(Exception e){Backend.Log(e.ToString());onlineStatus.Text=e.Message;}finally{catalogueCancellation.Dispose();catalogueCancellation=null;onlineProgress.IsIndeterminate=false;UpdateOnlineButtons();}
    }
    async Task SearchOnline(int page)
    {
        if(onlineQuery.Text.Trim().Length<2){onlineStatus.Text="Enter at least two characters to search.";return;}
        await OnlineWork(async token=>{onlineStatus.Text="Searching…";var result=await Backend.Call<SearchResult>(new{Action="Search",Query=onlineQuery.Text.Trim(),Provider=(string)onlineSource.SelectedItem,Page=Math.Max(0,page)},token);onlineList.Items.Clear();
            foreach(var song in result.Items){var title=Text(song.Title,16);title.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;var subtitle=Text(string.IsNullOrWhiteSpace(song.Artist)?song.Provider:song.Artist+" • "+song.Provider,12);subtitle.Opacity=.7;onlineList.Items.Add(new ListViewItem{Tag=song,Content=Stack(title,subtitle),Padding=new Thickness(14,10,14,10)});}
            onlinePage=page;moreOnline=result.HasMore;onlineStatus.Text=$"{result.Items.Count} arrangements • Page {page+1}. "+(result.Items.Count==0?"Try fewer words or another source. ":"")+string.Join(" ",result.Warnings);
        });
    }
    async Task PreviewOnline(){var song=SelectedOnline();if(song==null)return;await OnlineWork(async token=>{onlineStatus.Text="Preparing your Orchestra-tone preview…";var result=await Backend.Call<PreviewResult>(new{Action="Preview",Item=song},token);previewAudio=new LayeredMusic.Audio(result.Wave);previewDuration=Math.Min(30,result.Duration)*1000;previewAudio.Start();previewClock.Start();onlineDetail.Text=song.Title+" • "+TimeSpan.FromSeconds(result.Duration).ToString(@"mm\:ss")+$" • {result.Parts} parts • {result.Notes:N0} notes";onlineStatus.Text="Playing the first 30 seconds with Orchestra's tones and saved balance.";});}
    async Task AddOnline(){var song=SelectedOnline();if(song==null)return;await OnlineWork(async token=>{onlineStatus.Text="Checking this arrangement…";var result=await Backend.Call<AddResult>(new{Action="Add",Item=song},token);onlineStatus.Text=result.AlreadyAdded?"Already in My Songs: "+result.Title:"Added to My Songs: "+result.Title;await RefreshSongs();});}
}
