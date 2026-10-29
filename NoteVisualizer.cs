using System;
using System.Linq;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace OrchestraVisual {
 public class Mark { public double Start,End,Hz; public int Pitch; public string Name,Part; }
 public class Entry { public double Time; public string Text; public bool On; }
 public class LayerForm : Form {
  public Mark[] Notes=new Mark[0]; public string Song="PowerShell Orchestra",Part="",Band="Mid";
  public double Position,Duration=1; public int ShownEvents {get;private set;}
  List<Entry> events=new List<Entry>(); Queue<Entry> history=new Queue<Entry>();
  Color Accent {get {return Band=="Low"?Color.FromArgb(184,143,255):Band=="High"?Color.FromArgb(255,198,92):Color.FromArgb(65,224,218);}}
  public LayerForm(){DoubleBuffered=true;ResizeRedraw=true;BackColor=Color.FromArgb(10,17,31);ForeColor=Color.White;AutoScaleMode=AutoScaleMode.None;StartPosition=FormStartPosition.Manual;MinimumSize=new Size(180,180);}
  public void Build(){
   Notes=Notes.OrderBy(n=>n.Start).ToArray();
   foreach(var n in Notes){events.Add(new Entry{Time=n.Start,On=true,Text="ON   "+n.Name.PadRight(4)+" "+n.Hz.ToString("0").PadLeft(5)+"Hz  "+(n.End-n.Start).ToString("0").PadLeft(5)+"ms  "+n.Part});events.Add(new Entry{Time=n.End,On=false,Text="OFF  "+n.Name.PadRight(4)+" "+n.Hz.ToString("0").PadLeft(5)+"Hz  "+n.Part});}
   events=events.OrderBy(e=>e.Time).ThenBy(e=>e.On?1:0).ToList();
  }
  public void Advance(double position){
   double previous=Position;if(position<Position){ShownEvents=0;history.Clear();} Position=position;
   while(ShownEvents<events.Count && events[ShownEvents].Time<=Position){history.Enqueue(events[ShownEvents++]);while(history.Count>8)history.Dequeue();}
   Text="PowerShell Orchestra | "+Song+" | "+Part+" | "+Clock(Position);
   if((int)(previous/1000)!=(int)(Position/1000)||Notes.Any(n=>n.End>Position-2600&&n.Start<Position+1100))Invalidate();
  }
  static string Clock(double ms){return TimeSpan.FromMilliseconds(Math.Max(0,ms)).ToString(@"mm\:ss");}
  void Label(Graphics g,string value,RectangleF area,float size,Color color,bool bold=false,bool right=false){
   using(var font=new Font("Segoe UI",Math.Max(8,size),bold?FontStyle.Bold:FontStyle.Regular,GraphicsUnit.Pixel))
   using(var brush=new SolidBrush(color))using(var format=new StringFormat{Trimming=StringTrimming.EllipsisCharacter,FormatFlags=StringFormatFlags.NoWrap,Alignment=right?StringAlignment.Far:StringAlignment.Near,LineAlignment=StringAlignment.Center})g.DrawString(value,font,brush,area,format);
  }
  protected override void OnPaint(PaintEventArgs e){
   base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.TextRenderingHint=System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
   float w=ClientSize.Width,h=ClientSize.Height;if(w<40||h<40)return;
   float s=Math.Max(.65f,Math.Min(1.8f,Math.Min(w/760f,h/450f))),m=18*s;
   using(var bg=new LinearGradientBrush(ClientRectangle,Color.FromArgb(22,32,53),Color.FromArgb(6,12,25),70))g.FillRectangle(bg,ClientRectangle);
   using(var glow=new SolidBrush(Color.FromArgb(10,Accent)))g.FillEllipse(glow,w*.48f,-h*.4f,w,h);
   using(var brush=new SolidBrush(Accent))g.FillRectangle(brush,0,0,w,3*s);
   float header=Math.Max(44*s,Math.Min(78*s,h*.18f));
   Label(g,Song,new RectangleF(m,8*s,w-m*2-90*s,24*s),13*s,Color.FromArgb(169,187,211));
   Label(g,Clock(Position),new RectangleF(w-m-86*s,8*s,86*s,24*s),18*s,Accent,true,true);
   Label(g,Part,new RectangleF(m,32*s,w-m*2,25*s),16*s,Color.White,true);
   var active=Notes.Where(n=>n.Start<=Position&&n.End>Position).ToArray();
   float hero=Math.Max(48*s,Math.Min(150*s,h*.24f));
   string names=active.Length==0?"—":string.Join(" + ",active.Select(n=>n.Name).Distinct().Take(4));
   if(active.Select(n=>n.Name).Distinct().Count()>4)names+=" +…";
   float noteSize=Math.Min(60*s,(w-m*2)/Math.Max(3,names.Length)*1.25f);
   Label(g,names,new RectangleF(m,header,w-m*2,hero*.72f),noteSize,active.Length>0?Accent:Color.FromArgb(81,103,132),true);
   string detail=active.Length==0?Band.ToUpper()+"  ·  listening for the next note":Band.ToUpper()+"  ·  "+active[0].Hz.ToString("0")+" Hz  ·  "+(active[0].End-active[0].Start).ToString("0")+" ms";
   Label(g,detail,new RectangleF(m,header+hero*.72f,w-m*2,hero*.28f),11*s,Color.FromArgb(151,174,201));
   float historyHeight=Math.Min(h*.23f,100*s),rollTop=header+hero+10*s,rollHeight=Math.Max(30,h-historyHeight-rollTop-16*s);
   var roll=new RectangleF(m,rollTop,w-m*2,rollHeight);
   using(var b=new SolidBrush(Color.FromArgb(110,2,8,19)))g.FillRectangle(b,roll);
   int low=Notes.Length==0?54:Notes.Min(n=>n.Pitch)-2,high=Notes.Length==0?78:Notes.Max(n=>n.Pitch)+2;
   if(high-low<12){int middle=(high+low)/2;low=middle-6;high=middle+6;}
   float row=roll.Height/(high-low+1); double from=Position-2600,span=3700;
   var state=g.Save();g.SetClip(roll);
   using(var pen=new Pen(Color.FromArgb(22,Accent)))for(int p=low;p<=high;p++){float y=roll.Bottom-(p-low+1)*row;g.DrawLine(pen,roll.Left,y,roll.Right,y);}
   using(var pen=new Pen(Color.FromArgb(27,180,205,240)))for(double time=Math.Floor(from/500)*500;time<from+span;time+=500){float x=roll.Left+(float)((time-from)/span)*roll.Width;g.DrawLine(pen,x,roll.Top,x,roll.Bottom);}
   foreach(var n in Notes){if(n.Start>from+span)break;if(n.End<from)continue;
    float x=roll.Left+(float)((n.Start-from)/span)*roll.Width,end=roll.Left+(float)((n.End-from)/span)*roll.Width,y=roll.Bottom-(n.Pitch-low+1)*row+1;
    var rect=new RectangleF(x,y,Math.Max(3,end-x-1),Math.Max(3,row-2));bool on=n.Start<=Position&&n.End>Position;
    int alpha=on?235:n.Start>Position?185:(int)Math.Max(20,80*(1-(Position-n.End)/2600));
    using(var b=new SolidBrush(Color.FromArgb(Math.Max(0,Math.Min(255,alpha)),Accent)))g.FillRectangle(b,rect);
    if(on)using(var pen=new Pen(Color.White,1))g.DrawRectangle(pen,rect.X,rect.Y,rect.Width,rect.Height);
   }
   float now=roll.Left+(float)(2600/span)*roll.Width;using(var pen=new Pen(Color.FromArgb(210,Color.White),1.5f))g.DrawLine(pen,now,roll.Top,now,roll.Bottom);g.Restore(state);
   float top=roll.Bottom+10*s,line=15*s;int rows=Math.Max(1,(int)((h-top-12*s)/line));var recent=history.Reverse().Take(rows).Reverse().ToArray();
   using(var font=new Font("Consolas",Math.Max(8,10*s),GraphicsUnit.Pixel))foreach(var entry in recent){using(var b=new SolidBrush(entry.On?Color.FromArgb(185,Accent):Color.FromArgb(91,115,146)))g.DrawString(TimeSpan.FromMilliseconds(entry.Time).ToString(@"mm\:ss\.fff")+"  "+entry.Text,font,b,m,top);top+=line;}
   using(var b=new SolidBrush(Color.FromArgb(45,Accent)))g.FillRectangle(b,0,h-3,w,3);
   using(var b=new SolidBrush(Accent))g.FillRectangle(b,0,h-3,(float)(w*Math.Min(1,Position/Math.Max(1,Duration))),3);
  }
 }
}
