# Base-R tests (no testthat). Records are also checked with the reference validator when the
# `estrec` CLI is on PATH or ESTREC_VALIDATOR names it.
if (!requireNamespace("fixest", quietly = TRUE)) quit(save = "no")
suppressMessages(library(fixest))
library(estrec)

set.seed(1); n <- 400
d <- data.frame(id = sample(40, n, TRUE), yr = sample(8, n, TRUE), g = sample(c("a", "b"), n, TRUE))
d$z <- rnorm(n); d$z2 <- rnorm(n); d$x <- d$z + d$z2 + rnorm(n); d$x2 <- rnorm(n)
d$y <- d$x + d$x2 + rnorm(n); d$y2 <- d$y + rnorm(n); d$w <- runif(n)
d$y[3] <- NA; d$x2[10] <- Inf; d$id[5] <- 999L          # a missing value, an Inf, a singleton

validator <- Sys.getenv("ESTREC_VALIDATOR", Sys.which("estrec"))
out <- tempfile("estrec"); dir.create(out)
check <- function(rec, name) {
  path <- write_estimation(rec, file.path(out, paste0(name, ".estrec.json")))
  if (nzchar(validator)) {
    res <- system2(validator, c("validate", path), stdout = TRUE, stderr = TRUE)
    status <- attr(res, "status")
    if (!is.null(status) && status != 0) stop(name, " failed validation:\n", paste(res, collapse = "\n"))
  }
  invisible(path)
}
eq <- function(a, b, tol = 1e-12) stopifnot(isTRUE(all.equal(as.numeric(a), as.numeric(b), tolerance = tol)))
dropped <- function(rec) rec$specification$sample$dropped

# OLS with fixed effects, clustered; sample drops by reason
f <- feols(y ~ x + x2 | id + yr, d, cluster = ~id)
r <- to_estimation(f)
check(r, "ols")
stopifnot(identical(r$meta$profiles, I(c("inference/0.1", "linear-fe/0.1"))))
eq(sapply(r$parameters, `[[`, "estimate"), coef(f))
eq(sapply(r$parameters, `[[`, "std_error"), se(f))
stopifnot(dropped(r)$missing == 1, dropped(r)$non_finite == 1, dropped(r)$singletons == 1,
          r$metrics$n_singletons == 1, r$metrics$nobs == f$nobs,
          r$specification$sample$rows_input - sum(unlist(dropped(r))) == f$nobs)
stopifnot(identical(r$structures$vcov[[1]]$cluster, I("id")), r$structures$vcov[[1]]$type == "CRV1",
          r$structures$vcov[[1]]$n_clusters$id == length(unique(d$id[obs(f)])))

# Several vcovs: the first is the default and gives the parameters
r <- to_estimation(f, vcov = list("hetero", ~id + yr, "iid"))
check(r, "vcovs")
stopifnot(vapply(r$structures$vcov, `[[`, "", "type") == c("HC1", "CRV1", "iid"),
          vapply(r$structures$vcov, `[[`, TRUE, "default") == c(TRUE, FALSE, FALSE))
eq(sapply(r$parameters, `[[`, "std_error"), se(summary(f, vcov = "hetero")))
stopifnot(identical(r$structures$vcov[[2]]$cluster, I(c("id", "yr"))))

# Without fixed effects: inference/0.1 only; weights
f0 <- feols(y ~ x + x2, d, weights = ~w)
r <- to_estimation(f0)
check(r, "nofe")
stopifnot(identical(r$meta$profiles, I("inference/0.1")), is.null(dropped(r)$singletons),
          r$specification$weights$variable == "w")

# Multiple estimation with split and subset: one record per model
m <- feols(c(y, y2) ~ csw(x2, x) | id, d, split = ~g, subset = ~yr > 2)
rs <- to_estimation(m)
stopifnot(length(rs) == length(m))
paths <- write_estimation(m, file.path(out, "multi.estrec.json"))
stopifnot(length(paths) == length(m), all(file.exists(paths)), grepl("multi-8\\.estrec\\.json$", paths[8]))
for (i in seq_along(rs)) {
  ri <- rs[[i]]; mi <- m[[i]]
  check(ri, paste0("multi", i))
  eq(sapply(ri$parameters, `[[`, "estimate"), coef(mi))
  stopifnot(ri$specification$sample$rows_input - sum(unlist(dropped(ri))) == mi$nobs,
            dropped(ri)$restriction == n - sum(d$yr > 2 & d$g == mi$model_info$sample$value),
            grepl("split: g ==", ri$specification$sample$restriction))
}

