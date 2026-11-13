# Collections (spec section 11): a set of records written as one estrec-collection file,
# and to_estimation() for a plain list of fits.

# A list of fits (or records) -> a flat list of records. A fixest_multi contributes one record
# per model; its records are named <name>.1, <name>.2, ... (or by the multi's own names when
# the element has no name). A record passes through unchanged.
to_estimation.list <- function(fit, ...) {
  if (is_estimation_record(fit)) return(fit)
  nm <- names(fit)
  if (is.null(nm)) nm <- rep("", length(fit))
  out <- list(); labs <- character()
  for (i in seq_along(fit)) {
    r <- if (is_estimation_record(fit[[i]])) list(fit[[i]]) else to_estimation(fit[[i]], ...)
    if (is_estimation_record(r)) r <- list(r)
    k <- length(r)
    inner <- names(r)
    lab <- if (k == 1L) nm[i]
           else if (nzchar(nm[i])) paste0(nm[i], ".", seq_len(k))
           else if (!is.null(inner)) inner
           else rep("", k)
    out <- c(out, unname(r)); labs <- c(labs, lab)
  }
  if (any(nzchar(labs))) names(out) <- labs
  out
}

# Write records as one collection. `x` is a list of fits or records (as for to_estimation),
# or one fit; `labels` name the members, `locators` say where each appears in `publication`.
write_collection <- function(x, path, kind = c("paper", "session", "replication", "batch", "other"),
                             labels = NULL, locators = NULL, publication = NULL,
                             session = NULL, events = NULL, provenance = NULL, title = NULL,
                             notes = NULL, tags = NULL, members = c("embed", "jsonl"),
                             hash = NULL, level = NULL, ...) {
  kind <- match.arg(kind)
  members <- match.arg(members)
  only_records <- is_estimation_record(x) ||
    (is.list(x) && length(x) && all(vapply(x, is_estimation_record, logical(1))))
  # fits are written at `level` (default 4); records given as they are unless `level` is set
  if (!only_records || !is.null(level)) level <- .est_resolve_level(level, NULL)
  need <- .est_levels()$min_by_kind[[kind]]
  if (!is.null(level) && !is.null(need) && level < need)
    stop("a ", kind, " collection needs disclosure level ", need, " or more, not ", level, call. = FALSE)
  recs <- if (is_estimation_record(x)) list(x)
          else if (only_records) x
          else to_estimation(x, level = level, ...)
  if (is_estimation_record(recs)) recs <- list(recs)
  if (is.null(labels)) labels <- names(recs)
  recs <- lapply(recs, .est_plain)
  if (!is.null(level)) {
    old <- vapply(recs, function(r) as.character(r$meta$id), "")
    recs <- lapply(recs, .est_reduce, level = level)
    new <- vapply(recs, function(r) as.character(r$meta$id), "")
    if (!is.null(events)) events <- lapply(events, function(e) {
      if (!is.null(e$member) && e$member %in% old) e$member <- new[match(e$member, old)]
      e
    })
  }
  n <- length(recs)
  if (!is.null(labels) && length(labels) != n)
    stop("`labels` has ", length(labels), " entries for ", n, " records", call. = FALSE)
  if (!is.null(locators) && length(locators) != n)
    stop("`locators` has ", length(locators), " entries for ", n, " records", call. = FALSE)
  if (is.null(hash)) {
    hash <- requireNamespace("openssl", quietly = TRUE)
    if (!hash) message("member sha256 left out: install the 'openssl' package to write them")
  } else if (isTRUE(hash) && !requireNamespace("openssl", quietly = TRUE)) {
    stop("hash = TRUE needs the 'openssl' package", call. = FALSE)
  }
  ids <- vapply(recs, function(r) as.character(r$meta$id), "")
  if (anyDuplicated(ids))
    stop("a record appears more than once: one member per record, with several locators",
         call. = FALSE)

  entries <- lapply(seq_len(n), function(i) {
    r <- recs[[i]]
    lab <- if (!is.null(labels) && !is.na(labels[i]) && nzchar(labels[i])) labels[[i]]
    .est_compact(c(list(id = r$meta$id, created = r$meta$created, label = lab),
                   .est_locator_fields(if (!is.null(locators)) locators[[i]]),
                   list(sha256 = if (hash) .est_sha256(.est_canonical_json(r)))))
  })

  coll <- .est_compact(list(
    schema = "estrec-collection/0.1",
    meta = .est_compact(list(id = .est_uuid(), created = .est_now(), kind = kind,
                             title = title, tags = if (!is.null(tags)) I(tags), notes = notes,
                             producer = estrec_info(),
                             disclosure = if (!is.null(level)) list(level = as.integer(level)))),
    publication = publication, session = session, provenance = provenance,
    members = NULL, events = if (!is.null(events)) I(events)))
  if (!is.null(level)) {
    # the collection's own fields above the level (session times, clients, worker events, ...)
    coll <- .est_apply_level(coll, level, .est_levels()$collection_marks)$record
    if (level == 1L) coll$meta$created <- substr(coll$meta$created, 1L, 10L)
  }
  entry <- list(when = if (identical(level, 1L)) substr(.est_now(), 1L, 10L) else .est_now())
  if (is.null(level) || level >= 4L) entry$by <- estrec_info()
  entry$action <- "created"
  if (!is.null(level)) entry$level <- as.integer(level)
  coll$history <- list(entry)
  embedded <- coll
  embedded$members <- I(Map(function(e, r) c(e, list(record = r)), entries, unname(recs)))
  embedded <- embedded[c(setdiff(names(embedded), c("members", "events", "history")),
                         intersect(c("members", "events", "history"), names(embedded)))]
  json <- .est_json(embedded, pretty = TRUE)
  if (members == "embed" && nchar(json, type = "bytes") > 16e6) {
    message("the collection would pass 16 MB: its records go to a members file")
    members <- "jsonl"
  }
  paths <- path
  if (members == "jsonl") {
    stem <- sub("(\\.estrec-collection)?\\.json$", "", basename(path))
    file <- file.path(dirname(path), paste0(stem, ".members.jsonl"))
    lines <- vapply(recs, function(r) .est_json(r), "")
    con <- file(file, open = "wb")
    writeLines(enc2utf8(lines), con, useBytes = TRUE)
    close(con)
    att <- .est_compact(list(id = "members", role = "members", path = basename(file),
                             media_type = "application/jsonl", created = .est_now(),
                             sha256 = if (hash) .est_sha256_file(file),
                             bytes = file.size(file), rows = n))
    embedded$members <- I(lapply(entries, function(e) c(e, list(attachment = "members"))))
    embedded$attachments <- I(list(att))
    json <- .est_json(embedded, pretty = TRUE)
    paths <- c(path, file)
  }
  con <- file(path, open = "wb")
  writeLines(enc2utf8(json), con, useBytes = TRUE)
  close(con)
  invisible(paths)
}

