# Base R fits -> records. lm: inference/0.1. glm: inference/0.1 and glm/0.1. Written against
# R 4.x stats; robust and clustered vcovs come from 'sandwich' (vcovHC, vcovCL).
#
# The default vcov is the model-based one that summary() reports, and its tests are summary()'s:
# t tests for lm and for GLMs whose dispersion is estimated (gaussian, Gamma, inverse.gaussian,
# quasi families), z tests for Poisson and binomial. A sandwich vcov follows lmtest::coeftest():
# t tests on the residual df for lm, z tests for glm. Intervals are Wald intervals on the same
# distribution as the tests (confint() on a glm profiles the likelihood instead).

to_estimation.lm <- function(fit, data = NULL, vcov = NULL, conf_level = 0.95,
                             tests = NULL, title = NULL, notes = NULL, tags = NULL,
                             publication = NULL, call = TRUE, identifying = TRUE,
                             digest = NULL, level = NULL, purpose = NULL, program = NULL,
                             data_info = NULL, ...) {
  tests_expr <- substitute(tests); tests_env <- parent.frame()
  .st_record(fit, data = data, vcov = vcov, conf_level = conf_level, tests = tests,
             tests_expr = tests_expr, tests_env = tests_env, title = title, notes = notes,
             tags = tags, publication = publication, call = call, identifying = identifying,
             digest = digest, level = level, purpose = purpose, program = program,
             data_info = data_info)
}

to_estimation.glm <- function(fit, data = NULL, vcov = NULL, conf_level = 0.95,
                              tests = NULL, title = NULL, notes = NULL, tags = NULL,
                              publication = NULL, call = TRUE, identifying = TRUE,
                              digest = NULL, level = NULL, purpose = NULL, program = NULL,
                              data_info = NULL, ...) {
  tests_expr <- substitute(tests); tests_env <- parent.frame()
  .st_record(fit, data = data, vcov = vcov, conf_level = conf_level, tests = tests,
             tests_expr = tests_expr, tests_env = tests_env, title = title, notes = notes,
             tags = tags, publication = publication, call = call, identifying = identifying,
             digest = digest, level = level, purpose = purpose, program = program,
             data_info = data_info)
}

