"""Local audio-to-MIDI: separate full mixes, then transcribe the pitched parts."""
import argparse
import contextlib
import json
import logging
import os
from pathlib import Path
import sys
import tempfile
import time

os.environ.setdefault("OMP_NUM_THREADS", "4")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "2")
os.environ.setdefault("NUMBA_NUM_THREADS", "2")
logging.basicConfig(level=logging.ERROR)
ROOT = Path(__file__).resolve().parent
os.environ.setdefault("TORCH_HOME", str(ROOT / "Models"))


def report(message, percent, progress_file=None):
    print(message, file=sys.stderr, flush=True)
    if progress_file:
        progress_file = Path(progress_file)
        progress_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = progress_file.with_suffix(".tmp")
        temporary.write_text(json.dumps({"message": message, "percent": percent}), encoding="utf-8")
        temporary.replace(progress_file)


def clean_notes(notes, minimum=0.08, merge_gap=0.04):
    """Join tiny same-pitch gaps and remove isolated pitch glitches."""
    import pretty_midi
    grouped = {}
    for note in sorted(notes, key=lambda n: (n.pitch, n.start)):
        if note.end <= note.start or note.start < 0:
            continue
        previous = grouped.setdefault(note.pitch, [])
        if previous and note.start - previous[-1].end <= merge_gap:
            previous[-1].end = max(previous[-1].end, note.end)
            previous[-1].velocity = max(previous[-1].velocity, note.velocity)
        else:
            previous.append(pretty_midi.Note(note.velocity, note.pitch, note.start, note.end))
    return sorted((n for group in grouped.values() for n in group if n.end-n.start >= minimum),
                  key=lambda n: (n.start, n.pitch))


def monophonic_notes(audio, sample_rate, kind):
    """Follow the fundamental on an isolated lead/bass, rather than its harmonics."""
    import librosa
    import numpy as np
    import pretty_midi
    from scipy.ndimage import median_filter

    audio = librosa.resample(audio, orig_sr=sample_rate, target_sr=16000)
    if np.max(np.abs(audio), initial=0) < 1e-5:
        return []
    hop = 256
    low, high, frame = (28, 60, 4096) if kind == "bass" else (45, 88, 2048)
    # Chunked pYIN bounds memory on full-length songs; discard the context overlap.
    notes = []
    for offset in range(0, len(audio), 20*16000):
        begin = max(0, offset-16000)
        end = min(len(audio), offset+21*16000)
        chunk = audio[begin:end]
        f0, voiced, probability = librosa.pyin(
            chunk, fmin=librosa.midi_to_hz(low), fmax=librosa.midi_to_hz(high),
            sr=16000, frame_length=frame, hop_length=hop, fill_na=np.nan)
        rms = librosa.feature.rms(y=chunk, frame_length=frame, hop_length=hop)[0][:len(f0)]
        floor = max(1e-5, float(np.max(rms))*0.025)
        # pYIN's Viterbi voicing already rejects unpitched frames. Requiring a
        # near-certain frame probability here truncates breathy/vibrato vocals.
        valid = voiced & (probability >= (0.35 if kind == "bass" else 0.20)) & (rms > floor)
        pitch = np.rint(librosa.hz_to_midi(np.nan_to_num(f0, nan=440.0))).astype(int)
        # Smooth one-frame semitone flicker without extending across rests.
        pitch = median_filter(pitch, size=3)
        pitch[~valid] = -1
        for i in range(1, len(pitch)-1):
            if pitch[i] == -1 and pitch[i-1] == pitch[i+1] >= 0:
                pitch[i] = pitch[i-1]
        run = 0
        for i in range(1, len(pitch)+1):
            if i < len(pitch) and pitch[i] == pitch[run]:
                continue
            start = max(offset/16000, (begin+run*hop)/16000)
            finish = min((offset+20*16000)/16000, (begin+i*hop)/16000, len(audio)/16000)
            if pitch[run] >= 0 and finish-start >= 0.05:
                level = float(np.mean(rms[run:i])) / max(float(np.max(rms)), 1e-5)
                velocity = int(np.clip(60+45*np.sqrt(level), 55, 110))
                notes.append(pretty_midi.Note(velocity, int(pitch[run]), start, finish))
            run = i
    return clean_notes(notes, minimum=0.09, merge_gap=0.05)


def separate_mix(audio, sample_rate, progress_file=None):
    import random
    import librosa
    import numpy as np
    import torch
    from demucs.apply import apply_model
    from demucs.pretrained import get_model

    torch.set_num_threads(4)
    torch.manual_seed(0)
    random.seed(0)
    report("Loading the instrument-separation model (first run downloads weights)...", 8, progress_file)
    model = get_model("htdemucs")
    model.eval()
    rate = model.samplerate
    audio = librosa.resample(audio, orig_sr=sample_rate, target_sr=rate, axis=0)
    wave = torch.from_numpy(np.ascontiguousarray(audio.T)).float()
    reference = wave.mean(0)
    mean, std = reference.mean(), reference.std().clamp_min(1e-6)
    report("Separating vocals, bass, drums and accompaniment locally...", 15, progress_file)
    with torch.inference_mode():
        estimates = apply_model(model, ((wave-mean)/std)[None], device="cpu", shifts=1,
                                split=True, overlap=0.25, progress=True, num_workers=0)[0]
        estimates = estimates*std+mean
    return {name: estimates[i].mean(0).numpy() for i, name in enumerate(model.sources)}, rate


