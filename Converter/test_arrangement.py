"""Musical structure checks using known chords, a lead, bass and silent bars."""
import numpy as np
import pretty_midi
from arrangement import arrange,arrange_balanced

rate=22050;duration=10
audio=np.zeros(rate*duration,dtype=np.float32)
for start,end,pitches in [(0,4,[48,52,55]),(6,10,[45,48,52])]:
    t=np.arange(int((end-start)*rate))/rate
    for pitch in pitches:
        f=440*2**((pitch-69)/12)
        audio[int(start*rate):int(end*rate)]+=(.12*np.sin(2*np.pi*f*t)+.03*np.sin(4*np.pi*f*t)).astype(np.float32)
midi=pretty_midi.PrettyMIDI()
lead=pretty_midi.Instrument(80,name='Lead melody');bass=pretty_midi.Instrument(33,name='Bass')
for start in np.arange(0,10,.5):
    if 4<=start<6:continue
    lead.notes.append(pretty_midi.Note(100,72 if start<4 else 76,float(start+.03),float(start+.43)))
    bass.notes.append(pretty_midi.Note(90,36 if start<4 else 33,float(start),float(start+.4)))
lead.notes.insert(2,pretty_midi.Note(60,91,.91,.98))
midi.instruments=[lead,bass]
result,details=arrange(midi,audio,rate,np.arange(0,10,.5),10,120)
assert len(result.instruments)==3
for track in result.instruments:
    assert all(0<=n.start<n.end<=duration for n in track.notes)
    assert not any(n.start<5<n.end for n in track.notes),'Silent bar was filled'
    if track.name!='Restrained chords':
        assert all(a.end<=b.start+1e-6 for a,b in zip(track.notes,track.notes[1:])),track.name
harmony=result.instruments[2].notes
first={n.pitch%12 for n in harmony if n.start<3}
last={n.pitch%12 for n in harmony if n.start>6}
assert first=={0,4,7},('C major misidentified',first)
assert last=={9,0,4},('A minor misidentified',last)
assert max(n.velocity for n in harmony)<min(n.velocity for n in result.instruments[0].notes)
events=sorted((time,delta) for track in result.instruments for n in track.notes for time,delta in [(n.start,1),(n.end,-1)])
count=peak=0
for _,delta in events: count+=delta;peak=max(peak,count)
assert peak<=5,peak
assert not any(n.pitch==91 for n in result.instruments[0].notes)
print('PASS: C/Am chord recognition, silence, one lead, one bass, restrained chord balance, isolated spike rejection, at most five simultaneous notes.')

# The richer mode must retain syncopated source attacks and backing motifs,
# without returning to an unbounded transcription pile.
for n in list(bass.notes):
    n.end=n.start+.18
    bass.notes.append(pretty_midi.Note(90,n.pitch,n.start+.25,n.start+.43))
bass.notes.sort(key=lambda n:n.start)
backing=pretty_midi.Instrument(0,name='Accompaniment Mid')
for start in np.arange(.25,10,.5):
    if 4<=start<6:continue
    backing.notes.append(pretty_midi.Note(92,64,float(start),float(start+.13)))
midi.instruments.append(backing)
balanced,details=arrange_balanced(midi,audio,rate,np.arange(0,10,.5),10,120)
parts={i.name:i for i in balanced.instruments}
assert len(parts['Rhythmic bass'].notes)>len(result.instruments[1].notes),'Bass syncopation discarded'
assert any(abs(n.start-.25)<.03 for n in parts['Rhythmic bass'].notes)
assert len(parts['Backing hooks'].notes)>=8,'Supported backing motif discarded'
assert all(not(n.start<5<n.end) for i in balanced.instruments for n in i.notes),'Silent bar filled'
events=sorted((t,d) for i in balanced.instruments for n in i.notes for t,d in [(n.start,1),(n.end,-1)])
count=peak=0
for _,delta in events:count+=delta;peak=max(peak,count)
assert peak<=8,peak
assert len({n.pitch for n in parts['Voiced harmony'].notes if n.start<.1})==4,'Harmony stayed a plain triad'
print('PASS: richer mode retains offbeat bass and source hooks, adds four-note harmony, preserves silence and stays within eight voices.')
