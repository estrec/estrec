# Base-R tests of render_table() (no testthat); they need modelsummary.
if (!requireNamespace("modelsummary", quietly = TRUE)) quit(save = "no")
library(estrec)
options(modelsummary_format_numeric_latex = "plain")
cells <- function(x, label) unname(unlist(x[x$term == label, setdiff(names(x), c("part", "term", "statistic"))][1, ]))

# the spec's example, as the Python reference and the browser render it
ex <- Sys.getenv("ESTREC_EXAMPLES", "../../schema/examples")
if (dir.exists(ex)) {
  x <- render_table(file.path(ex, "paper.estrec-table.json"), output = "data.frame")
  stopifnot(identical(names(x)[4:6], c("(1)", "(2)", "(3)")),
            identical(unname(unlist(x[x$part == "manual" & x$term == "", 4:6])), rep("mpg", 3)),
            identical(cells(x, "Weight (1000 lbs)"), c("-3.206***", "-3.181***", "-3.310***")),
            identical(unname(unlist(x[2, 4:6])), c("(0.754)", "(0.693)", "(1.064)")),
            identical(cells(x, "Horsepower"), c("", "-0.023**", "-0.021*")),
            identical(cells(x, "N"), c("32", "32", "32")),
            identical(cells(x, "RMSE"), c("2.392", "2.241", "2.240")),
            identical(cells(x, "Std. errors"), c("iid", "HC1", "HC1")),
            identical(cells(x, "Cylinders FE"), c("Yes", "Yes", "Yes")),
            identical(cells(x, "Wald p"), c("0.000", "0.000", "0.001")),
            identical(cells(x, "Controls"), c("No", "No", "qsec")),
            !"qsec" %in% x$term)

  # several lines under each estimate, p-value formats (the Python reference's cells)
  spec <- jsonlite::fromJSON(file.path(ex, "paper.estrec-table.json"), simplifyVector = FALSE)
  spec$uncertainty <- list("std_error", "[{p_value}]", "t = {statistic}")
  spec$format <- list(digits = 3, p_style = "less_than")
  x <- render_table(spec, output = "data.frame", base_dir = ex)
  stopifnot(identical(unname(unlist(x[1:4, 4])), c("-3.206***", "(0.754)", "[<0.001]", "t = -4.252")),
            identical(unname(unlist(x[3, 6])), "[0.004]"),
            identical(cells(x, "Wald p"), c("<0.001", "<0.001", "<0.001")))
  spec$uncertainty <- "[{p_value}]"
  for (case in list(list(f = list(), want = "[0.000]"), list(f = list(p_digits = 4), want = "[0.0002]"),
                    list(f = list(p_digits = 2, p_style = "less_than"), want = "[<0.01]"))) {
    spec$format <- c(list(digits = 3), case$f)
    stopifnot(identical(render_table(spec, output = "data.frame", base_dir = ex)[2, 4], case$want))
  }
  # heading rows: labels on top, the dependent variable renamed, none at all, a bad kind
  spec$head <- list("response", "label")
  spec$response_labels <- list(mpg = "Miles per gallon")
  x <- render_table(spec, output = "data.frame", base_dir = ex)
  stopifnot(identical(names(x)[4:6], c("Miles per gallon", "Miles per gallon ", "Miles per gallon  ")),
            identical(unname(unlist(x[x$part == "manual" & x$term == "", 4:6])), c("baseline", "horsepower", "full")))
  spec["head"] <- list(list())
  stopifnot(identical(names(render_table(spec, output = "data.frame", base_dir = ex))[4], "\u00a0"))
  spec$head <- list("number", "bogus")
  stopifnot(grepl("'bogus' is not one of", tryCatch(render_table(spec, base_dir = ex), error = conditionMessage)))
  spec$head <- NULL; spec$response_labels <- NULL
  # a sparkline line is the interval as text here
  spec$uncertainty <- list("std_error", list(sparkline = list(color = "#c0392b")))
  x <- render_table(spec, output = "data.frame", base_dir = ex)
  stopifnot(identical(unname(unlist(x[3, 4])), "[-4.750, -1.661]"))
  spec$estimate <- FALSE
  x <- render_table(spec, output = "data.frame", base_dir = ex)
  stopifnot(identical(unname(unlist(x[1:2, 4])), c("(0.754)", "[-4.750, -1.661]")), x$term[1] == "Weight (1000 lbs)")
  spec$estimate <- NULL
  spec$uncertainty <- list(sparkline = list(scale = "row"))
  stopifnot(identical(unname(unlist(render_table(spec, output = "data.frame", base_dir = ex)[2, 4])), "[-4.750, -1.661]"))
  spec$uncertainty <- list("({stderr})")
  stopifnot(grepl("unknown placeholder \\{stderr\\}", tryCatch(render_table(spec, base_dir = ex), error = conditionMessage)))
  spec$uncertainty <- NULL; spec["uncertainty"] <- list(NULL)
  x <- render_table(spec, output = "data.frame", base_dir = ex)
  stopifnot(!any(grepl("^\\(", unlist(x[x$part == "estimates", 4]))))
}

