# Records of PROCESS (Andrew F. Hayes's conditional process macro) runs in R.
#
# PROCESS isn't part of estrec: users get it from https://www.afhayes.com/download.html and
# source() it. record_process() runs a process() call with save = 2, keeps its printed output
# (and prints it), and reads it the way spss/estrec_process.py reads PROCESS's text: the text
# gives the sections and labels, the save = 2 matrix the numbers at full precision (one matrix
# row per printed table row, in print order). The reader mirrors the Python one function for
# function; tests/test_process.py checks that both give the same record.

# Run a process() call and return its record.
#   rec <- record_process(process(data = d, y = "y", x = "x1", m = "x2", model = 4, seed = 1))
#   write_estimation(rec, "m4.estrec.json")
# save = 2 is added (save = 1, the bootstrap draws, becomes 3); PROCESS's result is the
# record's "process" attribute. save = 2 makes PROCESS probe every interaction (intprobe = 1).
record_process <- function(expr, title = NULL, identifying = FALSE, digest = NULL,
                           envir = parent.frame()) {
  call <- substitute(expr)
  if (!is.call(call)) stop("record_process() takes a process(...) call", call. = FALSE)
  save <- if (is.null(call$save)) 0 else eval(call$save, envir)
  if (save == 4) stop("record_process() can't use save = 4 (regression diagnostics)", call. = FALSE)
  call$save <- if (save %in% c(1, 3)) 3 else 2
  if (is.null(call$progress)) call$progress <- 0
  txt <- utils::capture.output(res <- eval(call, envir))
  cat(txt, sep = "\n")
  mat <- if (is.list(res) && !is.data.frame(res)) res[[2]] else res
  rec <- .proc_record(txt, as.matrix(mat), call, envir, title = title, identifying = identifying,
                      digest = digest)
  attr(rec, "process") <- if (save %in% c(1, 3)) res[[1]] else res
  rec
}

# ---------------------------------------------------------------- reading the text

.proc_num_re <- "^[-+]?(\\d+\\.?\\d*|\\.\\d+)([eE][-+]?\\d+)?$"
.proc_isnum <- function(x) grepl(.proc_num_re, x, perl = TRUE)
.proc_key <- function(s) {
  s <- trimws(gsub("\\s+", " ", trimws(sub(":+$", "", trimws(s %||% "")))))
  tolower(s)
}

.proc_section <- function(title = "", kind = "table", columns = character(0), lines = character(0))
  list(title = title, kind = kind, columns = columns, rows = list(), lines = lines)

# the value in `row` under the first heading in `...`
.proc_col <- function(sec, row, ..., skip = 0L) {
  heads <- vapply(sec$columns, .proc_key, "")
  for (n in c(...)) {
    n <- .proc_key(n)
    for (i in seq_along(heads)) {
      if (i > skip && (heads[i] == n || sub("\\(.*\\)$", "", heads[i]) == n) && i <= length(row$values)) {
        v <- row$values[i]
        return(if (is.na(v)) NULL else v)
      }
    }
  }
  NULL
}

