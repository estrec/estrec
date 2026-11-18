# Table specs (estrec-table/0.1, spec/table.md): render a spec with modelsummary.

# Render a table spec: a path to an *.estrec-table.json file or the spec as a list. The
# records come from the spec's sources (relative to its folder, or `base_dir`) and from
# `records` (records, a list of them, or read_collection()'s result). Each column becomes a
# modelsummary model from the record's tidy() (with the column's vcov), so the output formats
# and themes are modelsummary's; `...` goes to modelsummary().
render_table <- function(spec, output = "default", records = NULL, base_dir = NULL, ...) {
  if (!requireNamespace("modelsummary", quietly = TRUE))
    stop("render_table() needs the 'modelsummary' package", call. = FALSE)
  if (is.character(spec)) {
    if (is.null(base_dir)) base_dir <- dirname(spec)
    spec <- jsonlite::fromJSON(spec, simplifyVector = FALSE)
  }
  if (!identical(spec$schema, "estrec-table/0.1"))
    stop("not an estrec-table/0.1 spec", call. = FALSE)
  if (!is.null(spec$panels)) return(.tab_panels(spec, output, records, base_dir, ...))
  idx <- .tab_index(spec, records, base_dir)
  cols <- spec$columns
  if (!length(cols)) stop("the spec has no columns", call. = FALSE)
  found <- .tab_found(spec, cols, idx, "columns")
  fmt <- spec$format %||% list()
  digits <- fmt$digits %||% 3
  big <- fmt$thousands %||% ","
  missing <- fmt$missing %||% ""
  unc <- if ("uncertainty" %in% names(spec)) spec$uncertainty else "std_error"
  lines <- .tab_lines(unc)
  sparks <- .tab_sparks(unc)
  draws <- any(!vapply(sparks, is.null, TRUE)) && .tab_draws(output)
  p_digits <- fmt$p_digits %||% digits
  p_style <- fmt$p_style %||% "fixed"

  # each line under the estimates is filled here, by the spec's rules, into a text column
  # (line1, line2, ...) that modelsummary's `statistic` templates name
  tidies <- lapply(seq_along(cols), function(i) {
    c <- cols[[i]]
    vc <- c$vcov
    if (is.numeric(vc)) vc <- vc + 1   # the spec counts from 0, tidy() from 1
    t <- tidy.estimation_record(found[[i]], vcov = vc, component = c$component)
    t <- .tab_row_p(t, found[[i]], c)
    if (!is.null(c$response) && "response" %in% names(t)) t <- t[t$response %in% c$response, , drop = FALSE]
    # the p-value the stars use, and {star_p} shows (spec/table.md 5.1)
    t$star.p <- .tab_sig_p(.tab_sig_of(spec, c), t, found[[i]], c)
    for (k in seq_along(lines))
      t[[paste0("line", k)]] <- vapply(seq_len(nrow(t)), function(j)
        .tab_fill(lines[[k]], t[j, , drop = FALSE], digits, p_digits, p_style, missing), "")
    t$p.value <- t$star.p  # modelsummary's stars
    # a sparkline cell holds a placeholder here; .tab_draw() puts the drawing in its place
    if (draws) for (k in which(!vapply(sparks, is.null, TRUE)))
      t[[paste0("line", k)]] <- sprintf("estrecspark%dc%dr%d", k, i, seq_len(nrow(t)))
    t
  })
  # heading rows (spec/table.md 3.1): the first names the models; the others open the body
  head <- .tab_head(spec, cols, found, tidies)
  headers <- if (length(head)) head[[1]] else strrep("\u00a0", seq_along(cols))
  # modelsummary needs distinct names; it pads repeats with spaces, as here
  headers <- paste0(headers, strrep(" ", stats::ave(seq_along(headers), headers, FUN = seq_along) - 1L))

  # terms: listed rows first, then unlisted ones (by first appearance) through keep/drop
  coef_map <- character()
  taken <- character()
  for (r in spec$rows %||% list()) {
    names_ <- unlist(r$terms %||% r$term)
    lab <- r$label %||% names_[1]
    coef_map <- c(coef_map, stats::setNames(rep(lab, length(names_)), names_))
    taken <- c(taken, names_)
  }
  if (!isFALSE(spec$keep_unlisted)) {
    keep <- unlist(spec$keep); drop <- unlist(spec$drop)
    for (p in c(keep, drop)) tryCatch(grepl(p, "", perl = TRUE),
                                      error = function(e) stop("pattern doesn't compile: ", p, call. = FALSE))
    seen <- character()
    for (t in tidies) for (term in t$term) {
      if (term %in% c(taken, seen)) next
      if (length(keep) && !any(vapply(keep, grepl, TRUE, term, perl = TRUE))) next
      if (length(drop) && any(vapply(drop, grepl, TRUE, term, perl = TRUE))) next
      seen <- c(seen, term)
    }
    coef_map <- c(coef_map, stats::setNames(seen, seen))
  }

  # modelsummary wants each model to have a term shown; a column with none (a panel's term it
  # lacks) gets a placeholder row, taken out of the data frame again below
  none <- ".estrec.none"
  empty <- identical(output, "data.frame") &&
    any(!vapply(tidies, function(t) any(t$term %in% names(coef_map)), TRUE))
  if (empty) {
    tidies <- lapply(tidies, function(t) {
      if (any(t$term %in% names(coef_map))) return(t)
      fake <- t[rep(NA_integer_, 1L), , drop = FALSE]
      for (k in names(fake)) if (is.numeric(fake[[k]])) fake[[k]] <- 0
      fake$term <- none
      for (k in grep("^line[0-9]+$", names(fake), value = TRUE)) fake[[k]] <- ""
      rbind(t, fake)
    })
    coef_map <- c(coef_map, stats::setNames(none, none))
  }
  models <- lapply(tidies, function(t) structure(list(tidy = t, glance = data.frame(nobs = NA)),
                                                 class = "modelsummary_list"))
  names(models) <- headers

  stat_rows <- .tab_stat_rows(spec$stats %||% list(), cols, found, fmt, digits, big, missing, p_digits, p_style)
  top <- lapply(head[-1], function(h) c("", h))
  add_rows <- NULL
  if (length(top) || length(stat_rows)) {
    add_rows <- as.data.frame(do.call(rbind, c(top, stat_rows)), stringsAsFactors = FALSE)
    names(add_rows) <- c("term", headers)
    attr(add_rows, "position") <- c(seq_along(top), rep(NA, length(stat_rows)))
  }

  stars <- unlist(spec$stars)
  star_arg <- FALSE
  if (length(stars)) {
    sym <- unlist(fmt$star_symbols) %||% strrep("*", seq_along(stars))
    star_arg <- stats::setNames(stars, sym)
  }
  statistic <- if (length(lines)) sprintf("{line%d}", seq_along(lines)) else NULL
  est_arg <- "estimate"
  if (isFALSE(spec$estimate)) {
    # no estimate row: the first line takes its place (spec/table.md 5)
    if (!length(lines)) stop("estimate: with no estimate and no lines, terms have nothing to show", call. = FALSE)
    est_arg <- statistic[1]; statistic <- statistic[-1]
    if (!length(statistic)) statistic <- NULL
    star_arg <- FALSE
  }
  notes <- c(unlist(spec$notes), .tab_unc_note(unc, lines))
  src <- .tab_sig_note(list(spec))
  if (length(spec$stars) && !isFALSE(spec$estimate) && nzchar(src)) notes <- c(notes, paste0("Stars from ", substring(src, 14), "."))
  args <- list(models, output = output, coef_map = coef_map, estimate = est_arg, statistic = statistic,
               stars = star_arg, fmt = digits, gof_omit = ".*", add_rows = add_rows)
  if (!is.null(spec$title)) args$title <- spec$title
  if (length(notes)) args$notes <- as.list(notes)
  spans <- .tab_spans(spec, length(cols))
  if (!draws && (is.null(spans) || identical(output, "data.frame"))) {
    out <- do.call(modelsummary::modelsummary, c(args, list(...)))
    if (empty) { out <- out[out$term != none, , drop = FALSE]; rownames(out) <- NULL }
    if (length(spans) && is.data.frame(out)) {
      top <- out[1, , drop = FALSE]
      top[1, ] <- c("manual", "", "", .tab_span_row(spans, length(cols)))
      out <- rbind(top, out)
      rownames(out) <- NULL
    }
    return(out)
  }
  file <- !output %in% c("default", "tinytable", "html", "latex", "markdown", "typst")
  if (file) args$output <- "tinytable"
  x <- do.call(modelsummary::modelsummary, c(args, list(...)))
  if (draws) x <- .tab_draw(x, tidies, sparks, digits, p_digits, p_style, missing)
  x <- .tab_group_cols(x, spans)
  if (!file) return(x)
  tinytable::save_tt(x, output, overwrite = TRUE)
  invisible(x)
}

