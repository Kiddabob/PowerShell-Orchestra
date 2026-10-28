using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Windowing;
using System.Diagnostics;
using System.Text.Json;
using Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Graphics;
namespace PowerShellOrchestra;
public partial class MainWindow : Window
{
    readonly CancellationTokenSource lifetime=new();
    readonly AppWindow appWindow;
    readonly List<FrameworkElement> pages=new();
    AppearanceSettings appearance=AppearanceSettings.Load();
    bool initializing=true,closing;
    TextBlock libraryStatus;CenteredWrapPanel songCards;ComboBox screenChoice,styleChoice;
    DispatcherTimer libraryTimer=new(){Interval=TimeSpan.FromSeconds(4)};bool refreshing;
    List<Song> songs=new();string librarySignature="";
    public MainWindow()
    {
        InitializeComponent();Title="PowerShell Orchestra";
        appWindow=AppWindow.GetFromWindowId(Microsoft.UI.Win32Interop.GetWindowIdFromWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)));
        appWindow.Resize(new SizeInt32(1120,820));appWindow.SetIcon(Path.Combine(Backend.Root,"PowerShell-Orchestra-Note.ico"));
        ExtendsContentIntoTitleBar=true;SetTitleBar(TitleDrag);
        AddTab("My Songs","\uE8D6",BuildLibrary());AddTab("Online MIDI","\uE721",BuildCatalogue());AddTab("Converter","\uE8AB",BuildConverter());AddTab("Appearance","\uE790",BuildAppearance());
        initializing=false;ApplyAppearance(false);
        Root.SizeChanged+=(s,e)=>{foreach(var page in pages)page.Width=Math.Max(320,e.NewSize.Width);};
        Root.ActualThemeChanged+=(s,e)=>{UpdateCaption();DispatcherQueue.TryEnqueue(()=>{if(!closing){acrylicBackdrop?.Configure(appearance);RefreshCardSurfaces();UpdateAcrylicControls();}});};
        systemColors.ColorValuesChanged+=(s,e)=>DispatcherQueue.TryEnqueue(()=>{if(!closing)ApplyAppearance(false);});
        // Some unpackaged Windows configurations do not expose this WinRT
        // subscription. Native theme resources and colour events still apply.
        try{accessibility.HighContrastChanged+=(s,e)=>DispatcherQueue.TryEnqueue(()=>{if(!closing)ApplyAppearance(false);});}catch(System.Runtime.InteropServices.COMException e){Backend.Log("High-contrast notification unavailable: "+e.Message);}
        Root.Loaded+=async(s,e)=>{SizeForDisplay();await RefreshSongs();await RefreshScreens();if(Environment.GetCommandLineArgs().Contains("--verify"))await VerifyNativeApp();};
        Activated+=async(s,e)=>{if(e.WindowActivationState!=WindowActivationState.Deactivated && !closing){await RefreshScreens();}};
        libraryTimer.Tick+=async(s,e)=>{if(!closing)await RefreshSongs(true);};libraryTimer.Start();
        Closed+=(s,e)=>{closing=true;libraryTimer.Stop();lifetime.Cancel();StopPreview();conversionCancellation?.Cancel();CloseSpotify();};
    }
    void AddTab(string title,string glyph,FrameworkElement content){pages.Add(content);Tabs.TabItems.Add(new TabViewItem{Header=title,IsClosable=false,IconSource=new FontIconSource{Glyph=glyph},Content=content});}
    void SizeForDisplay(){double scale=Root.XamlRoot?.RasterizationScale??1;var area=DisplayArea.GetFromWindowId(appWindow.Id,DisplayAreaFallback.Primary).WorkArea;int width=Math.Min((int)(1120*scale),area.Width-48),height=Math.Min((int)(820*scale),area.Height-48);appWindow.MoveAndResize(new RectInt32(area.X+(area.Width-width)/2,area.Y+(area.Height-height)/2,width,height));}
    static TextBlock Text(string text,double size=0){var t=new TextBlock{Text=text,TextWrapping=TextWrapping.Wrap};if(size>0)t.FontSize=size;return t;}
    static TextBlock Heading(string text)=>new(){Text=text,FontSize=28,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,Margin=new Thickness(0,0,0,6)};
    static StackPanel Stack(params UIElement[] children){var panel=new StackPanel{Spacing=12};foreach(var child in children)panel.Children.Add(child);return panel;}
    static readonly List<WeakReference<Border>> surfaceCards=new();
    static void UpdateCardSurface(Border border,AppearanceSettings appearance){bool dark=border.ActualTheme==ElementTheme.Dark;var settings=new Windows.UI.ViewManagement.AccessibilitySettings();if(settings.HighContrast){var colors=new Windows.UI.ViewManagement.UISettings();border.Background=new SolidColorBrush(colors.GetColorValue(Windows.UI.ViewManagement.UIColorType.Background));border.BorderBrush=new SolidColorBrush(colors.GetColorValue(Windows.UI.ViewManagement.UIColorType.Foreground));}else{byte alpha=appearance?.Material=="Acrylic"&&appearance.AcrylicCustom?(byte)Math.Round(Percent(appearance.AcrylicPanelOpacity)*255/100):(byte)(dark?220:235);border.Background=new SolidColorBrush(dark?Windows.UI.Color.FromArgb(alpha,45,45,45):Windows.UI.Color.FromArgb(alpha,255,255,255));border.BorderBrush=new SolidColorBrush(dark?Windows.UI.Color.FromArgb(50,255,255,255):Windows.UI.Color.FromArgb(25,0,0,0));}}
    void RefreshCardSurfaces(){for(int i=surfaceCards.Count-1;i>=0;i--){if(surfaceCards[i].TryGetTarget(out var border))UpdateCardSurface(border,appearance);else surfaceCards.RemoveAt(i);}}
    static Border Card(UIElement content){var border=new Border{Child=content,CornerRadius=new CornerRadius(12),BorderThickness=new Thickness(1),Padding=new Thickness(18)};surfaceCards.Add(new WeakReference<Border>(border));void Update()=>UpdateCardSurface(border,App.Main?.appearance);border.Loaded+=(s,e)=>Update();border.ActualThemeChanged+=(s,e)=>Update();Update();return border;}
    static Button Button(string label,Action action,bool accent=false,string glyph=null){var b=new Button();if(glyph==null)b.Content=label;else b.Content=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,Children={new FontIcon{Glyph=glyph,FontSize=16},Text(label)}};if(accent)b.Style=(Style)Application.Current.Resources["OrchestraAccentButton"];AutomationPropertiesName(b,label);b.Click+=(s,e)=>action();return b;}
    static void AutomationPropertiesName(DependencyObject control,string name)=>Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(control,name);
    static ComboBox Choices(params string[] labels){var box=new ComboBox{MinWidth=180,HorizontalAlignment=HorizontalAlignment.Stretch};foreach(var label in labels)box.Items.Add(label);box.SelectedIndex=0;return box;}
    static ScrollViewer Scroll(UIElement child)=>new(){Content=child,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,HorizontalContentAlignment=HorizontalAlignment.Stretch};
    static Grid CenteredPage(StackPanel content){
        var host=new Grid{HorizontalAlignment=HorizontalAlignment.Stretch};host.Children.Add(content);
        var scroll=new ScrollViewer{Content=host,HorizontalContentAlignment=HorizontalAlignment.Left,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        void Size(){host.Width=Math.Max(1,scroll.ActualWidth);host.InvalidateMeasure();}
        scroll.Loaded+=(s,e)=>Size();scroll.SizeChanged+=(s,e)=>Size();return new Grid{Children={scroll}};
    }
    static Grid PageGrid(){var grid=new Grid{Padding=new Thickness(26,20,26,20),RowSpacing=14};grid.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});grid.RowDefinitions.Add(new RowDefinition{Height=new GridLength(1,GridUnitType.Star)});grid.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});return grid;}
    async Task Error(Exception error){Backend.Log(error.ToString());if(closing)return;await new ContentDialog{Title="PowerShell Orchestra",Content=Text(error.Message),CloseButtonText="Close",XamlRoot=Root.XamlRoot,RequestedTheme=Root.RequestedTheme}.ShowAsync();}
    async Task<string> PickFile(params string[] extensions){var picker=new FileOpenPicker();foreach(var extension in extensions)picker.FileTypeFilter.Add(extension);WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));var file=await picker.PickSingleFileAsync();return file?.Path;}
    async Task<string> SaveFile(string name,string extension){var picker=new FileSavePicker{SuggestedFileName=name};picker.FileTypeChoices.Add(extension.ToUpperInvariant()+" file",new List<string>{extension});WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));return (await picker.PickSaveFileAsync())?.Path;}
    Grid BuildLibrary()
    {
        var page=PageGrid();var toolbar=new ResponsivePanel();
        toolbar.Children.Add(Button("Add MIDI",async()=>{try{var path=await PickFile(".mid",".midi");if(path!=null){await Backend.Call<JsonElement>(new{Action="Import",Path=path},lifetime.Token);await RefreshSongs();}}catch(Exception e){await Error(e);}},false,"\uE710"));
        toolbar.Children.Add(Button("Refresh",async()=>await RefreshSongs(),false,"\uE72C"));
        screenChoice=Choices("Automatic screens");screenChoice.MinWidth=170;AutomationPropertiesName(screenChoice,"Playback screen count");toolbar.Children.Add(screenChoice);
        styleChoice=Choices("PowerShell console","Graphical panels","Plain console log");styleChoice.MinWidth=190;AutomationPropertiesName(styleChoice,"Playback display style");toolbar.Children.Add(styleChoice);
        var settings=ReadPlayerSettings();styleChoice.SelectedIndex=settings.style switch{"Panels"=>1,"Text"=>2,_=>0};
        screenChoice.SelectionChanged+=(s,e)=>{if(!updatingScreens)SavePlayerSettings();};styleChoice.SelectionChanged+=(s,e)=>SavePlayerSettings();
        var header=Stack(Heading("My Songs"),Text("Your music, played across the screens you choose."),toolbar);page.Children.Add(header);
        songCards=new CenteredWrapPanel();var scroll=Scroll(songCards);Grid.SetRow(scroll,1);page.Children.Add(scroll);
        libraryStatus=Text("Loading your library…");Grid.SetRow(libraryStatus,2);page.Children.Add(libraryStatus);return page;
    }
    static ScrollViewer ScrollHorizontal(UIElement child)=>new(){Content=child,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollBarVisibility=ScrollBarVisibility.Disabled};
    bool updatingScreens;
    (string style,int screens) ReadPlayerSettings(){try{using var d=JsonDocument.Parse(File.ReadAllText(Path.Combine(Backend.Root,"player-settings.json")));return(d.RootElement.TryGetProperty("DisplayStyle",out var s)?s.GetString():"Console",d.RootElement.TryGetProperty("ScreenCount",out var n)?n.GetInt32():0);}catch{return("Console",0);}}
    async Task RefreshScreens(){if(updatingScreens||closing)return;updatingScreens=true;try{var result=await Backend.Call<JsonElement>(new{Action="Displays"},lifetime.Token);int count=Math.Max(1,result.GetProperty("Count").GetInt32());int saved=ReadPlayerSettings().screens;if(screenChoice.Items.Count!=count+1){screenChoice.Items.Clear();screenChoice.Items.Add($"Automatic (all {count})");for(int i=1;i<=count;i++)screenChoice.Items.Add(i==1?"1 screen (primary)":$"{i} screens");}screenChoice.SelectedIndex=Math.Min(Math.Max(0,saved),count);}catch(Exception e){Backend.Log(e.Message);}finally{updatingScreens=false;}}
    void SavePlayerSettings(){if(initializing||updatingScreens)return;File.WriteAllText(Path.Combine(Backend.Root,"player-settings.json"),JsonSerializer.Serialize(new{DisplayStyle=new[]{"Console","Panels","Text"}[Math.Max(0,styleChoice.SelectedIndex)],ScreenCount=Math.Max(0,screenChoice.SelectedIndex)},Backend.Json));}
    async Task RefreshSongs(bool quiet=false)
    {
        if(refreshing)return;refreshing=true;
        try{var items=await Backend.Call<List<Song>>(new{Action="Songs"},lifetime.Token);string signature=string.Join("|",items.Select(s=>s.Id+s.Title+s.Icon+s.SourceUrl));if(quiet && signature==librarySignature)return;songs=items;librarySignature=signature;songCards.Children.Clear();foreach(var song in songs)songCards.Children.Add(SongCard(song));libraryStatus.Text=$"{songs.Count} songs • Mixer changes apply to the next playback";}
        catch(OperationCanceledException){}catch(Exception e){libraryStatus.Text=e.Message;Backend.Log(e.ToString());}finally{refreshing=false;}
    }
    Border SongCard(Song song)
    {
        var image=new Image{Width=140,Height=140,Stretch=Stretch.Uniform,Source=new BitmapImage(new Uri(song.Icon))};
        var imageArea=new Grid{Width=150,Height=150,HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(0,0,0,4)};imageArea.Children.Add(image);
        var pencil=Button("Song options",()=>{},false);pencil.Content=new FontIcon{Glyph="\uE70F",FontSize=16};ToolTipService.SetToolTip(pencil,"Song and icon options");pencil.Width=34;pencil.Height=34;pencil.MinHeight=0;pencil.Padding=new Thickness(0);pencil.HorizontalAlignment=HorizontalAlignment.Right;pencil.VerticalAlignment=VerticalAlignment.Top;pencil.Visibility=Visibility.Collapsed;
        var menu=new MenuFlyout();var generate=new MenuFlyoutItem{Text="Generate icon",Icon=new FontIcon{Glyph="\uE790"}};generate.Click+=async(s,e)=>{try{var result=await Backend.Call<JsonElement>(new{Action="IconPrompt",song.Id},lifetime.Token);string prompt=result.GetProperty("Prompt").GetString();var data=new DataPackage();data.SetText(prompt);Clipboard.SetContent(data);Backend.OpenUrl("https://chatgpt.com/?q="+Uri.EscapeDataString(prompt));libraryStatus.Text="ChatGPT opened with the song prompt. Download the image, then choose Use custom icon.";}catch(Exception ex){await Error(ex);}};menu.Items.Add(generate);
        var custom=new MenuFlyoutItem{Text="Use custom icon…",Icon=new FontIcon{Glyph="\uEB9F"}};custom.Click+=async(s,e)=>{try{var path=await PickFile(".png",".jpg",".jpeg",".ico");if(path!=null){await Backend.Call<JsonElement>(new{Action="SaveIcon",song.Id,Path=path},lifetime.Token);await RefreshSongs();}}catch(Exception ex){await Error(ex);}};menu.Items.Add(custom);
        var rename=new MenuFlyoutItem{Text="Rename song…",Icon=new FontIcon{Glyph="\uE8AC"}};rename.Click+=async(s,e)=>await RenameSong(song);menu.Items.Add(rename);
        if(!string.IsNullOrEmpty(song.SourceUrl)){var source=new MenuFlyoutItem{Text="Open MIDI source"};source.Click+=(s,e)=>Backend.OpenUrl(song.SourceUrl);menu.Items.Add(source);}
        bool hover=false;pencil.Flyout=menu;imageArea.Children.Add(pencil);imageArea.PointerEntered+=(s,e)=>{hover=true;pencil.Visibility=Visibility.Visible;};imageArea.PointerExited+=(s,e)=>{hover=false;if(!pencil.IsPointerOver)pencil.Visibility=Visibility.Collapsed;};imageArea.GotFocus+=(s,e)=>pencil.Visibility=Visibility.Visible;imageArea.LostFocus+=(s,e)=>{if(!hover)pencil.Visibility=Visibility.Collapsed;};
        var title=Text(song.Title,16);title.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;title.TextAlignment=TextAlignment.Center;title.Height=44;title.MaxLines=2;
        var buttons=new StackPanel{Orientation=Orientation.Horizontal,Spacing=6,HorizontalAlignment=HorizontalAlignment.Center};
        var play=Button("Play",()=>Backend.LaunchSong(song.Midi,song.Title),true);play.Padding=new Thickness(12,7,12,7);buttons.Children.Add(play);
        var mixer=Button("Mixer",async()=>await ShowMixer(song));mixer.Padding=new Thickness(10,7,10,7);buttons.Children.Add(mixer);
        if(song.CanDelete){var delete=Button("Delete",async()=>{var dialog=new ContentDialog{Title="Delete this MIDI?",Content=Text($"Move “{song.Title}” to the Recycle Bin? Your original audio is preserved."),PrimaryButtonText="Delete",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close,XamlRoot=Root.XamlRoot,RequestedTheme=Root.RequestedTheme};if(await dialog.ShowAsync()==ContentDialogResult.Primary){try{await Backend.Call<JsonElement>(new{Action="Delete",song.Id},lifetime.Token);await RefreshSongs();}catch(Exception e){await Error(e);}}});delete.Padding=new Thickness(8,7,8,7);buttons.Children.Add(delete);}
        var card=Card(Stack(imageArea,title,buttons));card.Width=264;card.Height=300;card.Padding=new Thickness(12);return card;
    }
    async Task RenameSong(Song song)
    {
        var name=new TextBox{Header="Song name",Text=song.Title,MaxLength=160,MinWidth=300};
        var dialog=new ContentDialog{Title="Rename song",Content=name,PrimaryButtonText="Save",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Primary,XamlRoot=Root.XamlRoot,RequestedTheme=Root.RequestedTheme,IsPrimaryButtonEnabled=!string.IsNullOrWhiteSpace(name.Text)};
        name.TextChanged+=(s,e)=>dialog.IsPrimaryButtonEnabled=!string.IsNullOrWhiteSpace(name.Text);
        if(await dialog.ShowAsync()==ContentDialogResult.Primary){try{await Backend.Call<JsonElement>(new{Action="Rename",song.Id,Title=name.Text.Trim()},lifetime.Token);await RefreshSongs();libraryStatus.Text="Song renamed.";}catch(Exception e){await Error(e);}}
    }
    async Task ShowMixer(Song song)
    {
        try{
            var mix=await Backend.Call<Mix>(new{Action="Mix",song.Id},lifetime.Token);var sliders=new Dictionary<string,Slider>();var panel=new StackPanel{Spacing=18,MinWidth=400};
            panel.Children.Add(Text("100% preserves the MIDI balance. 0% mutes. Saved levels apply to your next playback."));
            void Row(string id,string label,int value){var percent=Text(value+"%");var slider=new Slider{Minimum=0,Maximum=100,Value=value,StepFrequency=1,Header=label,MinWidth=360};slider.ValueChanged+=(s,e)=>percent.Text=((int)e.NewValue)+"%";sliders[id]=slider;panel.Children.Add(Stack(slider,percent));}
            Row("master","Master",mix.Master);foreach(var part in mix.Parts)Row(part.Id,part.Name,part.Level);
            panel.Children.Add(Button("Reset to MIDI balance",()=>{foreach(var slider in sliders.Values)slider.Value=100;}));
            var dialog=new ContentDialog{Title=song.Title+" — Mixer",Content=new ScrollViewer{Content=panel,MaxHeight=480},PrimaryButtonText="Save mix",SecondaryButtonText="Save and play",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Primary,XamlRoot=Root.XamlRoot,RequestedTheme=Root.RequestedTheme};var choice=await dialog.ShowAsync();
            if(choice!=ContentDialogResult.None){var parts=sliders.Where(p=>p.Key!="master").ToDictionary(p=>p.Key,p=>(int)p.Value.Value);await Backend.Call<JsonElement>(new{Action="SaveMix",song.Id,Master=(int)sliders["master"].Value,Parts=parts},lifetime.Token);libraryStatus.Text="Mix saved for “"+song.Title+"”.";if(choice==ContentDialogResult.Secondary)Backend.LaunchSong(song.Midi,song.Title);}
        }catch(Exception e){await Error(e);}
    }
}
public class CenteredWrapPanel : Panel
{
    const double CardWidth=264,CardHeight=300,Gap=18;
    protected override Size MeasureOverride(Size available){int columns=Math.Max(1,(int)((double.IsInfinity(available.Width)?1000:available.Width)+Gap)/(int)(CardWidth+Gap));foreach(var child in Children)child.Measure(new Size(CardWidth,CardHeight));return new Size(double.IsInfinity(available.Width)?columns*(CardWidth+Gap):available.Width,Math.Ceiling(Children.Count/(double)columns)*(CardHeight+Gap));}
    protected override Size ArrangeOverride(Size final){int columns=Math.Max(1,(int)((final.Width+Gap)/(CardWidth+Gap)));for(int row=0;row*columns<Children.Count;row++){int count=Math.Min(columns,Children.Count-row*columns);double x=Math.Max(0,(final.Width-(count*CardWidth+(count-1)*Gap))/2);for(int col=0;col<count;col++)Children[row*columns+col].Arrange(new Rect(x+col*(CardWidth+Gap),row*(CardHeight+Gap),CardWidth,CardHeight));}return final;}
}
public class ResponsivePanel : Panel
{
    const double Gap=10,RowGap=8;
    protected override Size MeasureOverride(Size available){double width=double.IsInfinity(available.Width)?1200:available.Width,x=0,y=0,line=0;foreach(var child in Children){child.Measure(new Size(width,double.PositiveInfinity));var size=child.DesiredSize;if(x>0&&x+size.Width>width){x=0;y+=line+RowGap;line=0;}x+=size.Width+Gap;line=Math.Max(line,size.Height);}return new Size(width,y+line);}
    protected override Size ArrangeOverride(Size final){double x=0,y=0,line=0;foreach(var child in Children){var size=child.DesiredSize;if(x>0&&x+size.Width>final.Width){x=0;y+=line+RowGap;line=0;}child.Arrange(new Rect(x,y,Math.Min(size.Width,final.Width),size.Height));x+=size.Width+Gap;line=Math.Max(line,size.Height);}return final;}
}
