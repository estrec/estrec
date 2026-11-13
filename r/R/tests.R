# Hypothesis tests in a record's `tests` (spec 4.8). estrec doesn't run tests: add_test()
# takes the result of a test that another function ran, and as_estimation_test() reads it into
# test objects (name, statistic, distribution and df, p-value, what it tested). Each kind of
# result is one as_estimation_test() method, so a package, or a user, adds support for its own
# results with a method, without changing estrec.

# Append a test result to a record. `hypothesis` and `vcov` describe the test when the result
# doesn't say: the hypothesis text and the structures.vcov entry it used (a type, or
# list(type =, cluster =)). They are recorded, not used to compute anything.
add_test <- function(record, test, label = NULL, category = NULL, hypothesis = NULL,
                     vcov = NULL, id = NULL, tags = NULL, origin = "postestimation",
                     by = estrec_info()) {
  if (!is_estimation_record(record))
    stop("`record` must be an estimation record: add_test(rec, wald(fit, ...))", call. = FALSE)
  .est_add_test(record, test, substitute(test), parent.frame(), label = label,
                category = category, hypothesis = hypothesis, vcov = vcov, id = id, tags = tags,
                origin = origin, by = by)
}

# Read a test result into a list of test objects (spec 4.8, $defs/test). `record` is the record
# the test is about (methods may use its terms); `call` is the call that made the result, as
# text, and `expr` the same call unevaluated, with `env` to evaluate its arguments in.
as_estimation_test <- function(x, record = NULL, call = NULL, expr = NULL, env = parent.frame(), ...)
  UseMethod("as_estimation_test")

as_estimation_test.default <- function(x, record = NULL, call = NULL, ...) {
  if (is.character(x))
    stop("estrec records test results; it doesn't run tests. Run the test ",
         "(fixest::wald(), marginaleffects::hypotheses(), car::linearHypothesis()) and pass ",
         "its result", call. = FALSE)
  stop("no as_estimation_test() method for class ", paste(class(x), collapse = "/"),
       "; write one, or pass a test object (a list with name and statistic or p_value)",
       call. = FALSE)
}

# A plain list: a test object, a list of them, or a fixest wald() result (which has no class)
as_estimation_test.list <- function(x, record = NULL, call = NULL, expr = NULL, env = parent.frame(), ...) {
  if (!is.null(x[["stat", exact = TRUE]]) && !is.null(x[["df1", exact = TRUE]]))
    return(list(.est_from_wald(x, record, expr, env, call)))
  if (!is.null(x[["name", exact = TRUE]])) return(list(x))
  if (length(x) && all(vapply(x, function(t) is.list(t) && !is.null(t[["name", exact = TRUE]]), NA)))
    return(unname(x))
  NextMethod()
}

as_estimation_test.htest <- function(x, record = NULL, call = NULL, ...)
  list(.est_from_htest(x, call))

as_estimation_test.anova <- function(x, record = NULL, call = NULL, ...)
  list(.est_from_anova(x, call))

as_estimation_test.data.frame <- function(x, record = NULL, call = NULL, ...)
  .est_from_table(x, call)

.est_add_test <- function(record, test, expr, env, label = NULL, category = NULL,
                          hypothesis = NULL, vcov = NULL, id = NULL, tags = NULL,
                          origin = "postestimation", by = estrec_info()) {
  level <- .est_declared_level(record)
  if (!is.null(level) && level < 2L)
    stop("tests are disclosure level 2; this record declares level ", level, call. = FALSE)
  call <- if (is.call(expr)) paste(deparse(expr, width.cutoff = 500L), collapse = " ")
  ts <- as_estimation_test(test, record = record, call = call, expr = expr, env = env)
  if (length(ts) > 1L && !is.null(id)) stop("give `id` one test at a time", call. = FALSE)
  for (t in ts) {
    if (is.null(t$name) || (is.null(t$statistic) && is.null(t$p_value)))
      stop("a test needs a name and a statistic or p_value", call. = FALSE)
    if (!is.null(category)) t$category <- category
    if (!is.null(label)) t$label <- label
    if (!is.null(hypothesis)) t$hypothesis$text <- hypothesis
    if (!is.null(vcov)) t$vcov <- if (is.list(vcov)) .est_compact(list(type = vcov$type,
      cluster = if (length(vcov$cluster)) I(as.character(vcov$cluster)))) else vcov
    if (length(tags)) t$tags <- I(tags)
    t$origin <- t$origin %||% origin
    taken <- vapply(record$tests %||% list(), function(x) x$id %||% "", "")
    if (is.null(id)) {
      n <- length(taken) + 1L
      while (paste0("t", n) %in% taken) n <- n + 1L
      tid <- paste0("t", n)
    } else if (id %in% taken) {
      stop("a test with id ", id, " is already in the record", call. = FALSE)
    } else tid <- id
    added <- .est_now()
    t <- c(list(id = tid), t[setdiff(names(t), "id")], list(added = added))
    record$tests <- c(record$tests, list(t))
    record$history <- c(record$history, list(list(when = added, by = by, action = "extended",
                                                  sections = I("tests"))))
  }
  # what the record's level withholds (a test's source, the history entry's `by` below 4)
  if (!is.null(level) && level < 5L) record <- .est_apply_level(record, level)$record
  record
}