# IV: iv/0.1 with first-stage statistics; fit_x is canonically x
fi <- feols(y ~ x2 | id | x ~ z + z2, d)
r <- to_estimation(fi)
check(r, "iv")
stopifnot("iv/0.1" %in% r$meta$profiles, r$meta$estimator$method == "2sls",
          identical(r$specification$endogenous, I("x")),
          r$parameters[[1]]$term == "fit_x", r$parameters[[1]]$canonical$name == "x")
cat_of <- function(rec) vapply(rec$tests, `[[`, "", "category")
fs <- r$tests[cat_of(r) == "first_stage"][[1]]
eq(fs$statistic, fitstat(fi, ~ivf1)[[1]]$stat)
stopifnot(fs$response == "x", fs$component == "first_stage", is.null(r$structures$first_stage),
          all(c("model", "weak_identification", "endogeneity", "overidentification") %in% cat_of(r)),
          r$tests[cat_of(r) == "overidentification"][[1]]$name == "sargan")
# fixest's kpr: kept only with a non-iid vcov, one endogenous variable and one instrument, as the
# KP rk Wald F without fixest's chi2 p-value (it matches ivreg2's e(rkf) only there; iv profile)
stopifnot(!"kleibergen_paap_rk_wald_f" %in% vapply(r$tests, `[[`, "", "name"),   # overidentified
          "kpr_omitted" %in% vapply(r$meta$messages, `[[`, "", "code"))
fx <- feols(y ~ x2 | id | x ~ z, d, vcov = "hetero")
rx <- to_estimation(fx)
kp <- Filter(function(t) t$name == "kleibergen_paap_rk_wald_f", rx$tests)
stopifnot(length(kp) == 1, kp[[1]]$category == "weak_identification", is.null(kp[[1]]$p_value),
          kp[[1]]$vcov == "HC1", !"kpr_omitted" %in% vapply(c(list(), rx$meta$messages), `[[`, "", "code"))
eq(kp[[1]]$statistic, fitstat(fx, ~kpr)$kpr$stat)
rx <- to_estimation(feols(y ~ x2 | id | x ~ z, d, vcov = "iid"))
stopifnot(!"kleibergen_paap_rk_wald_f" %in% vapply(rx$tests, `[[`, "", "name"))
check(rx, "iv_exact_iid")
# two endogenous, exactly identified, hetero: fixest's kpr is computed but unreliable, so left out
# (finite rows, no FE: with any row dropped, as an NA, Inf or a singleton, fixest's kpr errors for
# 2+ endogenous variables)
dc <- d[Reduce(`&`, lapply(d[c("y", "x", "x2", "z", "z2")], is.finite)), ]
f2 <- feols(y ~ 1 | x + x2 ~ z + z2, dc, vcov = "hetero")
stopifnot(is.finite(fitstat(f2, ~kpr)$kpr$stat))
rx <- to_estimation(f2)
stopifnot(!"kleibergen_paap_rk_wald_f" %in% vapply(rx$tests, `[[`, "", "name"),
          "kpr_omitted" %in% vapply(rx$meta$messages, `[[`, "", "code"))
check(rx, "iv_exact2_hetero")

# Tests: the model Wald test from fixest; test results recorded as given, never computed
r <- to_estimation(f)
mt <- r$tests[[1]]
stopifnot(mt$category == "model", mt$name == "wald", mt$origin == "estimation", mt$vcov == "CRV1")
eq(mt$statistic, fitstat(f, ~wald)$wald$stat)
stopifnot(inherits(try(add_test(r, "x = 0"), silent = TRUE), "try-error"),   # no tests run here
          inherits(try(add_test(r, 3), silent = TRUE), "try-error"),
          inherits(try(add_test(list(), wald(f, print = FALSE)), silent = TRUE), "try-error"))

# fixest wald(): the terms come from the call's keep/drop, the rest from the result
d$counter <- sample(-6:3, n, TRUE)
fe <- feols(y ~ i(counter, x2, ref = -1) + x * x2 | id, d, cluster = ~id)
keep <- "^counter::-[2-6]:"
w <- wald(fe, keep = keep, print = FALSE)
r <- add_test(to_estimation(fe), wald(fe, keep = keep, print = FALSE), label = "pre-trends")
pt <- r$tests[[2]]
stopifnot(pt$statistic == w$stat, pt$p_value == w$p, pt$df1 == 5, pt$df2 == w$df2,
          length(pt$hypothesis$terms) == 5, all(grepl("^counter::-[2-6]:", pt$hypothesis$terms)),
          identical(pt$vcov$cluster, I("id")), pt$source$name == "fixest",
          grepl("wald(fe, keep = keep", pt$source$call, fixed = TRUE),
          pt$origin == "postestimation", r$history[[2]]$action == "extended")