.st_record <- function(fit, data, vcov, conf_level, tests, tests_expr, tests_env, title, notes,
                       tags, publication, call, identifying, digest, level, purpose, program,
                       data_info) {
  if (inherits(fit, "mlm"))
    stop("estrec doesn't write multivariate lm fits (a matrix response) yet; fit one lm per response",
         call. = FALSE)
  if (inherits(fit, "negbin"))
    stop("estrec doesn't write MASS::glm.nb fits yet (theta is estimated outside the glm)",
         call. = FALSE)
  level <- .est_resolve_level(level, purpose)
  is_glm <- inherits(fit, "glm")
  est <- if (is_glm) .st_glm_estimator(fit) else list(family = "linear", method = "ols")
  if (is.null(data)) data <- .st_data(fit)

  smry <- summary(fit)
  aliased <- names(stats::coef(fit))[is.na(stats::coef(fit))]
  terms <- setdiff(names(stats::coef(fit)), aliased)
  # summary()'s tests: z when the dispersion is known (Poisson, binomial), else t
  model_z <- is_glm && !.st_dispersion_estimated(fit)

  vcov_args <- if (is.null(vcov)) list("iid") else if (inherits(vcov, "formula")) list(vcov)
               else if (is.list(vcov)) vcov else as.list(vcov)
  vcovs <- lapply(seq_along(vcov_args), function(i)
    .st_vcov(fit, vcov_args[[i]], terms, is_glm, model_z, default = i == 1L))
  main <- vcovs[[1]]

  # Parameters, from the default vcov
  b <- stats::coef(fit)[terms]
  if (identical(main$type, "iid")) {
    ct <- smry$coefficients[terms, , drop = FALSE]
    se <- ct[, 2]; stat <- ct[, 3]; p <- ct[, 4]
  } else {
    se <- sqrt(diag(attr(main, "V")))
    stat <- b / se
    p <- if (is.null(main$df_t)) 2 * stats::pnorm(-abs(stat))
         else 2 * stats::pt(-abs(stat), main$df_t)
  }
  crit <- if (is.null(main$df_t)) stats::qnorm(1 - (1 - conf_level) / 2)
          else stats::qt(1 - (1 - conf_level) / 2, main$df_t)
  parameters <- lapply(terms, function(t) list(
    term = t, canonical = .st_canonical(fit, t),
    estimate = .est_num(b[[t]]), std_error = .est_num(se[[t]]),
    statistic = .est_num(stat[[t]]), p_value = .est_num(p[[t]]),
    conf_low = .est_num(b[[t]] - crit * se[[t]]), conf_high = .est_num(b[[t]] + crit * se[[t]])))
  parameters <- c(parameters, lapply(aliased, function(t)
    list(term = t, canonical = .st_canonical(fit, t), dropped = "collinear")))
  vcovs <- lapply(vcovs, function(v) { attr(v, "V") <- NULL; v })

  sample <- .st_sample(fit, data)
  nobs <- stats::nobs(fit)
  ll <- tryCatch(stats::logLik(fit), error = function(e) NULL)
  llv <- if (!is.null(ll) && is.finite(as.numeric(ll))) as.numeric(ll)
  ic <- function(f) if (!is.null(llv)) .est_num(f(fit))

  if (is_glm) {
    metrics <- list(nobs = nobs, df_residual = df.residual(fit), log_lik = .est_num(llv),
                    deviance = .est_num(fit$deviance), null_deviance = .est_num(fit$null.deviance),
                    df_null = fit$df.null, aic = ic(stats::AIC), bic = ic(stats::BIC),
                    dispersion = .est_num(smry$dispersion), conf_level = conf_level)
  } else {
    w <- stats::weights(fit)
    y <- stats::fitted(fit) + stats::residuals(fit)
    if (is.null(w)) w <- rep(1, length(y))
    has_int <- attr(stats::terms(fit), "intercept") == 1L
    tss <- if (has_int) sum(w * (y - sum(w * y) / sum(w))^2) else sum(w * y^2)
    metrics <- list(nobs = nobs, df_residual = df.residual(fit),
                    r2 = .est_num(smry$r.squared), adj_r2 = .est_num(smry$adj.r.squared),
                    sigma = .est_num(smry$sigma), rss = .est_num(stats::deviance(fit)),
                    tss = .est_num(tss), log_lik = .est_num(llv),
                    aic = ic(stats::AIC), bic = ic(stats::BIC), conf_level = conf_level)
  }
  metrics <- .est_compact(metrics)

  # Specification
  text <- paste(deparse(stats::formula(fit), width.cutoff = 500L), collapse = "")
  wvar <- .st_weight_var(fit)
  wtype <- if (is_glm && est$distribution == "binomial") "frequency" else "analytic"
  options <- if (is_glm) list(tolerance = fit$control$epsilon,
                              max_iterations = as.integer(fit$control$maxit))
  spec <- .est_compact(list(
    formula = list(text = text, syntax = "R"),
    terms = I(terms),
    weights = if (!is.null(wvar)) list(variable = wvar, type = wtype),
    clusters = I(main$cluster %||% character(0)),
    sample = sample[c("restriction", "rows_input", "dropped")],
    options = options))
  if (is.null(spec$sample$restriction)) spec$sample["restriction"] <- list(NULL)
  if (is.null(spec$weights)) spec["weights"] <- list(NULL)
  if (is_glm) spec["offset"] <- list(.st_offset(fit))
  if (isTRUE(call)) spec$call <- paste(deparse(fit$call, width.cutoff = 500L), collapse = " ")
  if (!is.null(program)) spec$program <- .est_program(program)

  structures <- list(vcov = vcovs)
  if (is_glm) {
    structures$numerics <- .est_compact(list(
      kind = "object", iterative = TRUE, algorithm = "irls", converged = isTRUE(fit$converged),
      boundary = isTRUE(fit$boundary), tolerance = fit$control$epsilon,
      max_iterations = as.integer(fit$control$maxit), iterations = as.integer(fit$iter),
      collinear_terms = I(aliased)))
  } else if (length(aliased)) {
    structures$numerics <- list(kind = "object", iterative = FALSE, algorithm = "qr",
                                collinearity_tolerance = 1e-7, collinear_terms = I(aliased))
  }

  # Tests: summary.lm's F test that every slope is zero (model-based vcov)
  st_tests <- list()
  fs <- if (!is_glm) smry$fstatistic
  if (length(fs) == 3L && is.finite(fs[[1]]))
    st_tests <- list(list(category = "model", name = "f", origin = "estimation",
                          statistic = .est_num(fs[[1]]), distribution = "F",
                          df1 = .est_num(fs[[2]]), df2 = .est_num(fs[[3]]),
                          p_value = .est_num(stats::pf(fs[[1]], fs[[2]], fs[[3]], lower.tail = FALSE)),
                          vcov = "iid"))

  provenance <- list(
    software = .est_software("stats"),
    environment = .est_environment(),
    data = list(.st_data_input(fit, data, data_info)))
  if (identifying) {
    provenance$agent <- .est_agent()
    provenance$execution <- list(invocation = list(argv = I(commandArgs())))
  }

  messages <- sample$messages
  if (is_glm && !isTRUE(fit$converged))
    messages <- c(messages, list(list(level = "warning", code = "not_converged", source = "stats",
                  message = sprintf("the IRLS iterations did not converge (%d iterations)", as.integer(fit$iter)))))
  if (is_glm && isTRUE(fit$boundary))
    messages <- c(messages, list(list(level = "warning", code = "boundary", source = "stats",
                  message = "the fitted values reached the boundary of the parameter space")))
  if (length(aliased))
    messages <- c(messages, list(list(level = "info", code = "collinear", source = "stats",
                  message = paste("collinear terms dropped:", paste(aliased, collapse = ", ")))))

  profiles <- c("inference/0.1", if (is_glm) "glm/0.1")
  status <- if (is_glm && (!isTRUE(fit$converged) || isTRUE(fit$boundary))) "warning" else "ok"
  meta <- .est_compact(list(
    id = .est_uuid(), created = .est_now(), status = status, estimator = est,
    responses = I(all.vars(stats::formula(fit)[[2]])), profiles = I(profiles),
    title = title %||% if (level >= 3L) text, tags = if (length(tags)) I(tags),
    notes = notes, producer = estrec_info()))
  if (length(messages)) meta$messages <- messages

  rec <- list(schema = "estrec/0.1", meta = meta, specification = spec, metrics = metrics,
              parameters = parameters, structures = structures)
  if (length(st_tests))
    rec$tests <- lapply(seq_along(st_tests), function(i) c(list(id = paste0("t", i)), st_tests[[i]]))
  rec$provenance <- provenance
  if (!is.null(publication)) rec$publication <- publication
  rec <- .est_at_level(rec, level, purpose)
  if (!is.null(tests)) {
    exprs <- tests_expr
    one <- !is.list(tests) || is.data.frame(tests) || inherits(tests, "htest") ||
      !is.null(tests[["stat", exact = TRUE]]) || !is.null(tests[["name", exact = TRUE]])
    if (one) { tests <- list(tests); exprs <- list(exprs) }
    else exprs <- if (is.call(exprs) && identical(exprs[[1L]], quote(list))) as.list(exprs)[-1L]
                  else vector("list", length(tests))
    for (i in seq_along(tests))
      rec <- .est_add_test(rec, tests[[i]], exprs[[i]], tests_env)
  }
  .est_add_digest(rec, digest)
}