# The columns' records, found in the index (spec/table.md 3); `path` names the columns in errors.
.tab_found <- function(spec, cols, idx, path) {
  src_ids <- vapply(spec$sources %||% list(), function(s) as.character(s$id), "")
  lapply(seq_along(cols), function(i) {
    c <- cols[[i]]
    if (!is.null(c$source) && !c$source %in% src_ids)
      stop(path, "[", i - 1, "].source: no source '", c$source, "'", call. = FALSE)
    f <- (if (!is.null(c$source)) idx[[paste0(c$source, "\r", c$record)]]) %||% idx[[c$record]]
    if (is.null(f)) stop(path, "[", i - 1, "]: record ", c$record, " not found", call. = FALSE)
    f
  })
}

# Statistics rows (spec/table.md 6): each a character vector, the label then a cell per column.
.tab_stat_rows <- function(stats, cols, found, fmt, digits, big, missing, p_digits, p_style) {
  lapply(stats, function(s) {
    d <- s$digits %||% digits
    if (!is.null(s$values)) {
      if (length(s$values) != length(cols))
        stop("a text row has ", length(s$values), " values for ", length(cols), " columns", call. = FALSE)
      return(c(s$label, vapply(s$values, as.character, "")))
    }
    cells <- vapply(seq_along(cols), function(i) {
      rec <- found[[i]]; vc <- cols[[i]]$vcov
      if (is.numeric(vc)) vc <- vc + 1
      if (!is.null(s$metric)) {
        v <- rec$metrics[[s$metric]]
        v <- if (is.null(v)) NULL else .est_metric_value(v)
        if (is.null(v) && s$metric == "rmse" && !is.null(rec$metrics$rss) && !is.null(rec$metrics$nobs))
          v <- sqrt(.est_dbl(rec$metrics$rss) / .est_dbl(rec$metrics$nobs))
        return(.tab_value(v, d, big, missing))
      }
      if (!is.null(s$vcov)) {
        v <- .est_pick_vcov(rec, vc)
        if (is.null(v)) return(missing)
        if (s$vcov == "type") return(.est_vcov_label(v))
        n <- unlist(v$n_clusters)
        return(if (length(n)) paste(vapply(n, .tab_value, "", 0, big, missing), collapse = " / ") else missing)
      }
      if (!is.null(s$fixed_effect))
        return(if (s$fixed_effect %in% unlist(rec$specification$fixed_effects)) fmt$fe_yes %||% "Y"
               else fmt$fe_no %||% "N")
      if (!is.null(s$test)) {
        tt <- Filter(function(t) identical(t$label, s$test), rec$tests %||% list())
        if (!length(tt)) tt <- Filter(function(t) identical(t$name, s$test), rec$tests %||% list())
        if (!length(tt)) return(missing)
        which <- s$value %||% "statistic"
        v <- .est_dbl(tt[[1]][[which]])
        if (is.na(v)) return(missing)
        return(if (which == "p_value") .tab_p(v, s$digits %||% p_digits, p_style) else .tab_fixed(v, d))
      }
      missing
    }, "")
    label <- s$label %||% (if (!is.null(s$metric)) .tab_stat_labels[s$metric] %|NA|% s$metric
                           else if (!is.null(s$vcov)) (if (s$vcov == "type") "Std. errors" else "Clusters")
                           else if (!is.null(s$fixed_effect)) paste0("FE: ", s$fixed_effect)
                           else s$test)
    c(unname(label), cells)
  })
}

