"""End-to-end MP3 decoding, pitch detection and MIDI creation check."""
from pathlib import Path
import tempfile
import numpy as np
import pretty_midi
import soundfile as sf
from transcribe import convert
from musical_notes import tracked_notes as monophonic_notes, contour_to_notes, backing_notes

root=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="orchestra-converter-check-",dir=root) as folder:
    folder=Path(folder).resolve()
    assert folder.parent==root and folder.name.startswith("orchestra-converter-check-")
    rate=22050
    audio=np.zeros(int(6*rate),dtype=np.float32)
    for start,end,pitches in [(0.25,1.15,[60]),(1.5,2.4,[64]),(2.75,3.65,[67]),(4,5.2,[60,64,67])]:
        a,b=int(start*rate),int(end*rate)
        time=np.arange(b-a)/rate
        envelope=np.minimum(1,time/0.01)*np.minimum(1,(end-start-time)/0.04)*np.exp(-time/1.1)
        for pitch in pitches:
            frequency=440*2**((pitch-69)/12)
            tone=sum(weight*np.sin(2*np.pi*frequency*harmonic*time) for harmonic,weight in [(1,1),(2,0.3),(3,0.12)])
            audio[a:b]+=0.13*tone*envelope
    source=folder/"known-notes.mp3"
    output=folder/"known-notes.mid"
    sf.write(source,audio,rate,format="MP3")
    result=convert(source,output)
    midi=pretty_midi.PrettyMIDI(str(output))
    notes=[note for instrument in midi.instruments for note in instrument.notes]
    pitches={note.pitch for note in notes}
    assert {60,64,67}.issubset(pitches),f"Expected pitches missing: {pitches}"
    chord_pitches={note.pitch for note in notes if note.start<4.6 and note.end>4.3}
    assert {60,64,67}.issubset(chord_pitches),f"Simultaneous chord pitches missing: {chord_pitches}"
    assert all(note.end>note.start>=0 for note in notes)
    assert output.read_bytes()[:4]==b"MThd"
    assert source.exists(),"Original MP3 was modified or removed"
    try:
        convert(source,output)
        raise AssertionError("Existing MIDI was overwritten")
    except FileExistsError:
        pass
    print(f"PASS: real MP3 decoded; C4/E4/G4 and their simultaneous chord detected; {len(notes)} valid MIDI notes; source retained and overwrite refused.")

# Fundamentals must survive stronger harmonics, processing boundaries and rests.
rate=16000
audio=np.zeros(18*rate,dtype=np.float32)
for start,end,pitch in [(0.4,1.3,60),(2.0,2.9,64),(15.4,16.8,67)]:
    a,b=int(start*rate),int(end*rate)
    time=np.arange(b-a)/rate
    f=440*2**((pitch-69)/12)
    envelope=np.minimum(1,time/.03)*np.minimum(1,(end-start-time)/.03)
    audio[a:b]=(0.2*np.sin(2*np.pi*f*time)+0.35*np.sin(4*np.pi*f*time))*envelope
lead=monophonic_notes(audio,rate,'vocals')
assert {60,64,67}.issubset({n.pitch for n in lead}),[(n.pitch,n.start,n.end) for n in lead]
assert any(n.pitch==67 and n.start<15.6 and n.end>16.6 for n in lead),'Held note clipped at processing boundary'
assert not any(n.start<1.7<n.end for n in lead),'Rest filled with a phantom note'
assert all(a.end<=b.start+0.02 for a,b in zip(lead,lead[1:])),'Monophonic lead contains overlapping notes'
bass=np.zeros(3*rate,dtype=np.float32)
time=np.arange(2*rate)/rate
f=440*2**((36-69)/12)
bass[rate//2:rate//2+len(time)]=0.3*np.sin(2*np.pi*f*time)+0.2*np.sin(4*np.pi*f*time)
assert any(n.pitch==36 and n.end-n.start>1.7 for n in monophonic_notes(bass,rate,'bass')),'Bass fundamental not retained'
print('PASS: lead fundamentals, rests, held note across chunk boundary and C2 bass retained.')

# Vibrato and a 60 ms confidence dip must not fragment a sustained note.
step=.02
timeline=np.arange(200)*step
frequency=261.626*2**(.40*np.sin(2*np.pi*6*timeline)/12)
confidence=np.full(200,.8);confidence[40:43]=.05
rms=np.full(200,.1);rms[90:100]=0;confidence[90:100]=0
notes=contour_to_notes(frequency,confidence,rms,step,4,'vocals')
assert len(notes)==2 and all(n.pitch==60 for n in notes),'Vibrato fragmented the phrase'
assert notes[0].end>=1.76 and notes[1].start>=2,'True silent rest was filled'
notes=contour_to_notes(frequency,np.full(200,.08),np.full(200,.1),step,4,'vocals')
assert not notes,'Low-confidence noise started a phrase'

# A quiet, supported chord tail should survive, but a never-credible pitch
# must not be fabricated to make the output seem fuller.
frames=np.zeros((300,88),dtype=np.float32);onsets=frames.copy()
for pitch in [60,64,67]:
    frames[40:65,pitch-21]=.75;frames[65:130,pitch-21]=.13;onsets[40,pitch-21]=.9
frames[:,80-21]=.075
prediction={'note':frames,'onset':onsets}
notes=backing_notes(prediction,4)
assert {n.pitch for n in notes}=={60,64,67},'Unsupported pitch added to chord'
assert min(n.end-n.start for n in notes)>.9,'Quiet chord tails were clipped'
print('PASS: vibrato and confidence dips sustained; real rests retained; weak noise rejected; quiet chord tails recovered.')

# A strong vowel must not seed a different, weakly supported neighbouring
# pitch. Keep the original detailed policy available for comparison.
frequency=np.r_[np.full(40,440.),np.full(20,493.883),np.full(40,440.)]
confidence=np.r_[np.full(40,.90),np.full(20,.18),np.full(40,.90)]
rms=np.full(100,.1)
detailed=contour_to_notes(frequency,confidence,rms,.02,2,'vocals')
stable=contour_to_notes(frequency,confidence,rms,.02,2,'vocals',stable_vocal=True)
assert any(n.pitch==71 for n in detailed),'Fixture did not exercise the old phrase gate'
assert not any(n.pitch==71 for n in stable),'Neighbouring vowel legitimised an uncertain pitch'
assert sum(n.end-n.start for n in stable)>1.4,'Stable melody discarded the supported phrase'

# A brief semitone scoop between two sustained notes is not a new sung note
# in stable mode. Longer, intentional semitone changes must remain intact.
frequency=np.r_[np.full(35,440.),np.full(6,466.164),np.full(35,440.)]
stable=contour_to_notes(frequency,np.full(76,.9),np.full(76,.1),.02,1.52,'vocals',stable_vocal=True)
assert len(stable)==1 and stable[0].pitch==69 and stable[0].end>1.45,'Vocal scoop fragmented the sung note'
frequency=np.r_[np.full(35,440.),np.full(25,466.164),np.full(35,440.)]
stable=contour_to_notes(frequency,np.full(95,.9),np.full(95,.1),.02,1.9,'vocals',stable_vocal=True)
assert any(n.pitch==70 and n.end-n.start>.4 for n in stable),'Intentional semitone note removed'
print('PASS: uncertain vocal fragments and brief scoops rejected; sustained phrases and intentional semitone notes retained.')