# the event-study example: no estimate rows; sparklines drawn in HTML (SVG) and LaTeX (TikZ)
# as the Python reference draws them (tests/test_table.py pins the same first cell), the
# interval as text elsewhere
if (dir.exists(ex)) {
  es <- file.path(ex, "event-study.estrec-table.json")
  x <- render_table(es, output = "data.frame")
  stopifnot(identical(x$term[1:7], c("t \u2212 3", "t \u2212 2", "t \u2212 1", "t", "t + 1", "t + 2", "t + 3")),
            all(grepl("^\\[", unlist(x[1:7, 4]))))
  t3_tikz <- paste0(
    "\\tikz[x=.75pt,y=.75pt,baseline=0pt]{\\useasboundingbox (0,-4.8) rectangle (80,11.2);",
    "\\draw[line width=.75pt,color={rgb,255:red,85;green,85;blue,85}] (59.9,-4.8) -- (59.9,11.2);",
    "\\fill[color={rgb,255:red,43;green,95;blue,142},fill opacity=.22] (60.2,3.2) .. controls (65.47,7.2)",
    " and (70.73,7.2) .. (76.0,3.2) .. controls (70.73,-0.8) and (65.47,-0.8) .. (60.2,3.2) -- cycle;",
    "\\draw[line width=.975pt,line cap=round,color={rgb,255:red,43;green,95;blue,142}] (60.2,3.2) -- (76.0,3.2);",
    "\\filldraw[fill={rgb,255:red,43;green,95;blue,142},draw=white,line width=.675pt] (60.2,3.2) circle[radius=1.425pt];",
    "\\filldraw[fill={rgb,255:red,43;green,95;blue,142},draw=white,line width=.675pt] (76.0,3.2) circle[radius=1.425pt];",
    "\\filldraw[fill={rgb,255:red,27;green,61;blue,92},draw=white,line width=.825pt] (68.1,3.2) circle[radius=2.175pt];}")
  t3_svg <- paste0(
    '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="16" viewBox="0 0 80 16" role="img"',
    ' aria-label="[0.001, 0.060]"><line x1="59.9" y1="0" x2="59.9" y2="16" stroke="#555555" stroke-width="1"/>',
    '<path d="M60.2 8.0Q68.1 2.0 76.0 8.0Q68.1 14.0 60.2 8.0Z" fill="#2b5f8e" fill-opacity="0.22"/>')
  shown <- function(output) paste(utils::capture.output(print(render_table(es, output = output), output)), collapse = "\n")
  h <- shown("html"); l <- shown("latex"); m <- shown("markdown")
  stopifnot(grepl(t3_svg, h, fixed = TRUE), lengths(regmatches(h, gregexpr("<svg xmlns", h, fixed = TRUE))) == 7L,
            grepl(t3_tikz, l, fixed = TRUE), lengths(regmatches(l, gregexpr("\\tikz[", l, fixed = TRUE))) == 7L,
            grepl("[0.001, 0.060]", m, fixed = TRUE), !grepl("tikz|<svg", m))
  f <- tempfile(fileext = ".html"); render_table(es, output = f)
  stopifnot(grepl(t3_svg, paste(readLines(f, warn = FALSE), collapse = "\n"), fixed = TRUE))
  # by row and across the table: the axes of the Python reference (each row's own, one shared)
  spec <- jsonlite::fromJSON(es, simplifyVector = FALSE)
  spec$uncertainty <- list(sparkline = list(scale = "row"))
  l <- paste(utils::capture.output(print(render_table(spec, output = "latex", base_dir = ex), "latex")), collapse = "\n")
  stopifnot(!grepl(t3_tikz, l, fixed = TRUE), grepl("(4.0,3.2) .. controls", l, fixed = TRUE))
}

