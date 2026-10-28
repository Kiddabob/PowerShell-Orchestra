using System;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace OrchestraConsole {
 public class Mark {public double Start,End,Hz;public int Pitch;public string Name,Part;}
 public class Entry {public double Time;public bool On;public string Text;}
 [StructLayout(LayoutKind.Explicit,CharSet=CharSet.Unicode)]public struct Cell {
  [FieldOffset(0)]public char Character;[FieldOffset(2)]public ushort Color;
 }
 [StructLayout(LayoutKind.Sequential)]struct Coord {public short X,Y;public Coord(int x,int y){X=(short)x;Y=(short)y;}}
 [StructLayout(LayoutKind.Sequential)]struct Rect {public short Left,Top,Right,Bottom;}
 public class Canvas {
  [DllImport("kernel32.dll")]static extern IntPtr GetStdHandle(int id);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool WriteConsoleOutputW(IntPtr handle,Cell[] buffer,Coord size,Coord origin,ref Rect region);
  public string Song="",Part="",Band="Mid";public double Duration=1,Position;public Mark[] Notes=new Mark[0];
  public int ShownEvents {get;private set;} public int Frames {get;private set;}public int Width {get;private set;}public int Height {get;private set;}
  List<Entry> events=new List<Entry>();Queue<Entry> history=new Queue<Entry>();Cell[] cells;
  ushort Accent {get{return (ushort)(Band=="Low"?13:Band=="High"?14:11);}}
  static string Clock(double time){return TimeSpan.FromMilliseconds(Math.Max(0,time)).ToString(@"mm\:ss");}
  static string Stamp(double time){return TimeSpan.FromMilliseconds(Math.Max(0,time)).ToString(@"mm\:ss\.fff");}
  public void Build(){Notes=Notes.OrderBy(n=>n.Start).ToArray();foreach(var n in Notes){
   string value=n.Name.PadRight(4)+" "+n.Hz.ToString("0").PadLeft(5)+"Hz "+(n.End-n.Start).ToString("0").PadLeft(5)+"ms  "+n.Part;
   events.Add(new Entry{Time=n.Start,On=true,Text="ON   "+value});events.Add(new Entry{Time=n.End,On=false,Text="OFF  "+value});}
   events=events.OrderBy(e=>e.Time).ThenBy(e=>e.On?1:0).ToList();
  }
  void Put(int row,int col,string text,ushort color){if(row<0||row>=Height)return;for(int i=0;i<text.Length&&col+i<Width;i++)if(col+i>=0){int index=row*Width+col+i;cells[index].Character=text[i];cells[index].Color=color;}}
  static string NoteName(int pitch){return new[]{"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}[((pitch%12)+12)%12]+(pitch/12-1);}
  public Cell[] Compose(int width,int height,double position){
   Width=Math.Max(20,width);Height=Math.Max(8,height);if(cells==null||cells.Length!=Width*Height)cells=new Cell[Width*Height];
   for(int i=0;i<cells.Length;i++){cells[i].Character=' ';cells[i].Color=7;}
   if(position<Position){ShownEvents=0;history.Clear();}Position=position;
   while(ShownEvents<events.Count&&events[ShownEvents].Time<=position){history.Enqueue(events[ShownEvents++]);while(history.Count>512)history.Dequeue();}
   Put(0,0,"Windows PowerShell",15);Put(0,Math.Max(20,Width-16),Clock(position)+" / "+Clock(Duration),8);
   Put(1,0,"PS Orchestra> ",14);Put(1,14,"play \""+Song+"\"",7);
   Put(2,0,"# "+Band.ToUpper()+" | "+Part,Accent);
   var active=Notes.Where(n=>n.Start<=position&&n.End>position).ToArray();
   string now=active.Length==0?"(rest)":string.Join(" + ",active.Select(n=>n.Name).Distinct());
   Put(3,0,"Now: ",7);Put(3,5,now,active.Length==0?(ushort)8:Accent);
   if(active.Length>0)Put(3,Math.Min(Width-24,Math.Max(25,now.Length+8)),active[0].Hz.ToString("0")+" Hz  "+(active[0].End-active[0].Start).ToString("0")+" ms",8);
   if(Height>=16){
    int rollHeight=Math.Min(18,Math.Max(3,Height-12)),top=6,left=6,plot=Math.Max(8,Width-left-2);
    int low=Notes.Length==0?54:Notes.Min(n=>n.Pitch)-1,high=Notes.Length==0?78:Notes.Max(n=>n.Pitch)+1;if(high-low<6){low-=3;high+=3;}
    double from=position-2600,span=4400;int playhead=left+(int)(plot*2600/span);
    rollHeight=Math.Min(rollHeight,high-low+1);Put(4,0,"# Live piano roll",8);
    Put(5,left,"PAST",8);Put(5,playhead-1,"NOW",15);Put(5,left+plot-10,"NEXT +1.8s",Accent);
    for(int row=0;row<rollHeight;row++){int pitch=high-(int)Math.Round(row*(high-low)/(double)Math.Max(1,rollHeight-1));Put(top+row,0,NoteName(pitch).PadLeft(4)+" |",8);Put(top+row,left,new string('.',plot),8);Put(top+row,playhead,"|",7);}
    foreach(var n in Notes){if(n.Start>from+span)break;if(n.End<from)continue;
     int row=top+(int)Math.Round((high-n.Pitch)/(double)Math.Max(1,high-low)*(rollHeight-1));
     int a=left+(int)Math.Floor((n.Start-from)/span*plot),b=left+(int)Math.Ceiling((n.End-from)/span*plot);
     a=Math.Max(left,a);b=Math.Min(left+plot,Math.Max(a+1,b));bool sounding=n.Start<=position&&n.End>position,upcoming=n.Start>position;
     // Filled terminal cells make upcoming notes visible against the dim grid.
     // White marks the sounding note; only a dim trail remains after note-off.
     ushort color=sounding?(ushort)0xF0:upcoming?(ushort)(Accent<<4):(ushort)(Accent&7);
     if(b>a){Put(row,a,new string(sounding?'#':upcoming?'-':'=',b-a),color);if(upcoming)Put(row,a,">",color);}
    }
    top+=rollHeight+1;Put(top++,0,"Time        Event Note    Pitch   Length  Part",8);
    var recent=history.Reverse().Take(Math.Max(0,Height-top-2)).Reverse();foreach(var entry in recent)Put(top++,0,Stamp(entry.Time)+"  "+entry.Text,entry.On?Accent:(ushort)8);
   }else {var entry=history.LastOrDefault();if(entry!=null)Put(5,0,Stamp(entry.Time)+" "+entry.Text,Accent);}
   int length=Math.Max(4,Width-25),done=(int)(length*Math.Min(1,position/Math.Max(1,Duration)));
   Put(Height-1,0,"PS Orchestra> ["+new string('=',done)+new string(' ',length-done)+"]",Accent);
   return cells;
  }
  public void Paint(double position){
   int width=Console.WindowWidth,height=Console.WindowHeight;var data=Compose(width,height,position);
   var region=new Rect{Left=(short)Console.WindowLeft,Top=(short)Console.WindowTop,Right=(short)(Console.WindowLeft+Width-1),Bottom=(short)(Console.WindowTop+Height-1)};
   if(!WriteConsoleOutputW(GetStdHandle(-11),data,new Coord(Width,Height),new Coord(0,0),ref region))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());Frames++;
  }
  public string[] TextPreview(int width,int height,double position){var frame=Compose(width,height,position);var rows=new string[Height];for(int y=0;y<Height;y++){var line=new StringBuilder();for(int x=0;x<Width;x++)line.Append(frame[y*Width+x].Character);rows[y]=line.ToString();}return rows;}
 }
}
