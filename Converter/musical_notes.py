"""Audio-supported note decoding: phrase continuity, attacks and quiet backing parts."""
import numpy as np
from scipy.ndimage import binary_propagation, median_filter, uniform_filter1d
from scipy.signal import find_peaks


def regions(mask):
    edges = np.diff(np.r_[False, mask, False].astype(np.int8))
    return zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1))


def level_audio(audio, rate):
    """Slow gain recovery for quiet passages; leave silence and transients intact."""
    import librosa
    audio = np.asarray(audio, dtype=np.float32)
    if not len(audio):
        return audio
    hop = 256
    rms = librosa.feature.rms(y=audio, frame_length=2048, hop_length=hop)[0]
    smooth = uniform_filter1d(rms, max(3, int(rate/hop)), mode="nearest")
    gain = np.minimum(5.0, 0.12/np.maximum(smooth, 0.024))
    gain = np.interp(np.arange(len(audio)), np.arange(len(gain))*hop, gain)
    return np.asarray(np.clip(audio*gain, -1, 1), dtype=np.float32)


def tuned_vocal_notes(frequencies,confidence,rms,step,duration,smoothing='balanced'):
    """Fit held chromatic note states instead of copying every sung inflection."""
    import librosa
    import pretty_midi
    if smoothing not in ('gentle','balanced','firm'):
        raise ValueError('Vocal smoothing must be gentle, balanced or firm')
    change_cost,inflection_limit={'gentle':(.65,.11),'balanced':(1.,.18),'firm':(1.45,.24)}[smoothing]
    count=min(len(frequencies),len(confidence),len(rms))
    if not count:return []
    frequency=np.asarray(frequencies[:count])
    certainty=median_filter(np.nan_to_num(confidence[:count]),3)
    energy=median_filter(np.asarray(rms[:count]),3)
    if np.max(energy)<1e-6:return []
    pitch=median_filter(librosa.hz_to_midi(np.maximum(frequency,1)),3)
    floor=max(1e-5,float(np.percentile(energy,95))*.018)
    weak=(certainty>=.13)&(energy>floor)&np.isfinite(pitch)
    strong=(certainty>=.32)&weak
    voiced=binary_propagation(strong,mask=weak)
    # Brief consonants/uncertainty can interrupt F0 while the sung note carries
    # on. Bridge only bounded gaps with audible energy, never actual silence.
    for a,b in list(regions(~voiced)):
        if a and b<count and (b-a)*step<=.16 and np.min(energy[a:b])>floor:
            voiced[a:b]=True
    output=[]
    for begin,end in regions(voiced):
        if (end-begin)*step<.08:continue
        observed=pitch[begin:end];strength=np.clip((certainty[begin:end]-.13)/.87,0,1)**2
        evidence=observed[strength>.03]
        if not len(evidence):continue
        lower=max(36,int(np.floor(np.min(evidence)))-1)
        upper=min(96,int(np.ceil(np.max(evidence)))+1)
        states=np.arange(lower,upper+1)
        distance=np.abs(states[:,None]-states[None,:])
        transition=np.where(distance==0,0,change_cost*(1.8+.12*distance+.9*(distance>=7)))
        # Changing note has a cost. Sustained evidence overcomes it; vibrato
        # and low-confidence frames generally keep the current intended note.
        emissions=np.minimum((observed[:,None]-states[None,:])**2,16)*strength[:,None]
        values=emissions[0].copy();parents=[]
        for row in emissions[1:]:
            choices=values[:,None]+transition
            parent=np.argmin(choices,axis=0);parents.append(parent)
            values=row+choices[parent,np.arange(len(states))]
        path=[int(np.argmin(values))]
        for parent in reversed(parents):path.append(int(parent[path[-1]]))
        path=states[np.asarray(path[::-1])]
        for _ in range(2):
            bounds=np.r_[0,np.flatnonzero(np.diff(path))+1,len(path)]
            for index,(a,b) in enumerate(zip(bounds[:-1],bounds[1:])):
                segment=observed[a:b]
                wing=max(1,len(segment)//3)
                glide=abs(float(np.median(segment[-wing:])-np.median(segment[:wing])))>.20
                if (b-a)*step>inflection_limit:continue
                if not a:
                    if b<len(path) and glide:path[a:b]=path[b]
                    continue
                if b==len(path):
                    if glide:path[a:b]=path[a-1]
                    continue
                local=begin+a
                before=energy[max(begin,local-int(.12/step)):local+1]
                after=energy[local:min(end,local+int(.10/step)+1)]
                attack=len(before)>0 and len(after)>0 and np.min(before)<np.max(after)*.60
                if attack:continue
                if path[a-1]==path[b]:
                    path[a:b]=path[a-1]
                else:
                    if (b-a)*step<.075 or glide:
                        left,right=path[a-1],path[b]
                        path[a:b]=left if np.mean((segment-left)**2)<=np.mean((segment-right)**2) else right
        bounds=np.r_[0,np.flatnonzero(np.diff(path))+1,len(path)]
        for a,b in zip(bounds[:-1],bounds[1:]):
            if (b-a)*step<.075:continue
            # Pitch smoothing must not turn repeated syllables at the same
            # pitch into one drone. Keep clear energy-separated attacks.
            envelope=uniform_filter1d(energy[begin+a:begin+b],3)
            peaks,_=find_peaks(np.r_[0,envelope,0],distance=max(1,int(.09/step)),
                prominence=max(floor,float(np.max(envelope))*.18))
            peaks=peaks-1;peaks=peaks[(peaks>=0)&(peaks<len(envelope))]
            cuts=[a]
            for left,right in zip(peaks[:-1],peaks[1:]):
                valley=left+int(np.argmin(envelope[left:right+1]))
                if envelope[valley]<min(envelope[left],envelope[right])*.60:
                    cut=a+valley
                    if (cut-cuts[-1])*step>=.075 and (b-cut)*step>=.075:cuts.append(cut)
            cuts.append(b)
            for start,finish in zip(cuts[:-1],cuts[1:]):
                on=(begin+start)*step;off=min(duration,(begin+finish)*step)
                if off-on>=.065:output.append(pretty_midi.Note(106,int(path[a]),on,off))
    return output


def contour_to_notes(frequencies, confidence, rms, step, duration, kind, stable_vocal=False):
    """Use hysteresis to sustain credible notes through short uncertain frames."""
    import librosa
    import pretty_midi
    count = min(len(frequencies), len(confidence), len(rms))
    frequencies, confidence, rms = frequencies[:count], confidence[:count], rms[:count]
    if not count or np.max(rms) < 1e-6:
        return []
    confidence = median_filter(confidence, 3)
    floor = max(1e-5, float(np.percentile(rms, 95))*0.018)
    # A weak frame may continue a credible phrase, but cannot start one alone.
    weak = (confidence >= (0.16 if kind == "bass" else 0.13)) & (rms > floor)
    strong = (confidence >= (0.42 if kind == "bass" else 0.32)) & weak
    valid = binary_propagation(strong, mask=weak)
    smoothing = max(3, int(round(0.04/step)) | 1)
    semitones = median_filter(librosa.hz_to_midi(np.maximum(frequencies, 1)), smoothing)
    pitches = np.full(count, -1, dtype=int)
    previous = -1
    for i in range(count):
        if not valid[i]:
            previous = -1
            continue
        candidate = int(round(semitones[i]))
        # Vibrato near a semitone boundary must not chop a held note apart.
        if previous >= 0 and abs(semitones[i]-previous) < 0.72:
            candidate = previous
        pitches[i] = previous = candidate
    # Bridge short confidence gaps only between matching pitches, with actual
    # energy still present. Real silent rests are never filled.
    for a, b in list(regions(pitches < 0)):
        if a and b < count and (b-a)*step <= 0.09 and pitches[a-1] == pitches[b]:
            if np.min(rms[a:b]) > floor:
                pitches[a:b] = pitches[a-1]
    # Remove a brief pitch wobble only when the same surrounding note supports it.
    boundaries = np.r_[0, np.flatnonzero(np.diff(pitches)) + 1, count]
    for index,(a,b) in enumerate(zip(boundaries[:-1],boundaries[1:])):
        vocal_scoop=(stable_vocal and kind=='vocals' and index>0 and index+2<len(boundaries)
            and (b-a)*step<=.16 and (a-boundaries[index-1])*step>=.18
            and (boundaries[index+2]-b)*step>=.18 and abs(pitches[a]-pitches[a-1])<=2)
        if a and b < count and ((b-a)*step < 0.06 or vocal_scoop) and pitches[a-1] == pitches[b] >= 0:
            if np.min(rms[a:b]) > floor:
                pitches[a:b] = pitches[a-1]
    notes = []
    boundaries = np.r_[0, np.flatnonzero(np.diff(pitches)) + 1, count]
    reference = max(float(np.percentile(rms, 95)), 1e-6)
    for a, b in zip(boundaries[:-1], boundaries[1:]):
        if pitches[a] < 0 or (b-a)*step < 0.065:
            continue
        if stable_vocal and kind == 'vocals':
            certainty=float(np.median(confidence[a:b]))
            anchored=float(np.mean(confidence[a:b]>=.45))
            spread=float(np.percentile(semitones[a:b],80)-np.percentile(semitones[a:b],20))
            # A confident neighbouring vowel cannot legitimise an uncertain
            # consonant, backing-voice fragment or passing speech inflection.
            if certainty<.32 or anchored<.30 or spread>.75:continue
            if (b-a)*step<.12 and (certainty<.78 or spread>.40):continue
        # Repeated attacks at the same pitch are distinct notes, not one drone.
        energy = uniform_filter1d(rms[a:b], 3)
        peaks, _ = find_peaks(energy, distance=max(1, int(0.09/step)),
                              prominence=max(floor, float(np.max(energy))*0.18))
        splits = [a]
        for left, right in zip(peaks[:-1], peaks[1:]):
            valley = left+int(np.argmin(energy[left:right+1]))
            if energy[valley] < min(energy[left], energy[right])*0.60:
                cut = a+valley
                if (cut-splits[-1])*step >= 0.075 and (b-cut)*step >= 0.075:
                    splits.append(cut)
        splits.append(b)
        for begin, end in zip(splits[:-1], splits[1:]):
            velocity = int(np.clip(48+58*np.sqrt(float(np.mean(rms[begin:end]))/reference), 45, 112))
            finish = min(duration, end*step)
            if finish > begin*step:
                notes.append(pretty_midi.Note(velocity, int(pitches[a]), begin*step, finish))
    return notes


def tracked_notes(audio, rate, kind, progress=None, vocal_mode='tuned', diagnostics=None,
                  vocal_smoothing='balanced'):
    """CREPE full model with a continuous decoded contour across processing chunks."""
    import librosa
    import torch
    import torchcrepe
    torch.set_num_threads(4)
    audio = librosa.resample(audio, orig_sr=rate, target_sr=16000)
    if np.max(np.abs(audio), initial=0) < 1e-5:
        return []
    hop, chunk_samples = 320, 16*16000
    count = 1+len(audio)//hop
    frequency = np.zeros(count, dtype=np.float32)
    confidence = np.zeros(count, dtype=np.float32)
    crepe_frequency=np.zeros(count,dtype=np.float32) if diagnostics else None
    yin_frequency=np.zeros(count,dtype=np.float32) if diagnostics else None
    fmin, fmax = (35.0, 300.0) if kind == "bass" else (65.0, 1250.0)
    for offset in range(0, len(audio), chunk_samples):
        # Context avoids a false attack or dropout at a chunk boundary.
        begin, end = max(0, offset-8000), min(len(audio), offset+chunk_samples+8000)
        wave = torch.from_numpy(np.ascontiguousarray(audio[begin:end]))[None]
        # Decode the complete contextual chunk, not each inference minibatch.
        # Independent batch decoders can reset the melody every 1.28 seconds.
        with torch.inference_mode():
            activations = [torchcrepe.infer(batch, model="full", device="cpu")
                for batch in torchcrepe.preprocess(wave, 16000, hop, batch_size=128, device="cpu")]
            logits = torch.cat(activations).T[None]
            def stable_viterbi(values):
                bins, _ = torchcrepe.decode.viterbi(values)
                # CREPE normally dithers F0 by up to 20 cents. That is useful
                # for continuous audio synthesis, but MIDI rounding must repeat.
                cents=bins.to(torch.float32)*torchcrepe.CENTS_PER_BIN+1997.3794084376191
                return bins,10*torch.pow(2.0,cents/1200)
            pitch, periodicity = torchcrepe.postprocess(logits, fmin, fmax,
                decoder=stable_viterbi, return_periodicity=True)
        if kind == 'bass':
            pitch,periodicity=pitch.clone(),periodicity.clone()
            # Very low fundamentals can be mistaken for their octave by CREPE.
            # Independent periodicity evidence disambiguates these cases.
            yin, _, yin_confidence = librosa.pyin(audio[begin:end], sr=16000,
                fmin=librosa.midi_to_hz(28), fmax=librosa.midi_to_hz(60),
                frame_length=4096, hop_length=hop, fill_na=None)
            length=min(len(yin),pitch.shape[-1])
            crepe=pitch[0,:length].numpy()
            certainty=periodicity[0,:length].numpy()
            distance=librosa.hz_to_midi(np.maximum(crepe,1))-librosa.hz_to_midi(np.maximum(yin[:length],1))
            octave=(np.abs(np.abs(distance)-12)<0.7) | (np.abs(np.abs(distance)-24)<0.7)
            choose=(octave & (yin_confidence[:length]>.22)) | (yin_confidence[:length]>.60) | ((certainty<.35)&(yin_confidence[:length]>.4))
            pitch[0,:length][torch.from_numpy(choose)]=torch.from_numpy(yin[:length][choose].astype(np.float32))
            periodicity[0,:length][torch.from_numpy(choose)]=torch.from_numpy(yin_confidence[:length][choose].astype(np.float32))
        elif kind == 'vocals' and vocal_mode in ('stable','tuned'):
            pitch,periodicity=pitch.clone(),periodicity.clone()
            yin,_,yin_confidence=librosa.pyin(audio[begin:end],sr=16000,
                fmin=65,fmax=1250,frame_length=2048,hop_length=hop,fill_na=None)
            length=min(len(yin),pitch.shape[-1])
            original=pitch[0,:length].numpy().copy()
            certainty=periodicity[0,:length].numpy()
            difference=librosa.hz_to_midi(np.maximum(original,1))-librosa.hz_to_midi(np.maximum(yin[:length],1))
            agree=np.abs(difference)<1.25
            lower_octave=(np.abs(difference-12)<.65)|(np.abs(difference-24)<.65)
            choose=(agree&(yin_confidence[:length]>.55))|(lower_octave&(yin_confidence[:length]>.75)&(certainty<.7))
            indices=torch.from_numpy(choose)
            pitch[0,:length][indices]=torch.from_numpy(yin[:length][choose].astype(np.float32))
            periodicity[0,:length][indices]=torch.maximum(periodicity[0,:length][indices],torch.from_numpy(yin_confidence[:length][choose].astype(np.float32)))
            conflict=(np.abs(difference)>1.25)&~lower_octave&(yin_confidence[:length]>.55)&(certainty<.70)
            periodicity[0,:length][torch.from_numpy(conflict)]=.05
        a, b = offset//hop, min(count, (offset+chunk_samples)//hop)
        if end == len(audio):
            b = count
        local = (offset-begin)//hop
        size = min(b-a, pitch.shape[-1]-local)
        frequency[a:a+size] = pitch[0, local:local+size].numpy()
        confidence[a:a+size] = periodicity[0, local:local+size].numpy()
        if diagnostics and kind=='vocals' and vocal_mode in ('stable','tuned'):
            crepe_frequency[a:a+size]=original[local:local+size]
            yin_frequency[a:a+size]=yin[local:local+size]
        if progress:
            progress(min(1, (offset+chunk_samples)/len(audio)))
    rms = librosa.feature.rms(y=audio, frame_length=1024, hop_length=hop)[0]
    if diagnostics:np.savez_compressed(diagnostics,frequency=frequency,confidence=confidence,rms=rms,crepe=crepe_frequency,yin=yin_frequency)
    if kind=='vocals' and vocal_mode=='tuned':
        return tuned_vocal_notes(frequency,confidence,rms,hop/16000,len(audio)/16000,vocal_smoothing)
    return contour_to_notes(frequency, confidence, rms, hop/16000, len(audio)/16000, kind,
                            stable_vocal=(kind=='vocals' and vocal_mode=='stable'))


def backing_notes(prediction, duration, sensitivity=0.5):
    """Strong note starts and a lower sustain threshold preserve quiet chord tails."""
    import pretty_midi
    from basic_pitch.note_creation import model_frames_to_time
    frames = median_filter(prediction["note"], size=(3, 1))
    onsets = prediction["onset"]
    times = model_frames_to_time(len(frames)+1)
    notes = []
    # Eight strong pitches may seed a chord; weak bins alone cannot seed notes.
    rank_floor = np.sort(frames, axis=1)[:, -8]
    for column in range(frames.shape[1]):
        signal = frames[:, column]
        background = float(np.percentile(signal, 15))
        off = max(0.09, min(0.22, background*2.5+0.035))
        on = max(0.12, 0.25+(sensitivity-0.5)*0.4, off+0.10)
        strong = (signal >= on) & (signal >= rank_floor)
        weak = signal >= off
        active = binary_propagation(strong, mask=weak)
        # Very short activation dips are common in plucked/chorus instruments.
        for a, b in list(regions(~active)):
            if a and b < len(active) and times[b]-times[a] <= 0.055 and np.min(signal[a:b]) >= 0.03:
                active[a:b] = True
        attack_peaks, _ = find_peaks(onsets[:, column], height=0.25, distance=7, prominence=0.12)
        for a, b in regions(active):
            if times[b]-times[a] < 0.075:
                continue
            splits = [a]
            for attack in attack_peaks[(attack_peaks > a+6) & (attack_peaks < b-6)]:
                if times[attack]-times[splits[-1]] >= 0.075:
                    splits.append(int(attack))
            splits.append(b)
            for begin, end in zip(splits[:-1], splits[1:]):
                start, finish = max(0.0, float(times[begin])), min(duration, float(times[end]))
                if finish-start >= 0.07:
                    velocity = int(np.clip(40+80*np.sqrt(float(np.mean(signal[begin:end]))), 40, 110))
                    notes.append(pretty_midi.Note(velocity, column+21, start, finish))
    return sorted(notes, key=lambda n: (n.start, n.pitch))


def align_attacks(notes, audio, rate):
    """Correct small detector delays against actual attacks; never force a beat grid."""
    import librosa
    if not notes:
        return notes
    hop = 256
    strength = librosa.onset.onset_strength(y=audio, sr=rate, hop_length=hop)
    attacks = librosa.onset.onset_detect(onset_envelope=strength, sr=rate,
        hop_length=hop, units="time", backtrack=False)
    for note in notes:
        if len(attacks):
            index = int(np.argmin(np.abs(attacks-note.start)))
            delta = float(attacks[index]-note.start)
            if abs(delta) <= 0.035:
                note.start = max(0, note.start+delta)
                # Preserve the supported release, avoiding artificial legato.
                note.end = max(note.end, note.start+0.04)
    previous={}
    for note in sorted(notes,key=lambda n:(n.pitch,n.start)):
        if note.pitch in previous and previous[note.pitch].end > note.start:
            previous[note.pitch].end=note.start
        previous[note.pitch]=note
    return notes
