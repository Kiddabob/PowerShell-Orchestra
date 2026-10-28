using Microsoft.UI.Xaml;
namespace PowerShellOrchestra;
public partial class App : Application
{
    public static MainWindow Main;
    public App(){InitializeComponent();UnhandledException+=(s,e)=>{Backend.Log(e.Exception.ToString());};}
    protected override void OnLaunched(LaunchActivatedEventArgs args){Main=new MainWindow();Main.Activate();Main.AppWindow.Show();}
}
