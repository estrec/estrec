# Base-R tests (no testthat) for lm and glm records. Records are also checked with the reference
# validator when the `estrec` CLI is on PATH or ESTREC_VALIDATOR names it.
library(estrec)

set.seed(2); n <- 300
d <- data.frame(g = sample(25, n, TRUE), h = sample(6, n, TRUE), f = sample(c("a", "b", "c"), n, TRUE))
d$x <- rnorm(n); d$x2 <- rnorm(n); d$w <- runif(n); d$t <- rpois(n, 5) + 1
d$y <- 1 + d$x - 0.5 * d$x2 + rnorm(n)
d$c <- rpois(n, exp(0.2 + 0.3 * d$x + log(d$t) / 4))
d$b <- rbinom(n, 1, plogis(0.4 * d$x))
d$pos <- rgamma(n, shape = 2, rate = 2 / exp(0.5 + 0.2 * d$x))
d$y[4] <- NA; d$x2[9] <- NA; d$w[12] <- 0

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
col <- function(rec, k) vapply(rec$parameters, function(p) p[[k]] %||% NA_real_, 0)
`%||%` <- function(a, b) if (is.null(a)) b else a
dropped <- function(rec) rec$specification$sample$dropped

# lm: summary()'s table, confint(), metrics, F test, sample drops
m <- lm(y ~ x + x2 + f, d)
r <- to_estimation(m)
check(r, "lm")
ct <- summary(m)$coefficients
stopifnot(identical(r$meta$profiles, I("inference/0.1")), r$meta$estimator$method == "ols",
          r$specification$formula$syntax == "R", identical(r$meta$responses, I("y")))
eq(col(r, "estimate"), ct[, 1]); eq(col(r, "std_error"), ct[, 2])
eq(col(r, "statistic"), ct[, 3]); eq(col(r, "p_value"), ct[, 4])
eq(col(r, "conf_low"), confint(m)[, 1]); eq(col(r, "conf_high"), confint(m)[, 2])
stopifnot(r$parameters[[4]]$canonical$factors[[1]]$variable == "f",
          r$parameters[[4]]$canonical$factors[[1]]$level == "b")
eq(r$metrics$r2, summary(m)$r.squared); eq(r$metrics$adj_r2, summary(m)$adj.r.squared)
eq(r$metrics$sigma, sigma(m)); eq(r$metrics$log_lik, logLik(m)); eq(r$metrics$aic, AIC(m))
eq(1 - r$metrics$rss / r$metrics$tss, summary(m)$r.squared)
stopifnot(r$metrics$nobs == nobs(m), r$metrics$df_residual == df.residual(m),
          r$specification$sample$rows_input == n, dropped(r)$missing == 2,
          r$structures$vcov[[1]]$type == "iid", r$structures$vcov[[1]]$df_t == df.residual(m))
fs <- summary(m)$fstatistic
stopifnot(r$tests[[1]]$name == "f"); eq(r$tests[[1]]$statistic, fs[1])
eq(r$tests[[1]]$p_value, pf(fs[1], fs[2], fs[3], lower.tail = FALSE))
eq(unlist(r$structures$vcov[[1]]$data), vcov(m))

# lm: weights (a zero weight is left out of nobs), subset, a collinear term
d$x3 <- 2 * d$x
m <- lm(y ~ x + x2 + x3, d, weights = w, subset = h > 1)
r <- to_estimation(m)
check(r, "lm_wsub")
stopifnot(r$specification$weights$variable == "w", r$metrics$nobs == nobs(m),
          dropped(r)$restriction == sum(d$h <= 1), dropped(r)$zero_weights == (d$h[12] > 1),
          r$specification$sample$rows_input - sum(unlist(dropped(r))) == nobs(m),
          r$parameters[[4]]$dropped == "collinear", length(r$structures$vcov[[1]]$labels) == 3)
eq(col(r, "estimate")[1:3], coef(m)[1:3]); eq(r$metrics$r2, summary(m)$r.squared)

# lm: sandwich vcovs; the first gives the parameters (coeftest: t on residual df)
if (requireNamespace("sandwich", quietly = TRUE)) {
  m <- lm(y ~ x + x2, d)
  r <- to_estimation(m, vcov = list("HC3", ~g, ~g + h, "iid"))
  check(r, "lm_vcovs")
  stopifnot(vapply(r$structures$vcov, `[[`, "", "type") == c("HC3", "CRV1", "CRV1", "iid"),
            vapply(r$structures$vcov, `[[`, TRUE, "default") == c(TRUE, FALSE, FALSE, FALSE),
            r$structures$vcov[[2]]$n_clusters$g == length(unique(d$g[-c(4, 9)])),
            identical(r$structures$vcov[[3]]$cluster, I(c("g", "h"))),
            identical(r$specification$clusters, I(character(0))))
  V <- sandwich::vcovHC(m, type = "HC3"); se <- sqrt(diag(V))
  eq(col(r, "std_error"), se)
  eq(col(r, "p_value"), 2 * pt(-abs(coef(m) / se), df.residual(m)))
  eq(unlist(r$structures$vcov[[2]]$data), sandwich::vcovCL(m, cluster = ~g, type = "HC1"))
  r <- to_estimation(m, vcov = ~g)
  stopifnot(identical(r$specification$clusters, I("g")))
}