# The rows' other p-values (spec/table.md 5.1): each tidy row's multiple-testing adjusted and
# resampling p-values, from the parameters tidy() kept (the same rows, in order).
.tab_row_p <- function(t, rec, c) {
  comp <- c$component
  kept <- Filter(function(p) identical(p$component, comp) && is.null(p$dropped), rec$parameters %||% list())
  ok <- length(kept) == nrow(t)
  t$p.adjusted <- if (ok) vapply(kept, function(p) .est_dbl(p$p_value_adjusted), 0) else rep(NA_real_, nrow(t))
  t$p.resampling <- if (ok) vapply(kept, function(p) .est_dbl(p$resampling$p_value), 0) else rep(NA_real_, nrow(t))
  t
}

# The p-value a column's stars use: its own `significance` (null for the coefficient's), else the table's.
.tab_sig_of <- function(spec, c) if ("significance" %in% names(c)) c$significance else spec$significance

.tab_sig_p <- function(sig, t, rec, c) {
  if (is.null(sig)) return(t$p.value)
  if (identical(sig, "p_value_adjusted")) return(t$p.adjusted)
  if (identical(sig, "resampling")) return(t$p.resampling)
  if (!is.list(sig) || !is.character(sig$test))
    stop("significance: 'p_value_adjusted', 'resampling', or {test, value}", call. = FALSE)
  which <- sig$value %||% "p_value"
  vapply(t$term, function(term) {
    tests <- Filter(function(x) identical(as.character(unlist(x$terms)), term), rec$tests %||% list())
    if (!is.null(c$response)) tests <- Filter(function(x) is.null(x$response) || identical(x$response, c$response), tests)
    hit <- Filter(function(x) identical(x$label, sig$test), tests)
    if (!length(hit)) hit <- Filter(function(x) identical(x$name, sig$test), tests)
    if (length(hit)) .est_dbl(hit[[1]][[which]]) else NA_real_
  }, 0, USE.NAMES = FALSE)
}

.tab_sig_desc <- function(sig) {
  if (is.null(sig)) return("the coefficients' p-values")
  if (identical(sig, "p_value_adjusted")) return("p-values adjusted for multiple testing")
  if (identical(sig, "resampling")) return("resampling p-values")
  paste0("the ", sig$test, " test's", if (identical(sig$value, "p_value_adjusted")) " adjusted" else "", " p-values")
}

# "; stars from <source>" when some column doesn't use the coefficients' own p-values, or per
# source with its columns (as the Python reference's notes); "" otherwise
.tab_sig_note <- function(views) {
  by <- list()
  for (v in views) for (j in seq_along(v$columns)) {
    d <- .tab_sig_desc(.tab_sig_of(v, v$columns[[j]]))
    by[[d]] <- union(by[[d]], sprintf("(%d)", j))
  }
  if (identical(names(by), .tab_sig_desc(NULL))) return("")
  if (length(by) == 1L) return(paste0("; stars from ", names(by)))
  paste0("; stars from ", paste(vapply(names(by), function(d) paste0(d, " in ", paste(by[[d]], collapse = ", ")), ""), collapse = "; "))
}

# Column groups shown (spec/table.md 3.2): a list of list(label, first, last), columns from 1,
# sorted; NULL when there are none or `head` leaves them out. Checked as the Python reference does.
.tab_spans <- function(spec, n) {
  groups <- spec$spanners
  if (!length(groups)) return(NULL)
  taken <- integer()
  for (j in seq_along(groups)) {
    g <- groups[[j]]
    if (!is.character(g$label)) stop("spanners[", j - 1, "]: a column group needs a `label` (text)", call. = FALSE)
    c <- unlist(g$columns)
    if (length(c) != 2L || any(c != round(c)) || c[1] < 1 || c[1] > c[2] || c[2] > n)
      stop("spanners[", j - 1, "].columns: [first, last], column numbers from 1 to ", n, call. = FALSE)
    if (any(c[1]:c[2] %in% taken)) stop("spanners[", j - 1, "].columns: columns in another group too", call. = FALSE)
    taken <- c(taken, c[1]:c[2])
  }
  if ("head" %in% names(spec) && !"spanner" %in% unlist(spec$head)) return(NULL)
  spans <- lapply(groups, function(g) list(label = g$label, first = as.integer(g$columns[[1]]), last = as.integer(g$columns[[2]])))
  spans[order(vapply(spans, function(g) g$first, 0L))]
}

