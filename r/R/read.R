# Reading records and collections, and the views on them: print(), and tidy()/glance() methods
# (registered on the 'generics' package when it is loaded) so table packages such as
# modelsummary take records as they take fitted models.

# Read a record (`*.estrec.json`), or every record in a folder (a named list, by file stem).
# The record is kept as written; numbers that JSON can't hold stay as "NaN"/"Inf"/"-Inf" strings
# and are decoded by the views.
read_estimation <- function(path) {
  if (length(path) != 1L) stop("`path` is one file or folder", call. = FALSE)
  if (dir.exists(path)) {
    files <- sort(list.files(path, pattern = "\\.estrec\\.json$", full.names = TRUE))
    if (!length(files)) stop("no *.estrec.json files in ", path, call. = FALSE)
    out <- lapply(files, read_estimation)
    names(out) <- sub("\\.estrec\\.json$", "", basename(files))
    return(out)
  }
  doc <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  if (identical(doc$schema, "estrec-collection/0.1"))
    stop(path, " is a collection: read it with read_collection()", call. = FALSE)
  if (!is_estimation_record(doc))
    stop(path, " is not an estrec/0.1 record (schema: ",
         if (is.null(doc$schema)) "absent" else doc$schema, ")", call. = FALSE)
  .est_as_record(doc, path = normalizePath(path))
}

# Read a collection: a named list of its member records, in the collection's order, named by
# member label (else id). Each record carries its member entry (label, locator) as attribute
# "member"; the collection without its records is attribute "collection". Records in a members
# file are found by meta.id.
read_collection <- function(path) {
  doc <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  if (!identical(doc$schema, "estrec-collection/0.1"))
    stop(path, " is not an estrec-collection/0.1 file", call. = FALSE)
  dir <- dirname(normalizePath(path))
  files <- list()
  members_file <- function(aid) {
    if (is.null(files[[aid]])) {
      att <- Filter(function(a) identical(a$id, aid), doc$attachments %||% list())
      if (!length(att)) stop("member attachment '", aid, "' is not in `attachments`", call. = FALSE)
      lines <- readLines(file.path(dir, att[[1]]$path), encoding = "UTF-8", warn = FALSE)
      recs <- lapply(lines[nzchar(lines)], jsonlite::fromJSON, simplifyVector = FALSE)
      names(recs) <- vapply(recs, function(r) as.character(r$meta$id), "")
      files[[aid]] <<- recs
    }
    files[[aid]]
  }
  index <- doc
  index$members <- lapply(doc$members, function(m) { m$record <- NULL; m })
  out <- lapply(doc$members, function(m) {
    rec <- if (!is.null(m$record)) m$record
           else if (!is.null(m$attachment)) members_file(m$attachment)[[as.character(m$id)]]
    if (is.null(rec)) stop("member ", m$id, " has no record", call. = FALSE)
    m$record <- NULL
    .est_as_record(rec, path = file.path(dir, "collection"), member = m)
  })
  names(out) <- vapply(doc$members, function(m)
    as.character(if (!is.null(m$label)) m$label else m$id), "")
  attr(out, "collection") <- index
  out
}

.est_as_record <- function(x, path = NULL, member = NULL) {
  structure(x, class = "estimation_record", path = path, member = member)
}

# A record as the plain list the JSON writers take
.est_plain <- function(x) {
  if (!inherits(x, "estimation_record")) return(x)
  attributes(x) <- list(names = names(x))
  x
}

# A JSON number, a non-finite string, or {value, ...} -> double (NA when absent or not numeric)
.est_dbl <- function(v) {
  if (is.list(v) && !is.null(names(v)) && "value" %in% names(v)) v <- v$value
  if (is.null(v) || length(v) != 1L) return(NA_real_)
  if (is.character(v)) return(switch(v, "NaN" = NaN, "Inf" = Inf, "-Inf" = -Inf, NA_real_))
  if (is.logical(v)) return(NA_real_)
  as.numeric(v)
}

# A metric for display: number, string or logical; NULL for structured values without `value`
.est_metric_value <- function(v) {
  if (is.list(v)) v <- if ("value" %in% names(v)) v$value else return(NULL)
  if (is.null(v)) return(NA)
  if (is.character(v) && v %in% c("NaN", "Inf", "-Inf")) return(.est_dbl(v))
  v
}