.proc_sections_from_text <- function(txt) {
  lines <- sub("\\s+$", "", gsub("\r", "", txt))
  out <- list(); pending <- character(0); last <- ""
  i <- 1L; n <- length(lines)
  flush <- function() {
    if (length(pending)) out[[length(out) + 1L]] <<- .proc_section("", "text", lines = pending)
    pending <<- character(0)
  }
  while (i <= n) {
    s <- trimws(lines[i])
    if (!nzchar(s)) { flush(); i <- i + 1L; next }
    if (startsWith(s, "*")) {
      flush()
      if (grepl("PROCESS Procedure for", s, fixed = TRUE))
        out[[length(out) + 1L]] <- .proc_section("", "text", lines = gsub("^[* ]+|[* ]+$", "", s))
      m <- regmatches(s, regexec("\\*\\s*([A-Za-z][A-Za-z ,()]+[A-Za-z)])\\s*\\*", s, perl = TRUE))[[1]]
      if (length(m)) out[[length(out) + 1L]] <- .proc_section(trimws(m[2]), "heading")
      i <- i + 1L; next
    }
    toks <- strsplit(gsub("Adj R-sq", "Adj_R-sq", s, fixed = TRUE), "\\s+")[[1]]
    j <- i + 1L
    while (j <= n && !nzchar(trimws(lines[j])) && j - i <= 2L) j <- j + 1L
    nxt <- if (j <= n) strsplit(trimws(lines[j]), "\\s+")[[1]] else character(0)
    nxt <- nxt[nzchar(nxt)]
    k <- length(toks)
    is_head <- k > 0 && !any(.proc_isnum(toks)) && length(nxt) > 0 &&
      sum(.proc_isnum(nxt)) >= k && length(nxt) >= k && all(.proc_isnum(utils::tail(nxt, k))) &&
      !any(endsWith(nxt, ":"))
    if (is_head) {
      if (length(pending)) { ttl <- pending[length(pending)]; pending <- pending[-length(pending)] }
      else ttl <- last
      last <- ""
      flush()
      if (grepl("->", ttl, fixed = TRUE)) {       # a path line titles a conditional table
        out[[length(out) + 1L]] <- .proc_section("", "text", lines = ttl)
        ttl <- ""
      }
      sec <- .proc_section(ttl, "table", columns = toks)
      i <- j
      while (i <= n) {
        r <- strsplit(trimws(lines[i]), "\\s+")[[1]]
        r <- r[nzchar(r)]
        if (!length(r) || length(r) < k || !all(.proc_isnum(utils::tail(r, k)))) break
        lab <- paste(utils::head(r, length(r) - k), collapse = " ")
        tk <- utils::tail(r, k)
        sec$rows[[length(sec$rows) + 1L]] <- list(label = if (nzchar(lab)) lab else NULL,
                                                  values = as.numeric(tk), tokens = tk)
        i <- i + 1L
      }
      out[[length(out) + 1L]] <- sec
      next
    }
    pending <- c(pending, s)
    last <- s
    i <- i + 1L
  }
  flush()
  out
}

# Replace the printed numbers with save = 2's: each printed table row matches the next matrix
# row whose leading values agree with it to the printed decimals ("Coding of" tables and the
# Johnson-Neyman text aren't in the matrix; blank rows separate some sections).
.proc_full_precision <- function(secs, mat) {
  p <- 1L; missed <- 0L
  for (si in seq_along(secs)) {
    s <- secs[[si]]
    if (s$kind != "table" || startsWith(.proc_key(s$title), "coding of")) next
    for (ri in seq_along(s$rows)) {
      row <- s$rows[[ri]]
      d <- nchar(sub("^[^.]*\\.?", "", sub("[eE].*$", "", row$tokens)))
      tol <- 0.5 * 10^(-d) + 1e-9
      k <- length(row$values); hit <- 0L
      if (p <= nrow(mat)) for (q in p:min(nrow(mat), p + 6L)) {
        mv <- mat[q, seq_len(min(k, ncol(mat)))]
        if (length(mv) == k && !anyNA(mv) && all(abs(mv - row$values) <= tol)) { hit <- q; break }
      }
      if (hit) {
        secs[[si]]$rows[[ri]]$values <- unname(mat[hit, seq_len(k)])
        p <- hit + 1L
      } else missed <- missed + 1L
    }
  }
  attr(secs, "missed") <- missed
  secs
}

# ---------------------------------------------------------------- interpreting

.proc_header_re <- "^(Model|Y|X|M\\d*|W|Z|Covariates?)\\s*:\\s*(.*)$"
.proc_outcome_re <- "(?i)^outcome variable\\s*:?\\s*(\\S*)\\s*$"

# (kind, value) in order
.proc_items <- function(secs) {
  out <- list()
  for (s in secs) {
    if (s$kind == "table") out[[length(out) + 1L]] <- list(kind = "table", v = s)
    else if (s$kind == "heading") out[[length(out) + 1L]] <- list(kind = "heading", v = s$title)
    else for (ln in s$lines) out[[length(out) + 1L]] <- list(kind = "line", v = ln)
  }
  out
}

.proc_match <- function(re, s) {
  m <- regmatches(s, regexec(re, s, perl = TRUE))[[1]]
  if (length(m)) m else NULL
}