# glm: Poisson with an offset (z tests, no df_t), binomial, Gamma, quasipoisson
p <- glm(c ~ x + x2, poisson, d, offset = log(t))
r <- to_estimation(p)
check(r, "poisson")
ct <- summary(p)$coefficients
stopifnot(identical(r$meta$profiles, I(c("inference/0.1", "glm/0.1"))),
          r$meta$estimator$distribution == "poisson", r$meta$estimator$link == "log",
          is.null(r$structures$vcov[[1]]$df_t), r$structures$numerics$converged,
          r$structures$numerics$iterations == p$iter, r$specification$offset$variable == "log(t)",
          r$metrics$df_null == p$df.null, dropped(r)$missing == 1, is.null(r$tests))
eq(col(r, "estimate"), ct[, 1]); eq(col(r, "std_error"), ct[, 2]); eq(col(r, "p_value"), ct[, 4])
eq(col(r, "conf_low"), confint.default(p)[, 1])
eq(r$metrics$deviance, deviance(p)); eq(r$metrics$null_deviance, p$null.deviance)
eq(r$metrics$log_lik, logLik(p)); eq(r$metrics$aic, AIC(p)); eq(r$metrics$dispersion, 1)

lg <- glm(b ~ x + offset(x2 / 10), binomial("probit"), d)
r <- to_estimation(lg)
check(r, "probit")
stopifnot(r$meta$estimator$link == "probit", r$specification$offset$variable == "x2/10")
eq(col(r, "statistic"), summary(lg)$coefficients[, 3])

gm <- glm(pos ~ x, Gamma("log"), d)
r <- to_estimation(gm)
check(r, "gamma")
stopifnot(r$meta$estimator$distribution == "gamma", r$structures$vcov[[1]]$df_t == df.residual(gm))
eq(col(r, "p_value"), summary(gm)$coefficients[, 4]); eq(r$metrics$dispersion, summary(gm)$dispersion)

qp <- glm(c ~ x, quasipoisson, d)
r <- to_estimation(qp)
check(r, "quasipoisson")
stopifnot(isTRUE(r$meta$estimator$quasi), r$meta$estimator$distribution == "poisson",
          is.null(r$metrics$log_lik), is.null(r$metrics$aic))
eq(col(r, "std_error"), summary(qp)$coefficients[, 2])

# glm with a clustered vcov (coeftest: z tests)
if (requireNamespace("sandwich", quietly = TRUE)) {
  r <- to_estimation(p, vcov = ~g)
  check(r, "poisson_cl")
  se <- sqrt(diag(sandwich::vcovCL(p, cluster = ~g, type = "HC1")))
  eq(col(r, "std_error"), se); eq(col(r, "p_value"), 2 * pnorm(-abs(coef(p) / se)))
}

# Not converged: a warning in meta
nc <- suppressWarnings(glm(b ~ x, binomial, d, control = glm.control(maxit = 1)))
r <- to_estimation(nc)
check(r, "notconv")
stopifnot(r$meta$status == "warning", !r$structures$numerics$converged)

# Added tests, data found after the fit, a list of fits, an unknown vcov
m1 <- lm(y ~ x, d); m2 <- lm(y ~ x + x2, d[complete.cases(d[c("y", "x2")]), ])
r <- add_test(to_estimation(m2), anova(m1 <- lm(y ~ x, m2$model), m2))
check(r, "lm_anova")
stopifnot(length(r$tests) == 2, r$tests[[2]]$origin == "postestimation")
rs <- to_estimation(list(a = m1, b = p))
stopifnot(length(rs) == 2, rs$b$meta$estimator$family == "glm")
stopifnot(inherits(try(to_estimation(m1, vcov = "nope"), silent = TRUE), "try-error"))
stopifnot(inherits(try(to_estimation(lm(cbind(y, x) ~ x2, d)), silent = TRUE), "try-error"))
f <- function() { dd <- d; lm(y ~ x, dd) }
r <- to_estimation(f())
stopifnot(r$specification$sample$rows_input == n, dropped(r)$missing == 1)
cat("test-stats.R: all passed\n")