# The vcov structures of a record (a list, possibly empty)
.est_vcovs <- function(x) {
  v <- x$structures$vcov
  if (is.null(v)) return(list())
  if (!is.null(v$kind)) list(v) else v
}

.est_vcov_label <- function(v) {
  type <- v$type %||% "?"
  cl <- unlist(v$cluster)
  if (length(cl)) paste0("by: ", paste(cl, collapse = " & ")) else type
}

# Pick a vcov: NULL = the default; a number = its position; a string = its `type` (e.g. "iid",
# "HC1", "CRV1") or a cluster label ("by: firm", or the cluster variables "firm", "firm & year")
.est_pick_vcov <- function(x, vcov) {
  vs <- .est_vcovs(x)
  if (is.null(vcov)) {
    d <- Filter(function(v) isTRUE(v$default), vs)
    return(if (length(d)) d[[1]] else NULL)
  }
  if (is.numeric(vcov)) {
    if (vcov < 1 || vcov > length(vs)) stop("the record has ", length(vs), " vcov", call. = FALSE)
    return(vs[[vcov]])
  }
  key <- function(v) c(v$type, .est_vcov_label(v), paste(unlist(v$cluster), collapse = " & "))
  hit <- Filter(function(v) vcov %in% key(v), vs)
  if (!length(hit))
    stop("no vcov '", vcov, "'; the record has: ",
         paste(vapply(vs, function(v) paste0(v$type, " (", .est_vcov_label(v), ")"), ""),
               collapse = ", "), call. = FALSE)
  if (length(hit) > 1L)
    stop("vcov '", vcov, "' matches ", length(hit), " matrices; pick one by position", call. = FALSE)
  hit[[1]]
}

# The parameters as a data frame with broom's column names. `component = NULL` keeps the main
# model (rows without a component); "all" keeps every row. Dropped terms are left out unless
# `dropped = TRUE`.
.est_parameters <- function(x, component = NULL, dropped = FALSE) {
  ps <- x$parameters
  chr <- function(p, k) { v <- p[[k]]; if (is.null(v)) NA_character_ else as.character(v) }
  df <- data.frame(
    term = vapply(ps, function(p) as.character(p$term), ""),
    estimate = vapply(ps, function(p) .est_dbl(p$estimate), 0),
    std.error = vapply(ps, function(p) .est_dbl(p$std_error), 0),
    statistic = vapply(ps, function(p) .est_dbl(p$statistic), 0),
    p.value = vapply(ps, function(p) .est_dbl(p$p_value), 0),
    conf.low = vapply(ps, function(p) .est_dbl(p$conf_low), 0),
    conf.high = vapply(ps, function(p) .est_dbl(p$conf_high), 0),
    response = vapply(ps, chr, "", "response"),
    component = vapply(ps, chr, "", "component"),
    dropped = vapply(ps, chr, "", "dropped"),
    stringsAsFactors = FALSE)
  if (is.null(component)) df <- df[is.na(df$component), , drop = FALSE]
  else if (!identical(component, "all")) df <- df[df$component %in% component, , drop = FALSE]
  if (!dropped) df <- df[is.na(df$dropped), , drop = FALSE]
  rownames(df) <- NULL
  df
}