def convert(source: Path, output: Path, sensitivity: float = 0.5, *, mode="solo",
            max_seconds=0, start_seconds=0, progress_file=None, work_dir=None,
            analysis_dir=None,vocal_mode='tuned',vocal_smoothing='balanced') -> dict:
    import basic_pitch
    from basic_pitch.inference import Model, predict
    import onnxruntime as ort
    import pretty_midi
    import numpy as np
    import soundfile as sf
    from musical_notes import tracked_notes, level_audio, backing_notes, align_attacks
    started = time.monotonic()

    if not source.is_file():
        raise FileNotFoundError(f"Audio file not found: {source}")
    if source.suffix.lower() not in {".mp3", ".wav", ".flac", ".ogg"}:
        raise ValueError("Choose an MP3, WAV, FLAC or OGG file.")
    if output.exists():
        raise FileExistsError(f"Output already exists; choose another name: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    report("Decoding audio...", 2, progress_file)
    with sf.SoundFile(source) as handle:
        sample_rate = handle.samplerate
        handle.seek(min(len(handle), int(start_seconds*sample_rate)))
        frames = int(max_seconds*sample_rate) if max_seconds else -1
        audio = handle.read(frames=frames, dtype="float32", always_2d=True)
    if len(audio) < sample_rate/4:
        raise ValueError("Choose at least a quarter-second of audio.")
    if audio.shape[1] == 1:
        audio = np.repeat(audio, 2, axis=1)
    else:
        audio = audio[:, :2]
    duration = len(audio)/sample_rate
    model_path = Path(basic_pitch.__file__).parent / "saved_models/icassp_2022/nmp.onnx"

    class CpuModel(Model):
        def __init__(self):
            options = ort.SessionOptions()
            options.intra_op_num_threads = 4
            options.inter_op_num_threads = 1
            self.model_type = Model.MODEL_TYPES.ONNX
            self.model = ort.InferenceSession(str(model_path), sess_options=options,
                                            providers=["CPUExecutionProvider"])

    result = pretty_midi.PrettyMIDI(initial_tempo=120, resolution=480)
    rhythm = None
    arrangement_details=None
    with tempfile.TemporaryDirectory(prefix="orchestra-transcribe-", dir=work_dir or ROOT) as work:
        work = Path(work)
        if mode in ("mix","arrange","balanced"):
            stems, sample_rate = separate_mix(audio, sample_rate, progress_file)
            del audio
            if analysis_dir:
                analysis_dir=Path(analysis_dir);analysis_dir.mkdir(parents=True,exist_ok=True)
                for name, stem in stems.items():
                    sf.write(analysis_dir/(name+'.wav'),stem,sample_rate,subtype='FLOAT')
            import librosa
            rhythm_audio = librosa.resample(stems['drums'], orig_sr=sample_rate, target_sr=22050)
            tempo, beats = librosa.beat.beat_track(y=rhythm_audio, sr=22050, units='time')
            if len(beats) >= 8 and float(np.ravel(tempo)[0]) > 0:
                # Fit the beat sequence instead of using a single quantised
                # inter-beat interval, which can skew a steady 120 BPM song.
                rhythm = 60/float(np.polyfit(np.arange(len(beats)),beats,1)[0])
                result = pretty_midi.PrettyMIDI(initial_tempo=rhythm, resolution=960)
            for kind, title, program, percent in [("vocals", "Lead melody", 80, 48), ("bass", "Bass", 33, 66)]:
                if kind=='vocals' and vocal_mode=='omit':continue
                report("Transcribing "+title.lower()+"...", percent, progress_file)
                track = pretty_midi.Instrument(program=program, name=title)
                def progress(fraction):
                    report('Following '+title.lower()+' phrases: '+str(round(fraction*100))+'%',
                           percent+int(fraction*16),progress_file)
                track.notes = tracked_notes(stems[kind], sample_rate, kind, progress,
                    vocal_mode=vocal_mode,vocal_smoothing=vocal_smoothing)
                if track.notes:
                    result.instruments.append(track)
            if mode == 'arrange':
                report('Arranging a clear lead, bass and restrained chords...',86,progress_file)
                from arrangement import arrange
                result,arrangement_details=arrange(result,stems['other'],sample_rate,beats,duration,rhythm or 120)
            report("Transcribing accompaniment and chords...", 82, progress_file)
            backing = stems["other"]
            sf.write(work/"pitched.wav", level_audio(backing,sample_rate), sample_rate, subtype="FLOAT")
            # The drum stem is deliberately never passed to a pitch detector.
            del stems
            onset = max(0.2, sensitivity-0.1)
        else:
            report("Transcribing isolated instrument and chords...", 15, progress_file)
            sf.write(work/"pitched.wav", audio.mean(axis=1), sample_rate, subtype="FLOAT")
            onset = sensitivity
        if mode != 'arrange':
            with contextlib.redirect_stdout(sys.stderr):
                prediction, detected, _ = predict(str(work/"pitched.wav"), CpuModel(), onset_threshold=onset,
                                     frame_threshold=0.25 if mode in ("mix","balanced") else 0.3,
                                     minimum_note_length=90 if mode in ("mix","balanced") else 80,
                                     multiple_pitch_bends=False)
        if mode in ('mix','balanced'):
            recovered = backing_notes(prediction, duration, sensitivity)
            align_attacks(recovered, backing, sample_rate)
            detected.instruments = [pretty_midi.Instrument(program=0)]
            detected.instruments[0].notes = recovered
            if analysis_dir:
                np.savez_compressed(analysis_dir/'backing-model.npz',**prediction)
        bands = {name: pretty_midi.Instrument(program=0, name=("Accompaniment " if mode in ("mix","balanced") else "Transcribed ")+name)
                 for name in ("Low", "Mid", "High")}
        for instrument in (detected.instruments if mode != 'arrange' else []):
            for note in (instrument.notes if mode in ('mix','balanced') else clean_notes(instrument.notes)):
                if note.end <= note.start:
                    continue
                note.end = min(note.end, duration)
                if note.start >= note.end:
                    continue
                band = "Low" if note.pitch < 60 else "Mid" if note.pitch < 72 else "High"
                bands[band].notes.append(note)
        result.instruments.extend(band for band in bands.values() if band.notes)
        if mode == 'balanced':
            report('Balancing source rhythm, backing hooks and voiced harmony...',91,progress_file)
            from arrangement import arrange_balanced
            if analysis_dir:result.write(str(analysis_dir/'source-notes.mid'))
            result,arrangement_details=arrange_balanced(result,backing,sample_rate,beats,duration,rhythm or 120,vocal_mode=vocal_mode)
    count = sum(len(i.notes) for i in result.instruments)
    if not count:
        raise ValueError("No pitched notes were detected. Try a cleaner recording or lower threshold.")
    report("Writing MIDI...", 97, progress_file)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".mid", delete=False) as handle:
            temporary = Path(handle.name)
        result.write(str(temporary))
        # On Windows rename fails if the destination appeared during conversion.
        temporary.rename(output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    details = {"output": str(output.resolve()), "notes": count,
               "seconds": round(result.get_end_time(), 3), "source_seconds": round(duration, 3),
               "tracks": len(result.instruments), "mode": mode,
               "vocal_mode":vocal_mode,
               "vocal_smoothing":vocal_smoothing if vocal_mode=='tuned' and mode!='solo' else None,
               "parts": {i.name: len(i.notes) for i in result.instruments},
               "elapsed_seconds": round(time.monotonic()-started, 1),
               "tempo_bpm": round(rhythm,2) if rhythm else None,
               "method": "Balanced source rhythm/hooks and voiced harmony" if mode == 'balanced' else "Simplified lead/bass/chord arrangement" if mode == 'arrange' else "Demucs + CREPE phrase tracking + adaptive Basic Pitch chords" if mode == "mix" else "Basic Pitch"}
    if arrangement_details: details['arrangement']=arrangement_details
    report("Conversion complete.", 100, progress_file)
    return details


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--mode", choices=["balanced","arrange","mix", "solo"], default="balanced")
    parser.add_argument("--max-seconds", type=float, default=0)
    parser.add_argument("--start-seconds", type=float, default=0)
    parser.add_argument("--progress-file", type=Path)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--analysis-dir", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--vocals",choices=['tuned','stable','detailed','omit'],default='tuned')
    parser.add_argument("--vocal-smoothing",choices=['gentle','balanced','firm'],default='balanced')
    args = parser.parse_args()
    if not 0.1 <= args.threshold <= 0.9:
        parser.error("Threshold must be between 0.1 and 0.9")
    try:
        if args.max_seconds < 0 or args.start_seconds < 0:
            parser.error("Time values must be non-negative")
        print(json.dumps(convert(args.input, args.output, args.threshold, mode=args.mode,
                                 max_seconds=args.max_seconds, start_seconds=args.start_seconds,
                                 progress_file=args.progress_file, work_dir=args.work_dir,
                                 analysis_dir=args.analysis_dir,vocal_mode=args.vocals,
                                 vocal_smoothing=args.vocal_smoothing)), flush=True)
    except Exception as error:
        print(f"Conversion failed: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
