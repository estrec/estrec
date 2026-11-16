# Base-R tests of new_table() and write_table() (no testthat); they need fixest.
if (!requireNamespace("fixest", quietly = TRUE)) quit(save = "no")
library(estrec)
dir <- tempfile("estrec-table-")
dir.create(file.path(dir, "records"), recursive = TRUE)
fails <- function(expr, pattern) {
  msg <- tryCatch({ expr; "" }, error = function(e) conditionMessage(e))
  stopifnot(grepl(pattern, msg))
}

f1 <- fixest::feols(mpg ~ wt | cyl, mtcars)
f2 <- fixest::feols(mpg ~ wt + hp | cyl + gear, mtcars, vcov = "hetero")
recs <- list(Base = to_estimation(f1), Full = to_estimation(f2))
for (k in names(recs)) write_estimation(recs[[k]], file.path(dir, "records", paste0(k, ".estrec.json")))

# new_table: one column per record, names as headers, FE rows, the Python reference's defaults
spec <- new_table(recs, sources = list(list(id = "r", path = "records")),
                  rows = list("wt", list(term = "hp", label = "Horsepower")),
                  head = c("label", "number"))   # headers show only with "label" in head
stopifnot(identical(spec$schema, "estrec-table/0.1"),
          grepl("^[0-9a-f]{8}-[0-9a-f]{4}-4", spec$meta$id),
          identical(vapply(spec$columns, `[[`, "", "header"), c("Base", "Full")),
          identical(vapply(spec$columns, `[[`, "", "record"),
                    unname(vapply(recs, function(r) r$meta$id, ""))),
          identical(spec$rows[[1]], list(term = "wt")),
          identical(spec$uncertainty, "std_error"),
          identical(spec$stars, list(0.1, 0.05, 0.01)),
          identical(vapply(spec$stats, function(s) s$label %||% s$metric %||% "vcov", ""),
                    c("nobs", "r2", "vcov", "FE: cyl", "FE: gear")))
stopifnot(identical(vapply(new_table(recs, headers = c("(a)", "(b)"))$columns, `[[`, "", "header"),
                    c("(a)", "(b)")),
          is.null(new_table(unname(recs))$columns[[1]]$header),
          identical(length(new_table(recs, fixed_effects = FALSE, stats = NULL)$stats), 0L),
          identical(new_table(recs, estimate = FALSE)$estimate, FALSE))
fails(new_table(list()), "a record or a list of records")
fails(new_table(recs, headers = "one"), "`headers` has 1 entries for 2 records")
if (requireNamespace("openssl", quietly = TRUE)) {
  pinned <- new_table(recs, pin = TRUE)
  stopifnot(all(grepl("^[0-9a-f]{64}$", vapply(pinned$columns, `[[`, "", "sha256"))))
}

# write_table: written, read back, and rendered from its sources
path <- file.path(dir, "t.estrec-table.json")
stopifnot(identical(write_table(spec, path), path))
back <- jsonlite::fromJSON(path, simplifyVector = FALSE)
stopifnot(identical(back$meta$id, spec$meta$id), identical(back$columns[[2]]$header, "Full"))
x <- render_table(path, output = "data.frame")
stopifnot(identical(names(x)[4:5], c("Base", "Full")), identical(back$head, list("label", "number")),
          "Horsepower" %in% x$term, "FE: gear" %in% x$term)

# a hand-written spec: schema and meta filled in; one-entry arrays stay arrays
hand <- list(columns = list(list(record = recs$Base$meta$id, source = "r")),
             sources = list(list(id = "r", path = "records")),
             head = "label", stars = 0.05, notes = "One note.", keep = "^w",
             rows = list(list(terms = "wt", label = "Weight")))
write_table(hand, path)
back <- jsonlite::fromJSON(path, simplifyVector = FALSE)
stopifnot(identical(names(back)[1:2], c("schema", "meta")),
          identical(back$schema, "estrec-table/0.1"),
          grepl("^[0-9a-f-]{36}$", back$meta$id), identical(back$meta$producer$name, "estrec"),
          # one-entry arrays read back as lists (a scalar would not)
          identical(back$head, list("label")), identical(back$stars, list(0.05)),
          identical(back$notes, list("One note.")), identical(back$keep, list("^w")),
          identical(back$rows[[1]]$terms, list("wt")))
x <- render_table(path, output = "data.frame")
stopifnot("Weight" %in% x$term)

# a spec's own meta is kept
hand$meta <- list(id = "8c0e5d1a-6b3f-4e2a-9d17-3f5a2c4b6e03", created = "2026-11-16T00:00:00Z")
write_table(hand, path)
stopifnot(identical(jsonlite::fromJSON(path)$meta$id, hand$meta$id))

fails(write_table(list(schema = "estrec/0.1", columns = list(1)), path), "not an estrec-table/0.1 spec")
fails(write_table(list(columns = list()), path), "no columns")
fails(write_table("x", path), "named list")
cat("test-write-table.R: ok\n")