# R names a factor's dummy by pasting the variable and level ("fb"); the fit's xlevels say
# which parts are factors, so they become "f::b" before the shared canonical naming
.st_canonical <- function(fit, term) {
  xl <- fit$xlevels
  if (!length(xl) || term == "(Intercept)") return(.est_canonical(term))
  parts <- strsplit(term, ":", fixed = TRUE)[[1]]
  parts <- vapply(parts, function(p) {
    for (v in names(xl)[order(-nchar(names(xl)))])
      if (startsWith(p, v) && substring(p, nchar(v) + 1L) %in% xl[[v]])
        return(paste0(v, "::", substring(p, nchar(v) + 1L)))
    p
  }, "")
  .est_canonical(paste(parts, collapse = ":"))
}

# Families whose dispersion summary.glm estimates (t tests) rather than fixes at 1 (z tests)
.st_dispersion_estimated <- function(fit) !fit$family$family %in% c("poisson", "binomial")

.st_glm_estimator <- function(fit) {
  fam <- fit$family$family
  quasi <- startsWith(fam, "quasi")
  dist <- if (quasi) sub("^quasi", "", fam) else fam
  dist <- switch(dist, Gamma = "gamma", inverse.gaussian = "inverse_gaussian", dist)
  if (identical(dist, "")) dist <- "quasi"  # quasi(): the variance function is the user's
  link <- switch(fit$family$link, `1/mu^2` = "inverse_square", fit$family$link)
  .est_compact(list(family = "glm", method = "irls", distribution = dist, link = link,
                    quasi = if (quasi) TRUE))
}