.proc_header <- function(secs) {
  h <- list(mediators = character(0), covariates = character(0))
  lines <- vapply(Filter(function(it) it$kind == "line", .proc_items(secs)), function(it) it$v, "")
  for (j in seq_along(lines)) {
    ln <- lines[j]
    if (grepl(.proc_outcome_re, ln, perl = TRUE)) break
    m <- .proc_match(paste0("(?i)", .proc_header_re), trimws(ln))
    if (!is.null(m)) {
      k <- tolower(m[2]); v <- trimws(m[3])
      if (startsWith(k, "cov")) {
        h$covariates <- c(h$covariates, if (nzchar(v)) strsplit(v, "\\s+")[[1]]
                          else if (j < length(lines)) strsplit(trimws(lines[j + 1L]), "\\s+")[[1]])
      } else if (k == "model" && nzchar(v)) {
        h$model <- as.integer(as.numeric(strsplit(v, "\\s+")[[1]][1]))
      } else if (startsWith(k, "m") && nzchar(v)) {
        h$mediators <- c(h$mediators, v)
      } else if (nzchar(v)) h[[k]] <- v
    }
  }
  text <- paste(lines, collapse = "\n")
  m <- .proc_match("(?i)sample\\s*\\n?\\s*size\\s*:?\\s*(\\d+)", text)
  if (!is.null(m)) h$nobs <- as.integer(m[2])
  m <- .proc_match("(?i)custom\\s*\\n?\\s*seed\\s*:?\\s*\\n?\\s*(\\d+)", text)
  if (!is.null(m)) h$seed <- as.numeric(m[2])
  m <- .proc_match("PROCESS Procedure for (\\w+) Version\\s+([\\d.]+)", text)
  if (!is.null(m)) { h$platform <- m[2]; h$version <- m[3] }
  h
}

.proc_value_after <- function(lines, pattern) {
  for (j in seq_along(lines)) {
    if (grepl(pattern, lines[j], ignore.case = TRUE, perl = TRUE)) {
      m <- .proc_match(":\\s*([-+]?\\d*\\.?\\d+)\\s*$", lines[j])
      if (!is.null(m)) return(as.numeric(m[2]))
      if (j < length(lines)) {
        m <- .proc_match("^\\s*([-+]?\\d*\\.?\\d+)\\s*$", lines[j + 1L])
        if (!is.null(m)) return(as.numeric(m[2]))
      }
    }
  }
  NULL
}

.proc_term <- function(label) {
  lab <- trimws(label %||% "")
  if (tolower(lab) == "constant") "(Intercept)" else lab
}

# (past the first `skip` columns: a conditional table's moderator values; a moderator named z
# isn't the z statistic)
.proc_row <- function(sec, row, term, ..., skip = 0L) {
  cl <- function(...) .proc_col(sec, row, ..., skip = skip)
  r <- list(term = term, estimate = .est_num(cl("coeff", "effect", "index")), std_error = .est_num(cl("se", "bootse")))
  r <- c(r, .est_compact(list(statistic = cl("t", "z"), p_value = cl("p"),
                              conf_low = cl("llci", "bootllci"), conf_high = cl("ulci", "bootulci"))))
  extra <- .est_compact(list(...))
  for (k in names(extra)) r[[k]] <- extra[[k]]
  r
}

.proc_eff <- "effects?(?:\\(s\\))?"
.proc_fit <- list(r2 = "r-sq", adj_r2 = c("adj r-sq", "adj_r-sq"), mse = "mse", df_residual = "df2",
                  deviance = "-2ll", pseudo_r2 = "mcfadden", cox_snell_r2 = "coxsnell",
                  nagelkerke_r2 = "nagelkrk")

.proc_moderator_cols <- function(s) {
  heads <- vapply(s$columns, .proc_key, "")
  for (i in seq_along(heads)) if (heads[i] %in% c("effect", "index", "coeff")) return(s$columns[seq_len(i - 1L)])
  character(0)
}