# records in memory: another vcov per column, shared rows, keep/drop, uncertainty, errors
if (requireNamespace("fixest", quietly = TRUE)) {
  suppressMessages(library(fixest))
  set.seed(2); n <- 300
  d <- data.frame(id = sample(30, n, TRUE), x = rnorm(n), z = rnorm(n)); d$y <- d$x + 0.5 * d$z + rnorm(n)
  r1 <- to_estimation(feols(y ~ x, d), vcov = list("iid", "hetero"))
  r2 <- to_estimation(feols(y ~ x + z | id, d), vcov = list(~id, "iid"))
  spec <- list(schema = "estrec-table/0.1",
               meta = list(id = "8c0e5d1a-6b3f-4e2a-9d17-3f5a2c4b6e02", created = "2026-11-05T10:00:00Z"),
               columns = list(list(record = r1$meta$id, header = "A"),
                              list(record = r2$meta$id, header = "B"),
                              list(record = r2$meta$id, header = "B iid", vcov = "iid"),
                              list(record = r1$meta$id, header = "A HC1", vcov = 1L)),
               rows = list(list(terms = list("x"), label = "Treatment")),
               drop = list("^\\(Intercept\\)$"),
               stats = list(list(metric = "nobs"), list(vcov = "type"), list(vcov = "n_clusters"),
                            list(fixed_effect = "id"), list(label = "Sample", values = list("all", "all", "all", "all"))),
               stars = list(0.05, 0.01), format = list(digits = 2, fe_yes = "X"))
  x <- render_table(spec, output = "data.frame", records = list(r1, r2))
  stopifnot(identical(names(x)[4:7], c("(1)", "(2)", "(3)", "(4)")),
            identical(unname(unlist(x[x$part == "manual" & x$term == "", 4:7])), rep("y", 4)))
  spec$head <- list("label", "number")
  x <- render_table(spec, output = "data.frame", records = list(r1, r2))
  stopifnot(identical(names(x)[4:7], c("A", "B", "B iid", "A HC1")),
            identical(unname(unlist(x[x$part == "manual" & x$term == "", 4:7])), c("(1)", "(2)", "(3)", "(4)")),
            identical(x$term[x$part == "estimates"], c("Treatment", "Treatment", "z", "z")),
            identical(cells(x, "Std. errors"), c("iid", "by: id", "iid", "HC1")),
            identical(cells(x, "Clusters"), c("", "30", "", "")),
            identical(cells(x, "FE: id"), c("", "X", "X", "")),
            identical(cells(x, "Sample"), rep("all", 4)),
            identical(cells(x, "N"), rep("300", 4)))
  se <- function(col) as.numeric(gsub("[()]", "", x[2, col]))
  stopifnot(abs(se("B iid") - round(sqrt(vcov(feols(y ~ x + z | id, d), vcov = "iid")["x", "x"]), 2)) < 1e-12,
            abs(se("A HC1") - round(sqrt(vcov(feols(y ~ x, d), vcov = "hetero")["x", "x"]), 2)) < 1e-12)
  # intervals and no stars
  spec2 <- modifyList(spec, list(uncertainty = "conf_int", stars = NULL))
  x2 <- render_table(spec2, output = "data.frame", records = list(r1, r2))
  stopifnot(grepl("^\\[-?[0-9.]+, -?[0-9.]+\\]$", x2[2, 4]), !grepl("\\*", x2[1, 4]))
  # errors: a missing record, a text row of the wrong length, an unknown source
  bad <- spec; bad$columns[[1]]$record <- "missing"
  stopifnot(grepl("not found", tryCatch(render_table(bad, records = list(r1, r2)), error = conditionMessage)))
  bad <- spec; bad$stats[[5]]$values <- list("a")
  stopifnot(grepl("1 values for 4", tryCatch(render_table(bad, records = list(r1, r2)), error = conditionMessage)))
  bad <- spec; bad$columns[[1]]$source <- "nowhere"
  stopifnot(grepl("no source", tryCatch(render_table(bad, records = list(r1, r2)), error = conditionMessage)))
}
cat("test-table: ok\n")
