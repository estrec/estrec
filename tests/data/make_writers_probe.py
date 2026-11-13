"""Writes writers_probe.csv: a small simulated panel shared by the SAS, SPSS and Julia writer
probes and tests, so each tool's estimates can be checked against R and Python here.

100 units x 20 years (2,000 rows); groups of 5 units for clustering; survey strata and PSUs;
outcomes: continuous y, binary ybin, count cnt; regressors x1, x2 and a categorical cat (3
levels); instrument z for x1; positive weight w; a few missing values in x2 (rows 7, 400,
1500). Run: python tests/data/make_writers_probe.py
"""

from pathlib import Path

import numpy as np

rng = np.random.default_rng(20261113)
n_id, n_t = 100, 20
idv = np.repeat(np.arange(1, n_id + 1), n_t)
year = np.tile(np.arange(2001, 2001 + n_t), n_id)
grp = (idv - 1) // 5 + 1                         # 20 clusters
stratum = (grp - 1) // 5 + 1                     # 4 strata
psu = grp
a_id = rng.normal(0, 1, n_id)[idv - 1]           # unit effect
a_t = rng.normal(0, 0.5, n_t)[year - 2001]       # year effect
z = rng.normal(0, 1, idv.size)
x1 = 0.6 * z + 0.4 * a_id + rng.normal(0, 1, idv.size)
x2 = rng.normal(0, 1, idv.size)
cat = rng.integers(1, 4, idv.size)
w = rng.uniform(0.5, 2.0, idv.size)
u = rng.normal(0, 1, idv.size) + 0.3 * rng.normal(0, 1, n_id)[idv - 1]
y = 1.0 + 0.5 * x1 - 0.3 * x2 + 0.2 * (cat == 2) + 0.4 * (cat == 3) + a_id + a_t + u
eta = -0.2 + 0.7 * x1 - 0.5 * x2 + 0.5 * a_id
ybin = (rng.uniform(size=idv.size) < 1 / (1 + np.exp(-eta))).astype(int)
cnt = rng.poisson(np.exp(0.3 + 0.3 * x1 - 0.2 * x2 + 0.3 * a_id))
x2 = x2.round(6).astype(object)
for r in (6, 399, 1499):
    x2[r] = ""

out = Path(__file__).with_name("writers_probe.csv")
cols = dict(id=idv, year=year, grp=grp, stratum=stratum, psu=psu, cat=cat, x1=x1.round(6),
            x2=x2, z=z.round(6), w=w.round(6), y=y.round(6), ybin=ybin, cnt=cnt)
with out.open("w", newline="\n") as f:
    f.write(",".join(cols) + "\n")
    for i in range(idv.size):
        f.write(",".join(str(v[i]) for v in cols.values()) + "\n")
print(out, idv.size, "rows")
