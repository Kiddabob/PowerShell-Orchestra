using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace PowerShellOrchestra;

// Spotify supplies the track reference only. Audio always comes from a file
// explicitly selected by the user; neither embeds nor previews are transcribed.
internal sealed record SpotifyReference(string Url,string Title,string Artist);
internal static class SpotifyService
{
    static readonly HttpClient client=new(){Timeout=TimeSpan.FromSeconds(20),MaxResponseContentBufferSize=256*1024};
    internal static string TrackUrl(string value)
    {
        value=value?.Trim()??"";
        var uriMatch=Regex.Match(value,@"^spotify:track:([A-Za-z0-9]{22})$");
        if(uriMatch.Success)return "https://open.spotify.com/track/"+uriMatch.Groups[1].Value;
        if(!Uri.TryCreate(value,UriKind.Absolute,out var uri)||uri.Scheme!="https"||uri.Host!="open.spotify.com"||!uri.IsDefaultPort||uri.UserInfo!="")return null;
        var match=Regex.Match(uri.AbsolutePath,@"^/(?:intl-[a-zA-Z-]+/)?track/([A-Za-z0-9]{22})/?$");
        return match.Success?"https://open.spotify.com/track/"+match.Groups[1].Value:null;
    }
    internal static string SearchUrl(string query)=>"https://open.spotify.com/search/"+Uri.EscapeDataString(query.Trim());
    internal static (string Title,string Artist) DocumentTitle(string title)
    {
        var match=Regex.Match(title??"",@"^(.*?) - (?:song and lyrics|song) by (.*?) \| Spotify$");
        return match.Success?(match.Groups[1].Value.Trim(),match.Groups[2].Value.Trim()):("","");
    }
    internal static async Task<string> FetchTitle(string trackUrl,CancellationToken token)
    {
        string canonical=TrackUrl(trackUrl)??throw new ArgumentException("Use a Spotify song link.");
        string json=await client.GetStringAsync("https://open.spotify.com/oembed?url="+Uri.EscapeDataString(canonical),token);
        using var data=JsonDocument.Parse(json);
        string title=data.RootElement.GetProperty("title").GetString()?.Trim();
        if(string.IsNullOrWhiteSpace(title))throw new InvalidOperationException("Spotify did not return a song title.");
        return title;
    }
    internal static string FileTitle(SpotifyReference reference)
    {
        string name=string.IsNullOrWhiteSpace(reference.Artist)?reference.Title:reference.Artist+" - "+reference.Title;
        name=new string(name.Select(c=>Path.GetInvalidFileNameChars().Contains(c)?'_':c).ToArray()).Trim().TrimEnd('.');
        if(name.Length>140)name=name[..140].TrimEnd('.',' ');
        return string.IsNullOrWhiteSpace(name)?"Spotify song":name;
    }
}
