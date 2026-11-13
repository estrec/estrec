using EstRec, Test
using FixedEffectModels, GLM, DataFrames, CSV, CategoricalArrays

const DATA = joinpath(@__DIR__, "..", "..", "tests", "data", "writers_probe.csv")
d = CSV.read(DATA, DataFrame)
d.catc = categorical(d.cat)

est(r) = Dict(p["term"] => p["estimate"] for p in r["parameters"])
se(r) = Dict(p["term"] => p["std_error"] for p in r["parameters"])

@testset "EstRec" begin
    @testset "RFC 8785 numbers" begin
        for (x, s) in [(0.0, "0"), (-0.0, "0"), (1.0, "1"), (123.0, "123"), (0.1, "0.1"),
                       (1e21, "1e+21"), (1e20, "100000000000000000000"), (1e-7, "1e-7"),
                       (0.000001, "0.000001"), (5e-324, "5e-324"), (1.5e300, "1.5e+300"),
                       (-2.5e-10, "-2.5e-10"), (123456.789, "123456.789")]
            @test EstRec._es_number(x) == s
        end
        @test String(canonical_json(Dict("b" => 1, "a" => [true, nothing, "é"]))) ==
              "{\"a\":[true,null,\"é\"],\"b\":1}"
    end

    @testset "fixed effects, clustered" begin
        m = reg(d, @formula(y ~ x1 + x2 + fe(id) + fe(year)), Vcov.cluster(:grp))
        r = to_estimation(m; data = d)
        @test r["meta"]["profiles"] == ["inference/0.1", "linear-fe/0.1"]
        @test est(r)["x1"] == coef(m)[1] && se(r)["x2"] == stderror(m)[2]
        @test r["specification"]["sample"]["dropped"] == Dict("missing" => 3, "singletons" => 0)
        @test [f["levels"] for f in r["structures"]["fixed_effects"]] == [100, 20]
        v = r["structures"]["vcov"][1]
        @test v["type"] == "CRV1" && v["cluster"] == ["grp"] && v["n_clusters"]["grp"] == 20
        @test v["df_t"] == 19
        @test r["meta"]["core_digest"]["value"] == core_digest(r)
        @test_throws ArgumentError to_estimation(m)          # FE fit needs data
    end

    @testset "singletons and weights" begin
        d2 = copy(d)
        d2.id[1] = 999                                        # a singleton unit
        m = reg(d2, @formula(y ~ x1 + x2 + fe(id)), Vcov.robust(); weights = :w)
        r = to_estimation(m; data = d2, weights = :w)
        @test r["specification"]["sample"]["dropped"]["singletons"] == 1
        @test r["metrics"]["n_singletons"] == 1
        @test r["specification"]["weights"]["variable"] == "w"
        @test r["structures"]["vcov"][1]["type"] == "HC1"
        @test any(msg -> msg["code"] == "singletons", r["meta"]["messages"])
    end

    @testset "IV" begin
        m = reg(d, @formula(y ~ x2 + (x1 ~ z)), Vcov.robust())
        r = to_estimation(m; data = d)
        @test "iv/0.1" in r["meta"]["profiles"]
        @test r["specification"]["endogenous"] == ["x1"] && r["specification"]["instruments"] == ["z"]
        @test r["specification"]["formula"]["text"] == "y ~ x2 + (x1 ~ z)"
        # parameters follow the vcov's order even though coeftable reorders them
        @test [p["term"] for p in r["parameters"]] == r["structures"]["vcov"][1]["labels"] == coefnames(m)
        @test est(r)["x1"] == coef(m)[findfirst(==("x1"), coefnames(m))]
    end

    @testset "GLM.jl" begin
        l = lm(@formula(y ~ x1 + x2 + catc), d)
        r = to_estimation(l; data = d)
        @test r["meta"]["profiles"] == ["inference/0.1"]
        p = Dict(q["term"] => q for q in r["parameters"])
        @test p["catc: 2"]["canonical"] == Dict("name" => "catc2",
            "factors" => [Dict("variable" => "catc", "level" => "2")])
        @test r["specification"]["sample"]["dropped"] == Dict("missing" => 3)
        g = glm(@formula(ybin ~ x1 + x2), d, Binomial(), LogitLink())
        r = to_estimation(g; data = d)
        @test r["meta"]["estimator"]["distribution"] == "binomial" && r["meta"]["estimator"]["link"] == "logit"
        @test !haskey(r["structures"]["vcov"][1], "df_t")       # z tests
        @test r["structures"]["numerics"]["converged"] == true
        @test r["metrics"]["log_lik"] ≈ loglikelihood(g)
    end

    @testset "write and unsupported" begin
        path = tempname() * ".estrec.json"
        write_estimation(lm(@formula(y ~ x1), d), path; data = d)
        @test occursin("\"schema\": \"estrec/0.1\"", read(path, String))
        @test_throws ArgumentError to_estimation(42)
    end
end
