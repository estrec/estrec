# GLM.jl fits -> records. `lm`: inference/0.1. `glm`: inference/0.1 and glm/0.1. Written
# against GLM 1.9 (fits wrapped in StatsModels' TableRegressionModel) and later versions that
# return the model itself.
#
# GLM.jl computes only the model-based covariance ("iid"). It throws when the IRLS
# iterations don't converge, so a fitted model has converged.
module EstRecGLMExt

using EstRec
using EstRec: Obj, num, compact, now_utc, parameter_rows, matrix_rows, software,
              formula_vars, missing_rows, data_entry, add_digest!, estrec_info, SCHEMA
using GLM
using GLM: LinearModel, GeneralizedLinearModel
import StatsAPI, StatsModels, Tables

const GLMFit = Union{LinearModel,GeneralizedLinearModel}

EstRec.to_estimation(m::StatsModels.TableRegressionModel{<:GLMFit}; kwargs...) =
    glm_record(m, m.model; kwargs...)
EstRec.to_estimation(m::GLMFit; kwargs...) = glm_record(m, m; kwargs...)

const DIST = Dict("Normal" => "gaussian", "Binomial" => "binomial", "Bernoulli" => "binomial",
                  "Poisson" => "poisson", "Gamma" => "gamma", "InverseGaussian" => "inverse_gaussian",
                  "NegativeBinomial" => "negative_binomial", "Geometric" => "geometric")
const LINK = Dict("LogitLink" => "logit", "ProbitLink" => "probit", "CloglogLink" => "cloglog",
                  "CauchitLink" => "cauchit", "LogLink" => "log", "IdentityLink" => "identity",
                  "InverseLink" => "inverse", "InverseSquareLink" => "inverse_square",
                  "SqrtLink" => "sqrt", "NegativeBinomialLink" => "negative_binomial")

function glm_record(wrapper, mod; data = nothing, title = nothing, notes = nothing, tags = nothing,
                    conf_level::Real = 0.95, digest::Bool = true, call = nothing)
    is_glm = mod isa GeneralizedLinearModel
    f = try StatsModels.formula(wrapper) catch; nothing end
    ct = StatsAPI.coeftable(wrapper; level = conf_level)
    terms = String.(ct.rownms)
    parameters = parameter_rows(ct, terms)
    N = Int(StatsAPI.nobs(wrapper))
    dfr = StatsAPI.dof_residual(wrapper)
    z = ct.colnms[3] == "z"   # known dispersion: z tests, no df

    wts = is_glm ? mod.rr.wts : mod.rr.wts
    weighted = !isempty(wts)
    vc = Obj("kind" => "matrix", "labels" => terms, "data" => matrix_rows(StatsAPI.vcov(wrapper)),
             "type" => "iid", "tool_type" => "model-based",
             "ssc" => Obj("convention" => "GLM.jl",
                          "formula" => z ? "inverse Fisher information (dispersion 1)" :
                                           "dispersion estimated as the sum of squared (Pearson) residuals / (N - K)"))
    z || (vc["df_t"] = num(dfr))
    vc["default"] = true

    # sample
    vars = f === nothing ? Symbol[] : formula_vars(f)
    rows_input = data === nothing ? nothing : length(Tables.rows(data))
    dropped = Obj()
    if data !== nothing
        n_miss = count(missing_rows(data, vars))
        dropped["missing"] = n_miss
        rest = rows_input - n_miss - N
        rest != 0 && (dropped["other"] = rest)
    end
    sample = rows_input === nothing ? nothing :
        Obj("restriction" => nothing, "rows_input" => rows_input, "dropped" => dropped)

    if is_glm
        dist = string(nameof(typeof(mod.rr.d)))
        link = string(nameof(typeof(mod.rr.link)))
        estimator = compact(Obj("family" => "glm", "method" => "irls",
            "distribution" => get(DIST, dist, lowercase(dist)), "link" => get(LINK, link, lowercase(link))))
        metrics = compact(Obj(
            "nobs" => N, "df_residual" => z ? nothing : num(dfr),
            "log_lik" => num(StatsAPI.loglikelihood(wrapper)),
            "log_lik_null" => num(StatsAPI.nullloglikelihood(wrapper)),
            "deviance" => num(StatsAPI.deviance(wrapper)),
            "deviance_null" => num(StatsAPI.nulldeviance(wrapper)),
            "aic" => num(StatsAPI.aic(wrapper)), "bic" => num(StatsAPI.bic(wrapper)),
            "dispersion" => z ? 1.0 : num(GLM.dispersion(mod, true)),
            "conf_level" => conf_level))
    else
        estimator = Obj("family" => "linear", "method" => "ols")
        rss = StatsAPI.deviance(wrapper)
        metrics = compact(Obj(
            "nobs" => N, "df_residual" => num(dfr),
            "r2" => num(StatsAPI.r2(wrapper)), "adj_r2" => num(StatsAPI.adjr2(wrapper)),
            "sigma" => num(sqrt(rss / dfr)), "rss" => num(rss),
            "log_lik" => num(StatsAPI.loglikelihood(wrapper)),
            "aic" => num(StatsAPI.aic(wrapper)), "bic" => num(StatsAPI.bic(wrapper)),
            "conf_level" => conf_level))
    end

    spec = compact(Obj(
        "formula" => f === nothing ? nothing : Obj("text" => EstRec.formula_text(f), "syntax" => "StatsModels"),
        "terms" => terms,
        "sample" => sample, "call" => call))
    weighted && (spec["weights"] = Obj("type" => "frequency"))

    structures = Obj("vcov" => Any[vc])
    if is_glm
        structures["numerics"] = compact(Obj("kind" => "object", "iterative" => true,
            "algorithm" => "irls", "converged" => true,
            "max_iterations" => hasfield(typeof(mod), :maxiter) ? mod.maxiter : nothing,
            "tolerance" => hasfield(typeof(mod), :rtol) ? num(mod.rtol) : nothing))
    end

    profiles = is_glm ? ["inference/0.1", "glm/0.1"] : ["inference/0.1"]
    resp = f === nothing ? nothing : String.(formula_vars(StatsModels.FormulaTerm(f.lhs, StatsModels.ConstantTerm(1))))
    meta = compact(Obj(
        "id" => string(EstRec.uuid4()), "created" => now_utc(), "status" => "ok",
        "estimator" => estimator, "responses" => resp, "profiles" => profiles,
        "title" => something(title, f === nothing ? nothing : EstRec.formula_text(f), Some(nothing)),
        "tags" => tags, "notes" => notes, "producer" => estrec_info()))

    rec = Obj("schema" => SCHEMA, "meta" => meta, "specification" => spec,
              "metrics" => metrics, "parameters" => parameters, "structures" => structures)
    rec["provenance"] = Obj(
        "software" => software([GLM => "estimator", StatsModels => "formula"]),
        "data" => Any[data_entry(data, something(rows_input, N))])
    rec["history"] = Any[Obj("when" => now_utc(), "by" => estrec_info(), "action" => "created")]
    digest && add_digest!(rec)
    rec
end

end # module
