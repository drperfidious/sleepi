# Apple-only version of evaluate.py for the Mac: same metrics and the same matched
# false-alarm procedure (bar set so that 1% of non-target clips are flagged), computed
# from apple_scores.csv (score_apple.swift) and labels.csv (make_testset.py).
# Usage: python3 evaluate_apple.py [testset dir] [apple_scores.csv]
import sys, csv, json, numpy as np

ts = sys.argv[1] if len(sys.argv) > 1 else 'testset'
rows = list(csv.DictReader(open(ts + '/labels.csv')))
cat = np.array([r['category'] for r in rows])
files = [r['file'] for r in rows]
scores = {(r['condition'], r['file']): r for r in csv.DictReader(open(sys.argv[2] if len(sys.argv) > 2 else 'apple_scores.csv'))}
conds = [c for c in ['clean', 'ac_10dB', 'ac_5dB', 'ac_0dB'] if (c, files[0]) in scores]
noise_files = sorted(f for c, f in scores if c == 'noise_only')
TARGETS = {'snoring': 'snoring', 'coughing': 'cough'}  # ESC-50 category: Apple label

def col(c, lab, fs):
    return np.array([float(scores[(c, f)][lab]) for f in fs])

def recall_at_fpr(y, s, fpr):
    thr = np.quantile(s[y == 0], 1 - fpr)
    return (s[y == 1] > thr).mean()

def auc(y, s):
    p, n = s[y == 1][:, None], s[y == 0][None, :]
    return (p > n).mean() + 0.5 * (p == n).mean()

res = {}
for tgt, lab in TARGETS.items():
    y = (cat == tgt).astype(int)
    r = {}
    for c in conds:
        s = col(c, lab, files)
        r[c] = {
            'apple_auc': round(auc(y, s), 3),
            'apple_recall@0.5': round((s[y == 1] > .5).mean(), 3),
            'apple_falsepos@0.5': round((s[y == 0] > .5).mean(), 4),
            'apple_recall@1%fp': round(recall_at_fpr(y, s, .01), 3),
            'apple_top_false_classes': sorted(
                {cc: int(((s > .5) & (cat == cc)).sum()) for cc in set(cat.tolist()) if cc != tgt}.items(),
                key=lambda t: -t[1])[:3],
        }
    nz = col('noise_only', lab, noise_files)
    r['noise_only_windows'] = len(nz)
    r['apple_noise_false_alarms@0.5'] = int((nz > .5).sum())
    res[tgt] = r

json.dump(res, open('apple_results.json', 'w'), indent=1)
for tgt, r in res.items():
    print('==', tgt, 'noise-only false alarms apple:', r['apple_noise_false_alarms@0.5'], 'of', r['noise_only_windows'])
    print(f"{'cond':10} {'AUC':>6} {'rec@.5':>7} {'fp@.5':>7} {'rec@1%fp':>9}")
    for c in conds:
        v = r[c]
        print(f"{c:10} {v['apple_auc']:6.3f} {v['apple_recall@0.5']:7.2f} {v['apple_falsepos@0.5']:7.3f} {v['apple_recall@1%fp']:9.2f}  {v['apple_top_false_classes']}")
