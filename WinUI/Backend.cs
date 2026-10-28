using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
namespace PowerShellOrchestra;
public class Song {public string Id{get;set;} public string Title{get;set;} public string Midi{get;set;} public string Icon{get;set;} public string Theme{get;set;} public bool CanDelete{get;set;} public string SourceUrl{get;set;}}
public class OnlineSong {public string Title{get;set;} public string Artist{get;set;} public string Provider{get;set;} public string SourceUrl{get;set;} public string DownloadUrl{get;set;} public override string ToString()=>Title;}
public class SearchResult {public List<OnlineSong> Items{get;set;}=new();public List<string> Warnings{get;set;}=new();public bool HasMore{get;set;}}
public class PreviewResult {public string Wave{get;set;} public double Duration{get;set;} public int Notes{get;set;} public int Parts{get;set;}}
public class AddResult {public string Title{get;set;} public bool AlreadyAdded{get;set;} public string Midi{get;set;}}
public class MixPart {public string Id{get;set;} public string Name{get;set;} public int Level{get;set;}}
public class Mix {public int Master{get;set;} public List<MixPart> Parts{get;set;}=new();}
public static class Backend
{
    public static readonly JsonSerializerOptions Json=new(){PropertyNameCaseInsensitive=true,WriteIndented=true};
    public static readonly string Root=FindRoot();
    public static readonly string PowerShell=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe");
    static string FindRoot(){var directory=new DirectoryInfo(AppContext.BaseDirectory);while(directory!=null){if(File.Exists(Path.Combine(directory.FullName,"OrchestraLibrary.ps1")))return directory.FullName;directory=directory.Parent;}return Environment.CurrentDirectory;}
    public static void Log(string text){try{Directory.CreateDirectory(Path.Combine(Root,"WinUI","Logs"));File.AppendAllText(Path.Combine(Root,"WinUI","Logs","app.log"),DateTimeOffset.Now+" "+text+Environment.NewLine);}catch{}}
    public static async Task<T> Call<T>(object request,CancellationToken token=default)
    {
        string folder=Path.Combine(Root,"WinUI","Jobs",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);
        string input=Path.Combine(folder,"input.json"),output=Path.Combine(folder,"output.json");
        try{
            await File.WriteAllTextAsync(input,JsonSerializer.Serialize(request,Json),token);
            var info=new ProcessStartInfo(PowerShell){UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true,RedirectStandardOutput=true};
            foreach(var arg in new[]{"-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",Path.Combine(Root,"WinUI","Bridge.ps1"),"-RequestPath",input,"-ResponsePath",output})info.ArgumentList.Add(arg);
            using var process=Process.Start(info);var errors=process.StandardError.ReadToEndAsync();var stdout=process.StandardOutput.ReadToEndAsync();
            using var registration=token.Register(()=>{try{if(!process.HasExited)process.Kill(true);}catch{}});
            await process.WaitForExitAsync(token);string error=await errors;await stdout;
            if(!File.Exists(output))throw new InvalidOperationException(string.IsNullOrWhiteSpace(error)?"The Orchestra worker did not finish.":error.Trim());
            using var document=JsonDocument.Parse(await File.ReadAllTextAsync(output,token));var response=document.RootElement;
            if(!response.GetProperty("Ok").GetBoolean())throw new InvalidOperationException(response.GetProperty("Error").GetString());
            return response.GetProperty("Result").Deserialize<T>(Json);
        }finally{try{Directory.Delete(folder,true);}catch{}}
    }
    public static void LaunchSong(string midi,string title){var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","conhost.exe")){UseShellExecute=true};foreach(var arg in new[]{"powershell.exe","-NoLogo","-NoProfile","-NoExit","-ExecutionPolicy","Bypass","-File",Path.Combine(Root,"Play-RushE-Layers.ps1"),"-MidiFile",midi,"-SongTitle",title})info.ArgumentList.Add(arg);Process.Start(info);}
    public static void OpenUrl(string url){if(!Uri.TryCreate(url,UriKind.Absolute,out var uri)||uri.Scheme!="https")throw new InvalidOperationException("Expected a secure website address.");Process.Start(new ProcessStartInfo(url){UseShellExecute=true});}
}
