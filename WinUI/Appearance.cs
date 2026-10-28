using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Documents;
using Windows.UI;
using Windows.UI.ViewManagement;
using System.Text.Json;
namespace PowerShellOrchestra;
public class AppearanceSettings
{
    public string Theme{get;set;}="System";public string Material{get;set;}="Mica";public bool WindowsAccent{get;set;}=true;public string Accent{get;set;}="#0078D4";public string Font{get;set;}="Segoe UI Variable";public double FontSize{get;set;}=14;public string ReduceMotion{get;set;}="System";
    public bool AcrylicCustom{get;set;}=false;public string AcrylicKind{get;set;}="Base";
    public double AcrylicDarkness{get;set;}=0;public double AcrylicTintOpacity{get;set;}=50;public double AcrylicLuminosityOpacity{get;set;}=70;public double AcrylicPanelOpacity{get;set;}=90;
    public bool AcrylicThemeTint{get;set;}=true;public string AcrylicTintColor{get;set;}="#FFFFFF";
    public bool AcrylicThemeFallback{get;set;}=true;public string AcrylicFallbackColor{get;set;}="#202020";
    public static AppearanceSettings Load(){try{return JsonSerializer.Deserialize<AppearanceSettings>(File.ReadAllText(Path.Combine(Backend.Root,"appearance-settings.json")),Backend.Json)??new();}catch{return new();}}
}
public partial class MainWindow
{
    readonly UISettings systemColors=new();readonly AccessibilitySettings accessibility=new();
    ComboBox themeBox,materialBox,fontBox,motionBox;ToggleSwitch windowsAccent;ColorPicker accentPicker;NumberBox fontSizeBox;TextBlock appearanceStatus;bool updatingAppearance;
    TunableAcrylicBackdrop acrylicBackdrop;
    Expander acrylicSection;ComboBox acrylicKind;ToggleSwitch acrylicDefaults,acrylicThemeTint,acrylicThemeFallback;Slider acrylicDarkness,acrylicOpacity,acrylicLuminosity,acrylicPanels;ColorPicker acrylicTint,acrylicFallback;StackPanel acrylicControls;TextBlock acrylicStatus;
    Grid BuildAppearance()
    {
        var panel=new StackPanel{Spacing=18,MaxWidth=880,HorizontalAlignment=HorizontalAlignment.Stretch,Margin=new Thickness(30,24,30,30)};
        panel.Children.Add(Heading("Appearance"));panel.Children.Add(Text("A familiar Windows look, with the freedom to make it yours."));
        themeBox=Choices("System","Light","Dark");themeBox.SelectedIndex=appearance.Theme switch{"Light"=>1,"Dark"=>2,_=>0};
        materialBox=Choices("Mica","Acrylic","Solid");materialBox.SelectedIndex=appearance.Material switch{"Acrylic"=>1,"Solid"=>2,_=>0};
        panel.Children.Add(Card(Stack(Setting("Mode","Follow Windows or choose a light or dark appearance.",themeBox),Setting("Background material","Mica picks up your wallpaper; Acrylic adds frosted glass.",materialBox))));
        panel.Children.Add(BuildAcrylicSettings());
        windowsAccent=new ToggleSwitch{Header="Use Windows accent colour",IsOn=appearance.WindowsAccent};
        accentPicker=new ColorPicker{Color=ParseColor(appearance.Accent),IsAlphaEnabled=false,IsColorChannelTextInputVisible=true,IsHexInputVisible=true,IsColorSliderVisible=true,MaxWidth=420,HorizontalAlignment=HorizontalAlignment.Left};accentPicker.Visibility=appearance.WindowsAccent?Visibility.Collapsed:Visibility.Visible;
        panel.Children.Add(Card(Stack(windowsAccent,Text("Windows colour updates are applied automatically. Turn this off to choose your own accent."),accentPicker)));
        fontBox=Choices("Segoe UI Variable","Segoe UI","Arial","Calibri","Cascadia Code");fontBox.SelectedItem=appearance.Font;if(fontBox.SelectedIndex<0)fontBox.SelectedIndex=0;
        fontSizeBox=new NumberBox{Minimum=12,Maximum=22,Value=Math.Clamp(appearance.FontSize,12,22),SmallChange=1,SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Compact,Width=150};
        motionBox=Choices("System","On","Off");motionBox.SelectedItem=appearance.ReduceMotion;if(motionBox.SelectedIndex<0)motionBox.SelectedIndex=0;
        var advanced=new Expander{Header="Advanced",HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,IsExpanded=true,Content=Stack(Setting("UI font","Segoe UI Variable is the Windows 11 default.",fontBox),Setting("UI font size","Adjust the size of body text and controls.",fontSizeBox),Setting("Reduce motion","Reduce page entrance animations or follow Windows.",motionBox))};panel.Children.Add(advanced);
        appearanceStatus=Text("Appearance changes are saved automatically. Windows accessibility and transparency preferences take priority.");panel.Children.Add(appearanceStatus);
        panel.Children.Add(Button("Reset appearance to defaults",()=>{appearance=new();SyncAppearanceControls();ApplyAppearance();}));
        void Changed(){if(initializing||updatingAppearance)return;appearance.Theme=(string)themeBox.SelectedItem;appearance.Material=(string)materialBox.SelectedItem;appearance.WindowsAccent=windowsAccent.IsOn;appearance.Accent=Hex(accentPicker.Color);appearance.Font=(string)fontBox.SelectedItem;appearance.FontSize=double.IsNaN(fontSizeBox.Value)?14:Math.Clamp(fontSizeBox.Value,12,22);appearance.ReduceMotion=(string)motionBox.SelectedItem;accentPicker.Visibility=appearance.WindowsAccent?Visibility.Collapsed:Visibility.Visible;ApplyAppearance();}
        themeBox.SelectionChanged+=(s,e)=>Changed();materialBox.SelectionChanged+=(s,e)=>Changed();fontBox.SelectionChanged+=(s,e)=>Changed();motionBox.SelectionChanged+=(s,e)=>Changed();windowsAccent.Toggled+=(s,e)=>Changed();accentPicker.ColorChanged+=(s,e)=>Changed();fontSizeBox.ValueChanged+=(s,e)=>Changed();
        return CenteredPage(panel);
    }
    static Grid Setting(string title,string description,FrameworkElement control)
    {
        var row=new Grid{ColumnSpacing=28,Padding=new Thickness(0,8,0,8)};row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});row.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});row.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});var name=Text(title);name.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;var desc=Text(description,12);desc.Opacity=.7;var labels=Stack(name,desc);row.Children.Add(labels);Grid.SetColumn(control,1);row.Children.Add(control);
        row.SizeChanged+=(s,e)=>{bool narrow=e.NewSize.Width<620;Grid.SetColumn(control,narrow?0:1);Grid.SetRow(control,narrow?1:0);Grid.SetColumnSpan(control,narrow?2:1);Grid.SetColumnSpan(labels,narrow?2:1);control.HorizontalAlignment=narrow?(double.IsNaN(control.Width)?HorizontalAlignment.Stretch:HorizontalAlignment.Left):HorizontalAlignment.Right;control.Margin=new Thickness(0,narrow?12:0,0,0);};return row;
    }
    static Color ParseColor(string value){try{value=value.TrimStart('#');return Color.FromArgb(255,Convert.ToByte(value.Substring(0,2),16),Convert.ToByte(value.Substring(2,2),16),Convert.ToByte(value.Substring(4,2),16));}catch{return Color.FromArgb(255,0,120,212);}}
    static string Hex(Color color)=>$"#{color.R:X2}{color.G:X2}{color.B:X2}";
    static Color Shade(Color color,double amount){byte Mix(byte component)=>(byte)Math.Clamp(amount>=0?component+(255-component)*amount:component*(1+amount),0,255);return Color.FromArgb(255,Mix(color.R),Mix(color.G),Mix(color.B));}
    void ApplyAppearance(bool save=true,bool refreshTheme=true)
    {
        var requested=appearance.Theme switch{"Light"=>ElementTheme.Light,"Dark"=>ElementTheme.Dark,_=>ElementTheme.Default};
        Root.RequestedTheme=requested;
        foreach(var page in pages)page.RequestedTheme=requested;
        if(appearance.Material=="Acrylic"){
            if(SystemBackdrop is not TunableAcrylicBackdrop){acrylicBackdrop=new TunableAcrylicBackdrop();acrylicBackdrop.StateChanged+=()=>DispatcherQueue.TryEnqueue(()=>{if(!closing)UpdateAcrylicControls();});acrylicBackdrop.Configure(appearance);SystemBackdrop=acrylicBackdrop;}
            else{acrylicBackdrop=(TunableAcrylicBackdrop)SystemBackdrop;acrylicBackdrop.Configure(appearance);}
        }else if(appearance.Material=="Solid"){SystemBackdrop=null;acrylicBackdrop=null;}
        else{if(SystemBackdrop is not MicaBackdrop)SystemBackdrop=new MicaBackdrop();acrylicBackdrop=null;}
        bool solid=appearance.Material=="Solid"||(appearance.Material=="Acrylic"&&!Microsoft.UI.Composition.SystemBackdrops.DesktopAcrylicController.IsSupported());
        Color solidColor=Root.ActualTheme==ElementTheme.Dark?Color.FromArgb(255,32,32,32):Color.FromArgb(255,243,243,243);
        if(solid&&appearance.Material=="Acrylic"&&appearance.AcrylicCustom&&!appearance.AcrylicThemeFallback&&!accessibility.HighContrast)solidColor=ParseColor(appearance.AcrylicFallbackColor);
        Root.Background=solid?new SolidColorBrush(solidColor):new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        if(!accessibility.HighContrast){
            var accent=appearance.WindowsAccent?systemColors.GetColorValue(UIColorType.Accent):ParseColor(appearance.Accent);
            Root.Resources["SystemAccentColor"]=accent;
            foreach(var pair in new[]{("SystemAccentColorLight1",.25),("SystemAccentColorLight2",.5),("SystemAccentColorLight3",.75),("SystemAccentColorDark1",-.2),("SystemAccentColorDark2",-.4),("SystemAccentColorDark3",-.6)})Root.Resources[pair.Item1]=Shade(accent,pair.Item2);
            Root.Resources["AccentFillColorDefaultBrush"]=new SolidColorBrush(accent);Root.Resources["AccentFillColorSecondaryBrush"]=new SolidColorBrush(Shade(accent,.12));Root.Resources["AccentFillColorTertiaryBrush"]=new SolidColorBrush(Shade(accent,-.12));
            bool darkText=(accent.R*.299+accent.G*.587+accent.B*.114)>155;
            Root.Resources["TextOnAccentFillColorPrimaryBrush"]=new SolidColorBrush(darkText?Microsoft.UI.Colors.Black:Microsoft.UI.Colors.White);
        }else{foreach(string key in new[]{"SystemAccentColor","SystemAccentColorLight1","SystemAccentColorLight2","SystemAccentColorLight3","SystemAccentColorDark1","SystemAccentColorDark2","SystemAccentColorDark3","AccentFillColorDefaultBrush","AccentFillColorSecondaryBrush","AccentFillColorTertiaryBrush","TextOnAccentFillColorPrimaryBrush"})Root.Resources.Remove(key);}
        Root.Resources["ContentControlThemeFontFamily"]=new FontFamily(appearance.Font??"Segoe UI Variable");Root.Resources["ControlContentThemeFontSize"]=Math.Clamp(appearance.FontSize,12,22);
        Tabs.FontFamily=new FontFamily(appearance.Font??"Segoe UI Variable");Tabs.FontSize=Math.Clamp(appearance.FontSize,12,22);
        bool motion=appearance.ReduceMotion=="Off" || (appearance.ReduceMotion=="System" && systemColors.AnimationsEnabled);
        foreach(var page in pages)page.Transitions=motion?new Microsoft.UI.Xaml.Media.Animation.TransitionCollection{new Microsoft.UI.Xaml.Media.Animation.EntranceThemeTransition()}:new Microsoft.UI.Xaml.Media.Animation.TransitionCollection();
        // Refresh theme-resource consumers when switching the local accent.
        if(save){if(refreshTheme){Root.RequestedTheme=Root.ActualTheme==ElementTheme.Dark?ElementTheme.Light:ElementTheme.Dark;Root.RequestedTheme=requested;}File.WriteAllText(Path.Combine(Backend.Root,"appearance-settings.json"),JsonSerializer.Serialize(appearance,Backend.Json));appearanceStatus.Text="Appearance saved. Changes apply across every tab.";}
        UpdateCaption();
        RefreshCardSurfaces();UpdateAcrylicControls();
    }
    void UpdateCaption(){if(appWindow==null)return;bool dark=Root.ActualTheme==ElementTheme.Dark;appWindow.TitleBar.ButtonBackgroundColor=Microsoft.UI.Colors.Transparent;appWindow.TitleBar.ButtonInactiveBackgroundColor=Microsoft.UI.Colors.Transparent;appWindow.TitleBar.ButtonForegroundColor=dark?Microsoft.UI.Colors.White:Microsoft.UI.Colors.Black;appWindow.TitleBar.ButtonInactiveForegroundColor=dark?Microsoft.UI.Colors.Gray:Microsoft.UI.Colors.DimGray;if(appearance.Material=="Solid")Root.Background=new SolidColorBrush(dark?Color.FromArgb(255,32,32,32):Color.FromArgb(255,243,243,243));}
    void SyncAppearanceControls(){updatingAppearance=true;themeBox.SelectedItem=appearance.Theme;materialBox.SelectedItem=appearance.Material;windowsAccent.IsOn=appearance.WindowsAccent;accentPicker.Color=ParseColor(appearance.Accent);accentPicker.Visibility=appearance.WindowsAccent?Visibility.Collapsed:Visibility.Visible;fontBox.SelectedItem=appearance.Font;fontSizeBox.Value=appearance.FontSize;motionBox.SelectedItem=appearance.ReduceMotion;SyncAcrylicControls();updatingAppearance=false;}
}
