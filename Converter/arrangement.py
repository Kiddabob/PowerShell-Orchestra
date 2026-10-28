"""Simplified arrangements: a lead, a bass and restrained, voiced triads."""
import itertools
from collections import defaultdict
import numpy as np
import pretty_midi


def beat_grid(beats, duration, tempo=120):
    beats=np.asarray(beats,dtype=float)
    beats=beats[(beats>=0)&(beats<duration)]
    if len(beats)<4:
        beats=np.arange(0,duration,60/tempo)
    period=float(np.median(np.diff(beats)))
    while beats[0]>period*.5:
        beats=np.r_[beats[0]-period,beats]
    while beats[-1]+period<duration:
        beats=np.r_[beats,beats[-1]+period]
    return beats,period


def snap(value, beats, period, divisions=4):
    index=int(np.clip(np.searchsorted(beats,value)-1,0,len(beats)-1))
    start=beats[index]
    length=beats[index+1]-start if index+1<len(beats) else period
    return max(0,float(start+round((value-start)/length*divisions)*length/divisions))


def clean_lead(notes,beats,period,duration):
    notes=sorted(notes,key=lambda n:n.start)
    selected=[]
    for i,n in enumerate(notes):
        if n.end-n.start<max(.10,period*.19):
            continue
        pitch=n.pitch
        if 0<i<len(notes)-1 and n.end-n.start<period*.4:
            before,after=notes[i-1].pitch,notes[i+1].pitch
            if abs(before-after)<=2 and min(abs(pitch-before),abs(pitch-after))>=7:
                continue
        selected.append(n)
    if not selected:
        return []
    weights=np.array([n.end-n.start for n in selected])
    order=np.argsort([n.pitch for n in selected])
    middle=selected[order[np.searchsorted(np.cumsum(weights[order]),weights.sum()/2)]].pitch
    shift=12*round((69-middle)/12)
    result=[]
    for n in selected:
        pitch=n.pitch+shift
        while pitch<60: pitch+=12
        while pitch>84: pitch-=12
        start=snap(n.start,beats,period)
        end=min(duration,max(start+period/4,snap(n.end,beats,period)))
        if result and abs(result[-1].start-start)<.02:
            if n.end-n.start>result[-1].end-result[-1].start:
                result[-1]=pretty_midi.Note(110,pitch,start,end)
            continue
        if result and result[-1].end>start:
            result[-1].end=start
        if end>start:
            result.append(pretty_midi.Note(110,pitch,start,end))
    return [n for n in result if n.end-n.start>=.055]


CHORDS=[(root,minor,tuple((root+x)%12 for x in (0,3 if minor else 4,7)))
        for root in range(12) for minor in (False,True)]


def chord_sequence(audio,rate,beats,period,bass,duration):
    import librosa
    wave=librosa.resample(audio,orig_sr=rate,target_sr=22050)
    harmonic=librosa.effects.harmonic(wave,margin=3)
    hop=512
    chroma=librosa.feature.chroma_cqt(y=harmonic,sr=22050,hop_length=hop,norm=None)
    chroma=np.maximum(chroma-np.percentile(chroma,20,axis=0,keepdims=True),0)
    rms=librosa.feature.rms(y=wave,hop_length=hop)[0]
    templates=np.zeros((24,12))
    for i,(_,_,pcs) in enumerate(CHORDS):
        templates[i,list(pcs)]=[1,.9,.8]
    templates/=np.linalg.norm(templates,axis=1,keepdims=True)
    options=[]
    for phase in (0,1):
        boundaries=np.unique(np.r_[0,beats[phase::2],duration])
        boundaries=boundaries[(boundaries>=0)&(boundaries<=duration)]
        scores=[]
        for a,b in zip(boundaries[:-1],boundaries[1:]):
            first,last=int(a*22050/hop),max(int(a*22050/hop)+1,int(b*22050/hop))
            profile=np.mean(chroma[:,first:last],axis=1)
            energy=float(np.mean(rms[first:last]))
            profile/=max(np.linalg.norm(profile),1e-8)
            values=templates@profile
            support=np.zeros(12)
            for n in bass:
                support[n.pitch%12]+=max(0,min(b,n.end)-max(a,n.start))
            if support.sum():
                support/=support.sum()
                values+=np.array([support[root]*.12 for root,_,_ in CHORDS])
            silence=energy<max(1e-5,float(np.percentile(rms,90))*.035)
            if silence: values[:]=-.5
            scores.append(np.r_[values,.58 if silence else .44])
        scores=np.asarray(scores)
        options.append((float(np.mean(np.max(scores,axis=1))),boundaries,scores))
    _,boundaries,scores=max(options,key=lambda o:o[0])
    # Harmonic continuity wins over rapid swaps between nearly tied guesses.
    transitions=np.full((25,25),.20)
    np.fill_diagonal(transitions,0)
    transitions[24,:]=transitions[:,24]=.07
    transitions[24,24]=0
    for i,(_,_,a) in enumerate(CHORDS):
        for j,(_,_,b) in enumerate(CHORDS):
            if i!=j: transitions[i,j]+=.035*(3-len(set(a)&set(b)))
    values=scores[0].copy();parents=[]
    for row in scores[1:]:
        candidates=values[:,None]-transitions
        parent=np.argmax(candidates,axis=0);parents.append(parent)
        values=row+candidates[parent,np.arange(25)]
    path=[int(np.argmax(values))]
    for parent in reversed(parents): path.append(int(parent[path[-1]]))
    path.reverse()
    return [(float(a),float(b),None if choice==24 else CHORDS[choice],float(scores[i,choice]))
            for i,(a,b,choice) in enumerate(zip(boundaries[:-1],boundaries[1:],path))]