# tidy(): parameters, from the default vcov as written, or recomputed from another vcov in the
# record (std.error from its diagonal, t tests on its df_t, normal when it has none). conf.level
# other than the record's recomputes the interval the same way.
tidy.estimation_record <- function(x, conf.int = TRUE, conf.level = NULL, vcov = NULL,
                                   component = NULL, dropped = FALSE, ...) {
  df <- .est_parameters(x, component = component, dropped = dropped)
  v <- .est_pick_vcov(x, vcov)
  level <- .est_dbl(x$metrics$conf_level)
  recompute <- !is.null(vcov) && !isTRUE(v$default)
  if (recompute) {
    if (identical(v$kind, "link"))
      stop("this vcov is in an attachment (", v$attachment, "); estrec can't read attachments yet",
           call. = FALSE)
    labs <- unlist(v$labels %||% v$row_labels)
    m <- do.call(rbind, lapply(v$data, function(r) vapply(r, .est_dbl, 0)))
    se <- sqrt(diag(m))[match(df$term, labs)]
    if (any(is.na(se) & !is.na(df$estimate)))
      warning("terms not in the vcov get no standard error: ",
              paste(df$term[is.na(se) & !is.na(df$estimate)], collapse = ", "), call. = FALSE)
    df$std.error <- se
    df$statistic <- df$estimate / se
  }
  dft <- if (!is.null(v)) .est_dbl(v$df_t) else NA_real_
  if (recompute) {
    df$p.value <- if (is.na(dft)) 2 * stats::pnorm(-abs(df$statistic))
                  else 2 * stats::pt(-abs(df$statistic), dft)
  }
  if (is.null(conf.level)) conf.level <- if (is.na(level)) 0.95 else level
  if (recompute || is.na(level) || abs(conf.level - level) > 1e-12 ||
      all(is.na(df$conf.low))) {
    q <- if (is.na(dft)) stats::qnorm(1 - (1 - conf.level) / 2)
         else stats::qt(1 - (1 - conf.level) / 2, dft)
    df$conf.low <- df$estimate - q * df$std.error
    df$conf.high <- df$estimate + q * df$std.error
  }
  if (!conf.int) df$conf.low <- df$conf.high <- NULL
  keep <- c("response", "component", "dropped")
  for (k in keep) if (all(is.na(df[[k]]))) df[[k]] <- NULL
  df
}

.est_glance_names <- c(r2 = "r.squared", adj_r2 = "adj.r.squared", r2_within = "r2.within",
                       adj_r2_within = "r2.within.adjusted", pseudo_r2 = "pseudo.r.squared",
                       log_lik = "logLik", aic = "AIC", bic = "BIC", f_stat = "F", rmse = "rmse",
                       df_residual = "df.residual", df_model = "df", n_clusters = "nclusters")

# The metrics a regression table shows by default (modelsummary's gof rows)
.est_table_metrics <- c("nobs", "r2", "adj_r2", "r2_within", "adj_r2_within", "pseudo_r2",
                        "aic", "bic", "log_lik", "f_stat", "rmse")

# glance(): one row of the record's metrics under broom names (modelsummary's gof rows), the
# default vcov as `vcov.type` ("by: firm", or its type), and one "FE: <name>" = "X" column per
# fixed effect, as modelsummary shows fixest's. `metrics = "table"` keeps the metrics a table
# usually shows, with RMSE as sqrt(rss / nobs) when the record has both; "all" keeps every
# scalar metric (unregistered names with "_" -> ".").
glance.estimation_record <- function(x, vcov = NULL, metrics = c("table", "all"), ...) {
  metrics <- match.arg(metrics)
  ms <- x$metrics %||% list()
  ms <- ms[setdiff(names(ms), "conf_level")]
  if (metrics == "table") {
    if (is.null(ms$rmse) && !is.null(ms$rss) && !is.null(ms$nobs))
      ms$rmse <- sqrt(.est_dbl(ms$rss) / .est_dbl(ms$nobs))
    ms <- ms[intersect(.est_table_metrics, names(ms))]
  }
  vals <- lapply(ms, .est_metric_value)
  vals <- vals[!vapply(vals, is.null, logical(1))]
  nm <- names(vals)
  nm <- ifelse(nm %in% names(.est_glance_names), .est_glance_names[nm], gsub("_", ".", nm))
  out <- stats::setNames(vals, nm)
  v <- .est_pick_vcov(x, vcov)
  if (!is.null(v)) out$vcov.type <- .est_vcov_label(v)
  for (fe in unlist(x$specification$fixed_effects)) out[[paste0("FE: ", fe)]] <- "X"
  as.data.frame(out, check.names = FALSE, stringsAsFactors = FALSE)
}

