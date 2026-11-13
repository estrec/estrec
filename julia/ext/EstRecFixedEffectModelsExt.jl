# FixedEffectModels.jl fits (`reg`) -> records: inference/0.1; linear-fe/0.1 with fixed
# effects; iv/0.1 for IV. Written against FixedEffectModels 2.2 and Vcov 0.8.
#
# The fitted model keeps the estimation sample (`esample`) but not the singleton count, the
# weights or the fixed effects' level counts. With `data` (the table the model was fitted
# on), the writer counts levels and splits the dropped rows into missing values and
# singletons; fixed-effect fits need it.
module EstRecFixedEffectModelsExt

using EstRec
using EstRec: Obj, num, compact, now_utc, parameter_rows, canonical_term, matrix_rows, software,
              formula_vars, missing_rows, data_entry, add_digest!, estrec_info, SCHEMA
using FixedEffectModels
using FixedEffectModels: FixedEffectModel
import FixedEffectModels.Vcov
import StatsAPI, StatsModels, Tables

function EstRec.to_estimation(m::FixedEffectModel; data = nothing, weights = nothing,
                              title = nothing, notes = nothing, tags = nothing,
                              conf_level::Real = 0.95, digest::Bool = true, call = nothing)
    has_fe_ = FixedEffectModels.has_fe(m)
    is_iv = FixedEffectModels.has_iv(m)
    has_fe_ && data === nothing &&
        throw(ArgumentError("a fixed-effects fit needs `data` (the table it was fitted on) to count the fixed effects' levels"))
    if data !== nothing && length(Tables.rows(data)) != length(m.esample)
        throw(ArgumentError("`data` has $(length(Tables.rows(data))) rows but the fit saw $(length(m.esample))"))
    end
    cols = data === nothing ? nothing : Tables.columntable(data)

    # parameters in coefnames order (the vcov's); coeftable may list them in another order
    ct = StatsAPI.coeftable(m; level = conf_level)
    rows = Dict(String(r) => i for (i, r) in enumerate(ct.rownms))
    terms = String.(StatsAPI.coefnames(m))
    order = [rows[t] for t in terms]
    ct_ordered = (cols = [c[order] for c in ct.cols], colnms = ct.colnms, pvalcol = ct.pvalcol)
    parameters = parameter_rows(ct_ordered, terms)

    # vcov
    V = StatsAPI.vcov(m)
    vt = m.vcov_type
    N = m.nobs
    K = length(terms) + m.dof_fes
    clusters = String[]
    if vt isa Vcov.ClusterCovariance
        clusters = String.(collect(keys(m.nclusters)))
        type = "CRV1"
        formula_ssc = "(N - 1) / (N - K) * G / (G - 1), G the smallest cluster count, K the regressors plus the fixed-effect levels not nested in a cluster"
    elseif vt isa Vcov.RobustCovariance
        type = "HC1"
        formula_ssc = "N / (N - K), K the regressors plus the fixed-effect levels"
    else
        type = "iid"
        formula_ssc = "RSS / (N - K), K the regressors plus the fixed-effect levels"
    end
    vc = Obj("kind" => "matrix", "labels" => terms, "data" => matrix_rows(Matrix(V)),
             "type" => type, "tool_type" => string(typeof(vt).name.name))
    if !isempty(clusters)
        vc["cluster"] = clusters
        vc["n_clusters"] = Obj(String(k) => Int(v) for (k, v) in pairs(m.nclusters))
        vc["n_clusters_min"] = Int(minimum(values(m.nclusters)))
    end
    vc["ssc"] = Obj("convention" => "FixedEffectModels", "formula" => formula_ssc,
                    "K_counts" => Obj("regressors" => length(terms), "dof_fes" => m.dof_fes))
    vc["df_t"] = m.dof_residual
    vc["default"] = true

    # sample
    rows_input = length(m.esample)
    dropped = Obj()
    restriction = nothing
    if cols !== nothing
        vars = formula_vars(m.formula)
        append!(vars, Symbol.(clusters))
        weights === nothing || push!(vars, Symbol(weights))
        miss = missing_rows(cols, vars)
        n_miss = count(miss)
        rest = rows_input - n_miss - N
        dropped["missing"] = n_miss
        if has_fe_
            dropped["singletons"] = max(rest, 0)
            rest < 0 && (dropped["other"] = rest)  # can't happen without `subset`
        elseif rest != 0
            dropped["other"] = rest
        end
    else
        dropped["other"] = rows_input - N
    end

    # fixed effects: levels in the estimation sample
    fes = Any[]
    if has_fe_
        for k in m.fekeys
            comps = Symbol.(split(String(k), "&"))
            comps = [Symbol(replace(String(c), r"^fe_?\(?|\)$" => "")) for c in comps]
            all(c -> haskey(cols, c), comps) || continue
            keyrows = [Tuple(cols[c][i] for c in comps) for i in eachindex(m.esample) if m.esample[i]]
            entry = Obj("kind" => "object", "name" => String(k), "levels" => length(unique(keyrows)))
            length(comps) > 1 && (entry["components"] = String.(comps))
            push!(fes, entry)
        end
    end

    # metrics
    metrics = compact(Obj(
        "nobs" => N, "df_residual" => m.dof_residual, "df_model" => m.dof,
        "df_absorbed" => has_fe_ ? m.dof_fes : nothing,
        "r2" => num(StatsAPI.r2(m)), "adj_r2" => num(StatsAPI.adjr2(m)),
        "rss" => num(m.rss), "tss" => num(m.tss),
        "sigma" => num(sqrt(m.rss / (N - K))),
        "conf_level" => conf_level,
        "r2_within" => has_fe_ ? num(m.r2_within) : nothing,
        "n_singletons" => get(dropped, "singletons", nothing)))

    # specification
    spec = Obj(
        "formula" => Obj("text" => EstRec.formula_text(m.formula), "syntax" => "StatsModels"),
        "terms" => terms,
        "weights" => weights === nothing ? nothing : Obj("variable" => String(Symbol(weights)), "type" => "analytic"),
        "fixed_effects" => String.(m.fekeys),
        "clusters" => clusters,
        "sample" => Obj("restriction" => restriction, "rows_input" => rows_input, "dropped" => dropped),
        "options" => Obj("drop_singletons" => has_fe_))
    if is_iv
        endo, inst = iv_terms(m.formula)
        spec["endogenous"] = endo
        spec["instruments"] = inst
    end
    call === nothing || (spec["call"] = call)

    structures = Obj("vcov" => Any[vc])
    has_fe_ && (structures["fixed_effects"] = fes)
    if has_fe_
        structures["numerics"] = Obj("kind" => "object", "iterative" => true,
            "algorithm" => "lsmr", "converged" => m.converged, "iterations" => m.iterations)
    end

    tests = Any[]
    if isfinite(m.F)
        push!(tests, Obj("id" => "t1", "category" => "model",
            "name" => type == "iid" ? "f" : "wald", "origin" => "estimation",
            "statistic" => num(m.F), "distribution" => "F", "df1" => m.dof,
            "df2" => m.dof_residual, "p_value" => num(m.p), "vcov" => type))
    end
    if is_iv && isfinite(m.F_kp)
        push!(tests, Obj("id" => "t$(length(tests) + 1)", "category" => "weak_identification",
            "name" => "kleibergen_paap_rk_wald_f", "origin" => "estimation",
            "statistic" => num(m.F_kp), "p_value" => num(m.p_kp), "vcov" => type))
    end

    profiles = ["inference/0.1"]
    has_fe_ && push!(profiles, "linear-fe/0.1")
    is_iv && push!(profiles, "iv/0.1")
    status = (has_fe_ && !m.converged) ? "warning" : "ok"
    meta = compact(Obj(
        "id" => string(EstRec.uuid4()), "created" => now_utc(), "status" => status,
        "estimator" => Obj("family" => "linear", "method" => is_iv ? "2sls" : "ols"),
        "responses" => [m.responsename isa AbstractString ? m.responsename : string(m.responsename)],
        "profiles" => profiles,
        "title" => something(title, EstRec.formula_text(m.formula)),
        "tags" => tags, "notes" => notes, "producer" => estrec_info()))
    msgs = Any[]
    if get(dropped, "singletons", 0) > 0
        push!(msgs, Obj("level" => "info", "code" => "singletons", "source" => "FixedEffectModels",
                        "message" => "$(dropped["singletons"]) singleton rows dropped"))
    end
    status == "warning" && push!(msgs, Obj("level" => "warning", "code" => "not_converged",
        "source" => "FixedEffectModels", "message" => "the fixed-effects demeaning did not converge ($(m.iterations) iterations)"))
    isempty(msgs) || (meta["messages"] = msgs)

    rec = Obj("schema" => SCHEMA, "meta" => meta, "specification" => compact(spec),
              "metrics" => metrics, "parameters" => parameters, "structures" => structures)
    isempty(tests) || (rec["tests"] = tests)
    rec["provenance"] = Obj(
        "software" => software([FixedEffectModels => "estimator", Vcov => "vcov",
                                StatsModels => "formula"]),
        "data" => Any[data_entry(data, rows_input)])
    rec["history"] = Any[Obj("when" => now_utc(), "by" => estrec_info(), "action" => "created")]
    digest && add_digest!(rec)
    rec
end

# (endogenous ~ instruments) inside a FixedEffectModels formula
function iv_terms(f)
    for t in (f.rhs isa Tuple ? f.rhs : (f.rhs,))
        if t isa StatsModels.FormulaTerm
            return (String.(EstRec.formula_vars(StatsModels.FormulaTerm(t.lhs, StatsModels.ConstantTerm(1)))),
                    String.(EstRec.formula_vars(StatsModels.FormulaTerm(StatsModels.ConstantTerm(1), t.rhs))))
        end
    end
    String[], String[]
end

end # module