# the groups as a row of cells: each label in its group's first column
.tab_span_row <- function(spans, n) {
  cells <- rep("", n)
  for (g in spans) cells[g$first] <- g$label
  cells
}

# tinytable column groups over the model columns (after the stub column)
.tab_group_cols <- function(x, spans) {
  if (!length(spans) || !inherits(x, "tinytable")) return(x)
  j <- lapply(spans, function(g) g$first:g$last + 1L)
  names(j) <- vapply(spans, function(g) g$label, "")
  tinytable::group_tt(x, j = j)
}

# a panel's own settings, each the top level's unless it sets it (spec/table.md 4.1)
.tab_panel_fields <- c("rows", "keep", "drop", "keep_unlisted", "estimate", "uncertainty")

# A spec with panels (spec/table.md 4.1): each panel is rendered as a table of its own through
# modelsummary (its columns, terms, lines and statistics), the blocks stacked, then the top
# level's statistics. output = "data.frame" gives the cells, each panel's label on a row of its
# own; other outputs a tinytable whose row groups are the panels (sparklines show as text).
.tab_panels <- function(spec, output, records, base_dir, ...) {
  panels <- spec$panels
  if (!is.list(panels) || !length(panels)) stop("panels: a list of at least one panel", call. = FALSE)
  idx <- .tab_index(spec, records, base_dir)
  cols <- spec$columns
  n <- length(cols)
  if (!n) stop("the spec has no columns", call. = FALSE)
  found <- .tab_found(spec, cols, idx, "columns")
  fmt <- spec$format %||% list()
  digits <- fmt$digits %||% 3
  p_digits <- fmt$p_digits %||% digits
  tidies <- lapply(seq_along(cols), function(i) tidy.estimation_record(found[[i]], component = cols[[i]]$component))
  head <- .tab_head(spec, cols, found, tidies)
  terms <- character(); cells <- NULL; at <- list(); notes <- character(); views <- list()
  for (k in seq_along(panels)) {
    p <- panels[[k]]
    if (!is.character(p$label)) stop("panels[", k - 1, "].label: a panel needs a `label` (text)", call. = FALSE)
    sub <- spec
    sub$panels <- NULL; sub$title <- NULL; sub$notes <- NULL
    for (f in c(.tab_panel_fields, "columns")) if (f %in% names(p)) sub[f] <- list(p[[f]])
    if (length(sub$columns) != n)
      stop("panels[", k - 1, "].columns: ", length(sub$columns), " columns; the table has ", n, call. = FALSE)
    sub["stats"] <- list(p$stats %||% list())
    sub["head"] <- list(list())
    views <- c(views, list(sub))
    x <- render_table(sub, output = "data.frame", records = records, base_dir = base_dir)
    at[[p$label]] <- length(terms) + 1L
    # a term's label on its first row only, as the Python reference's built table
    terms <- c(terms, ifelse(x$part == "estimates" & x$statistic != "estimate", "", x$term))
    cells <- rbind(cells, as.matrix(x[, 3 + seq_len(n), drop = FALSE]))
    unc <- if ("uncertainty" %in% names(sub)) sub$uncertainty else "std_error"
    notes <- union(notes, .tab_unc_note(unc, .tab_lines(unc)))
  }
  tail <- .tab_stat_rows(spec$stats %||% list(), cols, found, fmt, digits, fmt$thousands %||% ",",
                         fmt$missing %||% "", p_digits, fmt$p_style %||% "fixed")
  rule <- if (length(tail)) length(terms) + 1L else NULL
  for (r in tail) { terms <- c(terms, r[1]); cells <- rbind(cells, r[-1]) }
  stars <- unlist(spec$stars)
  if (length(stars) && any(vapply(panels, function(p) !isFALSE(if ("estimate" %in% names(p)) p$estimate else spec$estimate), TRUE))) {
    sym <- unlist(fmt$star_symbols) %||% strrep("*", seq_along(stars))
    notes <- c(paste0(paste(sprintf("%s p < %s", sym, format(stars, scientific = FALSE, drop0trailing = TRUE, trim = TRUE)), collapse = ", "),
                      .tab_sig_note(views)), notes)
  }
  notes <- c(unlist(spec$notes), notes)
  headers <- if (length(head)) head[[1]] else rep("", n)
  top <- head[-1]
  spans <- .tab_spans(spec, n)
  if (length(spans) && identical(output, "data.frame")) top <- c(list(.tab_span_row(spans, n)), top)
  if (identical(output, "data.frame")) {
    lab <- character(); out <- NULL
    starts <- unlist(at)
    for (r in seq_along(terms)) {
      if (r %in% starts) { lab <- c(lab, names(starts)[starts == r]); out <- rbind(out, rep("", n)) }
      lab <- c(lab, terms[r]); out <- rbind(out, cells[r, ])
    }
    for (h in rev(top)) { lab <- c("", lab); out <- rbind(h, out) }
    df <- data.frame(term = lab, out, stringsAsFactors = FALSE, check.names = FALSE, row.names = NULL)
    names(df) <- c("term", headers)
    return(df)
  }
  body <- rbind(do.call(rbind, top), cells)
  df <- data.frame(c(rep("", length(top)), terms), body, stringsAsFactors = FALSE, check.names = FALSE, row.names = NULL)
  names(df) <- c(" ", headers)
  args <- list(df, notes = if (length(notes)) as.list(notes))
  if (!is.null(spec$title)) args$caption <- spec$title
  x <- do.call(tinytable::tt, args)
  if (!is.null(rule)) x <- tinytable::style_tt(x, i = rule + length(top) - 1L, line = "b", line_width = 0.05)
  x <- tinytable::group_tt(x, i = lapply(at, function(r) r + length(top)))
  x <- .tab_group_cols(x, spans)
  x <- tryCatch(tinytable::style_tt(x, i = "groupi", italic = TRUE), error = function(e) x)
  if (output %in% c("default", "tinytable", "html", "latex", "markdown", "typst")) return(x)
  tinytable::save_tt(x, output, overwrite = TRUE)
  invisible(x)
}