.est_record_terms <- function(record)
  vapply(Filter(function(p) is.null(p$dropped), record$parameters), `[[`, "", "term")

# fixest's keep/drop: regexes; "%" starts a literal name, "!" negates a pattern
.est_match <- function(labels, patterns) {
  hit <- function(k) {
    neg <- startsWith(k, "!"); if (neg) k <- substring(k, 2L)
    m <- if (startsWith(k, "%")) labels == substring(k, 2L) else grepl(k, labels, perl = TRUE)
    if (neg) !m else m
  }
  Reduce(`|`, lapply(patterns, hit), logical(length(labels)))
}

# fixest wald(): H0 that the coefficients it selects are all zero
.est_from_wald <- function(w, record, expr, env, call) {
  terms <- NULL
  if (!is.null(record) && is.call(expr) && grepl("(^|:)wald$", paste(deparse(expr[[1L]]), collapse = ""))) {
    args <- as.list(expr)[-1L]
    arg <- function(nm) if (!is.null(args[[nm]])) tryCatch(eval(args[[nm]], env), error = function(e) NULL)
    keep <- arg("keep"); drop <- arg("drop")
    labels <- .est_record_terms(record)
    sel <- if (is.character(keep)) .est_match(labels, keep) else rep(TRUE, length(labels))
    if (is.character(drop)) sel <- sel & !.est_match(labels, drop)
    terms <- labels[sel]
    if (length(terms) != as.numeric(w$df1)) {
      warning("the wald() call's keep/drop match ", length(terms), " of the record's terms but the ",
              "test has ", w$df1, " restrictions; terms not recorded", call. = FALSE)
      terms <- NULL
    }
  }
  .est_compact(list(
    category = "restriction", name = "wald",
    hypothesis = if (length(terms)) list(text = paste(terms, "= 0", collapse = ", "), terms = I(terms)),
    statistic = .est_num(as.numeric(w$stat)), distribution = "F", df1 = as.numeric(w$df1),
    df2 = .est_num(as.numeric(w$df2)), p_value = .est_num(as.numeric(w$p)), method = "wald",
    vcov = if (!is.null(w$vcov)) .est_wald_vcov(w$vcov),
    source = .est_compact(list(name = "fixest", version = as.character(utils::packageVersion("fixest")),
                               call = call %||% "wald()"))))
}

# "Clustered (id & yr)" -> list(type = "CRV1", cluster = c("id", "yr"))
.est_wald_vcov <- function(label) {
  type <- .fx_vcov_type(label)
  cl <- regmatches(label, regexpr("(?<=\\().*(?=\\))", label, perl = TRUE))
  if (identical(type, "CRV1") && length(cl)) list(type = type, cluster = I(trimws(strsplit(cl, "&", fixed = TRUE)[[1]])))
  else type
}

# A results table -> one test per row. marginaleffects::hypotheses() gives one row per
# hypothesis (estimate, std.error, statistic, p.value, conf.low, conf.high; z tests unless `df`
# was set), or with joint = TRUE one row with statistic, p.value, df1, df2.
.est_from_table <- function(tab, call) {
  tab <- as.data.frame(tab)
  if (!nrow(tab)) stop("the table has no rows", call. = FALSE)
  col <- function(i, nm) if (nm %in% names(tab)) { v <- tab[[nm]][i]; if (is.factor(v)) v <- as.character(v); v }
  is_me <- inherits(tab, "hypotheses") || !is.null(attr(tab, "vcov.type"))
  src <- .est_compact(list(
    name = if (is_me) "marginaleffects",
    version = if (is_me && requireNamespace("marginaleffects", quietly = TRUE))
      as.character(utils::packageVersion("marginaleffects")),
    call = call))
  vt <- attr(tab, "vcov.type")
  lapply(seq_len(nrow(tab)), function(i) {
    text <- col(i, "hypothesis") %||% col(i, "term")
    joint <- !is.null(col(i, "df1"))
    df <- col(i, "df")
    use_t <- is.numeric(df) && is.finite(df)
    finite_df2 <- joint && is.finite(col(i, "df2") %||% Inf)
    .est_compact(list(
      category = if (joint) "restriction" else "linear_combination",
      name = if (joint) "wald" else if (use_t) "t" else "z",
      hypothesis = if (!is.null(text)) list(text = as.character(text)),
      estimate = .est_num(col(i, "estimate")), std_error = .est_num(col(i, "std.error")),
      conf_low = .est_num(col(i, "conf.low")), conf_high = .est_num(col(i, "conf.high")),
      statistic = .est_num(col(i, "statistic")),
      distribution = if (joint) (if (finite_df2) "F" else "chi2") else if (use_t) "t" else "normal",
      df = if (use_t) df, df1 = if (joint) col(i, "df1"), df2 = if (finite_df2) col(i, "df2"),
      p_value = .est_num(col(i, "p.value")), method = "wald",
      # marginaleffects' own vcov label ("by: id", "HC3"), not a structures.vcov type
      options = if (is.character(vt) && length(vt) == 1L) list(vcov_type = vt),
      source = if (length(src)) src))
  })
}