# A member's locator from a label string, a locator list, or a list of locator lists
.est_locator_fields <- function(loc) {
  if (is.null(loc) || (is.atomic(loc) && length(loc) == 1L && is.na(loc))) return(list())
  if (is.character(loc)) {
    locs <- lapply(loc, function(s) list(label = s))
  } else if (is.list(loc) && !is.null(names(loc))) {
    locs <- list(loc)
  } else {
    locs <- lapply(loc, function(l) if (is.character(l)) list(label = l) else l)
  }
  if (!length(locs)) list()
  else if (length(locs) == 1L) list(locator = locs[[1]])
  else list(locators = I(locs))
}

# JSON as write_estimation writes it (17 significant digits, NULL and NA as null)
.est_json <- function(x, pretty = FALSE) {
  as.character(jsonlite::toJSON(x, auto_unbox = TRUE, digits = I(17), null = "null",
                                na = "null", pretty = pretty))
}

# RFC 8785 canonical JSON of a record as it is written: serialised with the writer's options,
# read back, then canonicalised, so the hash matches what a reader of the file computes
.est_canonical_json <- function(x) {
  .est_jcs(jsonlite::fromJSON(.est_json(x), simplifyVector = FALSE))
}

.est_jcs <- function(x) {
  if (is.null(x)) return("null")
  if (is.list(x)) {
    if (!is.null(names(x))) {
      keys <- names(x)
      ord <- order(vapply(keys, .est_utf16_key, ""), method = "radix")
      return(paste0("{", paste0(vapply(ord, function(i)
        paste0(.est_json_string(keys[i]), ":", .est_jcs(x[[i]])), ""), collapse = ","), "}"))
    }
    return(paste0("[", paste0(vapply(x, .est_jcs, ""), collapse = ","), "]"))
  }
  if (length(x) != 1L) stop("canonical JSON: unexpected vector of length ", length(x))
  if (is.logical(x)) return(if (is.na(x)) "null" else if (x) "true" else "false")
  if (is.character(x)) return(.est_json_string(x))
  if (is.integer(x)) return(as.character(x))
  if (is.numeric(x)) return(.est_es_number(x))
  stop("canonical JSON: can't encode ", class(x)[1])
}