def voice_chord(pcs,previous):
    choices=[p for p in range(48,65) if p%12 in pcs]
    candidates=[v for v in itertools.combinations(choices,3)
                if len({p%12 for p in v})==3 and v[-1]-v[0]<=12]
    return min(candidates,key=lambda v:sum(abs(a-b) for a,b in zip(v,previous))+.15*abs(np.mean(v)-55))


def arrange(midi,backing,rate,beats,duration,tempo=120):
    beats,period=beat_grid(beats,duration,tempo)
    lead=next((i.notes for i in midi.instruments if i.name=='Lead melody'),[])
    bass=next((i.notes for i in midi.instruments if i.name=='Bass'),[])
    chords=chord_sequence(backing,rate,beats,period,bass,duration)
    result=pretty_midi.PrettyMIDI(initial_tempo=tempo,resolution=960)
    melody=pretty_midi.Instrument(program=80,name='Clean lead')
    melody.notes=clean_lead(lead,beats,period,duration)
    low=pretty_midi.Instrument(program=33,name='Simple bass')
    for a,b in zip(beats,np.r_[beats[1:],duration]):
        candidates=[(max(0,min(b,n.end)-max(a,n.start))*n.velocity,n.pitch) for n in bass]
        evidence,pitch=max(candidates,default=(0,36))
        if evidence<=0:
            chord=next((c for x,y,c,s in chords if x<=a<y and c is not None and s>.62),None)
            if chord is None: continue
            pitch=36+chord[0]
        while pitch<28: pitch+=12
        while pitch>47: pitch-=12
        if b-a>.08: low.notes.append(pretty_midi.Note(76,pitch,max(0,float(a)),float(a+(b-a)*.82)))
    harmony=pretty_midi.Instrument(program=48,name='Restrained chords')
    previous=(48,55,60)
    for a,b,chord,score in chords:
        if chord is None or b-a<period*.7 or score<.50: continue
        previous=voice_chord(chord[2],previous)
        for pitch in previous:
            harmony.notes.append(pretty_midi.Note(32,pitch,a,min(duration,b-.025)))
    result.instruments=[i for i in (melody,low,harmony) if i.notes]
    return result,{'style':'Clean arrangement','max_voices':5,
        'melody_notes':len(melody.notes),'bass_notes':len(low.notes),'chord_notes':len(harmony.notes),
        'interpretation':'Simplified inferred harmony and bass; not an exact recovered score.'}


def rhythmic_line(notes,beats,period,duration,bass=False,minimum_duration=.055,snap_timing=True):
    """Keep source phrasing and syncopation; correct only small timing errors."""
    result=[]
    ordered=sorted(notes,key=lambda n:n.start)
    for i,n in enumerate(ordered):
        if n.end-n.start<.075: continue
        if 0<i<len(ordered)-1 and n.end-n.start<.14:
            before,after=ordered[i-1].pitch,ordered[i+1].pitch
            if abs(before-after)<=2 and min(abs(n.pitch-before),abs(n.pitch-after))>=10: continue
        pitch=n.pitch
        if bass:
            while pitch>55: pitch-=12
            while pitch<28: pitch+=12
        elif not 45<=pitch<=88: continue
        target=snap(n.start,beats,period) if snap_timing else n.start
        delta=target-n.start if abs(target-n.start)<=.045 else 0
        start=max(0,n.start+delta);end=min(duration,n.end+delta)
        if end-start<.065:continue
        velocity=int(np.clip(n.velocity,68,88) if bass else np.clip(n.velocity+10,100,116))
        note=pretty_midi.Note(velocity,pitch,start,end)
        if result and start-result[-1].start<.025:
            if end-start>result[-1].end-result[-1].start:result[-1]=note
            continue
        if result and result[-1].end>start:result[-1].end=start
        result.append(note)
    return [n for n in result if n.end-n.start>=minimum_duration]