# An anova-style comparison (anova(m1, m2), car::linearHypothesis(), lmtest::waldtest(),
# lmtest::lrtest()): the test is in the last row
.est_from_anova <- function(a, call) {
  heading <- paste(attr(a, "heading") %||% "", collapse = "\n")
  a <- as.data.frame(a)
  n <- nrow(a)
  if (n < 2L) stop("an anova table with one row isn't a comparison; pass a test result", call. = FALSE)
  get <- function(...) { for (nm in c(...)) if (nm %in% names(a)) return(as.numeric(a[[nm]][n])); NULL }
  hyp <- if (grepl("Hypothesis:", heading, fixed = TRUE)) {
    h <- sub("^.*Hypothesis:\n", "", heading)
    h <- strsplit(h, "\n\n", fixed = TRUE)[[1]][1]
    paste(trimws(strsplit(h, "\n", fixed = TRUE)[[1]]), collapse = ", ")
  }
  F <- get("F"); chisq <- get("Chisq")
  lr <- grepl("Likelihood ratio", heading, ignore.case = TRUE)
  df1 <- if ("#Df" %in% names(a)) abs(diff(as.numeric(a[["#Df"]][c(n - 1L, n)])))
         else abs(get("Df") %||% NA)
  .est_compact(list(
    category = "restriction",
    name = if (lr) "likelihood_ratio" else if (!is.null(F)) "f" else "chi2",
    hypothesis = if (!is.null(hyp)) list(text = hyp),
    statistic = .est_num(if (!is.null(F)) F else chisq),
    distribution = if (!is.null(F)) "F" else "chi2",
    df1 = if (!is.null(F)) .est_num(df1), df2 = if (!is.null(F)) .est_num(get("Res.Df")),
    df = if (is.null(F)) .est_num(df1),
    p_value = .est_num(get("Pr(>F)", "Pr(>Chisq)")),
    method = if (lr) "likelihood_ratio" else if (grepl("Wald", heading)) "wald",
    source = .est_compact(list(call = call))))
}

# stats htest: t.test(), chisq.test(), wilcox.test(), ...
.est_from_htest <- function(h, call) {
  sn <- names(h$statistic) %||% ""
  dist <- switch(sn, t = "t", "X-squared" = "chi2", F = "F", z = , Z = "normal", NULL)
  par <- h$parameter
  ci <- h$conf.int
  est <- if (length(h$estimate) == 1L) as.numeric(h$estimate)
  hyp <- .est_compact(list(
    text = if (length(h$null.value) == 1L)
      sprintf("%s = %s", names(h$null.value) %||% "value", format(unname(h$null.value))),
    alternative = switch(h$alternative %||% "", two.sided = "two_sided", greater = "greater",
                         less = "less", NULL)))
  .est_compact(list(
    name = switch(sn, t = "t", "X-squared" = "chi2", F = "f", z = , Z = "z", sn),
    label = h$method, hypothesis = if (length(hyp)) hyp,
    estimate = .est_num(est), std_error = .est_num(h$stderr),
    conf_low = if (length(ci) == 2L) .est_num(ci[1]), conf_high = if (length(ci) == 2L) .est_num(ci[2]),
    statistic = .est_num(as.numeric(h$statistic)), distribution = dist,
    df = if (length(par) == 1L && !identical(dist, "F")) .est_num(as.numeric(par)),
    df1 = if (identical(dist, "F") && length(par) == 2L) .est_num(as.numeric(par[1])),
    df2 = if (identical(dist, "F") && length(par) == 2L) .est_num(as.numeric(par[2])),
    p_value = .est_num(h$p.value),
    source = .est_compact(list(name = "stats", call = call))))
}
