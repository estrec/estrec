"""
    EstRec

Writes fitted models as estrec records (https://estrec.org): a JSON file for one statistical
estimation run, saying what was estimated, what came out, and how and where it ran.

Version 0.1 writes FixedEffectModels.jl fits (`reg`: OLS and IV, with fixed effects and
iid, robust or clustered covariance) and GLM.jl fits (`lm`, `glm`). The writers load with
those packages (package extensions), so EstRec itself depends on neither.

    using EstRec, FixedEffectModels
    m = reg(df, @formula(y ~ x1 + x2 + fe(id) + fe(year)), Vcov.cluster(:grp))
    write_estimation(m, "fit.estrec.json"; data = df)

`to_estimation(model; data)` returns the record (an `OrderedDict`) without writing it.
"""
module EstRec

using Dates: now, UTC, format
using OrderedCollections: OrderedDict
using SHA: sha256
using UUIDs: uuid4
import StatsAPI
import StatsModels
import Tables

export to_estimation, write_estimation, core_digest, canonical_json, estrec_info

const Obj = OrderedDict{String,Any}
const SCHEMA = "estrec/0.1"
const VERSION_STR = "0.1.0"

"""Name and version of this writer, as records give it in `meta.producer`."""
estrec_info() = Obj("name" => "EstRec.jl", "version" => VERSION_STR)

"""
    to_estimation(model; data = nothing, title = nothing, notes = nothing, tags = nothing,
                  conf_level = 0.95, digest = true) -> OrderedDict

The record for a fitted model. `data` is the table the model was fitted on; with it, rows
dropped are split by reason (missing values, singletons) and cluster counts checked.
"""
function to_estimation(model; kwargs...)
    throw(ArgumentError("EstRec has no writer for $(typeof(model)); it writes " *
        "FixedEffectModels.jl and GLM.jl fits (load FixedEffectModels or GLM first)"))
end

"""
    write_estimation(model_or_record, path; kwargs...) -> path

Writes one record as pretty-printed JSON. A model is converted with `to_estimation` first
(keyword arguments go to it).
"""
function write_estimation(x, path::AbstractString; indent::Int = 1, kwargs...)
    rec = x isa AbstractDict ? x : to_estimation(x; kwargs...)
    io = IOBuffer()
    _json(io, rec, indent, 0)
    write(io, '\n')
    tmp = path * ".tmp"
    open(tmp, "w") do f
        write(f, take!(io))
    end
    mv(tmp, path; force = true)
    return path
end

# ---------------------------------------------------------------- numbers and values

# A number as the format stores it: finite numbers as is; NaN and infinities as strings
# ("NaN", "Inf", "-Inf"); missing/nothing as nothing (the field is left out or null).
num(x::Nothing) = nothing
num(x::Missing) = nothing
num(x::Integer) = Int(x)
function num(x::Real)
    f = Float64(x)
    isnan(f) && return "NaN"
    isinf(f) && return f > 0 ? "Inf" : "-Inf"
    return f
end

"""Drop the entries whose value is `nothing`."""
compact(d::AbstractDict) = Obj(k => v for (k, v) in d if v !== nothing)

