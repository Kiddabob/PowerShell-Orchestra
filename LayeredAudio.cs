using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LayeredMusic {
    public class Note {
        public int Track, Channel, Port, Pitch, Velocity, Layer;
        public string Part;
        public double StartMs, EndMs;
        public string MixId { get { return Track+":"+Port+":"+Channel; } }
        public string Name { get { return Names[Pitch%12]+(Pitch/12-1); } }
        public double Hertz { get { return 440*Math.Pow(2,(Pitch-69)/12.0); } }
        static readonly string[] Names={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};
    }
    public class Layer {
        public int Id, Track, Channel;
        public string Band, Title;
        public int NoteCount;
        public int CombinedVoices=1;
    }
    public class Score {
        public List<Note> Notes=new List<Note>();
        public List<Layer> Layers=new List<Layer>();
        public double DurationMs;
        public int SampleRate=22050;
        public double PeakBeforeScaling;
        public double ReferencePeak;
        public Dictionary<int,List<VolumePoint>> Volumes=new Dictionary<int,List<VolumePoint>>();
        public Dictionary<string,double> PartGains=new Dictionary<string,double>();
        public int IdealWindows;
    }
    public class VolumePoint {public double TimeMs,Gain,Previous;}
    class MidiEvent { public long Tick; public int Order, Track, Kind, Channel, Port, A, B; }
    class Voice {
        public int Track,Channel,Port,Number,Combined=1,LastPitch;
        public double EndMs;
        public string Band,Part;
        public List<Note> Notes=new List<Note>();
    }
    public static class Midi {
        static int U16(BinaryReader r) { return (r.ReadByte()<<8)|r.ReadByte(); }
        static int U32(BinaryReader r) {
            uint n=((uint)r.ReadByte()<<24)|((uint)r.ReadByte()<<16)|((uint)r.ReadByte()<<8)|r.ReadByte();
            if(n>int.MaxValue) throw new InvalidDataException("MIDI chunk too large."); return (int)n;
        }
        static int Var(BinaryReader r,long end) {
            int n=0;
            for(int i=0;i<4;i++) {
                if(r.BaseStream.Position>=end) throw new InvalidDataException("Truncated MIDI number.");
                int b=r.ReadByte(); n=(n<<7)|(b&127); if(b<128) return n;
            }
            throw new InvalidDataException("Invalid MIDI number.");
        }
        static byte[] Bytes(BinaryReader r,int n,long end) {
            if(n<0 || n>end-r.BaseStream.Position) throw new InvalidDataException("Truncated MIDI event.");
            return r.ReadBytes(n);
        }
        static long Key(int track,int port,int channel,int pitch) { return (long)track*524288+port*2048+channel*128+pitch; }
        public static Score Read(string path,double speed,int transpose,double maxSeconds) {
            return Read(path,speed,transpose,maxSeconds,24);
        }
        public static Score Read(string path,double speed,int transpose,double maxSeconds,int maxWindows) {
            if(maxWindows<3) throw new ArgumentOutOfRangeException("maxWindows");
            var events=new List<MidiEvent>(); var titles=new Dictionary<int,string>(); int division,order=0;
            using(var r=new BinaryReader(File.OpenRead(path))) {
                if(Encoding.ASCII.GetString(r.ReadBytes(4))!="MThd") throw new InvalidDataException("Not a standard MIDI file.");
                int header=U32(r); if(header<6) throw new InvalidDataException("Invalid MIDI header.");
                int format=U16(r),tracks=U16(r); division=U16(r);
                if(format>1 || division==0 || (division&32768)!=0) throw new NotSupportedException("Requires MIDI format 0/1 with ticks-per-quarter timing.");
                Bytes(r,header-6,r.BaseStream.Length);
                for(int t=0;t<tracks;t++) {
                    if(Encoding.ASCII.GetString(r.ReadBytes(4))!="MTrk") throw new InvalidDataException("Missing MIDI track.");
                    int length=U32(r); long end=r.BaseStream.Position+length;
                    if(end>r.BaseStream.Length) throw new InvalidDataException("Truncated MIDI track.");
                    long tick=0; int running=0,port=0;
                    while(r.BaseStream.Position<end) {
                        tick+=Var(r,end); int status=r.ReadByte();
                        if(status<128) { if(running==0) throw new InvalidDataException("Missing running status."); r.BaseStream.Position--; status=running; }
                        else if(status<240) running=status;
                        if(status==255) {
                            int type=r.ReadByte(),size=Var(r,end); byte[] data=Bytes(r,size,end);
                            if(type==3) titles[t]=Encoding.UTF8.GetString(data).Trim();
                            if(type==33 && size==1) port=data[0];
                            if(type==81 && size==3) {
                                int tempo=(data[0]<<16)|(data[1]<<8)|data[2];
                                if(tempo<=0) throw new InvalidDataException("Invalid MIDI tempo.");
                                events.Add(new MidiEvent { Tick=tick,Order=order++,Track=t,Kind=3,A=tempo });
                            }
                            if(type==47) { r.BaseStream.Position=end; break; }
                        } else if(status==240 || status==247) { running=0; Bytes(r,Var(r,end),end); }
                        else if(status>=128 && status<240) {
                            int kind=status&240,ch=status&15;
                            byte[] data=Bytes(r,(kind==192 || kind==208)?1:2,end);
                            if(data.Any(b=>b>127)) throw new InvalidDataException("Invalid MIDI data byte.");
                            if(ch!=9 && (kind==128 || kind==144 || kind==176))
                                events.Add(new MidiEvent { Tick=tick,Order=order++,Track=t,Channel=ch,Port=port,
                                    Kind=kind==176?2:((kind==144 && data[1]>0)?1:0),A=data[0],B=data[1] });
                        } else throw new InvalidDataException("Unsupported MIDI status.");
                    }
                    events.Add(new MidiEvent { Tick=tick,Order=order++,Kind=4 });
                }
            }
            events.Sort((a,b)=>a.Tick!=b.Tick?a.Tick.CompareTo(b.Tick):a.Order.CompareTo(b.Order));
            var score=new Score(); var active=new Dictionary<long,Queue<Note>>();
            var held=new List<Note>(); var sustain=new bool[4096]; long last=0; double now=0; int micros=500000;
            var channelVolume=Enumerable.Repeat(100,4096).ToArray();var expression=Enumerable.Repeat(127,4096).ToArray();
            foreach(var e in events) {
                now+=(e.Tick-last)*(double)micros/division/1000.0; last=e.Tick;
                if(e.Kind==3) { micros=e.A; continue; }
                long key=Key(e.Track,e.Port,e.Channel,e.A); int controller=e.Port*16+e.Channel;
                if(e.Kind==1) {
                    if(!score.Volumes.ContainsKey(controller))score.Volumes[controller]=new List<VolumePoint>{new VolumePoint{TimeMs=-10,Gain=100/127.0,Previous=100/127.0}};
                    var n=new Note { Track=e.Track,Channel=e.Channel,Port=e.Port,Pitch=e.A,Velocity=e.B,StartMs=now,EndMs=-1 };
                    score.Notes.Add(n);
                    if(!active.ContainsKey(key)) active[key]=new Queue<Note>(); active[key].Enqueue(n);
                } else if(e.Kind==0 && active.ContainsKey(key) && active[key].Count>0) {
                    var n=active[key].Dequeue(); if(sustain[controller]) held.Add(n); else n.EndMs=now;
                } else if(e.Kind==2) {
                    if(e.A==7 || e.A==11 || e.A==121){
                        if(e.A==7)channelVolume[controller]=e.B;
                        if(e.A==11)expression[controller]=e.B;
                        if(e.A==121)expression[controller]=127;
                        if(!score.Volumes.ContainsKey(controller))score.Volumes[controller]=new List<VolumePoint>{new VolumePoint{TimeMs=-10,Gain=100/127.0,Previous=100/127.0}};
                        var points=score.Volumes[controller];double gain=channelVolume[controller]/127.0*expression[controller]/127.0;
                        var previous=points[points.Count-1];double at=now/speed;
                        double before=previous.Previous+(previous.Gain-previous.Previous)*Math.Min(1,Math.Max(0,(at-previous.TimeMs)/5));
                        points.Add(new VolumePoint{TimeMs=at,Gain=gain,Previous=at==0?gain:before});
                    }
                    if(e.A==64) {
                        sustain[controller]=e.B>=64;
                        if(!sustain[controller]) foreach(var n in held.Where(n=>n.Channel==e.Channel && n.Port==e.Port).ToArray()) { n.EndMs=now; held.Remove(n); }
                    } else if(e.A==120 || e.A==123) {
                        foreach(var q in active.Values) foreach(var n in q.Where(n=>n.Channel==e.Channel && n.Port==e.Port)) n.EndMs=now;
                        foreach(var k in active.Keys.ToArray()) if(active[k].Count>0 && active[k].Peek().Channel==e.Channel && active[k].Peek().Port==e.Port) active[k].Clear();
                        foreach(var n in held.Where(n=>n.Channel==e.Channel && n.Port==e.Port).ToArray()) { n.EndMs=now; held.Remove(n); }
                    } else if(e.A==121) {
                        sustain[controller]=false;
                        foreach(var n in held.Where(n=>n.Channel==e.Channel && n.Port==e.Port).ToArray()) { n.EndMs=now; held.Remove(n); }
                    }
                }
            }
            score.DurationMs=now/speed;
            if(maxSeconds>0) score.DurationMs=Math.Min(score.DurationMs,maxSeconds*1000);
            foreach(var n in score.Notes) {
                n.EndMs=(n.EndMs<0?now:n.EndMs)/speed; n.StartMs/=speed;
                n.EndMs=Math.Min(n.EndMs,score.DurationMs); n.Pitch+=transpose;
            }
            score.Notes=score.Notes.Where(n=>n.Pitch>=0 && n.Pitch<=127 && n.EndMs>n.StartMs && n.StartMs<score.DurationMs).ToList();
            var voices=new List<Voice>();
            foreach(var group in score.Notes.GroupBy(n=>new { n.Track,n.Port,n.Channel,Band=n.Pitch<60?"Low":n.Pitch<72?"Mid":"High" })
                         .OrderBy(g=>g.Key.Track).ThenBy(g=>g.Key.Channel).ThenBy(g=>g.Key.Band=="High"?0:g.Key.Band=="Mid"?1:2)) {
                string trackTitle=titles.ContainsKey(group.Key.Track)?titles[group.Key.Track]:"";
                trackTitle=new string(trackTitle.Where(c=>!char.IsControl(c)).ToArray()).Trim();
                if(trackTitle.Length>36) trackTitle=trackTitle.Substring(0,36);
                if(trackTitle.Length==0) trackTitle="Track "+(group.Key.Track+1);
                var partVoices=new List<Voice>();
                foreach(var n in group.OrderBy(n=>n.StartMs).ThenBy(n=>n.Pitch)) {
                    n.Part=trackTitle;
                    var voice=partVoices.Where(v=>v.EndMs<=n.StartMs+0.001).OrderBy(v=>Math.Abs(v.LastPitch-n.Pitch)).FirstOrDefault();
                    if(voice==null) {
                        voice=new Voice { Track=n.Track,Port=n.Port,Channel=n.Channel,Band=group.Key.Band,Part=trackTitle,Number=partVoices.Count+1 };
                        partVoices.Add(voice); voices.Add(voice);
                    }
                    voice.Notes.Add(n); voice.EndMs=n.EndMs; voice.LastPitch=n.Pitch;
                }
            }
            score.IdealWindows=voices.Count;
            // Keep independent chord voices wherever the window budget permits.
            // First merge within an instrument, then within a register only.
            while(voices.Count>maxWindows) {
                var samePart=voices.GroupBy(v=>new { v.Track,v.Port,v.Channel,v.Band }).Where(g=>g.Count()>1)
                    .OrderBy(g=>g.Sum(v=>v.Notes.Count)).FirstOrDefault();
                Voice[] pair;
                if(samePart!=null) pair=samePart.OrderBy(v=>v.Notes.Count).Take(2).ToArray();
                else pair=voices.GroupBy(v=>v.Band).Where(g=>g.Count()>1).OrderByDescending(g=>g.Count()).First()
                    .OrderBy(v=>v.Notes.Count).Take(2).ToArray();
                Voice a=pair[0],b=pair[1];
                if(a.Track!=b.Track || a.Port!=b.Port || a.Channel!=b.Channel) {
                    a.Track=-1; a.Port=-1; a.Channel=-1; a.Part=a.Band+" ensemble";
                }
                a.Notes.AddRange(b.Notes); a.Combined+=b.Combined; voices.Remove(b);
            }
            foreach(var voice in voices) {
                var layer=new Layer { Id=score.Layers.Count,Track=voice.Track,Channel=voice.Channel,Band=voice.Band,
                    Title=voice.Part+" / "+voice.Band+" / "+(voice.Combined>1?voice.Combined+" voices":"voice "+voice.Number),
                    NoteCount=voice.Notes.Count,CombinedVoices=voice.Combined };
                score.Layers.Add(layer); foreach(var n in voice.Notes) n.Layer=layer.Id;
            }
            if(score.Notes.Count==0) throw new InvalidDataException("No playable notes in the requested section.");
            return score;
        }
        public static void LimitRegisters(Score score,int low,int mid,int high) {
            foreach(string band in new string[]{"Low","Mid","High"}) {
                int limit=Math.Max(1,band=="Low"?low:band=="Mid"?mid:high);
                while(score.Layers.Count(l=>l.Band==band)>limit) {
                    var pair=score.Layers.Where(l=>l.Band==band).OrderBy(l=>l.NoteCount).Take(2).ToArray();
                    Layer a=pair[0],b=pair[1];
                    foreach(var n in score.Notes.Where(n=>n.Layer==b.Id)) n.Layer=a.Id;
                    a.NoteCount+=b.NoteCount;a.CombinedVoices+=b.CombinedVoices;
                    a.Title=band+" ensemble / "+a.CombinedVoices+" voices";a.Track=-1;a.Channel=-1;
                    score.Layers.Remove(b);
                }
            }
            var ids=new Dictionary<int,int>();
            for(int i=0;i<score.Layers.Count;i++){ids[score.Layers[i].Id]=i;score.Layers[i].Id=i;}
            foreach(var n in score.Notes)n.Layer=ids[n.Layer];
        }
    }
    public static class Synth {
        public static void Render(Score score,string path,double volume) {
            int count=checked((int)Math.Ceiling(score.DurationMs*score.SampleRate/1000));
            var mix=new float[count];
            // Keep headroom based on the original arrangement. Turning one part
            // down must not automatically turn all the other parts back up.
            var reference=score.PartGains.Any(p=>p.Value!=1)?new float[count]:null;
            foreach(var n in score.Notes) {
                int start=(int)Math.Round(n.StartMs*score.SampleRate/1000),end=Math.Min(count,(int)Math.Round(n.EndMs*score.SampleRate/1000));
                double frequency=n.Hertz; if(frequency>=score.SampleRate*0.48) continue;
                double step=2*Math.PI*frequency/score.SampleRate;
                int attack=Math.Max(1,Math.Min((end-start)/2,score.SampleRate*3/1000));
                int release=Math.Max(1,Math.Min((end-start)/2,score.SampleRate*6/1000));
                double velocity=n.Velocity/127.0,partGain=1;
                if(score.PartGains.ContainsKey(n.MixId))partGain=Math.Max(0,Math.Min(1,score.PartGains[n.MixId]));
                List<VolumePoint> points;score.Volumes.TryGetValue(n.Port*16+n.Channel,out points);int point=0;
                if(points!=null)while(point+1<points.Count && points[point+1].TimeMs<=n.StartMs)point++;
                for(int i=start;i<end;i++) {
                    double env=Math.Min(1,Math.Min((i-start+1)/(double)attack,(end-i)/(double)release));
                    double gain=1;
                    if(points!=null){double ms=i*1000.0/score.SampleRate;while(point+1<points.Count && points[point+1].TimeMs<=ms)point++;
                        var control=points[point];gain=control.Previous+(control.Gain-control.Previous)*Math.Min(1,Math.Max(0,(ms-control.TimeMs)/5));}
                    float value=(float)(Math.Sin((i-start)*step)*velocity*gain*env);
                    mix[i]+=(float)(value*partGain);if(reference!=null)reference[i]+=value;
                }
            }
            double peak=0; foreach(float x in mix) peak=Math.Max(peak,Math.Abs(x)); score.PeakBeforeScaling=peak;
            double referencePeak=peak;if(reference!=null){referencePeak=0;foreach(float x in reference)referencePeak=Math.Max(referencePeak,Math.Abs(x));}
            score.ReferencePeak=referencePeak;
            double scale=32767*volume/Math.Max(1,referencePeak);
            using(var w=new BinaryWriter(File.Create(path))) {
                w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36+count*2); w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
                w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(score.SampleRate); w.Write(score.SampleRate*2);
                w.Write((short)2); w.Write((short)16); w.Write(Encoding.ASCII.GetBytes("data")); w.Write(count*2);
                foreach(float x in mix) w.Write((short)Math.Round(x*scale));
            }
        }
    }
    public sealed class Audio : IDisposable {
        [StructLayout(LayoutKind.Sequential,Pack=2)] struct Format { public ushort Tag,Channels; public uint Rate,BytesPerSecond; public ushort Align,Bits,Extra; }
        [StructLayout(LayoutKind.Sequential)] struct Header { public IntPtr Data; public uint Length,Recorded; public UIntPtr User; public uint Flags,Loops; public IntPtr Next; public UIntPtr Reserved; }
        [StructLayout(LayoutKind.Explicit,Size=12)] struct Position { [FieldOffset(0)] public uint Type; [FieldOffset(4)] public uint Value; }
        [DllImport("winmm.dll")] static extern uint waveOutOpen(out IntPtr h,uint device,ref Format f,IntPtr callback,IntPtr instance,uint flags);
        [DllImport("winmm.dll")] static extern uint waveOutPrepareHeader(IntPtr h,IntPtr p,uint size);
        [DllImport("winmm.dll")] static extern uint waveOutWrite(IntPtr h,IntPtr p,uint size);
        [DllImport("winmm.dll")] static extern uint waveOutGetPosition(IntPtr h,ref Position p,uint size);
        [DllImport("winmm.dll")] static extern uint waveOutReset(IntPtr h);
        [DllImport("winmm.dll")] static extern uint waveOutUnprepareHeader(IntPtr h,IntPtr p,uint size);
        [DllImport("winmm.dll")] static extern uint waveOutClose(IntPtr h);
        IntPtr handle,data,header; uint size=(uint)Marshal.SizeOf(typeof(Header)); int rate; bool prepared;
        static void Check(uint result) { if(result!=0) throw new InvalidOperationException("Windows audio error "+result); }
        public Audio(string wav) {
            try {
                byte[] bytes=File.ReadAllBytes(wav); rate=BitConverter.ToInt32(bytes,24);
                var format=new Format { Tag=1,Channels=1,Rate=(uint)rate,BytesPerSecond=(uint)rate*2,Align=2,Bits=16 };
                Check(waveOutOpen(out handle,0xFFFFFFFF,ref format,IntPtr.Zero,IntPtr.Zero,0));
                int length=bytes.Length-44; data=Marshal.AllocHGlobal(length); Marshal.Copy(bytes,44,data,length);
                header=Marshal.AllocHGlobal((int)size); Marshal.StructureToPtr(new Header { Data=data,Length=(uint)length },header,false);
                Check(waveOutPrepareHeader(handle,header,size)); prepared=true;
            } catch { Dispose(); throw; }
        }
        public void Start() { Check(waveOutWrite(handle,header,size)); }
        public double Milliseconds {
            get { var p=new Position { Type=2 }; Check(waveOutGetPosition(handle,ref p,12));
                if(p.Type==2) return p.Value*1000.0/rate; if(p.Type==1) return p.Value;
                if(p.Type==4) return p.Value*500.0/rate; throw new NotSupportedException("Unknown audio position format."); }
        }
        public bool Done { get { return (((Header)Marshal.PtrToStructure(header,typeof(Header))).Flags&1)!=0; } }
        public void Dispose() {
            if(handle!=IntPtr.Zero) { waveOutReset(handle); if(prepared) waveOutUnprepareHeader(handle,header,size); waveOutClose(handle); handle=IntPtr.Zero; }
            if(header!=IntPtr.Zero) { Marshal.FreeHGlobal(header); header=IntPtr.Zero; }
            if(data!=IntPtr.Zero) { Marshal.FreeHGlobal(data); data=IntPtr.Zero; }
        }
    }
    // The application's own console windows position themselves, rather than
    // moving or sending input to other applications.
    public static class ConsoleTile {
        [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr instance,string name,uint type,int width,int height,uint flags);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window,uint message,IntPtr wparam,IntPtr lparam);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
        static IntPtr largeIcon,smallIcon;
        [StructLayout(LayoutKind.Sequential)] struct Point {public int X,Y;}
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point point,uint flags);
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor,int kind,out uint x,out uint y);
        [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int id);
        [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h,out uint mode);
        [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h,uint mode);
        [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out Rect r);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
        [DllImport("user32.dll",EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr h,int index);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
        public static int[] Place(int x,int y,int width,int height) {
            uint mode; IntPtr input=GetStdHandle(-10);
            if(GetConsoleMode(input,out mode)) SetConsoleMode(input,(mode|0x80u)&~0x40u);
            IntPtr h=GetConsoleWindow(); if(h==IntPtr.Zero || !IsWindowVisible(h)) throw new InvalidOperationException("Launch this player through conhost.exe for independently tiled consoles.");
            Rect r=new Rect();
            // A move between monitors can trigger a delayed DPI/font resize in
            // conhost. Reapply the requested rectangle once that settles.
            for(int attempt=0;attempt<5;attempt++) {
                // HWND_TOP raises once in the normal window band. Never use
                // HWND_TOPMOST, so another application can cover the display.
                if(!SetWindowPos(h,IntPtr.Zero,x,y,width,height,0x0050)) throw new InvalidOperationException("Could not size this console window.");
                System.Threading.Thread.Sleep(200);
                GetWindowRect(h,out r);
                if(Math.Abs(r.Left-x)<=2 && Math.Abs(r.Top-y)<=2 && Math.Abs(r.Right-r.Left-width)<=2 && Math.Abs(r.Bottom-r.Top-height)<=2) break;
            }
            return new int[] { r.Left,r.Top,r.Right-r.Left,r.Bottom-r.Top };
        }
        public static void Raise() {
            IntPtr h=GetConsoleWindow(); if(h==IntPtr.Zero) return;
            SetWindowPos(h,IntPtr.Zero,0,0,0,0,0x0043); SetForegroundWindow(h);
        }
        public static bool IsForeground {get{return IsForegroundWindow(GetConsoleWindow());}}
        public static bool IsForegroundWindow(IntPtr window) {return window!=IntPtr.Zero && GetForegroundWindow()==window;}
        public static bool ReleaseFocus() {return ReleaseFocus(GetConsoleWindow());}
        public static bool ReleaseFocus(IntPtr window) {
            // Only relinquish this player's own active window. Activating the
            // shell desktop leaves the normal window stack and tile sizes alone.
            if(!IsForegroundWindow(window))return true;
            IntPtr desktop=GetShellWindow();if(desktop==IntPtr.Zero)return false;
            SetForegroundWindow(desktop);
            return !IsForegroundWindow(window);
        }
        public static bool IsTopMost { get { return (GetWindowLong(GetConsoleWindow(),-20)&8)!=0; } }
        public static double ScaleAt(int x,int y) {
            try {uint dx,dy;IntPtr monitor=MonitorFromPoint(new Point{X=x,Y=y},2);if(GetDpiForMonitor(monitor,0,out dx,out dy)==0)return Math.Max(1,dx/96.0);}
            catch(EntryPointNotFoundException){}catch(DllNotFoundException){}
            return 1;
        }
        public static void SetIcon(string path) {
            if(!File.Exists(path))return;
            IntPtr h=GetConsoleWindow();if(h==IntPtr.Zero)return;
            IntPtr big=LoadImage(IntPtr.Zero,path,1,GetSystemMetrics(11),GetSystemMetrics(12),0x10);
            IntPtr small=LoadImage(IntPtr.Zero,path,1,GetSystemMetrics(49),GetSystemMetrics(50),0x10);
            if(big==IntPtr.Zero || small==IntPtr.Zero){if(big!=IntPtr.Zero)DestroyIcon(big);if(small!=IntPtr.Zero)DestroyIcon(small);throw new InvalidOperationException("Could not load the Orchestra window icon.");}
            SendMessage(h,0x80,new IntPtr(1),big);SendMessage(h,0x80,IntPtr.Zero,small);
            if(largeIcon!=IntPtr.Zero)DestroyIcon(largeIcon);if(smallIcon!=IntPtr.Zero)DestroyIcon(smallIcon);
            largeIcon=big;smallIcon=small;
        }
        public static bool HasCustomIcon {get{
            IntPtr h=GetConsoleWindow();return largeIcon!=IntPtr.Zero && smallIcon!=IntPtr.Zero &&
                SendMessage(h,0x7F,new IntPtr(1),IntPtr.Zero)==largeIcon && SendMessage(h,0x7F,IntPtr.Zero,IntPtr.Zero)==smallIcon;
        }}
    }
}