.proc_fmt <- function(v) {
  if (is.character(v)) return(v)
  if (v == round(v)) return(format(v, scientific = FALSE, trim = TRUE))
  # to PROCESS's 4 printed decimals (half away from zero), then 3, in integers (as the Python
  # and SAS readers do)
  n4 <- floor(abs(v) * 10000 + 0.5)
  if (n4 == 0) return("0")
  sign <- if (v < 0) "-" else ""
  if (n4 < 100) return(paste0(sign, "0.00", sub("0+$", "", sprintf("%02d", as.integer(n4)))))
  n3 <- (n4 + 5) %/% 10
  sprintf("%s%d.%03d", sign, as.integer(n3 %/% 1000), as.integer(n3 %% 1000))
}

.proc_mod_value <- function(s, row, mod) {
  if (!length(mod)) return(NULL)
  vals <- row$values[seq_along(mod)]
  if (length(mod) == 1L) return(vals[1])
  paste(sprintf("%s=%s", trimws(mod), vapply(vals, function(v) .proc_numtext(v), "")), collapse = ", ")
}

# a number as Python's str() gives it (the moderator text of several moderators: "w=1.0, z=-1.0199")
.proc_numtext <- function(v) {
  if (v == round(v) && abs(v) < 1e15) return(paste0(format(v, scientific = FALSE, trim = TRUE), ".0"))
  for (d in 1:17) { t <- formatC(v, digits = d, format = "g"); if (as.numeric(t) == v) return(t) }
  formatC(v, digits = 17, format = "g")
}

.proc_at <- function(mod, mv) {
  names <- trimws(mod)
  if (is.character(mv) || length(names) != 1L) {
    parts <- strsplit(strsplit(as.character(mv), ", ", fixed = TRUE)[[1]], "=", fixed = TRUE)
    if (all(lengths(parts) == 2L))
      return(paste0(", at ", paste(vapply(parts, function(p) {
        v <- trimws(p[2])
        sprintf("%s = %s", trimws(p[1]), .proc_fmt(if (.proc_isnum(v)) as.numeric(v) else v))
      }, ""), collapse = ", ")))
    return(paste0(", at ", mv))
  }
  sprintf(", at %s = %s", names[1], .proc_fmt(mv))
}

.proc_eff_term <- function(eff, label, mv = NULL, mod = NULL) {
  base <- c(total = "total effect", direct = "direct effect")[[eff]]
  if (!is.null(label) && nzchar(label)) base <- paste0(base, ": ", label)
  if (!is.null(mv)) base <- paste0(base, .proc_at(mod, mv))
  base
}

.proc_indirect <- function(s, row, mod, path, relative = FALSE) {
  lab <- row$label
  if (!is.null(lab)) lab <- sub("^\\{(C\\d+\\))$", "(\\1", lab)   # PROCESS for SAS prints {C1)
  mv <- .proc_mod_value(s, row, mod)
  med <- NULL; treat <- NULL; eff <- "indirect"; extra <- list()
  has <- !is.null(lab) && nzchar(lab)
  if (has && toupper(lab) == "TOTAL") eff <- "total_indirect"
  else if (has && grepl("^\\(C\\d+\\)$", lab)) { eff <- "contrast"; extra$`_label` <- lab }
  else if (has && grepl("^Ind\\d+$", lab)) extra$`_ind` <- lab
  else if (relative && has) treat <- lab
  else if (has && !length(mod)) med <- lab
  if (eff == "indirect" && is.null(med) && is.null(extra$`_ind`) && length(path)) {
    if (length(path) == 3L) med <- path[2] else extra$path <- I(path)
  }
  term <- switch(eff, total_indirect = "total indirect effect", contrast = paste("contrast", lab), NULL)
  if (is.null(term)) {
    chain <- if (length(path) && (relative || length(mod) || !has)) path
    term <- paste0("indirect: ", if (length(chain)) paste(chain, collapse = " -> ") else (med %||% lab %||% ""))
    if (!is.null(treat)) term <- paste0(term, " [", treat, "]")
  }
  if (!is.null(mv)) term <- paste0(term, .proc_at(mod, mv))
  .proc_row(s, row, term, skip = length(mod), mediation = .est_compact(c(list(
    effect = eff, mediator = med, treatment = treat, moderator_value = mv), extra)))
}