# Whether sparklines are drawn: for modelsummary's tinytable outputs (the default, unless
# another factory is set) and files written from one; elsewhere they are the interval as text.
.tab_draws <- function(output) {
  if (identical(output, "default"))
    return(identical(getOption("modelsummary_factory_default", "tinytable"), "tinytable"))
  output %in% c("tinytable", "html", "latex", "markdown", "typst") ||
    grepl("\\.(html|tex|md|typ|txt)$", output)
}

# The sparkline cells of a tinytable from modelsummary: each placeholder becomes the
# interval as text, the SVG in HTML and a TikZ picture in LaTeX, drawn on the axes of the
# Python reference's _spark_domains (shared down a column, along a row or across the table,
# always holding 0), so the drawings are the same byte for byte.
.tab_draw <- function(x, tidies, sparks, digits, p_digits, p_style, missing) {
  d <- as.matrix(x@data)
  at <- which(matrix(grepl("^estrecspark[0-9]+c[0-9]+r[0-9]+$", d), nrow(d)), arr.ind = TRUE)
  if (!nrow(at)) return(x)
  cells <- lapply(seq_len(nrow(at)), function(n) {
    v <- as.integer(regmatches(d[at[n, 1], at[n, 2]], gregexpr("[0-9]+", d[at[n, 1], at[n, 2]]))[[1]])
    r <- tidies[[v[2]]][v[3], , drop = FALSE]
    sp <- sparks[[v[1]]]
    vals <- c(r$conf.low, r$estimate, r$conf.high)
    list(i = at[n, 1], j = at[n, 2], col = v[2], sp = sp,
         text = .tab_fill("[{conf_low}, {conf_high}]", r, digits, p_digits, p_style, missing),
         mark = if (length(vals) == 3L && all(is.finite(vals))) list(low = vals[1], estimate = vals[2], high = vals[3]))
  })
  key <- vapply(cells, function(c) paste(c$sp$scale, switch(c$sp$scale, column = c$col, row = c$i, table = 0)), "")
  for (k in unique(key)) {
    g <- which(key == k & !vapply(cells, function(c) is.null(c$mark), TRUE))
    if (!length(g)) next
    lo <- min(0, vapply(cells[g], function(c) c$mark$low, 0))
    hi <- max(0, vapply(cells[g], function(c) c$mark$high, 0))
    if (lo == hi) { lo <- -1; hi <- 1 }
    for (n in g) cells[[n]]$mark$domain <- c(lo, hi)
  }
  for (c in cells) {
    x <- tinytable::format_tt(x, i = c$i, j = c$j, fn = local({ s <- c$text; function(z) s }))
    if (is.null(c$mark)) next
    x <- tinytable::format_tt(x, i = c$i, j = c$j, output = "html",
                              fn = local({ s <- .tab_spark_svg(c$mark, c$sp$color, c$text); function(z) s }))
    x <- tinytable::format_tt(x, i = c$i, j = c$j, output = "latex",
                              fn = local({ s <- .tab_spark_tikz(c$mark, c$sp$color); function(z) s }))
  }
  x
}

# sparklines (spec/table.md 5): the lines' {color, scale}, or NULL for other lines
.tab_spark_color <- "#2b5f8e"
.tab_sparks <- function(unc) {
  if (is.null(unc)) return(list())
  items <- if (is.list(unc) && !is.null(names(unc))) list(unc) else as.list(unc)
  lapply(items, function(x) {
    if (!is.list(x) || !identical(names(x), "sparkline")) return(NULL)
    list(color = x$sparkline$color %||% .tab_spark_color, scale = x$sparkline$scale %||% "column")
  })
}