# Keys sort by their UTF-16 code units: each unit as 4 hex digits sorts the same way
.est_utf16_key <- function(s) {
  cp <- utf8ToInt(enc2utf8(s))
  units <- unlist(lapply(cp, function(c) {
    if (c < 0x10000) c else { c <- c - 0x10000; c(0xD800 + c %/% 0x400, 0xDC00 + c %% 0x400) }
  }))
  paste(sprintf("%04x", units), collapse = "")
}

.est_json_string <- function(s) {
  s <- enc2utf8(s)
  cp <- utf8ToInt(s)
  if (!any(cp < 0x20 | cp == 0x22 | cp == 0x5C)) return(paste0("\"", s, "\""))
  short <- c("8" = "\\b", "9" = "\\t", "10" = "\\n", "12" = "\\f", "13" = "\\r",
             "34" = "\\\"", "92" = "\\\\")
  out <- vapply(cp, function(c) {
    k <- as.character(c)
    if (!is.na(short[k])) short[[k]]
    else if (c < 0x20) sprintf("\\u%04x", c)
    else intToUtf8(c)
  }, "")
  paste0("\"", paste0(out, collapse = ""), "\"")
}

# ECMAScript Number.prototype.toString (RFC 8785): the shortest digits that round-trip, in
# fixed notation from 1e-6 to below 1e21, else in exponent form
.est_es_number <- function(x) {
  if (!is.finite(x)) stop("non-finite number in canonical JSON")
  if (x == 0) return("0")
  sign <- if (x < 0) "-" else ""
  a <- abs(x)
  # the candidates are parsed by jsonlite (C strtod): R's own parser misrounds some of them
  # (as.numeric("1.366494285446904e+27") is one ulp off)
  cand <- sprintf("%.*e", 0:16, a)
  s <- cand[which(jsonlite::fromJSON(paste0("[", paste(cand, collapse = ","), "]")) == a)[1]]
  parts <- strsplit(s, "e", fixed = TRUE)[[1]]
  digits <- sub("0+$", "", gsub(".", "", parts[1], fixed = TRUE))
  if (!nzchar(digits)) digits <- "0"
  n <- as.integer(parts[2]) + 1L  # the decimal point comes after n digits
  k <- nchar(digits)
  if (k <= n && n <= 21) return(paste0(sign, digits, strrep("0", n - k)))
  if (0 < n && n <= 21) return(paste0(sign, substr(digits, 1, n), ".", substr(digits, n + 1, k)))
  if (-6 < n && n <= 0) return(paste0(sign, "0.", strrep("0", -n), digits))
  e <- n - 1L
  frac <- if (k > 1) paste0(".", substr(digits, 2, k)) else ""
  paste0(sign, substr(digits, 1, 1), frac, "e", if (e > 0) "+" else "-", abs(e))
}

# openssl's hashes keep their class through as.character(), which jsonlite can't write
.est_sha256 <- function(text) {
  as.vector(unclass(as.character(openssl::sha256(charToRaw(enc2utf8(text))))))
}

.est_sha256_file <- function(path) {
  con <- file(path, open = "rb")
  on.exit(close(con))
  as.vector(unclass(as.character(openssl::sha256(con))))
}
