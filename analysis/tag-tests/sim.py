"""Can one person's tagged nights show a real effect, and does the rule avoid false ones?
Simulated nights: AR(1) noise (phi 0.3), weekend shift, tags on some nights.
Test: mean(tagged) - mean(untagged), permutation p-value with tags shuffled within
weekday/weekend groups, Benjamini-Hochberg across all tags, plus a minimum size.
Numbers: TST night-to-night SD ~70 min (Messman 2022: 67 EEG, 77 actigraphy);
caffeine -45 min TST (Gardiner 2023). Sleeping HR SD 3 bpm and alcohol +2..+4 bpm are
assumptions (Pietila 2018 shows a dose effect on sleep HR/HRV but no bpm in the abstract)."""
import numpy as np
rng = np.random.default_rng(1)
PERM = 400

def nights(n, sd, weekend_shift):
    e = np.zeros(n); z = rng.normal(0, sd*np.sqrt(1-0.3**2), n); e[0] = rng.normal(0, sd)
    for i in range(1, n): e[i] = 0.3*e[i-1] + z[i]
    wk = (np.arange(n) % 7) >= 5
    return e + weekend_shift*wk, wk

def perm_p(y, t, wk):
    obs = y[t].mean() - y[~t].mean()
    cnt = 0
    for _ in range(PERM):
        tp = t.copy()
        for g in (wk, ~wk):
            idx = np.where(g)[0]; tp[idx] = rng.permutation(t[idx])
        if tp.sum() == 0 or (~tp).sum() == 0: continue
        if abs(y[tp].mean() - y[~tp].mean()) >= abs(obs): cnt += 1
    return (cnt+1)/(PERM+1), obs

def naive_p(y, t):
    obs = y[t].mean() - y[~t].mean(); cnt = 0
    for _ in range(PERM):
        tp = rng.permutation(t)
        if abs(y[tp].mean() - y[~tp].mean()) >= abs(obs): cnt += 1
    return (cnt+1)/(PERM+1), obs

def bh(ps, q=0.05):
    ps = np.asarray(ps); o = np.argsort(ps); m = len(ps); ok = np.zeros(m, bool)
    passed = ps[o] <= q*np.arange(1, m+1)/m
    if passed.any(): ok[o[:np.max(np.where(passed)[0])+1]] = True
    return ok

def run(weeks, sd, effect, rate, min_eff, ntags=6, sims=300, weekend_shift=30, weekend_tag=False, stratified=True, min_n=8):
    n = weeks*7; hits_real = 0; hits_false = 0
    for _ in range(sims):
        y, wk = nights(n, sd, weekend_shift)
        tags = []
        for k in range(ntags):
            if weekend_tag and k == 0: t = wk & (rng.random(n) < 0.8)
            else: t = rng.random(n) < rate
            tags.append(t)
        y = y + effect*tags[0]   # tag 0 has the real effect (or 0 for null)
        ps, ds = [], []
        for t in tags:
            if t.sum() < min_n or (~t).sum() < min_n: ps.append(1.0); ds.append(0); continue
            p, d = perm_p(y, t, wk) if stratified else naive_p(y, t)
            ps.append(p); ds.append(d)
        ok = bh(ps) & (np.abs(ds) >= min_eff)
        hits_real += ok[0]; hits_false += ok[1:].any()
    return hits_real/sims, hits_false/sims

if __name__ == "__main__":
    print("Tag 0 carries the effect; 5 other tags have none. 'shown' = rate the app would say 'linked'.")
    print("\nA) Caffeine-like tag, 2 nights/week, sleep time -45 min, SD 70, show if >=20 min")
    for w in (4, 8, 12, 16):
        r, f = run(w, 70, -45, 2/7, 20); print(f"  {w:2d} weeks: real effect shown {r:.0%}, any false tag shown {f:.0%}")
    print("\nB) Alcohol-like tag, 1 night/week, sleeping HR +3 bpm, SD 3, show if >=1.5 bpm")
    for w in (4, 8, 12, 16):
        r, f = run(w, 3, 3, 1/7, 1.5); print(f"  {w:2d} weeks: real effect shown {r:.0%}, any false tag shown {f:.0%}")
    print("\nB2) same, +2 bpm")
    for w in (8, 12):
        r, f = run(w, 3, 2, 1/7, 1.5); print(f"  {w:2d} weeks: real effect shown {r:.0%}, any false tag shown {f:.0%}")
    print("\nC) Same alcohol tag measured on sleep time, -20 min (assumed), SD 70")
    for w in (8, 16):
        r, f = run(w, 70, -20, 1/7, 20); print(f"  {w:2d} weeks: real effect shown {r:.0%}")
    print("\nD) Falsification: tag has NO effect but is mostly logged on weekends (weekend sleep +30 min)")
    for strat in (False, True):
        r, f = run(12, 70, 0, 0, 20, weekend_tag=True, stratified=strat)
        print(f"  {'weekday/weekend matched' if strat else 'naive comparison'}: no-effect tag shown as 'linked' {r:.0%}")
    print("\nE) All 6 tags have no effect, 12 weeks: any tag falsely shown")
    r, f = run(12, 70, 0, 2/7, 20); print(f"  {max(r,f):.0%} (tag0 {r:.0%}, others {f:.0%})")
