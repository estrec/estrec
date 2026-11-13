# fixest fits -> records. feols: inference/0.1, linear-fe/0.1 with fixed effects, iv/0.1 for IV.
# feglm and fepois: glm/0.1 and inference/0.1. Written against fixest 0.14.2.
#
# fixest keeps one set of removed rows (`obs_selection`) and reports the singleton count only
# in a message. To split the drops by reason, the writer needs the data the model was fitted
# on: it takes `data`, or else recovers it from the fit's call environment, as fixest's own
# methods do. Without it, the drops are recorded as `other`.

to_estimation.fixest_multi <- function(fit, ...) {
  fits <- as.list(fit)
  failed <- vapply(fits, function(f) isTRUE(f$NA_model), logical(1))
  if (all(failed)) stop("fixest couldn't estimate any of the models", call. = FALSE)
  if (any(failed))
    warning("fixest couldn't estimate model", if (sum(failed) > 1) "s", " ",
            paste(which(failed), collapse = ", "), " of ", length(fits), " (no coefficients); ",
            "no record is written for ", if (sum(failed) > 1) "them" else "it", call. = FALSE)
  lapply(fits[!failed], to_estimation.fixest, ...)
}

to_estimation.fixest <- function(fit, data = NULL, vcov = NULL, conf_level = 0.95,
                                 tests = NULL, title = NULL, notes = NULL, tags = NULL,
                                 publication = NULL, call = TRUE, identifying = TRUE,
                                 digest = NULL, level = NULL, purpose = NULL, program = NULL,
                                 data_info = NULL, ...) {
  tests_expr <- substitute(tests); tests_env <- parent.frame()
  level <- .est_resolve_level(level, purpose)
  is_glm <- fit$method %in% c("feglm", "fepois")
  if (!is_glm && fit$method != "feols")
    stop("estrec writes feols, feglm and fepois fits; ", fit$method, " isn't supported yet",
         call. = FALSE)
  if (isTRUE(fit$NA_model))
    stop("fixest couldn't estimate this model (no coefficients), so there's nothing to record",
         call. = FALSE)
  is_iv <- isTRUE(fit$is_iv)
  if (is_iv && !identical(fit$iv_stage, 2))
    stop("a first-stage fit: convert the second stage (summary(fit, stage = 2))", call. = FALSE)
  has_fe <- !is.null(fit$fixef_vars)
  if (is.null(data)) data <- tryCatch(eval(fit$call$data, fit$call_env), error = function(e) NULL)
  if (!is.null(data) && nrow(data) != fit$nobs_origin) {
    warning("`data` has ", nrow(data), " rows but the fit saw ", fit$nobs_origin,
            "; sample drops are recorded as `other`", call. = FALSE)
    data <- NULL
  }

  # vcovs: the fit's own, or each one asked for; the first is the default
  vcov_args <- if (is.null(vcov)) list(NULL) else if (is.list(vcov)) vcov else as.list(vcov)
  fits <- lapply(vcov_args, function(v) if (is.null(v)) fit else summary(fit, vcov = v))
  main <- fits[[1]]

  sample <- .fx_sample(fit, data)
  used <- fixest::obs(fit)

  # Parameters, from the default vcov
  ct <- fixest::coeftable(main)
  ci <- confint(main, level = conf_level)
  endo <- if (is_iv) fit$iv_endo_names else character(0)
  canon <- function(term) {
    if (startsWith(term, "fit_") && substring(term, 5L) %in% endo)
      return(list(name = substring(term, 5L), factors = list(list(variable = substring(term, 5L)))))
    .est_canonical(term)
  }
  parameters <- lapply(rownames(ct), function(term) list(
    term = term, canonical = canon(term),
    estimate = .est_num(ct[term, 1]), std_error = .est_num(ct[term, 2]),
    statistic = .est_num(ct[term, 3]), p_value = .est_num(ct[term, 4]),
    conf_low = .est_num(ci[term, 1]), conf_high = .est_num(ci[term, 2])))
  collinear <- if (is.null(fit$collin.var)) character(0) else fit$collin.var
  parameters <- c(parameters, lapply(collinear, function(t)
    list(term = t, canonical = canon(t), dropped = "collinear")))

  vcovs <- lapply(seq_along(fits), function(i) .fx_vcov(fits[[i]], data, used, default = i == 1L))

  # Metrics (fixest's own values)
  if (is_glm) {
    metrics <- .fx_glm_metrics(fit, sample, conf_level)
  } else {
    metrics <- list(nobs = fit$nobs, df_residual = df.residual(fit),
                    r2 = .est_num(fixest::r2(fit, "r2")), adj_r2 = .est_num(fixest::r2(fit, "ar2")),
                    sigma = .est_num(sigma(fit)), rss = .est_num(fit$ssr),
                    tss = .est_num(fit$ssr_null), log_lik = .est_num(as.numeric(logLik(fit))),
                    log_lik_null = .est_num(fit$ll_null), sq_corr_fitted = .est_num(fit$sq.cor),
                    aic = .est_num(stats::AIC(fit)), bic = .est_num(stats::BIC(fit)),
                    conf_level = conf_level)
  }
  if (!is.null(sample$dropped$singletons)) metrics$n_singletons <- sample$dropped$singletons
  if (has_fe && !is_glm) {
    metrics$r2_within <- .est_num(fixest::r2(fit, "wr2"))
    metrics$adj_r2_within <- .est_num(fixest::r2(fit, "war2"))
    metrics$log_lik_fe_only <- .est_num(fit$ll_fe_only)
  }
  metrics <- .est_compact(metrics)

  # Specification
  fixef_rm <- if (!is.null(fit$call$fixef.rm)) eval(fit$call$fixef.rm, fit$call_env) else "perfect_fit"
  collin_tol <- if (!is.null(fit$call$collin.tol)) eval(fit$call$collin.tol, fit$call_env) else 1e-10
  options <- list(drop_singletons = has_fe && fixef_rm != "none", fixef_rm = fixef_rm,
                  collinearity_tolerance = collin_tol)
  if (is_glm) {
    glm_ctl <- .fx_glm_control(fit)
    options$separation <- I(.fx_separation(fit, fixef_rm))
    options$tolerance <- glm_ctl$tol
    options$max_iterations <- glm_ctl$iter
    if (has_fe) {
      options$fixef_tolerance <- fit$fixef.tol
      options$fixef_max_iterations <- as.integer(fit$fixef.iter)
    }
  } else if (has_fe) {
    options$tolerance <- fit$fixef.tol
    options$max_iterations <- fit$fixef.iter
  }
  text <- paste(deparse(fit$fml_all$linear, width.cutoff = 500L), collapse = "")
  if (has_fe) text <- paste(text, "|", paste(fit$fixef_vars, collapse = " + "))
  if (is_iv) text <- paste(text, "|", paste(deparse(fit$fml_all$iv, width.cutoff = 500L), collapse = ""))
  wvar <- .fx_weight_vars(fit)
  spec <- list(formula = list(text = text, syntax = "fixest"),
               terms = I(names(stats::coef(fit))),
               weights = if (length(wvar)) list(variable = wvar, type = "analytic") else NULL,
               fixed_effects = I(if (has_fe) fit$fixef_vars else character(0)),
               clusters = I(vcovs[[1]]$cluster %||% character(0)),
               sample = sample[c("restriction", "rows_input", "dropped")],
               options = options)
  if (is.null(spec$sample$restriction)) spec$sample["restriction"] <- list(NULL)
  if (is_glm) spec["offset"] <- list(.fx_offset(fit))
  if (is_iv) {
    spec$endogenous <- I(fit$iv_endo_names)
    spec$instruments <- I(fit$iv_inst_names_xpd)
  }
  if (isTRUE(call)) spec$call <- paste(deparse(fit$call, width.cutoff = 500L), collapse = " ")
  if (!is.null(program)) spec$program <- .est_program(program)

  # Structures
  structures <- list(vcov = vcovs)
  if (has_fe) {
    structures$fixed_effects <- lapply(names(fit$fixef_sizes), function(n)
      list(kind = "object", name = n, levels = unname(fit$fixef_sizes[[n]])))
  }
  if (is_glm) {
    structures$numerics <- .est_compact(list(
      kind = "object", iterative = TRUE, algorithm = "irls", converged = isTRUE(fit$convStatus),
      tolerance = glm_ctl$tol, max_iterations = glm_ctl$iter,
      iterations = if (length(fit$iterations)) max(fit$iterations),
      fixef_algorithm = if (has_fe) "map", fixef_tolerance = if (has_fe) fit$fixef.tol,
      fixef_max_iterations = if (has_fe) as.integer(fit$fixef.iter), collinearity_tolerance = collin_tol,
      collinear_terms = I(collinear), collinearity_min_norm = .est_num(fit$collin.min_norm)))
  } else if (has_fe) {
    it <- fit$iterations
    structures$numerics <- .est_compact(list(
      kind = "object", iterative = TRUE, algorithm = "map", tolerance = fit$fixef.tol,
      max_iterations = fit$fixef.iter, iterations = if (length(it)) max(it),
      iterations_by_variable = if (length(it)) I(it), collinearity_tolerance = collin_tol,
      collinear_terms = I(collinear), collinearity_min_norm = .est_num(fit$collin.min_norm)))
  }
  # Tests: fixest's joint Wald test of the coefficients under the default vcov, and for IV the
  # first-stage, identification, endogeneity and overidentification tests
  iv_tests <- if (is_iv) .fx_iv_tests(fit)
  fx_tests <- Filter(Negate(is.null), c(list(.fx_model_test(main)), iv_tests))

  provenance <- list(
    software = .est_software("fixest"),
    environment = .est_environment(threads = list(fixest = fixest::getFixest_nthreads())),
    data = list(.fx_data_input(fit, data, data_info)))
  if (identifying) {
    provenance$agent <- .est_agent()
    provenance$execution <- list(invocation = list(argv = I(commandArgs())))
  }

  profiles <- c("inference/0.1", if (is_glm) "glm/0.1", if (has_fe && !is_glm) "linear-fe/0.1",
                if (is_iv) "iv/0.1")
  estimator <- if (is_glm) .fx_glm_estimator(fit)
               else list(family = "linear", method = if (is_iv) "2sls" else "ols")
  meta <- .est_compact(list(
    id = .est_uuid(), created = .est_now(), status = if (is_glm && !isTRUE(fit$convStatus)) "warning" else "ok",
    estimator = estimator,
    responses = I(fit$model_info$lhs %||% all.vars(fit$fml_all$linear)[1]),
    profiles = I(profiles), title = title %||% if (level >= 3L) .fx_title(fit, text), tags = if (length(tags)) I(tags),
    notes = notes, producer = estrec_info()))
  messages <- sample$messages
  if (is_glm && !isTRUE(fit$convStatus))
    messages <- c(messages, list(list(level = "warning", code = "not_converged", source = "fixest",
                  message = sprintf("the IRLS iterations did not converge (%d iterations)",
                                    as.integer(max(fit$iterations))))))
  if (!is.null(sample$dropped$separated) && sample$dropped$separated > 0)
    messages <- c(messages, list(list(level = "info", code = "separated", source = "fixest",
                  message = sprintf("%d rows dropped in fixed-effect levels whose outcomes are all at a bound",
                                    sample$dropped$separated))))
  if (!is.null(sample$dropped$singletons) && sample$dropped$singletons > 0)
    messages <- c(messages, list(list(level = "info", code = "singletons", source = "fixest",
                  message = sprintf("%d singleton rows dropped", sample$dropped$singletons))))
  if (length(collinear))
    messages <- c(messages, list(list(level = "info", code = "collinear", source = "fixest",
                  message = paste("collinear terms dropped:", paste(collinear, collapse = ", ")))))
  messages <- c(messages, attr(iv_tests, "messages"))
  if (length(messages)) meta$messages <- messages

  rec <- list(schema = "estrec/0.1", meta = meta, specification = spec, metrics = metrics,
              parameters = parameters, structures = structures)
  if (length(fx_tests))
    rec$tests <- lapply(seq_along(fx_tests), function(i) c(list(id = paste0("t", i)), fx_tests[[i]]))
  rec$provenance <- provenance
  if (!is.null(publication)) rec$publication <- publication
  rec <- .est_at_level(rec, level, purpose)
  # Test results given in the call, one or a list (see add_test). The calls that made them are
  # kept, so a wald() test records its terms and each test its call.
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

`%||%` <- function(a, b) if (is.null(a)) b else a

# provenance.data: the data the fit used. Its name is `data_info$name`, else the `data`
# argument as written in the call when it is a plain name; `data_info` adds the rest
# (version, source, checksum, publication with a data citation, location).
.fx_data_input <- function(fit, data, data_info) {
  arg <- fit$call$data
  name <- if (is.name(arg)) as.character(arg)
  d <- .est_compact(list(role = "estimation", name = name, rows = fit$nobs_origin,
                         columns = if (!is.null(data)) I(names(data))))
  for (k in names(data_info)) d[[k]] <- data_info[[k]]
  d
}

.fx_weight_vars <- function(fit) {
  if (is.null(fit$call$weights)) return(character(0))
  w <- fit$call$weights
  if (is.call(w) && identical(w[[1]], as.name("~"))) all.vars(w) else all.vars(as.formula(paste("~", deparse(w))))
}

.fx_title <- function(fit, text) {
  s <- fit$model_info$sample
  if (is.null(s) || identical(s$value, "Full sample")) return(text)
  sprintf("%s [%s = %s]", text, s$var, s$value)
}

# Rows in, the restriction (subset, split) and rows dropped by reason
.fx_sample <- function(fit, data) {
  n0 <- fit$nobs_origin
  keep <- rep(TRUE, n0)
  restriction <- character(0)
  messages <- list()
  sel <- fit$obs_selection
  if (!is.null(fit$call$subset)) {
    idx <- sel$subset
    if (!is.null(idx)) keep <- if (all(idx < 0)) !(seq_len(n0) %in% -idx) else seq_len(n0) %in% idx
    restriction <- c(restriction, paste("subset:", paste(deparse(fit$call$subset), collapse = "")))
  }
  s <- fit$model_info$sample
  split_known <- TRUE
  if (!is.null(s) && !identical(s$value, "Full sample")) {
    restriction <- c(restriction, sprintf("split: %s == %s", s$var, s$value))
    v <- if (!is.null(data)) tryCatch(eval(str2lang(s$var), data, fit$call_env), error = function(e) NULL)
    if (length(v) == n0) keep <- keep & !is.na(v) & as.character(v) == s$value else split_known <- FALSE
  }
  dropped <- list()
  n_restricted <- sum(keep)
  if (length(restriction) && split_known) dropped$restriction <- n0 - n_restricted

  if (is.null(data) || !split_known) {
    dropped$other <- if (split_known && length(restriction)) n_restricted - fit$nobs else n0 - fit$nobs
    messages <- list(list(level = "warning", code = "sample_unclassified", source = "estrec",
      message = "the data the model was fitted on wasn't available: rows dropped are recorded as `other`; pass `data` to split them by reason"))
  } else {
    vars <- unique(c(all.vars(fit$fml_all$linear),
                     if (!is.null(fit$fml_all$fixef)) all.vars(fit$fml_all$fixef),
                     if (!is.null(fit$fml_all$iv)) all.vars(fit$fml_all$iv),
                     if (!is.null(fit$call$cluster)) tryCatch(all.vars(as.formula(fit$call$cluster)),
                                                              error = function(e) character(0)),
                     .fx_weight_vars(fit)))
    vars <- intersect(vars, names(data))
    d <- data[keep, vars, drop = FALSE]
    miss <- !complete.cases(d)
    num <- vapply(d, is.numeric, logical(1))
    nonfin <- !miss & (if (any(num)) Reduce(`|`, lapply(d[num], function(x) is.infinite(x))) else FALSE)
    wv <- .fx_weight_vars(fit)
    zero_w <- if (length(wv) == 1L && wv %in% names(d)) !miss & !nonfin & d[[wv]] == 0 else FALSE
    dropped$missing <- sum(miss)
    if (any(nonfin)) dropped$non_finite <- sum(nonfin)
    if (any(zero_w)) dropped$zero_weights <- sum(zero_w)
    rest <- n_restricted - sum(miss) - sum(nonfin) - sum(zero_w) - fit$nobs
    has_fe <- !is.null(fit$fixef_vars)
    split <- NULL
    if (has_fe && fit$method %in% c("feglm", "fepois") && rest > 0) {
      cand <- which(keep)[!(miss | nonfin | zero_w)]
      split <- .fx_glm_removed(fit, data, cand)
      if (is.null(split)) {  # couldn't reproduce fixest's removals: `other`
        dropped$other <- rest
        messages <- list(list(level = "warning", code = "sample_unclassified", source = "estrec",
          message = "rows removed by the fixed effects couldn't be split into singletons and separated rows; they are recorded as `other`"))
      } else { dropped$singletons <- split$singletons; dropped$separated <- split$separated }
    } else if (has_fe) {
      dropped$singletons <- max(rest, 0L)
      if (fit$method %in% c("feglm", "fepois") && rest == 0) dropped$separated <- 0L
    }
    if (rest < 0 || (!has_fe && rest != 0)) {
      dropped$singletons <- NULL; dropped$separated <- NULL
      dropped$other <- n_restricted - fit$nobs - sum(miss) - sum(nonfin) - sum(zero_w)
      messages <- list(list(level = "warning", code = "sample_unclassified", source = "estrec",
        message = "sample counts don't add up by reason; the rest are recorded as `other`"))
    }
  }
  list(restriction = if (length(restriction)) paste(restriction, collapse = "; "),
       rows_input = n0, dropped = dropped, messages = messages)
}

.fx_vcov_type <- function(label) {
  if (!.fx_is_label(label)) return(NULL)
  if (grepl("^IID", label, ignore.case = TRUE)) return("iid")
  if (grepl("^Heteroskedasticity", label)) return("HC1")
  if (grepl("^Clustered|^Twoway|^Multiway", label)) return("CRV1")
  if (grepl("^Newey", label)) return("NW")
  if (grepl("^Driscoll", label)) return("DK")
  if (grepl("^Conley", label)) return("conley")
  label
}

# fixest labels the vcov in attr "vcov_type"; an unlabeled one stops in .fx_vcov with a clear error
.fx_is_label <- function(label) is.character(label) && length(label) == 1L && !is.na(label) && nzchar(label)

.fx_cluster_vars <- function(fit, label) {
  flag <- fit$summary_flags$vcov
  if (inherits(flag, "formula")) return(all.vars(flag))
  if (is.null(fit$summary_flags) && !is.null(fit$call$cluster))
    return(tryCatch(all.vars(as.formula(fit$call$cluster)), error = function(e) character(0)))
  if (!.fx_is_label(label)) return(character(0))
  m <- regmatches(label, regexec("^Clustered \\((.+)\\)$", label))[[1]]  # the default: first FE
  if (length(m) == 2L) return(trimws(strsplit(m[2], "&", fixed = TRUE)[[1]]))
  character(0)
}

.fx_vcov <- function(f, data, used, default) {
  vc <- vcov(f, attr = TRUE)
  label <- attr(vc, "vcov_type")
  if (!.fx_is_label(label))
    stop("fixest returned the variance matrix without its type label (fixest ",
         as.character(utils::packageVersion("fixest")), "); estrec is written against fixest 0.14. ",
         "Please update fixest, or report this with the model call", call. = FALSE)
  clusters <- .fx_cluster_vars(f, label)
  out <- list(kind = "matrix", labels = I(colnames(vc)),
              data = lapply(seq_len(nrow(vc)), function(i) I(unname(vc[i, ]))),
              type = .fx_vcov_type(label), tool_type = label)
  if (length(clusters)) {
    out$cluster <- I(clusters)
    if (!is.null(data) && all(clusters %in% names(data))) {
      n_cl <- lapply(clusters, function(v) length(unique(data[[v]][used])))
      names(n_cl) <- clusters
      out$n_clusters <- n_cl
      out$n_clusters_min <- min(unlist(n_cl))
    }
  }
  ssc <- attr(vc, "ssc")
  out$ssc <- list(convention = "fixest",
                  formula = "K.adj: (n-1)/(n-K) (n/(n-K)... per vcov type); G.adj: G/(G-1)",
                  factors = .est_compact(unclass(ssc)[c("K.adj", "K.fixef", "G.adj", "G.df", "t.df", "K.exact")]),
                  K_counts = .est_compact(list(df.K = attr(vc, "df.K"), K.fixef = ssc$K.fixef)))
  # GLMs with a known dispersion (Poisson, binomial) use z tests: no df
  z <- identical(colnames(fixest::coeftable(f))[3], "z value")
  out$df_t <- if (z) NULL else if (!is.null(attr(vc, "df.t"))) attr(vc, "df.t") else df.residual(f)
  out$default <- default
  out
}

.fx_fitstat <- function(fit, type) {
  tryCatch(suppressWarnings(unclass(fixest::fitstat(fit, as.formula(paste("~", type)), simplify = FALSE))),
           error = function(e) NULL)
}

# A fitstat entry (stat, p, df1/df2 or df, vcov) -> a test object
.fx_test <- function(x, category, name, distribution = "F", ...) {
  if (!is.list(x) || is.null(x$stat) || anyNA(x$stat)) return(NULL)
  num <- function(v) if (!is.null(v)) .est_num(as.numeric(v))  # kpr's are 1 x 1 matrices
  chi <- !is.null(x$df)
  .est_compact(c(list(category = category, name = name, origin = "estimation"), list(...),
                 list(statistic = num(x$stat), distribution = if (chi) "chi2" else distribution,
                      df = num(x$df), df1 = num(x$df1), df2 = num(x$df2), p_value = num(x$p),
                      vcov = if (!is.null(x$vcov)) .fx_vcov_type(x$vcov))))
}

# fixest's Wald test of joint nullity of the coefficients (intercept and FEs excluded), with
# the fit's vcov
.fx_model_test <- function(f) {
  .fx_test(.fx_fitstat(f, "wald")$wald, "model", "wald")
}

# fixest's IV diagnostics (fitstat) -> tests (iv/0.1)
.fx_iv_tests <- function(fit) {
  ivf <- .fx_fitstat(fit, "ivf"); ivwald <- .fx_fitstat(fit, "ivwald")
  out <- list()
  for (e in fit$iv_endo_names) {
    out <- c(out, list(
      .fx_test(ivf[[paste0("ivf1::", e)]], "first_stage", "f", component = "first_stage", response = e),
      # ivwald repeats ivf under an iid vcov
      if (!identical(ivwald[[paste0("ivwald1::", e)]]$vcov, "IID"))
        .fx_test(ivwald[[paste0("ivwald1::", e)]], "first_stage", "wald", component = "first_stage", response = e)))
  }
  cd <- .fx_fitstat(fit, "cd")$cd
  if (is.numeric(cd) && !is.na(cd))
    out <- c(out, list(list(category = "weak_identification", name = "cragg_donald_f",
                            origin = "estimation", statistic = .est_num(as.numeric(cd)))))
  # fixest's `kpr` is the Kleibergen-Paap rk Wald F, ivreg2's e(rkf) x (N - K)/N, but only with
  # one endogenous variable, one instrument and a non-iid vcov. Otherwise it is wrong (iid; 2+
  # endogenous: kp_stat takes row k of V for column k), missing (overidentified, non-iid) or an
  # error (clustered unless #coefs = k x l). Its chi2 p-value doesn't fit an F statistic, so only
  # the statistic is kept (docs: iv profile; checked against ivreg2 4.1.12, fixest 0.14.2)
  kpr <- .fx_fitstat(fit, "kpr")$kpr
  vc_type <- .fx_vcov_type(attr(stats::vcov(fit, attr = TRUE), "vcov_type") %||% "IID")
  vc_iid <- identical(vc_type, "iid")
  one <- length(fit$iv_endo_names) == 1 && length(fit$iv_inst_names_xpd) == 1
  kp_ok <- !vc_iid && one && is.list(kpr) && !anyNA(kpr$stat)
  if (kp_ok)
    out <- c(out, list(list(category = "weak_identification", name = "kleibergen_paap_rk_wald_f",
                            origin = "estimation", statistic = .est_num(as.numeric(kpr$stat)),
                            vcov = vc_type)))
  kp_msg <- if (!kp_ok) list(list(level = "info", code = "kpr_omitted", source = "estrec",
    message = paste("fixest's Kleibergen-Paap statistic (kpr) left out: it is valid only with a",
                    "non-iid vcov, one endogenous variable and one instrument")))
  out <- c(out, list(
    .fx_test(.fx_fitstat(fit, "wh")$wh, "endogeneity", "wu_hausman"),
    .fx_test(.fx_fitstat(fit, "sargan")$sargan, "overidentification", "sargan", "chi2")))
  structure(Filter(Negate(is.null), out), messages = kp_msg)
}

# --- GLMs (feglm, fepois) ---------------------------------------------------------------------

# glm.tol and glm.iter aren't stored in the fit: from the call, else fixest's defaults
.fx_glm_control <- function(fit) {
  get <- function(arg, default) {
    v <- fit$call[[arg]]
    if (is.null(v)) default else eval(v, fit$call_env)
  }
  list(tol = get("glm.tol", 1e-8), iter = as.integer(get("glm.iter", 25L)))
}

# meta.estimator. A quasi family has the base distribution, with its dispersion estimated
.fx_glm_estimator <- function(fit) {
  fam <- fit$family$family
  quasi <- startsWith(fam, "quasi")
  dist <- if (quasi) sub("^quasi", "", fam) else fam
  if (identical(dist, "")) dist <- "quasi"  # quasi(): the variance function is the user's
  .est_compact(list(family = "glm", method = "irls", distribution = dist,
                    link = fit$family$link, quasi = if (quasi) TRUE))
}

# fixef.rm -> options.separation. fixest checks separation only through the fixed effects
# (levels whose outcomes are all 0, or all 0 or 1 for binomial): ppmlhdfe's "fe" method
.fx_separation <- function(fit, fixef_rm) {
  if (is.null(fit$fixef_vars) || !fixef_rm %in% c("perfect_fit", "infinite_coef")) return(character(0))
  "fe"
}

# Offset: offset = ~x, or offset(x) in the formula. fixest uses it as given (no exposure)
.fx_offset <- function(fit) {
  v <- fit$call$offset
  if (!is.null(v)) {
    v <- eval(v, fit$call_env)
    if (inherits(v, "formula")) return(list(variable = paste(deparse(v[[length(v)]]), collapse = ""), exposure = FALSE))
    return(list(variable = paste(deparse(fit$call$offset), collapse = ""), exposure = FALSE))
  }
  tt <- attr(stats::terms(fit$fml_all$linear), "offset")
  if (length(tt)) {
    vars <- attr(stats::terms(fit$fml_all$linear), "variables")
    e <- vars[[tt[1] + 1L]][[2]]
    return(list(variable = paste(deparse(e), collapse = ""), exposure = FALSE))
  }
  NULL
}

.fx_glm_metrics <- function(fit, sample, conf_level) {
  fs <- .fx_fitstat(fit, "pr2")
  dist <- .fx_glm_estimator(fit)$distribution
  m <- list(nobs = fit$nobs, df_residual = df.residual(fit),
            log_lik = .est_num(as.numeric(logLik(fit))), log_lik_null = .est_num(fit$ll_null),
            log_lik_fe_only = .est_num(fit$ll_fe_only), deviance = .est_num(fit$deviance),
            # fitstat's pr2 is McFadden's; the fit's own pseudo_r2 element is the adjusted one
            pseudo_r2 = if (!is.null(fs$pr2)) .est_num(unname(fs$pr2)),
            aic = .est_num(stats::AIC(fit)), bic = .est_num(stats::BIC(fit)),
            dispersion = .est_num(fit$dispersion), sq_corr_fitted = .est_num(fit$sq.cor),
            conf_level = conf_level)
  d <- sample$dropped
  if (!is.null(fit$fixef_vars)) m$n_separated <- d$separated
  if (!is.null(d$singletons) || !is.null(d$separated))
    m$nobs_full <- fit$nobs + (d$singletons %||% 0L) + (d$separated %||% 0L)
  .est_compact(m)
}

# fixest removes the rows of fixed-effect levels that the FEs fit perfectly, without saying
# why. This repeats the removal on the rows the fit started from (`cand`): levels whose outcomes
# are all at a bound (0 for Poisson, 0 or 1 for binomial) are `separated`, other one-row levels
# `singletons`; a one-row level at a bound counts as separated. NULL when the FEs can't be
# rebuilt from `data` or the rows don't match the fit's.
.fx_glm_removed <- function(fit, data, cand) {
  fe <- fit$fixef_vars
  if (!all(fe %in% names(data)) || length(fit$fixef_terms) || length(fit$slope_flag) && any(fit$slope_flag != 0))
    return(NULL)
  y <- tryCatch(eval(fit$fml_all$linear[[2]], data, fit$call_env), error = function(e) NULL)
  if (length(y) != nrow(data)) return(NULL)
  y <- as.numeric(y)
  fixef_rm <- if (!is.null(fit$call$fixef.rm)) eval(fit$call$fixef.rm, fit$call_env) else "perfect_fit"
  dist <- .fx_glm_estimator(fit)$distribution
  bound_check <- fixef_rm %in% c("perfect_fit", "infinite_coef") && dist %in% c("poisson", "binomial")
  single_check <- fixef_rm %in% c("perfect_fit", "singletons")
  codes <- lapply(fe, function(v) match(data[[v]], unique(data[[v]])))
  alive <- cand
  sep <- integer(0); sgl <- integer(0)
  repeat {
    changed <- FALSE
    for (k in seq_along(codes)) {
      cd <- codes[[k]][alive]
      if (bound_check) {
        ya <- y[alive]
        lo <- tapply(ya, cd, min); hi <- tapply(ya, cd, max)
        at <- if (dist == "poisson") hi == 0 else (hi == 0) | (lo == 1)
        bad <- as.integer(names(at)[at])
        if (length(bad)) {
          drop <- alive[cd %in% bad]
          sep <- c(sep, drop); alive <- setdiff(alive, drop); changed <- TRUE
          cd <- codes[[k]][alive]
        }
      }
      if (single_check) {
        n <- tabulate(cd, nbins = max(codes[[k]], na.rm = TRUE))
        drop <- alive[n[cd] == 1L]
        if (length(drop)) { sgl <- c(sgl, drop); alive <- setdiff(alive, drop); changed <- TRUE }
      }
    }
    if (!changed) break
  }
  if (!setequal(alive, fixest::obs(fit))) return(NULL)
  list(separated = length(sep), singletons = length(sgl))
}