now_utc() = format(now(UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"

# ---------------------------------------------------------------- JSON output

function _json(io::IO, x::AbstractDict, ind::Int, lev::Int)
    if isempty(x)
        print(io, "{}")
        return
    end
    print(io, "{")
    first = true
    for (k, v) in x
        first || print(io, ",")
        first = false
        _nl(io, ind, lev + 1)
        _str(io, string(k))
        print(io, ind > 0 ? ": " : ":")
        _json(io, v, ind, lev + 1)
    end
    _nl(io, ind, lev)
    print(io, "}")
end
function _json(io::IO, x::Union{AbstractVector,Tuple}, ind::Int, lev::Int)
    if isempty(x)
        print(io, "[]")
        return
    end
    # numeric rows (vcov matrices) stay on one line
    flat = all(v -> v isa Union{Real,AbstractString,Nothing}, x)
    print(io, "[")
    for (i, v) in enumerate(x)
        i > 1 && print(io, flat && ind > 0 ? ", " : ",")
        flat || _nl(io, ind, lev + 1)
        _json(io, v, ind, lev + 1)
    end
    flat || _nl(io, ind, lev)
    print(io, "]")
end
_json(io::IO, x::AbstractString, ::Int, ::Int) = _str(io, x)
_json(io::IO, x::Symbol, ::Int, ::Int) = _str(io, string(x))
_json(io::IO, x::Bool, ::Int, ::Int) = print(io, x ? "true" : "false")
_json(io::IO, ::Nothing, ::Int, ::Int) = print(io, "null")
_json(io::IO, x::Integer, ::Int, ::Int) = print(io, Int(x))
function _json(io::IO, x::Real, ind::Int, lev::Int)
    v = num(x)
    v isa String ? _str(io, v) : print(io, _es_number(v))
end
_json(io::IO, x, ::Int, ::Int) = throw(ArgumentError("can't write a $(typeof(x)) as JSON"))

_nl(io::IO, ind::Int, lev::Int) = ind > 0 && print(io, "\n", " "^(ind * lev))

function _str(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' '
            print(io, "\\u", lpad(string(UInt16(c), base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
end

# ---------------------------------------------------------------- RFC 8785 canonical JSON

"""ECMAScript Number.prototype.toString, which RFC 8785 prescribes for numbers."""
function _es_number(x::Float64)
    x == 0 && return "0"
    isinteger(x) && abs(x) < 1e21 && return string(Int128(x))
    sign = x < 0 ? "-" : ""
    r = repr(abs(x))                       # shortest round-trip digits
    mant, exp = occursin('e', r) ? split(r, 'e') : (r, "0")
    ip, fp = occursin('.', mant) ? split(mant, '.') : (mant, "")
    digits = ip * fp
    n = length(ip) + parse(Int, exp)       # decimal point after n digits
    stripped = lstrip(digits, '0')
    n -= length(digits) - length(stripped)
    digits = rstrip(stripped, '0')
    k = length(digits)
    k <= n <= 21 && return sign * digits * "0"^(n - k)
    0 < n <= 21 && return sign * digits[1:n] * "." * digits[n+1:end]
    -6 < n <= 0 && return sign * "0." * "0"^(-n) * digits
    e = n - 1
    frac = k > 1 ? "." * digits[2:end] : ""
    return string(sign, digits[1], frac, "e", e > 0 ? "+" : "-", abs(e))
end

function _canon(io::IO, x)
    if x === nothing
        print(io, "null")
    elseif x isa Bool
        print(io, x ? "true" : "false")
    elseif x isa Integer
        abs(x) > 2^53 && throw(ArgumentError("integer $x is outside the range RFC 8785 allows"))
        print(io, Int(x))
    elseif x isa Real
        v = num(x)
        v isa String ? _str(io, v) : print(io, _es_number(v))
    elseif x isa AbstractString || x isa Symbol
        _str(io, string(x))
    elseif x isa Union{AbstractVector,Tuple}
        print(io, "[")
        for (i, v) in enumerate(x)
            i > 1 && print(io, ",")
            _canon(io, v)
        end
        print(io, "]")
    elseif x isa AbstractDict
        print(io, "{")
        # keys sorted by their UTF-16 code units
        ks = sort!([string(k) for k in keys(x)]; by = k -> transcode(UInt16, k))
        for (i, k) in enumerate(ks)
            i > 1 && print(io, ",")
            _str(io, k)
            print(io, ":")
            _canon(io, haskey(x, k) ? x[k] : x[Symbol(k)])
        end
        print(io, "}")
    else
        throw(ArgumentError("can't canonicalise a $(typeof(x))"))
    end
end

"""RFC 8785 (JSON Canonicalization Scheme) form of a JSON value, as UTF-8 bytes."""
function canonical_json(x)
    io = IOBuffer()
    _canon(io, x)
    take!(io)
end

const CORE = ("meta", "specification", "metrics", "parameters", "structures")

"""sha256 (hex) of the canonical form of the result sections (spec 7.2): `meta` without
`core_digest`, `specification`, `metrics`, `parameters`, `structures`."""
function core_digest(rec::AbstractDict)
    view = Obj()
    for k in CORE
        haskey(rec, k) || continue
        v = rec[k]
        if k == "meta" && v isa AbstractDict
            v = Obj(kk => vv for (kk, vv) in v if kk != "core_digest")
        end
        view[k] = v
    end
    bytes2hex(sha256(canonical_json(view)))
end

function add_digest!(rec::AbstractDict)
    delete!(rec["meta"], "core_digest")
    rec["meta"]["core_digest"] = Obj("algorithm" => "sha256", "canonicalization" => "RFC8785",
                                     "value" => core_digest(rec))
    rec
end

# ---------------------------------------------------------------- shared record pieces

"""Term name -> canonical {name, factors} (spec 4.4.1). StatsModels spells a categorical
level `cat: 2` and an interaction `x1 & x2`."""
function canonical_term(term::AbstractString)
    term == "(Intercept)" && return Obj("name" => "(Intercept)", "factors" => Any[])
    factors = Any[]
    for p in split(term, " & ")
        m = match(r"^(.+?): (.+)$", p)
        push!(factors, m === nothing ? Obj("variable" => String(p)) :
                       Obj("variable" => String(m[1]), "level" => String(m[2])))
    end
    has_level = [haskey(f, "level") for f in factors]
    name = if any(has_level) && !all(has_level)
        join([haskey(f, "level") ? "$(f["level"]).$(f["variable"])" : "c.$(f["variable"])" for f in factors], "#")
    else
        join([f["variable"] * (haskey(f, "level") ? f["level"] : "") for f in factors], ":")
    end
    Obj("name" => name, "factors" => factors)
end

"""Parameter rows from a coefficient table: estimate, std_error, statistic, p_value and the
confidence interval at `conf_level`."""
function parameter_rows(ct, terms)
    cols = ct.cols
    names = ct.colnms
    find(pred) = findfirst(pred, names)
    i_se = find(n -> occursin("Std", n))
    i_st = find(n -> n in ("t", "z", "t value", "z value"))
    i_p = ct.pvalcol
    i_lo = find(n -> startswith(n, "Lower"))
    i_hi = find(n -> startswith(n, "Upper"))
    rows = Any[]
    for (j, term) in enumerate(terms)
        push!(rows, compact(Obj(
            "term" => term, "canonical" => canonical_term(term),
            "estimate" => num(cols[1][j]),
            "std_error" => i_se === nothing ? nothing : num(cols[i_se][j]),
            "statistic" => i_st === nothing ? nothing : num(cols[i_st][j]),
            "p_value" => i_p > 0 ? num(cols[i_p][j]) : nothing,
            "conf_low" => i_lo === nothing ? nothing : num(cols[i_lo][j]),
            "conf_high" => i_hi === nothing ? nothing : num(cols[i_hi][j]))))
    end
    rows
end

matrix_rows(V::AbstractMatrix) = Any[Any[num(V[i, j]) for j in axes(V, 2)] for i in axes(V, 1)]

function package_version(mod::Module)
    v = pkgversion(mod)
    v === nothing ? nothing : string(v)
end

"""provenance.software: the estimating package, its covariance package if any, StatsModels,
Julia and this writer."""
function software(pkgs::Vector{Pair{Module,String}})
    out = Any[]
    for (m, role) in pkgs
        v = package_version(m)
        push!(out, compact(Obj("name" => string(nameof(m)), "version" => v,
            "purl" => v === nothing ? nothing : "pkg:julia/$(nameof(m))@$v",
            "role" => role, "source" => "General")))
    end
    push!(out, Obj("name" => "Julia", "version" => string(VERSION),
                   "purl" => "pkg:generic/julia@$(VERSION)", "role" => "language"))
    push!(out, Obj("name" => "EstRec.jl", "version" => VERSION_STR, "role" => "writer"))
    out
end

"""Variables a formula uses (left and right side), as Symbols."""
function formula_vars(f)
    vs = Symbol[]
    _termvars!(vs, f)
    unique!(vs)
end
_termvars!(vs, f::StatsModels.FormulaTerm) = (_termvars!(vs, f.lhs); _termvars!(vs, f.rhs))
_termvars!(vs, t::Union{Tuple,AbstractVector}) = foreach(x -> _termvars!(vs, x), t)
_termvars!(vs, t::StatsModels.Term) = push!(vs, t.sym)
_termvars!(vs, t::Union{StatsModels.ContinuousTerm,StatsModels.CategoricalTerm}) = push!(vs, t.sym)
_termvars!(vs, t::StatsModels.MatrixTerm) = _termvars!(vs, t.terms)
_termvars!(vs, t::StatsModels.InteractionTerm) = _termvars!(vs, t.terms)
_termvars!(vs, t::StatsModels.FunctionTerm) = _termvars!(vs, t.args)
_termvars!(vs, t::StatsModels.AbstractTerm) = nothing
_termvars!(vs, t) = nothing

"""A formula as text: `y ~ x2 + (x1 ~ z) + fe(year)` (IV parts in parentheses, function
terms as written)."""
formula_text(f::StatsModels.FormulaTerm) = string(_ttext(f.lhs), " ~ ", _ttext(f.rhs))
_ttext(t::Union{Tuple,AbstractVector}) = join(map(_ttext, t), " + ")
_ttext(t::StatsModels.MatrixTerm) = _ttext(t.terms)
_ttext(t::StatsModels.FormulaTerm) = "(" * formula_text(t) * ")"
_ttext(t::StatsModels.FunctionTerm) = string(t.exorig)
_ttext(t::StatsModels.InteractionTerm) = join(map(_ttext, t.terms), " & ")
_ttext(t::StatsModels.InterceptTerm{H}) where {H} = H ? "1" : "0"
_ttext(t::Union{StatsModels.Term,StatsModels.ContinuousTerm,StatsModels.CategoricalTerm}) = string(t.sym)
_ttext(t) = string(t)

"""Rows of `data` with a missing value in any of `vars` (a BitVector)."""
function missing_rows(data, vars)
    cols = Tables.columntable(data)
    n = length(first(cols))
    miss = falses(n)
    for v in vars
        haskey(cols, v) || continue
        col = cols[v]
        for i in 1:n
            x = col[i]
            if x === missing || (x isa AbstractFloat && isnan(x))
                miss[i] = true
            end
        end
    end
    miss
end

function data_entry(data, rows)
    out = Obj("role" => "estimation", "rows" => rows)
    if data !== nothing
        out["columns"] = [string(c) for c in Tables.columnnames(Tables.columns(data))]
    end
    out
end

end # module