.proc_interpret <- function(secs) {
  h <- .proc_header(secs)
  eqs <- list(); effects <- list(); tests <- list(); skipped <- character(0); fits <- list()
  keys <- list(); contrasts <- list(); products <- list()
  outcome <- NULL; path <- NULL; total_model <- FALSE; await <- FALSE; ind_ctx <- ""
  seen <- character(0); lines_all <- character(0)
  tm <- function() if (total_model) "total_effect_model"
  add <- function(lst, x) { lst[[length(lst) + 1L]] <- x; lst }
  for (it in .proc_items(secs)) {
    v <- it$v
    if (it$kind == "heading") {
      if (grepl("total effect model", v, ignore.case = TRUE)) total_model <- TRUE
      next
    }
    if (it$kind == "line") {
      lines_all <- c(lines_all, v)
      m <- .proc_match(.proc_outcome_re, v)
      if (!is.null(m)) {
        outcome <- if (nzchar(m[2])) m[2]
        await <- !nzchar(m[2]); path <- NULL
        next
      }
      if (await) {
        outcome <- strsplit(trimws(v), "\\s+")[[1]][1]; await <- FALSE
        if (outcome %in% seen && identical(outcome, h$y)) total_model <- TRUE
        seen <- c(seen, outcome)
        next
      }
      if (!is.null(outcome) && !length(seen)) seen <- c(seen, outcome)
      if (grepl(paste0("(?i)^(relative )?(conditional )?indirect ", .proc_eff), v, perl = TRUE))
        ind_ctx <- .proc_key(v)
      if (grepl("->", v, fixed = TRUE)) {
        toks <- strsplit(trimws(v), "\\s+")[[1]]
        toks <- toks[!toks %in% c("->", ":")]   # SAS: "Ind1 : X1 -> M -> Y"
        if (length(toks) && grepl("^Ind\\d+$", toks[1])) keys[[toks[1]]] <- toks[-1]
        else path <- toks
      }
      m <- .proc_match("^[({](C\\d+)\\)\\s+(.*)$", v)
      if (!is.null(m)) contrasts[[m[2]]] <- gsub("\\s+", " ", trimws(m[3]))
      m <- .proc_match("(?i)^(Int_\\d+)\\s*:?\\s*(.*)$", v)
      if (!is.null(m)) {
        p <- strsplit(trimws(m[3]), "\\s+")[[1]]
        products[[m[2]]] <- p[!p %in% c("x", ":")]
      }
      next
    }
    s <- v
    k <- .proc_key(s$title)
    k_ctx <- if (!nzchar(k) && length(path) && nzchar(ind_ctx)) ind_ctx else k
    if (k == "model summary") {
      for (row in s$rows) {
        f <- c(list(response = outcome, component = tm()),
               lapply(.proc_fit, function(cols) .proc_col(s, row, cols)))
        fits <- add(fits, .est_compact(f))
        fv <- .proc_col(s, row, "f")
        tests <- add(tests, .est_compact(list(
          category = "model", name = if (!is.null(fv)) "f" else "likelihood_ratio",
          label = paste0("Model summary, ", outcome, if (total_model) " (total effect model)" else ""),
          statistic = fv %||% .proc_col(s, row, "modelll", "-2ll"),
          df = .proc_col(s, row, "df1", "df"), df2 = .proc_col(s, row, "df2"),
          p_value = .proc_col(s, row, "p"), origin = "estimation", response = outcome,
          component = tm())))
      }
      next
    }
    if (k == "model") {
      for (row in s$rows) eqs <- add(eqs, .proc_row(s, row, .proc_term(row$label), response = outcome,
                                                    component = tm()))
      next
    }
    if (startsWith(k, "test(s) of highest order") || startsWith(k, "omnibus test")) {
      for (row in s$rows) {
        fv <- .proc_col(s, row, "f")
        lab <- c(trimws(sub(":+$", "", trimws(s$title))), row$label %||% "")
        tests <- add(tests, .est_compact(list(
          category = "restriction", name = if (!is.null(fv)) "f" else "chi2",
          label = paste(lab[nzchar(lab)], collapse = " "),
          statistic = fv %||% .proc_col(s, row, "chi-sq"),
          df = .proc_col(s, row, "df1", "df"), df2 = .proc_col(s, row, "df2"),
          p_value = .proc_col(s, row, "p"), origin = "estimation", response = outcome)))
      }
      next
    }
    if (grepl(paste0("^(relative )?total ", .proc_eff, " of x on y"), k, perl = TRUE)) {
      for (row in s$rows) effects <- add(effects, .proc_row(s, row, .proc_eff_term("total", row$label),
        mediation = .est_compact(list(effect = "total", treatment = row$label))))
      next
    }
    if (grepl(paste0("^(relative )?(conditional )?direct ", .proc_eff, " of x on y"), k, perl = TRUE)) {
      mod <- .proc_moderator_cols(s)
      for (row in s$rows) {
        mv <- .proc_mod_value(s, row, mod)
        effects <- add(effects, .proc_row(s, row, .proc_eff_term("direct", row$label, mv, mod), skip = length(mod),
          mediation = .est_compact(list(effect = "direct", treatment = row$label, moderator_value = mv))))
      }
      next
    }
    if (grepl(paste0("^(relative )?(conditional )?indirect ", .proc_eff, " of x on y"), k, perl = TRUE) ||
        (!nzchar(k) && length(path))) {
      mod <- .proc_moderator_cols(s)
      for (row in s$rows) effects <- add(effects, .proc_indirect(s, row, mod, path,
                                                                  relative = startsWith(k_ctx, "relative")))
      next
    }
    if (identical(unname(vapply(s$columns, .proc_key, "")), c("ss", "df", "ms"))) {
      rows <- list()
      for (r in s$rows) rows[[substr(.proc_key(r$label %||% ""), 1L, 5L)]] <- r
      res <- rows[["resid"]]; reg <- rows[["regre"]]
      nf <- length(fits)
      if (nf && identical(fits[[nf]]$response, outcome) && !is.null(res)) {
        if (is.null(fits[[nf]]$mse)) fits[[nf]]$mse <- .proc_col(s, res, "ms")
        if (is.null(fits[[nf]]$df_residual)) fits[[nf]]$df_residual <- .proc_col(s, res, "df")
      }
      nt <- length(tests)
      if (nt && identical(tests[[nt]]$name, "f") && identical(tests[[nt]]$response, outcome) &&
          !is.null(res) && !is.null(reg)) {
        if (is.null(tests[[nt]]$df)) tests[[nt]]$df <- .proc_col(s, reg, "df")
        if (is.null(tests[[nt]]$df2)) tests[[nt]]$df2 <- .proc_col(s, res, "df")
      }
      next
    }
    if (startsWith(k, "coding of") || startsWith(k, "anova summary")) next
    if (grepl("index of (partial |conditional )?moderated mediation", k, perl = TRUE)) {
      for (row in s$rows) {
        lab <- row$label
        term <- paste0("index of moderated mediation", if (!is.null(lab) && nzchar(lab)) paste0(" (", lab, ")") else "",
                       if (length(path)) paste0(": ", paste(path, collapse = " -> ")) else "")
        effects <- add(effects, .proc_row(s, row, term, mediation = .est_compact(list(
          effect = "index_moderated_mediation",
          mediator = if (length(path) == 3L) path[2], path = if (length(path) > 3L) I(path)))))
      }
      next
    }
    if (startsWith(k, "normal theory test")) {
      for (row in s$rows) tests <- add(tests, .est_compact(list(
        category = "linear_combination", name = "wald",
        label = paste("Normal theory (Sobel) test of the indirect effect through", row$label),
        estimate = .proc_col(s, row, "effect"), std_error = .proc_col(s, row, "se"),
        statistic = .proc_col(s, row, "z"), distribution = "normal",
        p_value = .proc_col(s, row, "p"), origin = "estimation")))
      next
    }
    if (grepl("^conditional effects? of (the )?focal predictor", k, perl = TRUE)) {
      mod <- .proc_moderator_cols(s)
      for (row in s$rows) {
        mv <- .proc_mod_value(s, row, mod)
        effects <- add(effects, .proc_row(s, row, paste0(h$x, if (!is.null(mv)) .proc_at(mod, mv) else ""), skip = length(mod),
                                          response = outcome, component = "conditional"))
      }
      next
    }
    if (length(s$rows)) {
      t <- trimws(sub(":+$", "", trimws(s$title)))
      skipped <- c(skipped, if (nzchar(t)) t else "(untitled table)")
    }
  }
  for (i in seq_along(effects)) {
    e <- effects[[i]]; med <- e$mediation %||% list()
    ind <- med$`_ind`; med$`_ind` <- NULL
    if (!is.null(ind) && !is.null(keys[[ind]])) {
      p <- keys[[ind]]
      if (length(p) == 3L) med$mediator <- p[2] else med$path <- I(p)
      e$term <- paste0("indirect: ", paste(p, collapse = " -> "))
    } else if (identical(med$effect, "indirect") && !is.null(med$mediator) && !is.null(h$x) && !is.null(h$y)) {
      short <- paste0("indirect: ", med$mediator)
      if (e$term == short || startsWith(e$term, paste0(short, " ")))
        e$term <- paste0("indirect: ", h$x, " -> ", med$mediator, " -> ", h$y, substring(e$term, nchar(short) + 1L))
    }
    if (identical(med$effect, "contrast")) {
      lab <- med$`_label` %||% ""; med$`_label` <- NULL
      d <- contrasts[[gsub("[()]", "", lab)]]
      e$term <- paste0("contrast ", lab, if (!is.null(d)) paste0(": ", d) else "")
    }
    if (!is.null(e$mediation)) e$mediation <- med
    effects[[i]] <- e
  }
  list(header = h, equations = eqs, effects = effects, tests = tests, fits = fits,
       products = products, skipped = skipped,
       conf = .proc_value_after(lines_all, "level of confidence"),
       reps = .proc_value_after(lines_all, "number of bootstrap"))
}

