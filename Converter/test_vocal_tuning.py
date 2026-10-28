"""Core sung notes should survive pitch smoothing, glides and repeated syllables."""
import numpy as np
from musical_notes import tuned_vocal_notes

step=.02
def decode(midi,energy=None,confidence=None,smoothing='balanced'):
    midi=np.asarray(midi,dtype=float)
    if energy is None:energy=np.full(len(midi),.2)
    if confidence is None:confidence=np.full(len(midi),.9)
    return tuned_vocal_notes(440*2**((midi-69)/12),confidence,energy,step,len(midi)*step,smoothing)

timeline=np.arange(150)*step
notes=decode(69+.85*np.sin(2*np.pi*5*timeline))
assert len(notes)==1 and notes[0].pitch==69 and notes[0].end>2.95,[(n.pitch,n.start,n.end) for n in notes]
print('PASS: wide sung vibrato becomes one held A4 note.')

notes=decode(np.r_[np.linspace(68,69,10),np.full(65,69.)])
assert len(notes)==1 and notes[0].pitch==69,[(n.pitch,n.start,n.end) for n in notes]
print('PASS: an incoming scoop settles on the intended held note without an extra pickup.')

notes=decode(np.r_[np.full(40,69.),np.linspace(69,72,12),np.full(40,72.)])
assert [n.pitch for n in notes]==[69,72],[(n.pitch,n.start,n.end) for n in notes]
print('PASS: a slide between A4 and C5 produces two notes without intermediate glide notes.')

notes=decode(np.r_[np.full(30,69.),np.full(25,70.),np.full(30,72.)])
assert [n.pitch for n in notes]==[69,70,72],[(n.pitch,n.start,n.end) for n in notes]
print('PASS: deliberate semitone and larger melody changes remain distinct.')

energy=np.full(120,.2);energy[38:43]=.04;energy[78:83]=.04
notes=decode(np.full(120,69.),energy=energy)
assert len(notes)==3 and {n.pitch for n in notes}=={69},[(n.pitch,n.start,n.end) for n in notes]
print('PASS: repeated syllables at one pitch remain separate attacks.')

energy=np.full(120,.2);energy[45:65]=0
notes=decode(np.full(120,69.),energy=energy)
assert len(notes)==2 and not any(n.start<1.1<n.end for n in notes),'Silent rest was filled'
confidence=np.full(120,.9);confidence[50:55]=.04
notes=decode(np.full(120,69.),confidence=confidence)
assert len(notes)==1 and notes[0].end>2.3,'Brief confidence dip chopped the held note'
print('PASS: real rests stay silent; brief uncertain voiced frames sustain the note.')

# A brief return to a neighbouring pitch is intentionally ambiguous: the user
# can keep that detail with Gentle or treat it as an inflection with Balanced.
phrase=np.r_[np.full(30,69.),np.full(8,70.),np.full(30,69.)]
assert [n.pitch for n in decode(phrase,smoothing='gentle')]==[69,70,69]
assert [n.pitch for n in decode(phrase,smoothing='balanced')]==[69]
for setting in ('gentle','balanced','firm'):
    notes=decode(np.r_[np.full(30,69.),np.full(25,70.),np.full(30,72.)],smoothing=setting)
    assert [n.pitch for n in notes]==[69,70,72],setting
    energy=np.full(120,.2);energy[45:65]=0
    notes=decode(np.full(120,69.),energy=energy,smoothing=setting)
    assert len(notes)==2 and not any(n.start<1.1<n.end for n in notes),setting
    energy=np.full(120,.2);energy[38:43]=.04;energy[78:83]=.04
    assert len(decode(np.full(120,69.),energy=energy,smoothing=setting))==3,setting
print('PASS: Gentle retains a brief melody detail; all strengths retain sustained changes, rests and repeated attacks.')