# A quick view in the console
print.estimation_record <- function(x, digits = 4, ...) {
  m <- x$meta
  est <- m$estimator
  cat("<estimation record>", if (!is.null(m$title)) paste0(" ", m$title), "\n", sep = "")
  cat("  ", paste(c(est$family, est$method), collapse = " / "),
      " of ", paste(unlist(m$responses), collapse = ", "),
      "   status: ", m$status %||% "?", "\n", sep = "")
  if (!is.null(x$specification$formula$text)) cat("  ", x$specification$formula$text, "\n", sep = "")
  mem <- attr(x, "member")
  if (!is.null(mem)) {
    loc <- mem$locator %||% if (length(mem$locators)) mem$locators[[1]]
    cat("  member: ", mem$label %||% mem$id,
        if (!is.null(loc)) paste0("  (", loc$label %||% .est_locator_text(loc), ")"), "\n", sep = "")
  }
  sw <- x$provenance$software
  if (length(sw)) {
    if (!is.null(sw$name)) sw <- list(sw)
    pick <- Filter(function(s) identical(s$role, "estimator"), sw)
    lang <- Filter(function(s) identical(s$role, "language"), sw)
    show <- c(if (length(pick)) pick[1] else sw[1], if (length(lang)) lang[1])   # SPSS/SAS records name no language
    cat("  software: ", paste(vapply(show, function(s)
      paste0(s$name, if (!is.null(s$version)) paste0(" ", s$version)), ""), collapse = ", "),
      "\n", sep = "")
  }
  v <- .est_pick_vcov(x, NULL)
  if (!is.null(v)) {
    ssc <- v$ssc$convention
    cat("  vcov: ", v$type %||% "?",
        if (length(v$cluster)) paste0(", clustered by ", paste(unlist(v$cluster), collapse = " & ")),
        if (!is.null(ssc)) paste0(" (", ssc, " ssc)"),
        if (length(.est_vcovs(x)) > 1L) paste0("; ", length(.est_vcovs(x)) - 1L, " more in the record"),
        "\n", sep = "")
  }
  cat("\n")
  p <- .est_parameters(x, component = "all", dropped = TRUE)
  if (nrow(p)) {
    tab <- data.frame(Estimate = format(signif(p$estimate, digits)),
                      `Std. Error` = format(signif(p$std.error, digits)),
                      `p value` = format.pval(p$p.value, digits = 3),
                      check.names = FALSE, stringsAsFactors = FALSE)
    stars <- as.character(cut(p$p.value, c(-Inf, 0.001, 0.01, 0.05, 0.1, Inf),
                              c("***", "**", "*", ".", "")))
    tab$` ` <- ifelse(is.na(stars), "", stars)
    tab[!is.na(p$dropped), 1:4] <- ""
    tab$` `[!is.na(p$dropped)] <- paste0("(", p$dropped[!is.na(p$dropped)], ")")
    lab <- p$term
    multi <- length(unique(p$response[!is.na(p$response)])) > 1L
    if (multi || any(!is.na(p$component)))
      lab <- paste0(ifelse(is.na(p$component), "", paste0("[", p$component, "] ")),
                    ifelse(multi & !is.na(p$response), paste0(p$response, ": "), ""), lab)
    rownames(tab) <- make.unique(lab)
    print(tab, right = TRUE)
    cat("\n")
  }
  ms <- lapply(x$metrics %||% list(), .est_metric_value)
  ms <- ms[!vapply(ms, function(v) is.null(v) || length(v) != 1L, logical(1))]
  if (length(ms)) {
    txt <- vapply(ms, function(v) {
      if (!is.numeric(v)) return(as.character(v))
      if (is.finite(v) && v == round(v) && abs(v) < 1e15) return(format(v, big.mark = ",", scientific = FALSE))
      format(signif(v, digits))
    }, "")
    cat(strwrap(paste(paste0(names(txt), " ", txt), collapse = "; "), prefix = "  "), sep = "\n")
  }
  fes <- x$structures$fixed_effects
  if (length(fes)) {
    if (!is.null(fes$name)) fes <- list(fes)
    cat("  fixed effects: ",
        paste(vapply(fes, function(f) paste0(f$name, " (", format(.est_dbl(f$levels), big.mark = ","), ")"), ""),
              collapse = ", "), "\n", sep = "")
  } else if (length(x$specification$fixed_effects)) {
    cat("  fixed effects: ", paste(unlist(x$specification$fixed_effects), collapse = ", "), "\n", sep = "")
  }
  if (length(x$tests)) cat("  tests: ", length(x$tests), "\n", sep = "")
  for (msg in m$messages) cat("  ", msg$level %||% "note", ": ", msg$message, "\n", sep = "")
  invisible(x)
}

.est_locator_text <- function(loc) {
  f <- c("study", "table", "panel", "column", "row", "figure", "equation", "page", "appendix", "section")
  f <- f[f %in% names(loc) & !vapply(f, function(k) is.null(loc[[k]]), logical(1))]
  paste(paste(f, vapply(f, function(k) as.character(loc[[k]]), "")), collapse = ", ")
}
