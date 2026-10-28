using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
namespace PowerShellOrchestra;

// A single-window SystemBackdrop, using the Windows compositor's Acrylic
// controller. Windows still owns blur, accessibility and transparency fallback.
public class TunableAcrylicBackdrop : SystemBackdrop
{
    DesktopAcrylicController controller;
    bool connected;
    AppearanceSettings settings=new();
    public bool Connected=>controller!=null;
    public double ActualTintOpacity=>controller?.TintOpacity??0;
    public double ActualLuminosityOpacity=>controller?.LuminosityOpacity??0;
    public Color ActualTint=>controller?.TintColor??Microsoft.UI.Colors.Transparent;
    public Color ActualFallback=>controller?.FallbackColor??Microsoft.UI.Colors.Transparent;
    public string ActualKind=>controller?.Kind.ToString()??"Unavailable";
    public string State=>controller?.State.ToString()??"Unavailable";
    public bool UsingWindowsDefaults=>!settings.AcrylicCustom;
    public event Action StateChanged;
    public void Configure(AppearanceSettings value){settings=value;Apply();}
    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target,XamlRoot root)
    {
        connected=true;
        base.OnTargetConnected(target,root);
        if(!DesktopAcrylicController.IsSupported())return;
        controller=new DesktopAcrylicController();controller.StateChanged+=(s,e)=>StateChanged?.Invoke();controller.SetSystemBackdropConfiguration(GetDefaultSystemBackdropConfiguration(target,root));controller.AddSystemBackdropTarget(target);Apply();
    }
    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        connected=false;
        base.OnTargetDisconnected(target);
        if(controller!=null){controller.RemoveSystemBackdropTarget(target);controller.Dispose();controller=null;}
    }
    protected override void OnDefaultSystemBackdropConfigurationChanged(ICompositionSupportsSystemBackdrop target,XamlRoot root)
    {
        // The controller already holds the default configuration instance.
        // Its updated activation/theme policy is therefore applied directly;
        // only our theme-derived custom values need to be refreshed here.
        if(connected)Apply();
    }
    static double Unit(double value)=>double.IsFinite(value)?Math.Clamp(value/100,0,1):0;
    static Color Parse(string value,Color fallback){try{value=value.TrimStart('#');return Color.FromArgb(255,Convert.ToByte(value.Substring(0,2),16),Convert.ToByte(value.Substring(2,2),16),Convert.ToByte(value.Substring(4,2),16));}catch{return fallback;}}
    void Apply()
    {
        if(controller==null)return;
        controller.Kind=settings.AcrylicKind=="Thin"?DesktopAcrylicKind.Thin:DesktopAcrylicKind.Base;
        // Reset first so theme-aware Windows defaults remain the basis for
        // both the default material and a custom material's automatic colours.
        controller.ResetProperties();
        if(!settings.AcrylicCustom)return;
        Color tint=settings.AcrylicThemeTint?controller.TintColor:Parse(settings.AcrylicTintColor,controller.TintColor);
        double light=1-Unit(settings.AcrylicDarkness);
        controller.TintColor=Color.FromArgb(255,(byte)Math.Round(tint.R*light),(byte)Math.Round(tint.G*light),(byte)Math.Round(tint.B*light));
        controller.TintOpacity=(float)Unit(settings.AcrylicTintOpacity);
        controller.LuminosityOpacity=(float)Unit(settings.AcrylicLuminosityOpacity);
        if(!settings.AcrylicThemeFallback)controller.FallbackColor=Parse(settings.AcrylicFallbackColor,controller.FallbackColor);
    }
}
