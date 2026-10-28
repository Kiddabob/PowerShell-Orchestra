using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
namespace PowerShellOrchestra;
public partial class MainWindow
{
    static double Percent(double value)=>double.IsFinite(value)?Math.Clamp(value,0,100):0;
    FrameworkElement BuildAcrylicSettings()
    {
        acrylicDefaults=new ToggleSwitch{Header="Use Windows Acrylic defaults",IsOn=!appearance.AcrylicCustom};
        acrylicKind=Choices("Standard","Thin");acrylicKind.SelectedIndex=appearance.AcrylicKind=="Thin"?1:0;
        acrylicDarkness=MaterialSlider("Tint darkness",appearance.AcrylicDarkness);
        acrylicOpacity=MaterialSlider("Tint opacity",appearance.AcrylicTintOpacity);
        acrylicLuminosity=MaterialSlider("Luminosity opacity",appearance.AcrylicLuminosityOpacity);
        acrylicPanels=MaterialSlider("Content panel opacity",appearance.AcrylicPanelOpacity);
        acrylicThemeTint=new ToggleSwitch{Header="Follow theme tint colour",IsOn=appearance.AcrylicThemeTint};
        acrylicThemeFallback=new ToggleSwitch{Header="Follow theme fallback colour",IsOn=appearance.AcrylicThemeFallback};
        acrylicTint=new ColorPicker{Color=ParseColor(appearance.AcrylicTintColor),IsAlphaEnabled=false,MaxWidth=420,HorizontalAlignment=HorizontalAlignment.Left};
        acrylicFallback=new ColorPicker{Color=ParseColor(appearance.AcrylicFallbackColor),IsAlphaEnabled=false,MaxWidth=420,HorizontalAlignment=HorizontalAlignment.Left};
        acrylicControls=Stack(
            Setting("Tint darkness","Darken the tint without changing the app's light/dark text theme.",acrylicDarkness),
            Setting("Tint opacity","How strongly the tint covers the glass. Lower values show more behind it.",acrylicOpacity),
            Setting("Luminosity opacity","How strongly the material's luminosity layer covers the background.",acrylicLuminosity),
            Setting("Content panel opacity","Lower this to reveal more glass through cards and settings panels.",acrylicPanels),
            acrylicThemeTint,acrylicTint,acrylicThemeFallback,acrylicFallback);
        acrylicStatus=Text("Windows controls the blur itself. These controls tune the native tint and luminosity layers.",12);
        var reset=Button("Reset Acrylic to Windows defaults",()=>{
            appearance.AcrylicCustom=false;appearance.AcrylicKind="Base";appearance.AcrylicDarkness=0;appearance.AcrylicTintOpacity=50;appearance.AcrylicLuminosityOpacity=70;appearance.AcrylicPanelOpacity=90;appearance.AcrylicThemeTint=appearance.AcrylicThemeFallback=true;appearance.AcrylicTintColor="#FFFFFF";appearance.AcrylicFallbackColor="#202020";
            updatingAppearance=true;SyncAcrylicControls();updatingAppearance=false;ApplyAppearance(refreshTheme:false);
        });
        acrylicSection=new Expander{Header="Acrylic tuning",HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,VerticalContentAlignment=VerticalAlignment.Top,IsExpanded=true,Content=Stack(acrylicDefaults,Setting("Material variant","Standard glass or the lighter Thin variant.",acrylicKind),acrylicControls,acrylicStatus,reset)};
        void Changed(){
            if(initializing||updatingAppearance)return;
            appearance.AcrylicCustom=!acrylicDefaults.IsOn;appearance.AcrylicKind=acrylicKind.SelectedIndex==1?"Thin":"Base";
            appearance.AcrylicDarkness=acrylicDarkness.Value;appearance.AcrylicTintOpacity=acrylicOpacity.Value;appearance.AcrylicLuminosityOpacity=acrylicLuminosity.Value;appearance.AcrylicPanelOpacity=acrylicPanels.Value;
            appearance.AcrylicThemeTint=acrylicThemeTint.IsOn;appearance.AcrylicThemeFallback=acrylicThemeFallback.IsOn;appearance.AcrylicTintColor=Hex(acrylicTint.Color);appearance.AcrylicFallbackColor=Hex(acrylicFallback.Color);
            ApplyAppearance(refreshTheme:false);
        }
        acrylicDefaults.Toggled+=(s,e)=>Changed();acrylicKind.SelectionChanged+=(s,e)=>Changed();
        foreach(var slider in new[]{acrylicDarkness,acrylicOpacity,acrylicLuminosity,acrylicPanels})slider.ValueChanged+=(s,e)=>Changed();
        acrylicThemeTint.Toggled+=(s,e)=>Changed();acrylicThemeFallback.Toggled+=(s,e)=>Changed();acrylicTint.ColorChanged+=(s,e)=>Changed();acrylicFallback.ColorChanged+=(s,e)=>Changed();
        UpdateAcrylicControls();return acrylicSection;
    }
    static Slider MaterialSlider(string title,double value){var slider=new Slider{Minimum=0,Maximum=100,Value=Percent(value),StepFrequency=1,Width=260,Header=Math.Round(Percent(value))+"%"};AutomationPropertiesName(slider,title);slider.ValueChanged+=(s,e)=>slider.Header=Math.Round(e.NewValue)+"%";return slider;}
    void SyncAcrylicControls(){
        if(acrylicDefaults==null)return;
        acrylicDefaults.IsOn=!appearance.AcrylicCustom;acrylicKind.SelectedIndex=appearance.AcrylicKind=="Thin"?1:0;acrylicDarkness.Value=Percent(appearance.AcrylicDarkness);acrylicOpacity.Value=Percent(appearance.AcrylicTintOpacity);acrylicLuminosity.Value=Percent(appearance.AcrylicLuminosityOpacity);acrylicPanels.Value=Percent(appearance.AcrylicPanelOpacity);
        acrylicThemeTint.IsOn=appearance.AcrylicThemeTint;acrylicThemeFallback.IsOn=appearance.AcrylicThemeFallback;acrylicTint.Color=ParseColor(appearance.AcrylicTintColor);acrylicFallback.Color=ParseColor(appearance.AcrylicFallbackColor);
    }
    void UpdateAcrylicControls(){
        if(acrylicSection==null)return;
        acrylicSection.Visibility=appearance.Material=="Acrylic"?Visibility.Visible:Visibility.Collapsed;
        foreach(var control in new Control[]{acrylicDarkness,acrylicOpacity,acrylicLuminosity,acrylicPanels,acrylicThemeTint,acrylicThemeFallback,acrylicTint,acrylicFallback})control.IsEnabled=appearance.AcrylicCustom;
        acrylicControls.Opacity=appearance.AcrylicCustom?1:.6;acrylicTint.Visibility=appearance.AcrylicThemeTint?Visibility.Collapsed:Visibility.Visible;acrylicFallback.Visibility=appearance.AcrylicThemeFallback?Visibility.Collapsed:Visibility.Visible;
        if(acrylicBackdrop?.Connected==true){
            if(!appearance.AcrylicCustom){bool previous=updatingAppearance;updatingAppearance=true;acrylicOpacity.Value=acrylicBackdrop.ActualTintOpacity*100;acrylicLuminosity.Value=acrylicBackdrop.ActualLuminosityOpacity*100;updatingAppearance=previous;}
            acrylicStatus.Text=acrylicBackdrop.State=="Active"?"Live Acrylic tuning. Windows controls blur strength; tint and luminosity update immediately.":"Windows is showing its fallback material right now. Your tuning applies when Acrylic is available.";
        }
        else if(appearance.Material=="Acrylic")acrylicStatus.Text="Windows cannot render Acrylic here, so the solid fallback colour is shown. Your tuning is saved.";
    }
}
