#requires -Version 5.1
<#
.SYNOPSIS
Plays a short original tone demo, or a supplied MIDI file as single-note beeps.
.EXAMPLE
.\Play-Tones.ps1
.EXAMPLE
.\Play-Tones.ps1 -MidiFile '.\Rush E.mid' -Speed 0.8
.EXAMPLE
.\Play-Tones.ps1 -MidiFile '.\Rush E.mid' -DescribeOnly
#>
[CmdletBinding()]
param(
    [string] $MidiFile,
    [ValidateRange(0.1, 4.0)] [double] $Speed = 1.0,
    [ValidateRange(-36, 36)] [int] $Transpose = 0,
    [ValidateRange(0, 3600)] [double] $MaxSeconds = 0,
    [switch] $DescribeOnly
)

$ErrorActionPreference = 'Stop'

if (-not ('ToneMusic.Reader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

namespace ToneMusic {
    public class Slice {
        public int Note;
        public double Milliseconds;
        public Slice(int note, double milliseconds) { Note=note; Milliseconds=milliseconds; }
    }
    class Event {
        public long Tick;
        public int Kind, Note, Value, Channel, Order;
    }
    public static class Reader {
        static int U16(BinaryReader r) { return (r.ReadByte()<<8)|r.ReadByte(); }
        static int U32(BinaryReader r) {
            uint n=((uint)r.ReadByte()<<24)|((uint)r.ReadByte()<<16)|((uint)r.ReadByte()<<8)|r.ReadByte();
            if(n>int.MaxValue) throw new InvalidDataException("MIDI chunk too large.");
            return (int)n;
        }
        static int Variable(BinaryReader r, long end) {
            int value=0;
            for(int i=0;i<4;i++) {
                if(r.BaseStream.Position>=end) throw new InvalidDataException("Truncated MIDI number.");
                int b=r.ReadByte(); value=(value<<7)|(b&127);
                if((b&128)==0) return value;
            }
            throw new InvalidDataException("Invalid MIDI variable-length number.");
        }
        static void Skip(BinaryReader r, int count, long end) {
            if(count<0 || count>end-r.BaseStream.Position) throw new InvalidDataException("Truncated MIDI event.");
            r.BaseStream.Position+=count;
        }
        public static Slice[] Read(string path) {
            var events=new List<Event>(); int order=0, division;
            using(var r=new BinaryReader(File.OpenRead(path))) {
                if(Encoding.ASCII.GetString(r.ReadBytes(4))!="MThd") throw new InvalidDataException("Expected a standard .mid file.");
                int header=U32(r);
                if(header<6) throw new InvalidDataException("Invalid MIDI header.");
                int format=U16(r), tracks=U16(r); division=U16(r);
                if(format>1) throw new NotSupportedException("Only MIDI formats 0 and 1 are supported.");
                if(division==0 || (division&0x8000)!=0) throw new NotSupportedException("Requires ticks-per-quarter MIDI timing; SMPTE is unsupported.");
                Skip(r,header-6,r.BaseStream.Length);
                for(int track=0;track<tracks;track++) {
                    if(Encoding.ASCII.GetString(r.ReadBytes(4))!="MTrk") throw new InvalidDataException("Missing MIDI track.");
                    int length=U32(r); long end=r.BaseStream.Position+length;
                    if(end>r.BaseStream.Length) throw new InvalidDataException("Truncated MIDI track.");
                    long tick=0; int running=0;
                    while(r.BaseStream.Position<end) {
                        tick+=Variable(r,end);
                        int status=r.ReadByte();
                        if(status<128) {
                            if(running==0) throw new InvalidDataException("Missing MIDI running status.");
                            r.BaseStream.Position--; status=running;
                        } else if(status<240) running=status;
                        if(status==255) {
                            // Meta events do not replace the last channel running status.
                            int type=r.ReadByte(), size=Variable(r,end);
                            if(type==81 && size==3) {
                                if(end-r.BaseStream.Position<3) throw new InvalidDataException("Truncated tempo.");
                                int tempo=(r.ReadByte()<<16)|(r.ReadByte()<<8)|r.ReadByte();
                                if(tempo<=0) throw new InvalidDataException("Invalid MIDI tempo.");
                                events.Add(new Event { Tick=tick, Kind=2, Value=tempo, Order=order++ });
                            } else Skip(r,size,end);
                            if(type==47) { r.BaseStream.Position=end; break; }
                        } else if(status==240 || status==247) {
                            running=0; Skip(r,Variable(r,end),end);
                        } else if(status>=128 && status<240) {
                            int kind=status&240, channel=status&15;
                            int size=(kind==192 || kind==208)?1:2;
                            if(end-r.BaseStream.Position<size) throw new InvalidDataException("Truncated channel event.");
                            int a=r.ReadByte(), b=size==2?r.ReadByte():0;
                            if(a>127 || b>127) throw new InvalidDataException("Invalid MIDI data byte.");
                            if((kind==128 || kind==144) && channel!=9)
                                events.Add(new Event { Tick=tick, Kind=(kind==144 && b>0)?1:0, Note=a, Channel=channel, Order=order++ });
                        } else throw new InvalidDataException("Unsupported MIDI status.");
                        if(r.BaseStream.Position>end) throw new InvalidDataException("Event extends past track.");
                    }
                    events.Add(new Event { Tick=tick, Kind=3, Order=order++ });
                }
            }
            events.Sort(delegate(Event a, Event b) { int c=a.Tick.CompareTo(b.Tick); return c!=0?c:a.Order.CompareTo(b.Order); });
            var result=new List<Slice>(); var active=new int[16,128];
            long previous=0; int micros=500000;
            var onsets=new HashSet<int>();
            foreach(var e in events) {
                if(e.Tick>previous) {
                    int highest=-1;
                    for(int n=127;n>=0 && highest<0;n--)
                        for(int c=0;c<16;c++) if(active[c,n]>0) { highest=n; break; }
                    double duration=(e.Tick-previous)*(double)micros/division/1000.0;
                    // Other voices and tempo events must not restart a held tone.
                    // Preserve actual repeated note attacks, even at the same pitch.
                    if(result.Count>0 && result[result.Count-1].Note==highest &&
                       (highest<0 || !onsets.Contains(highest)))
                        result[result.Count-1].Milliseconds+=duration;
                    else result.Add(new Slice(highest,duration));
                    previous=e.Tick;
                    onsets.Clear();
                }
                if(e.Kind==2) micros=e.Value;
                else if(e.Kind==1) { active[e.Channel,e.Note]++; onsets.Add(e.Note); }
                else if(e.Kind==0 && active[e.Channel,e.Note]>0) active[e.Channel,e.Note]--;
            }
            return result.ToArray();
        }
    }
}
'@
}

if ($MidiFile) {
    $resolvedMidi = (Resolve-Path -LiteralPath $MidiFile).ProviderPath
    $slices = [ToneMusic.Reader]::Read($resolvedMidi)
    $title = [IO.Path]::GetFileName($resolvedMidi)
} else {
    # Original E-minor arpeggio demonstration, not a Rush E transcription.
    $notes = @(64, 67, 71, 76, 71, 67, 64, -1, 66, 69, 72, 78, 72, 69, 66, -1,
               64, 67, 71, 76, 79, 76, 71, 67, 64)
    $slices = @($notes | ForEach-Object { [ToneMusic.Slice]::new($_, 140) })
    $title = 'Original E-minor tone demo (not Rush E)'
}

$totalMs = 0.0
$toneCount = 0
foreach ($slice in $slices) {
    $totalMs += $slice.Milliseconds / $Speed
    if ($slice.Note -ge 0) { $toneCount++ }
}
Write-Host $title
Write-Host ('{0} tone segments; {1:N2} seconds; speed {2}x; transpose {3} semitones.' -f $toneCount, ($totalMs / 1000), $Speed, $Transpose)
if ($MaxSeconds -gt 0) { Write-Host ('Preview limited to {0} seconds of score time.' -f $MaxSeconds) }
Write-Host 'MIDI chords use the highest active note. Drums, sustain, instruments and velocity are ignored.'
if ($DescribeOnly) { return }
if ($env:OS -ne 'Windows_NT') { throw 'Console.Beep playback requires Windows.' }
Write-Host 'Playing through the Windows default sound device. Press Ctrl+C to stop.'

# One Beep call per complete note. Repeated short calls restart the sound;
# deadline catch-up can truncate or skip notes when Windows calls run late.
# Preserve score durations instead. Device/call overhead may lengthen playback.
$playedMs = 0.0
foreach ($slice in $slices) {
        $durationMs = $slice.Milliseconds / $Speed
        if ($MaxSeconds -gt 0) {
            $durationMs = [Math]::Min($durationMs, $MaxSeconds * 1000 - $playedMs)
            if ($durationMs -le 0) { break }
        }
        $playedMs += $durationMs
        $duration = [int][Math]::Max(1, [Math]::Round($durationMs))
        $frequency = 0
        if ($slice.Note -ge 0) {
            $frequency = [int][Math]::Round(440 * [Math]::Pow(2, ($slice.Note + $Transpose - 69) / 12.0))
            if ($frequency -lt 37 -or $frequency -gt 32767) { $frequency = 0 }
        }
        if ($frequency -gt 0) { [Console]::Beep($frequency, $duration) }
        else { Start-Sleep -Milliseconds $duration }
}