# ---------------------------------------------------------------- the record

.proc_checked <- c("5.0", "5.1.1")

.proc_call_text <- function(h) {
  parts <- c(sprintf("y=%s", h$y %||% "None"), sprintf("x=%s", h$x %||% "None"))
  if (length(h$mediators)) parts <- c(parts, paste0("m=", paste(h$mediators, collapse = " ")))
  for (k in c("w", "z")) if (!is.null(h[[k]])) parts <- c(parts, sprintf("%s=%s", k, h[[k]]))
  if (length(h$covariates)) parts <- c(parts, paste0("cov=", paste(h$covariates, collapse = " ")))
  parts <- c(parts, sprintf("model=%s", h$model %||% "None"))
  paste0("PROCESS ", paste(parts, collapse = " /"), ".")
}

.proc_test <- function(t) {
  t <- .est_compact(t)
  df <- t$df; df2 <- t$df2; t$df <- NULL; t$df2 <- NULL
  if (identical(t$name, "f")) t <- c(t, .est_compact(list(distribution = "F", df1 = df, df2 = df2)))
  else if (!is.null(df)) t$df <- df
  t
}

.proc_record <- function(txt, mat, call, envir, title = NULL, identifying = FALSE, digest = NULL) {
  secs <- .proc_sections_from_text(txt)
  if (!any(grepl("PROCESS Procedure for", txt, fixed = TRUE)))
    stop("the call's output isn't PROCESS's", call. = FALSE)
  secs <- .proc_full_precision(secs, mat)
  missed <- attr(secs, "missed")
  info <- .proc_interpret(secs)
  h <- info$header
  meds <- h$mediators; model <- h$model
  ydich <- any(vapply(info$tests, function(t) identical(t$name, "likelihood_ratio") && identical(t$response, h$y), logical(1)))
  responses <- unique(unlist(lapply(info$equations, `[[`, "response")))
  prods <- info$products; names(prods) <- tolower(names(prods))
  params <- lapply(info$equations, function(e) {
    p <- prods[[tolower(e$term)]]
    e$canonical <- .est_canonical(if (length(p)) paste(p, collapse = ":") else e$term)
    e
  })
  params <- c(params, lapply(info$effects, function(e) { if (is.null(e$response)) e$response <- h$y; e }))
  messages <- list()
  if (!is.null(h$version) && !h$version %in% .proc_checked)
    messages <- c(messages, list(list(level = "warning", code = "process_version_unchecked", source = "estrec",
      message = sprintf(paste0("PROCESS %s hasn't been checked with this writer (checked: %s); PROCESS changes ",
                               "its output layout between minor versions, so compare the record with PROCESS's output"),
                        h$version, paste(.proc_checked, collapse = ", ")))))
  if (missed > 0)
    messages <- c(messages, list(list(level = "info", code = "printed_precision", source = "estrec",
      message = sprintf("%d of PROCESS's printed rows didn't match its save = 2 matrix; they carry the printed decimals",
                        missed))))
  if (length(info$skipped))
    messages <- c(messages, list(list(level = "info", code = "process_sections_skipped", source = "estrec",
      message = paste("PROCESS output not recorded:", paste(info$skipped, collapse = "; ")))))
  boot <- !is.null(info$reps) && any(vapply(info$effects, function(e)
    isTRUE((e$mediation$effect %||% "") %in% c("indirect", "total_indirect", "index_moderated_mediation")), logical(1)))
  spec <- list(call = paste(deparse(call, width.cutoff = 500L), collapse = " "),
               formula = list(text = .proc_call_text(h), syntax = "PROCESS"))
  if (length(meds)) {
    mods <- unlist(lapply(c("w", "z"), function(k) h[[k]]))
    structure <- if (length(mods)) "moderated" else if (identical(model, 6L)) "serial"
                 else if (length(meds) > 1L) "parallel" else "simple"
    spec$mediation <- .est_compact(list(
      treatment = h$x, mediators = I(meds), outcome = h$y, covariates = I(h$covariates),
      moderators = if (length(mods)) I(mods), structure = structure, process_model = model,
      models = lapply(responses, function(r) list(response = r,
                                                  estimator = if (ydich && identical(r, h$y)) "logit" else "ols")),
      inference = .est_compact(list(method = if (boot) "bootstrap" else "normal",
                                    reps = if (boot) as.integer(round(info$reps)),
                                    ci_type = if (boot) "percentile", seed = h$seed))))
  }
  metrics <- list(nobs = h$nobs)
  if (!is.null(info$conf)) metrics$conf_level <- info$conf / 100
  profiles <- if (length(meds) && any(vapply(info$effects, function(e) identical(e$mediation$effect, "indirect"), logical(1))))
    "mediation/0.1" else character(0)
  estimator <- list(family = if (length(meds)) "mediation" else "moderation",
                    method = if (ydich && !length(meds)) "logit" else "ols")
  meta <- .est_compact(list(
    id = .est_uuid(), created = .est_now(), status = "ok", estimator = estimator,
    responses = if (length(responses)) I(responses), profiles = I(profiles),
    title = title %||% sprintf("PROCESS model %s", model), producer = estrec_info(),
    messages = if (length(messages)) messages))
  structures <- list()
  if (length(info$fits)) structures$equations <- list(kind = "object", per_response = lapply(
    Filter(function(f) !is.null(f$response), info$fits), function(f) {
      if (is.null(f$nobs)) f$nobs <- h$nobs
      f
    }))
  rec <- list(schema = "estrec/0.1", meta = meta, specification = spec, metrics = .est_compact(metrics),
              parameters = params)
  if (length(structures)) rec$structures <- structures
  if (length(info$tests))
    rec$tests <- lapply(seq_along(info$tests), function(i) c(list(id = paste0("t", i)), .proc_test(info$tests[[i]])))
  r <- paste(R.version$major, R.version$minor, sep = ".")
  data_arg <- call$data
  rows <- if (!is.null(data_arg)) tryCatch(nrow(eval(data_arg, envir)), error = function(e) NULL)
  rec$provenance <- list(
    software = list(
      .est_compact(list(name = "PROCESS", version = h$version, role = "estimator",
                        url = "https://www.afhayes.com/download.html",
                        command = sprintf("PROCESS model %s", model))),
      list(name = "R", version = r, purl = sprintf("pkg:generic/r@%s", r), role = "language"),
      c(estrec_info(), .est_origin("estrec"), list(role = "writer"))),
    environment = .est_environment(),
    data = list(.est_compact(list(role = "estimation", name = if (is.name(data_arg)) as.character(data_arg),
                                  rows = rows))))
  if (identifying) {
    rec$provenance$agent <- .est_agent()
    rec$provenance$execution <- list(invocation = list(argv = I(commandArgs())))
  }
  rec$history <- list(list(when = rec$meta$created, by = estrec_info(), action = "created"))
  .est_add_digest(rec, digest)
}
