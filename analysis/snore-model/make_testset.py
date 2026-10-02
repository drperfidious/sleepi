# Build the held-out fan-noise test set used in refs/12, so Apple's built-in
# classifier (and any Create ML model) can be scored on exactly the same clips.
# Needs: ESC-50 (github.com/karolpiczak/ESC-50, CC BY-NC 3.0) and MS-SNSD noise_test
# (github.com/microsoft/MS-SNSD, MIT). Output: testset/<condition>/<file>.wav (16 kHz mono)
# plus testset/labels.csv. Conditions: clean and held-out air-conditioner noise at 10, 5, 0 dB SNR.
# Usage: python3 make_testset.py <ESC-50 dir> <MS-SNSD dir> [out dir]
import sys, os, glob, csv, numpy as np, soundfile as sf, librosa

SR = 16000
esc, snsd = sys.argv[1], sys.argv[2]
out = sys.argv[3] if len(sys.argv) > 3 else 'testset'

def load(f):
    x, sr = sf.read(f, dtype='float32')
    if x.ndim > 1: x = x.mean(1)
    return librosa.resample(x, orig_sr=sr, target_sr=SR) if sr != SR else x

def active_rms(x):
    fr = librosa.util.frame(np.pad(x, (0, 400)), frame_length=400, hop_length=160)
    e = np.sqrt((fr ** 2).mean(0) + 1e-12)
    a = e[e > e.max() * 10 ** (-30 / 20)]
    return np.sqrt((a ** 2).mean())

rng = np.random.default_rng(0)
noise = [load(f) for f in sorted(glob.glob(os.path.join(snsd, 'noise_test', 'AirConditioner*.wav')))]

def seg(i, n):
    x = noise[i % len(noise)]
    while len(x) < n: x = np.concatenate([x, x])
    s = rng.integers(0, len(x) - n + 1)
    return x[s:s + n]

rows = list(csv.DictReader(open(os.path.join(esc, 'meta', 'esc50.csv'))))
conds = [('clean', None), ('ac_10dB', 10), ('ac_5dB', 5), ('ac_0dB', 0)]
for c, _ in conds: os.makedirs(os.path.join(out, c), exist_ok=True)
with open(os.path.join(out, 'labels.csv'), 'w') as lf:
    lf.write('file,category,fold\n')
    for i, r in enumerate(rows):
        x = load(os.path.join(esc, 'audio', r['filename']))
        lf.write(f"{r['filename']},{r['category']},{r['fold']}\n")
        for c, snr in conds:
            y = x
            if snr is not None:
                nz = seg(i, len(x))
                y = x + nz * active_rms(x) / (nz.std() + 1e-9) / 10 ** (snr / 20)
                y = y / max(1.0, np.abs(y).max())
            sf.write(os.path.join(out, c, r['filename']), y.astype('float32'), SR, subtype='PCM_16')
print('wrote', len(rows), 'clips x', len(conds), 'conditions to', out)

# Added for the Mac run: noise-only windows for the false-alarm count, as in the pilot
# (held-out air-conditioner recordings, 5 s windows, scaled by 0.3, scored at a 0.5 bar).
os.makedirs(os.path.join(out, 'noise_only'), exist_ok=True)
n = 0
for i, x in enumerate(noise):
    for s in range(0, len(x) - 5 * SR + 1, 5 * SR):
        sf.write(os.path.join(out, 'noise_only', f'ac{i}_{s // SR:04d}.wav'), (x[s:s + 5 * SR] * 0.3).astype('float32'), SR, subtype='PCM_16')
        n += 1
print('wrote', n, 'noise-only windows')
