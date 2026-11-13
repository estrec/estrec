# EstRec.jl

Writes fitted Julia models as [estrec](https://estrec.org) records: a JSON file for one
estimation run, saying what was estimated, what came out, and how it ran.

```julia
using Pkg
Pkg.add(url = "https://github.com/estrec/estrec", subdir = "julia")

using EstRec, FixedEffectModels, CSV, DataFrames
df = CSV.read("panel.csv", DataFrame)
m = reg(df, @formula(y ~ x1 + x2 + fe(firm) + fe(year)), Vcov.cluster(:firm))
write_estimation(m, "fit.estrec.json"; data = df)
```

`to_estimation(m; data = df)` returns the record (an `OrderedDict`) without writing it.

## What it writes

| Package | Fits | Profiles |
|---|---|---|
| FixedEffectModels.jl (2.x) | `reg`: OLS and IV, with fixed effects; `Vcov.simple()`, `Vcov.robust()`, `Vcov.cluster(...)` | inference; linear-fe with fixed effects; iv |
| GLM.jl (1.9+) | `lm`; `glm` (any distribution and link) | inference; glm for `glm` |

The writers load with those packages (package extensions): EstRec itself depends on neither.

## Arguments

- `data`: the table the model was fitted on. Fixed-effects fits need it, to count each
  fixed effect's levels and the singletons dropped (FixedEffectModels doesn't store either).
  With it, every record splits the dropped rows by reason (`missing`, `singletons`).
- `weights`: the weights column, for a `reg(...; weights = :w)` fit; FixedEffectModels
  doesn't keep it.
- `title`, `notes`, `tags`: the record's own labels. `conf_level` (0.95). `digest` (true):
  adds `meta.core_digest`. `call`: the call as text, if you want it recorded.

## Conventions recorded

- Covariance: `iid`, `HC1` or `CRV1`, with FixedEffectModels' small-sample correction in
  `structures.vcov[].ssc` (K counts the regressors plus the fixed-effect levels not nested in
  a cluster; G/(G-1) with the smallest cluster count; t tests on G - 1 df). GLM.jl gives only
  the model-based covariance.
- GLMs with a known dispersion (binomial, Poisson) use z tests: no `df_t`.
- FixedEffectModels reports the Kleibergen-Paap F for IV but no first-stage F, so an IV record
  gets the validator's "expected a first_stage test" warning.

## Tests

`julia/test/runtests.jl` (Julia) and `tests/test_julia.py` (validates every record with the
reference validator and checks it against the fit), on `tests/data/writers_probe.csv`.
Checked with Julia 1.13.3, FixedEffectModels 2.2.0, Vcov 0.8.5, GLM 1.9.5.