# The data the model was fitted on: glm keeps it; for lm, the call's `data` in the formula's
# environment (where lm looked it up)
.st_data <- function(fit) {
  if (is.data.frame(fit$data)) return(fit$data)
  if (is.null(fit$call$data)) return(NULL)
  env <- environment(stats::formula(fit)) %||% globalenv()
  d <- tryCatch(eval(fit$call$data, env), error = function(e) NULL)
  if (is.data.frame(d)) d
}

.st_weight_var <- function(fit) {
  w <- fit$call$weights
  if (is.null(w)) return(NULL)
  paste(deparse(w), collapse = "")
}

.st_offset <- function(fit) {
  v <- fit$call$offset
  if (!is.null(v)) return(list(variable = paste(deparse(v), collapse = ""), exposure = FALSE))
  tt <- stats::terms(fit)
  off <- attr(tt, "offset")
  if (length(off)) {
    e <- attr(tt, "variables")[[off[1] + 1L]][[2]]
    return(list(variable = paste(deparse(e), collapse = ""), exposure = FALSE))
  }
  NULL
}

.st_data_input <- function(fit, data, data_info) {
  arg <- fit$call$data
  d <- .est_compact(list(role = "estimation", name = if (is.name(arg)) as.character(arg),
                         rows = if (!is.null(data)) nrow(data),
                         columns = if (!is.null(data)) I(names(data))))
  for (k in names(data_info)) d[[k]] <- data_info[[k]]
  d
}

# Rows in, the subset restriction and rows dropped: missing (na.action) and zero weights,
# which lm and glm keep in the fit but leave out of nobs()
.st_sample <- function(fit, data) {
  n_frame <- NROW(stats::residuals(fit))
  n_miss <- length(fit$na.action)
  w <- if (inherits(fit, "glm")) fit$prior.weights else fit$weights
  n_zero <- if (!is.null(fit$call$weights) && !is.null(w)) sum(w == 0) else 0L
  messages <- list()
  restriction <- if (!is.null(fit$call$subset))
    paste("subset:", paste(deparse(fit$call$subset), collapse = ""))
  dropped <- list()
  n_in <- n_frame + n_miss
  if (!is.null(data) && nrow(data) < n_in) {
    warning("`data` has ", nrow(data), " rows but the fit used ", n_in,
            "; it isn't the fit's data and is left out of the sample counts", call. = FALSE)
    data <- NULL
  }
  if (!is.null(data)) {
    extra <- nrow(data) - n_in
    if (extra > 0 && !is.null(restriction)) dropped$restriction <- extra
    else if (extra > 0) dropped$other <- extra
    rows_input <- nrow(data)
  } else {
    rows_input <- n_in
    if (!is.null(restriction))
      messages <- list(list(level = "warning", code = "sample_unclassified", source = "estrec",
        message = "the data the model was fitted on wasn't available: rows_input counts the rows after the subset; pass `data` to count the subset's rows"))
  }
  dropped$missing <- n_miss
  if (n_zero > 0) dropped$zero_weights <- n_zero
  list(restriction = restriction, rows_input = rows_input, dropped = dropped, messages = messages)
}