r <- add_test(r, wald(fe, keep = "^x", drop = ":", print = FALSE))
stopifnot(identical(as.character(r$tests[[3]]$hypothesis$terms), c("x", "x2")), r$tests[[3]]$df1 == 2)
r <- add_test(r, w)                                    # no call to read: no terms
stopifnot(is.null(r$tests[[4]]$hypothesis), r$tests[[4]]$statistic == w$stat)

# marginaleffects::hypotheses()-shaped results: one test per row
tab <- structure(data.frame(hypothesis = c("b1 = 0", "b2 = 0"), estimate = c(1, 2),
                            std.error = c(0.5, 0.4), statistic = c(2, 5), p.value = c(0.05, 1e-6),
                            conf.low = c(0, 1.2), conf.high = c(2, 2.8)),
                 class = c("hypotheses", "data.frame"), vcov.type = "HC3")
r <- add_test(r, tab)
stopifnot(length(r$tests) == 6, r$tests[[6]]$name == "z", r$tests[[6]]$estimate == 2,
          r$tests[[6]]$source$name == "marginaleffects", r$tests[[6]]$options$vcov_type == "HC3")

# anova comparison and htest
dl <- d[is.finite(d$x2) & !is.na(d$y), ]
m0 <- lm(y ~ x, dl); m1 <- lm(y ~ x + x2 + z, dl)
av <- anova(m0, m1)
r <- add_test(r, av, category = "restriction")
at <- r$tests[[7]]
stopifnot(at$name == "f", at$statistic == av$F[2], at$df1 == 2, at$df2 == av$Res.Df[2],
          at$p_value == av$`Pr(>F)`[2])
tt <- t.test(d$x2, mu = 0.1)
r <- add_test(r, tt)
ht <- r$tests[[8]]
stopifnot(ht$name == "t", ht$df == tt$parameter, ht$p_value == tt$p.value,
          ht$hypothesis$alternative == "two_sided", ht$label == "One Sample t-test")

# Any other result: a method for its class, or a test object
as_estimation_test.my_test <- function(x, ...)
  list(list(name = "wald", statistic = x$W, distribution = "chi2", df = x$k, p_value = x$p))
registerS3method("as_estimation_test", "my_test", as_estimation_test.my_test)
r <- add_test(r, structure(list(W = 3.2, k = 2, p = 0.2), class = "my_test"))
r <- add_test(r, list(name = "hansen_j", statistic = 1.1, distribution = "chi2", df = 1, p_value = 0.29),
              category = "overidentification", id = "j")
stopifnot(r$tests[[9]]$df == 2, r$tests[[10]]$id == "j",
          inherits(try(add_test(r, list(name = "x", statistic = 1), id = "j"), silent = TRUE), "try-error"))

# Results given to to_estimation()
r <- to_estimation(fe, tests = list(wald(fe, keep = keep, print = FALSE), tt))
stopifnot(length(r$tests) == 3, length(r$tests[[2]]$hypothesis$terms) == 5, r$tests[[3]]$name == "t")
r1 <- to_estimation(fe, tests = wald(fe, keep = keep, print = FALSE))
stopifnot(length(r1$tests) == 2, length(r1$tests[[2]]$hypothesis$terms) == 5)
check(r, "tests")

# Without the data: drops recorded as `other`, with a warning message
g <- function() { dd <- d; feols(y ~ x + x2 | id, dd) }
fg <- g()
rm_env <- fg; rm_env$call_env <- new.env()
r <- to_estimation(rm_env)
check(r, "nodata")
stopifnot(dropped(r)$other == n - fg$nobs, r$meta$messages[[1]]$code == "sample_unclassified")
r <- to_estimation(rm_env, data = d)
stopifnot(dropped(r)$singletons == 1)

# The core digest (spec 7.2): present with openssl, checked by the reference tool, broken by
# an edit to the results but not by a test added later
if (requireNamespace("openssl", quietly = TRUE)) {
  r <- to_estimation(f)
  stopifnot(r$meta$core_digest$algorithm == "sha256", nchar(r$meta$core_digest$value) == 64,
            identical(r$meta$core_digest$value, estrec:::.est_core_digest(r)))
  r2 <- r; r2$metrics$nobs <- r2$metrics$nobs + 1L
  stopifnot(!identical(r$meta$core_digest$value, estrec:::.est_core_digest(r2)))
  r3 <- add_test(r, list(name = "t", statistic = 1, p_value = 0.3))
  stopifnot(identical(r$meta$core_digest$value, estrec:::.est_core_digest(r3)))
  if (nzchar(validator)) {
    path <- check(r3, "digest")
    res <- system2(validator, c("digest", path), stdout = TRUE, stderr = TRUE)
    stopifnot(any(grepl("matches", res)))
  }
}
stopifnot(is.null(to_estimation(f, digest = FALSE)$meta$core_digest))