# the marks' x positions in tenths of a pixel across 80, rounded half up (as Python and JS)
.tab_spark_xs <- function(m) {
  lo <- m$domain[1]; hi <- m$domain[2]
  vapply(c(0, m$low, m$estimate, m$high), function(v) floor((4 + (v - lo) / (hi - lo) * 72) * 10 + 0.5), 0)
}
.tab_tenths <- function(n) sprintf("%d.%d", as.integer(n %/% 10), as.integer(n %% 10))
.tab_third <- function(a, b) { n <- (20 * (a + 2 * b) + 3) %/% 6; sprintf("%d.%02d", as.integer(n %/% 100), as.integer(n %% 100)) }
.tab_rgb <- function(color) strtoi(substring(color, c(2, 4, 6), c(3, 5, 7)), 16L)
.tab_dark <- function(color) paste0("#", paste(sprintf("%02x", (.tab_rgb(color) * 13L) %/% 20L), collapse = ""))
.tab_tikz_rgb <- function(color) { v <- .tab_rgb(color); sprintf("{rgb,255:red,%d;green,%d;blue,%d}", v[1], v[2], v[3]) }
.tab_html_escape <- function(s) {
  for (p in list(c("&", "&amp;"), c("<", "&lt;"), c(">", "&gt;"), c("\"", "&quot;"), c("'", "&#x27;")))
    s <- gsub(p[1], p[2], s, fixed = TRUE)
  s
}

.tab_spark_svg <- function(m, color, label = "") {
  x <- .tab_tenths(.tab_spark_xs(m))
  halo <- 'style="stroke:var(--bg,#ffffff)"'
  paste0(
    '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="16" viewBox="0 0 80 16" role="img"',
    if (nzchar(label)) paste0(' aria-label="', .tab_html_escape(label), '"'), ">",
    '<line x1="', x[1], '" y1="0" x2="', x[1], '" y2="16" stroke="#555555" stroke-width="1"/>',
    '<path d="M', x[2], ' 8.0Q', x[3], ' 2.0 ', x[4], ' 8.0Q', x[3], ' 14.0 ', x[2], ' 8.0Z" fill="', color,
    '" fill-opacity="0.22"/>',
    '<line x1="', x[2], '" y1="8.0" x2="', x[4], '" y2="8.0" stroke="', color, '" stroke-width="1.3" stroke-linecap="round"/>',
    '<circle cx="', x[2], '" cy="8.0" r="1.9" fill="', color, '" stroke-width="0.9" ', halo, '/>',
    '<circle cx="', x[4], '" cy="8.0" r="1.9" fill="', color, '" stroke-width="0.9" ', halo, '/>',
    '<circle cx="', x[3], '" cy="8.0" r="2.9" fill="', .tab_dark(color), '" stroke-width="1.1" ', halo, '/>',
    "</svg>")
}

.tab_spark_tikz <- function(m, color) {
  n <- .tab_spark_xs(m)
  x <- .tab_tenths(n)
  a <- .tab_third(n[2], n[3]); b <- .tab_third(n[4], n[3])
  c <- .tab_tikz_rgb(color); d <- .tab_tikz_rgb(.tab_dark(color))
  paste0(
    "\\tikz[x=.75pt,y=.75pt,baseline=0pt]{\\useasboundingbox (0,-4.8) rectangle (80,11.2);",
    "\\draw[line width=.75pt,color=", .tab_tikz_rgb("#555555"), "] (", x[1], ",-4.8) -- (", x[1], ",11.2);",
    "\\fill[color=", c, ",fill opacity=.22] (", x[2], ",3.2) .. controls (", a, ",7.2) and (", b, ",7.2) .. (",
    x[4], ",3.2) .. controls (", b, ",-0.8) and (", a, ",-0.8) .. (", x[2], ",3.2) -- cycle;",
    "\\draw[line width=.975pt,line cap=round,color=", c, "] (", x[2], ",3.2) -- (", x[4], ",3.2);",
    "\\filldraw[fill=", c, ",draw=white,line width=.675pt] (", x[2], ",3.2) circle[radius=1.425pt];",
    "\\filldraw[fill=", c, ",draw=white,line width=.675pt] (", x[4], ",3.2) circle[radius=1.425pt];",
    "\\filldraw[fill=", d, ",draw=white,line width=.825pt] (", x[3], ",3.2) circle[radius=2.175pt];",
    "}")
}

.tab_head_kinds <- c("number", "response", "label", "spanner")

# The heading rows' cells, top to bottom: a list of character vectors, one per row; a
# response or label row blank in every column is left out.
.tab_head <- function(spec, cols, found, tidies) {
  kinds <- if ("head" %in% names(spec)) as.character(unlist(spec$head)) else c("number", "response")
  bad <- setdiff(kinds, .tab_head_kinds)
  if (length(bad)) stop("head: '", bad[1], "' is not one of 'number', 'response', 'label', 'spanner'", call. = FALSE)
  if (anyDuplicated(kinds)) stop("head: '", kinds[anyDuplicated(kinds)], "' appears twice", call. = FALSE)
  labels <- spec$response_labels %||% list()
  cells <- list(
    number = sprintf("(%d)", seq_along(cols)),
    response = vapply(seq_along(cols), function(i) {
      name <- cols[[i]]$response
      if (is.null(name) && "response" %in% names(tidies[[i]])) {
        named <- sort(unique(stats::na.omit(tidies[[i]]$response)))
        named <- named[nzchar(named)]
        if (length(named) == 1L) name <- named
      }
      if (is.null(name)) name <- paste(unlist(found[[i]]$meta$responses), collapse = ", ")
      as.character(labels[[name]] %||% name)
    }, ""),
    label = vapply(seq_along(cols), function(i)
      as.character(cols[[i]]$header %||% attr(found[[i]], "member")$label %||% found[[i]]$meta$title %||% ""), "")
  )
  kinds <- setdiff(kinds, "spanner")  # column groups: .tab_spans()
  out <- lapply(kinds, function(k) cells[[k]])
  Filter(Negate(is.null), Map(function(k, x) if (k != "number" && !any(nzchar(x))) NULL else x, kinds, out))
}