# One vcov: "iid" (the model-based one), "HC0".."HC5" or "hetero" (HC1) through
# sandwich::vcovHC, or a one-sided formula of cluster variables through sandwich::vcovCL
# (type HC1: (n-1)/(n-k) and G/(G-1), Stata's CRV1). The matrix rides along in attr "V".
.st_vcov <- function(fit, v, terms, is_glm, model_z, default) {
  out <- NULL
  if (is.character(v) && length(v) == 1L && v %in% c("iid", "const")) {
    V <- stats::vcov(fit)[terms, terms, drop = FALSE]
    out <- list(type = "iid", tool_type = "model-based",
                ssc = list(convention = "R lm",
                           formula = if (!is_glm) "sigma^2 = RSS / (N - K)"
                                     else if (model_z) "inverse Fisher information (dispersion 1)"
                                     else "dispersion = sum of squared Pearson residuals / (N - K)"))
    z <- model_z
  } else {
    if (!requireNamespace("sandwich", quietly = TRUE))
      stop("robust and clustered vcovs need the 'sandwich' package", call. = FALSE)
    if (is.character(v) && length(v) == 1L) {
      type <- if (v == "hetero") "HC1" else v
      if (!type %in% paste0("HC", 0:5))
        stop("vcov = \"", v, "\" isn't known; use \"iid\", \"HC0\" to \"HC5\", \"hetero\" or a formula of cluster variables",
             call. = FALSE)
      V <- sandwich::vcovHC(fit, type = type)[terms, terms, drop = FALSE]
      out <- list(type = type, tool_type = sprintf("sandwich::vcovHC(type = \"%s\")", type),
                  ssc = list(convention = "sandwich",
                             formula = switch(type, HC0 = "none", HC1 = "N / (N - K)",
                                              HC2 = "1 / (1 - h_i)", HC3 = "1 / (1 - h_i)^2",
                                              HC4 = "1 / (1 - h_i)^delta_i", HC5 = "1 / sqrt((1 - h_i)^delta_i)")))
    } else if (inherits(v, "formula")) {
      cl <- all.vars(v)
      V <- sandwich::vcovCL(fit, cluster = v, type = "HC1")[terms, terms, drop = FALSE]
      out <- list(type = "CRV1", tool_type = sprintf("sandwich::vcovCL(cluster = %s, type = \"HC1\")",
                                                     paste(deparse(v), collapse = "")),
                  cluster = I(cl),
                  ssc = list(convention = "sandwich",
                             formula = "(N - 1) / (N - K) and G / (G - 1)"))
      vals <- tryCatch(stats::expand.model.frame(fit, v, na.expand = FALSE), error = function(e) NULL)
      if (!is.null(vals) && all(cl %in% names(vals))) {
        n_cl <- lapply(cl, function(x) length(unique(vals[[x]])))
        names(n_cl) <- cl
        out$n_clusters <- n_cl
        out$n_clusters_min <- min(unlist(n_cl))
      }
    } else {
      stop("each vcov is \"iid\", \"HC0\" to \"HC5\", \"hetero\" or a formula of cluster variables",
           call. = FALSE)
    }
    z <- is_glm  # lmtest::coeftest(): z tests for glm, t for lm
  }
  res <- c(list(kind = "matrix", labels = I(terms),
                data = lapply(seq_len(nrow(V)), function(i) I(unname(V[i, ])))),
           out[c("type", "tool_type")], out["cluster"], out["n_clusters"], out["n_clusters_min"],
           list(ssc = out$ssc))
  res <- .est_compact(res)
  if (!z) res$df_t <- df.residual(fit)
  res$default <- default
  attr(res, "V") <- V
  res
}