# provenance.software: purls follow where each package came from
sw <- to_estimation(f)$provenance$software
stopifnot(sw[[1]]$purl == sprintf("pkg:cran/fixest@%s", packageVersion("fixest")),
          startsWith(sw[[3]]$purl, "pkg:github/estrec/estrec"),
          sw[[3]]$name == "estrec")

# Writing a record leaves the caller's random numbers alone
set.seed(42); a <- runif(1); set.seed(42); invisible(to_estimation(f)); stopifnot(runif(1) == a)

# GLMs: glm/0.1 and inference/0.1; z tests (no df_t); rows the FEs fit perfectly split into
# separated (all-zero outcomes) and singletons, checked against the rows fixest kept
d$cnt <- rpois(n, exp(0.3 * ifelse(is.finite(d$x2), d$x2, 0)))
d$cnt[d$id == 7] <- 0L; d$expo <- runif(n, 1, 2)
p <- suppressMessages(fepois(cnt ~ x + offset(log(expo)) | id + yr, d, cluster = ~id))
r <- to_estimation(p)
check(r, "fepois")
stopifnot(identical(r$meta$profiles, I(c("inference/0.1", "glm/0.1"))),
          r$meta$estimator$distribution == "poisson", r$meta$estimator$link == "log",
          is.null(r$structures$vcov[[1]]$df_t), isTRUE(r$structures$numerics$converged),
          r$specification$offset$variable == "log(expo)",
          identical(r$specification$options$separation, I("fe")))
eq(sapply(r$parameters, `[[`, "estimate"), coef(p))
eq(sapply(r$parameters, `[[`, "p_value"), 2 * pnorm(-abs(coef(p) / se(p))))
eq(r$metrics$deviance, p$deviance); eq(r$metrics$log_lik, logLik(p))
eq(r$metrics$pseudo_r2, 1 - logLik(p) / p$ll_null)
stopifnot(dropped(r)$separated == sum(d$id == 7 & is.finite(d$x2) & !is.na(d$y)),
          dropped(r)$singletons == 1, r$metrics$n_separated == dropped(r)$separated,
          r$specification$sample$rows_input - sum(unlist(dropped(r))) == p$nobs,
          r$metrics$nobs_full == p$nobs + 1 + dropped(r)$separated)
b <- suppressMessages(feglm(I(y > 0) ~ x | yr, d, family = binomial("probit"), vcov = "hetero"))
r <- to_estimation(b)
check(r, "probit")
stopifnot(r$meta$estimator$distribution == "binomial", r$meta$estimator$link == "probit",
          r$structures$vcov[[1]]$type == "HC1", dropped(r)$separated == 0)
# a quasi family: t tests, the dispersion estimated, no likelihood
q <- suppressMessages(feglm(cnt ~ x, d, family = quasipoisson()))
r <- to_estimation(q)
check(r, "quasipoisson")
stopifnot(isTRUE(r$meta$estimator$quasi), r$structures$vcov[[1]]$df_t == df.residual(q),
          is.null(r$metrics$log_lik), !identical(r$metrics$dispersion, 1))

# fixest keeps models it couldn't estimate in multiple estimations (NA models, no coefficients):
# no record for those, with a warning; one alone fails clearly
d$y0 <- 0L
m <- suppressMessages(feglm(c(I(y > 0), y0) ~ x | yr, d, family = binomial, cluster = ~id))
w <- NULL
rs <- withCallingHandlers(to_estimation(m), warning = function(e) { w <<- conditionMessage(e); invokeRestart("muffleWarning") })
stopifnot(length(rs) == 1L, grepl("couldn't estimate model 2 of 2", w, fixed = TRUE))
e <- try(to_estimation(m[[2]]), silent = TRUE)
stopifnot(inherits(e, "try-error"), grepl("couldn't estimate this model", e, fixed = TRUE))
# a vcov without fixest's "vcov_type" label stops with a clear message, not in the label parser
vcov.estrec_bare <- function(object, ...) {
  v <- fixest:::vcov.fixest(object, ...); attributes(v) <- attributes(v)[c("dim", "dimnames")]; v
}
registerS3method("vcov", "estrec_bare", vcov.estrec_bare)
lg <- m[[1]]; class(lg) <- c("estrec_bare", class(lg))
e <- try(to_estimation(lg), silent = TRUE)
stopifnot(inherits(e, "try-error"), grepl("without its type label", e, fixed = TRUE))

# Unsupported fits fail clearly
stopifnot(inherits(try(to_estimation(fenegbin(cnt ~ x | id, d)), silent = TRUE), "try-error"),
          inherits(try(to_estimation(lm(y ~ x, d)), silent = TRUE), "try-error"))
cat("estrec tests passed", if (nzchar(validator)) "(records validated)" else "(validator not found)", "\n")