.tab_stat_labels <- c(nobs = "N", r2 = "R\u00b2", adj_r2 = "Adj. R\u00b2", r2_within = "Within R\u00b2",
                      adj_r2_within = "Adj. within R\u00b2", pseudo_r2 = "Pseudo R\u00b2", aic = "AIC",
                      bic = "BIC", log_lik = "Log lik.", rmse = "RMSE", f_stat = "F")

`%|NA|%` <- function(a, b) if (length(a) != 1L || is.na(a)) b else a

# lines under each estimate (spec/table.md section 5)
.tab_named_lines <- c(std_error = "({std_error})", statistic = "({statistic})", p_value = "[{p_value}]",
                      conf_int = "[{conf_low}, {conf_high}]")
.tab_placeholders <- c(estimate = "estimate", std_error = "std.error", statistic = "statistic",
                       p_value = "p.value", conf_low = "conf.low", conf_high = "conf.high", star_p = "star.p")

.tab_lines <- function(unc) {
  if (is.null(unc)) return(character())
  items <- if (is.list(unc) && !is.null(names(unc))) list(unc) else as.list(unc)
  vapply(seq_along(items), function(j) {
    x <- items[[j]]
    # a sparkline (spec/table.md 5): the interval as text, drawn by .tab_draw() where it can be
    if (is.list(x)) {
      if (!identical(names(x), "sparkline")) stop("uncertainty[", j - 1, "]: an object line is {\"sparkline\": {color, scale}}", call. = FALSE)
      return("[{conf_low}, {conf_high}]")
    }
    if (x %in% names(.tab_named_lines)) return(unname(.tab_named_lines[x]))
    if (!grepl("{", x, fixed = TRUE))
      stop("uncertainty[", j - 1, "]: '", x, "' is neither a name (",
           paste(names(.tab_named_lines), collapse = ", "), ") nor a template", call. = FALSE)
    ph <- regmatches(x, gregexpr("\\{([^{}]*)\\}", x))[[1]]
    ph <- substr(ph, 2, nchar(ph) - 1)
    bad <- setdiff(ph, names(.tab_placeholders))
    if (length(bad)) stop("uncertainty[", j - 1, "]: unknown placeholder {", bad[1], "}; use ",
                          paste(names(.tab_placeholders), collapse = ", "), call. = FALSE)
    if (!length(ph)) stop("uncertainty[", j - 1, "]: a template needs at least one placeholder", call. = FALSE)
    x
  }, "")
}

.tab_fixed <- function(x, digits) {
  if (is.na(x)) return("")
  if (!is.finite(x)) return(if (x > 0) "Inf" else "-Inf")
  s <- formatC(x, digits = digits, format = "f")
  if (startsWith(s, "-") && as.numeric(s) == 0) s <- substring(s, 2)
  s
}

.tab_p <- function(p, digits, style) {
  if (is.na(p)) return("")
  if (identical(style, "less_than") && p < 10^-digits) return(paste0("<", .tab_fixed(10^-digits, digits)))
  .tab_fixed(p, digits)
}

.tab_fill <- function(template, row, digits, p_digits, p_style, missing) {
  ph <- regmatches(template, gregexpr("\\{([^{}]*)\\}", template))[[1]]
  out <- template
  for (m in unique(ph)) {
    name <- substr(m, 2, nchar(m) - 1)
    x <- row[[.tab_placeholders[[name]]]]
    if (is.null(x) || is.na(x)) return(missing)
    val <- if (name %in% c("p_value", "star_p")) .tab_p(x, p_digits, p_style) else .tab_fixed(x, digits)
    out <- gsub(m, val, out, fixed = TRUE)
  }
  out
}

.tab_unc_note <- function(unc, lines) {
  if (is.null(unc) || !length(lines)) return(NULL)
  named <- c(std_error = "Standard errors in parentheses.", statistic = "Test statistics in parentheses.",
             p_value = "p-values in brackets.", conf_int = "Confidence intervals in brackets.")
  if (is.character(unc) && length(unc) == 1L && unc %in% names(named)) return(unname(named[unc]))
  words <- c(estimate = "estimate", std_error = "standard error", statistic = "test statistic",
             p_value = "p-value", conf_low = "lower bound", conf_high = "upper bound",
             star_p = "p-value of the stars")
  parts <- vapply(lines, function(t) {
    t <- sub("{conf_low}, {conf_high}", "confidence interval", t, fixed = TRUE)
    for (w in names(words)) t <- gsub(paste0("{", w, "}"), words[[w]], t, fixed = TRUE)
    t
  }, "")
  paste0("Under each estimate: ", paste(parts, collapse = "; "), ".")
}

.tab_value <- function(v, digits, big, missing) {
  if (is.null(v) || length(v) != 1L || (is.atomic(v) && is.na(v) && !is.nan(v))) return(missing)
  if (is.logical(v)) return(if (v) "Yes" else "No")
  if (is.character(v)) return(v)
  if (is.nan(v)) return(missing)
  if (is.finite(v) && v == round(v) && abs(v) < 1e15)
    return(formatC(v, format = "d", big.mark = big))
  if (!is.finite(v)) return(if (v > 0) "Inf" else "-Inf")
  .tab_fixed(v, digits)
}