def source_hooks(candidates,chords,lead,backing,rate,beats,period,duration):
    """Recover supported rhythmic motifs, without admitting an unlimited note pile."""
    signatures=defaultdict(set)
    def signature(n):
        beat=np.interp(n.start,beats,np.arange(len(beats)))
        return (n.pitch%12,int(round(beat*4))%16),int(beat//4)
    for n in candidates:
        if n.velocity>=68:
            key,bar=signature(n);signatures[key].add(bar)
    floor=max(1e-5,float(np.sqrt(np.mean(backing**2)))*.05)
    eligible=[]
    for n in candidates:
        if not 48<=n.pitch<=84 or not .085<=n.end-n.start<=period*2.2 or n.velocity<69:continue
        key,_=signature(n);recurs=len(signatures[key])>=2
        chord=next((c for a,b,c,s in chords if a<=n.start<b),None)
        belongs=chord is not None and n.pitch%12 in chord[2]
        if not belongs and not (recurs and n.velocity>=85):continue
        a,b=max(0,int(n.start*rate)),min(len(backing),int(n.end*rate))
        if b<=a or float(np.sqrt(np.mean(backing[a:b]**2)))<floor:continue
        if any(x.pitch==n.pitch and min(x.end,n.end)-max(x.start,n.start)>(n.end-n.start)*.65 for x in lead):continue
        target=snap(n.start,beats,period);delta=target-n.start if abs(target-n.start)<=.045 else 0
        start=max(0,n.start+delta);end=min(duration,n.end+delta)
        priority=n.velocity+15*recurs+10*belongs
        eligible.append((priority,pretty_midi.Note(int(np.clip(n.velocity-12,52,78)),n.pitch,start,end)))
    occupancy=np.zeros(int(duration*100)+2,dtype=np.int8);result=[]
    for _,n in sorted(eligible,key=lambda x:-x[0]):
        a,b=int(n.start*100),max(int(n.start*100)+1,int(np.ceil(n.end*100)))
        if np.any(occupancy[a:b]>=2):continue
        occupancy[a:b]+=1;result.append(n)
    return sorted(result,key=lambda n:(n.start,n.pitch))


def arrange_balanced(midi,backing,rate,beats,duration,tempo=120,vocal_mode='tuned'):
    beats,period=beat_grid(beats,duration,tempo)
    lead=next((i.notes for i in midi.instruments if i.name=='Lead melody'),[])
    bass=next((i.notes for i in midi.instruments if i.name=='Bass'),[])
    candidates=[n for i in midi.instruments if i.name.startswith('Accompaniment') for n in i.notes]
    chords=chord_sequence(backing,rate,beats,period,bass,duration)
    result=pretty_midi.PrettyMIDI(initial_tempo=tempo,resolution=960)
    melody=pretty_midi.Instrument(80,name='Lead melody')
    melody.notes=rhythmic_line(lead,beats,period,duration,minimum_duration=.10 if vocal_mode=='stable' else .055,snap_timing=vocal_mode!='tuned')
    low=pretty_midi.Instrument(33,name='Rhythmic bass')
    low.notes=rhythmic_line(bass,beats,period,duration,bass=True)
    pad=pretty_midi.Instrument(48,name='Voiced harmony')
    previous=(48,55,60);last={}
    for a,b,chord,score in chords:
        if chord is None or b-a<period*.6 or score<.50:continue
        previous=voice_chord(chord[2],previous)
        pitches=list(previous)
        extra=max(previous)+12
        if extra>76:extra=min(previous)-12
        pitches.append(extra)
        for pitch in pitches:
            end=min(duration,b-.02)
            if pitch in last and abs(last[pitch].end-a)<.04:
                last[pitch].end=end
            elif end>a:
                n=pretty_midi.Note(12,pitch,a,end);pad.notes.append(n);last[pitch]=n
    hooks=pretty_midi.Instrument(0,name='Backing hooks')
    hooks.notes=source_hooks(candidates,chords,melody.notes,backing,rate,beats,period,duration)
    result.instruments=[i for i in (melody,low,pad,hooks) if i.notes]
    return result,{'style':'Balanced arrangement','max_voices':8,
        'melody_notes':len(melody.notes),'bass_notes':len(low.notes),'harmony_notes':len(pad.notes),
        'hook_notes':len(hooks.notes),'source_backing_candidates':len(candidates),
        'interpretation':'Source-derived lead, bass and hooks with inferred voiced harmony.'}
