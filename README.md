# PowerShell Orchestra

A Windows music player that turns MIDI arrangements into electronic tones while displaying the parts across PowerShell windows and connected screens. It includes a WinUI 3 library, a MIDI catalogue, an audio-to-MIDI converter and appearance settings.

This is an early source release. It does not include third-party songs, recordings, conversion models or user data. Import a MIDI you have permission to use through **My Songs**, search the online MIDI catalogue, or convert a local audio file. Spotify search helps identify a track; it does not download or convert Spotify audio.

## Build and run

On Windows 10/11 x64, install the .NET 8 SDK and Windows PowerShell 5.1. From the project root run:

```powershell
./WinUI/Build-App.ps1
./App/PowerShellOrchestra.exe
```

The build restores the Windows App SDK packages and publishes the app to `App`. It uses the .NET 8 runtime installed on the computer. For the converter, install Python 3.11 and run `./Converter/Setup-Converter.ps1`; this creates a project-local environment and downloads its dependencies and model. Conversion can be slow and the quality varies with the source.

Select **My Songs** to import or play MIDI files, **Online MIDI** to search and preview arrangements, and **Converter** to work with local recordings. The piano-roll and graphical display styles are selectable in My Songs. The screen count can be set there too.

## Development

WinUI source is in `WinUI`; the playback engine and PowerShell windows are in the root. `Catalogue` contains the MIDI search backend; `Converter` contains the local transcription pipeline. User-created content, browser profiles, models and build output are excluded by `.gitignore`.

This project is under development. Spotify integration and graphical playback need further real-world testing. No license for redistribution of this source has yet been selected; third-party packages and any imported content have their own terms.