# Records a spec can use, keyed by meta.id and by "<source>\r<meta.id>"
.tab_index <- function(spec, records, base_dir) {
  idx <- list()
  add <- function(rec, src) {
    id <- rec$meta$id
    if (is.null(id)) return()
    if (!inherits(rec, "estimation_record")) rec <- .est_as_record(rec)
    if (!is.null(src) && is.null(idx[[paste0(src, "\r", id)]])) idx[[paste0(src, "\r", id)]] <<- rec
    if (is.null(idx[[id]])) idx[[id]] <<- rec
  }
  if (!is.null(records)) {
    recs <- if (is_estimation_record(records)) list(records) else records
    for (r in recs) add(r, NULL)
  }
  if (!is.null(base_dir)) {
    for (s in spec$sources %||% list()) {
      p <- file.path(base_dir, s$path)
      recs <- if (dir.exists(p)) read_estimation(p)
              else {
                doc <- jsonlite::fromJSON(p, simplifyVector = FALSE)
                if (identical(doc$schema, "estrec-collection/0.1")) read_collection(p)
                else list(read_estimation(p))
              }
      for (r in recs) add(r, s$id)
    }
  }
  idx
}

# Make a table spec (estrec-table/0.1) with one column per record, as Python's
# estrec.table.new_table() does. `records`: a record, a list of records, or
# read_collection()'s result; a list's names become the column headers unless `headers`
# is given. Entries of `rows` and `stats` may be plain strings (a term, a metric name).
# `...` comes second so that spec fields passed through it (`head`, ...) are never partially
# matched to these arguments (`head` would otherwise go to `headers`).
new_table <- function(records, ..., headers = NULL, rows = NULL,
                      stats = list("nobs", "r2", list(vcov = "type")),
                      uncertainty = "std_error", stars = c(0.1, 0.05, 0.01), title = NULL,
                      sources = NULL, pin = FALSE, fixed_effects = TRUE) {
  recs <- if (is_estimation_record(records)) list(records) else records
  if (!is.list(recs) || !length(recs) || !all(vapply(recs, is_estimation_record, logical(1))))
    stop("`records` must be a record or a list of records", call. = FALSE)
  if (is.null(headers) && !is.null(names(recs)) && all(nzchar(names(recs)))) headers <- names(recs)
  if (!is.null(headers) && length(headers) != length(recs))
    stop("`headers` has ", length(headers), " entries for ", length(recs), " records", call. = FALSE)
  if (isTRUE(pin) && !requireNamespace("openssl", quietly = TRUE))
    stop("pin = TRUE needs the 'openssl' package", call. = FALSE)
  cols <- lapply(seq_along(recs), function(i) {
    r <- .est_plain(recs[[i]])
    .est_compact(list(record = as.character(r$meta$id),
                      header = if (!is.null(headers)) as.character(headers[[i]]),
                      sha256 = if (isTRUE(pin)) .est_sha256(.est_canonical_json(r))))
  })
  st <- lapply(stats %||% list(), function(s) if (is.character(s)) list(metric = s) else s)
  if (fixed_effects) {
    fes <- unique(unlist(lapply(recs, function(r) r$specification$fixed_effects)))
    st <- c(st, lapply(fes, function(fe) list(fixed_effect = fe, label = paste0("FE: ", fe))))
  }
  spec <- list(schema = "estrec-table/0.1",
               meta = list(id = .est_uuid(), created = .est_now(), producer = estrec_info()))
  spec$title <- title
  spec$sources <- sources
  spec$columns <- cols
  if (length(rows)) spec$rows <- lapply(rows, function(r) if (is.character(r)) list(term = r) else r)
  spec$uncertainty <- uncertainty
  if (length(stars)) spec$stars <- as.list(stars)
  if (length(st)) spec$stats <- st
  utils::modifyList(spec, list(...))
}

# Write a table spec as JSON. `spec` is a list as render_table() takes; a missing `schema` or
# `meta` is filled in (a new id, now, this package as producer). Returns `path` invisibly.
write_table <- function(spec, path) {
  if (!is.list(spec) || is.null(names(spec)))
    stop("`spec` must be a named list (a table spec)", call. = FALSE)
  if (is.null(spec$schema)) spec <- c(list(schema = "estrec-table/0.1"), spec)
  if (!identical(spec$schema, "estrec-table/0.1"))
    stop("not an estrec-table/0.1 spec", call. = FALSE)
  if (!length(spec$columns)) stop("the spec has no columns", call. = FALSE)
  # fields the schema has as arrays stay arrays with one entry (auto_unbox would unbox them)
  for (f in c("head", "keep", "drop", "stars", "notes"))
    if (!is.null(spec[[f]])) spec[[f]] <- as.list(spec[[f]])
  if (!is.null(spec$rows)) spec$rows <- lapply(spec$rows, function(r) {
    if (is.list(r) && !is.null(r$terms)) r$terms <- as.list(r$terms)
    r
  })
  if (is.null(spec$meta)) {
    spec <- append(spec, list(meta = list(id = .est_uuid(), created = .est_now(),
                                          producer = estrec_info())), after = 1L)
  }
  jsonlite::write_json(spec, path, auto_unbox = TRUE, digits = I(17), null = "null",
                       na = "null", pretty = TRUE)
  invisible(path)
}
