# Word files (.docx) of a table, written as the Python reference's render(t, "docx") and the
# browser viewer's Save .docx write them: the same WordprocessingML, rules, widths and
# sparklines as Word drawing shapes, byte for byte in word/document.xml. render_table() builds
# the table the Python reference's build_table() builds (.tab_built) and this file writes it.

# ------------------------------------------------------------------ the built table

# A sparkline line's settings with the defaults filled in (spec/table.md 5), or NULL for a
# text line.
.tab_spark_line <- function(x) {
  if (!is.list(x) || !identical(names(x), "sparkline")) return(NULL)
  s <- x$sparkline
  list(color = s$color %||% .tab_spark_color, scale = s$scale %||% "column",
       place = s$place %||% "below", align = s$align %||% "estimate")
}

# Each sparkline mark's axis, [lo, hi], always holding 0: shared down a column, along a row or
# across the block (the line's scale), as the Python reference's _spark_domains. A mark with
# no interval (a term the column lacks) takes its group's axis, for its 0 rule; in a group
# with no intervals it is left out (NULL).
.tab_spark_domains <- function(rows) {
  groups <- list()
  for (i in seq_along(rows)) {
    sp <- rows[[i]]$sparkline
    if (is.null(sp)) next
    for (j in seq_along(sp$marks)) {
      if (is.null(sp$marks[[j]])) next
      key <- paste(sp$scale, switch(sp$scale, column = j, row = i, table = 0))
      groups[[key]] <- c(groups[[key]], list(c(i, j)))
    }
  }
  for (g in groups) {
    real <- Filter(function(ij) !is.null(rows[[ij[1]]]$sparkline$marks[[ij[2]]]$estimate), g)
    if (!length(real)) {
      for (ij in g) rows[[ij[1]]]$sparkline$marks[ij[2]] <- list(NULL)
      next
    }
    lo <- min(0, vapply(real, function(ij) rows[[ij[1]]]$sparkline$marks[[ij[2]]]$low, 0))
    hi <- max(0, vapply(real, function(ij) rows[[ij[1]]]$sparkline$marks[[ij[2]]]$high, 0))
    if (lo == hi) { lo <- -1; hi <- 1 }
    for (ij in g) rows[[ij[1]]]$sparkline$marks[[ij[2]]]$domain <- c(lo, hi)
  }
  rows
}

# A block's rows (the estimates' and its statistics') from modelsummary's data frame `df`,
# as the Python reference's built table has them: a term's first row is its "estimate" row
# with the label, the others "uncertainty" rows; a sparkline line's row also carries its
# marks, from the columns' tidies.
.tab_block_rows <- function(df, n, nstat, tidies, coef_map, unc, shows_est) {
  cells <- as.matrix(df[, 3 + seq_len(n), drop = FALSE])
  items <- if (is.null(unc)) list() else if (is.list(unc) && !is.null(names(unc))) list(unc) else as.list(unc)
  sparks <- lapply(items, .tab_spark_line)
  est <- which(df$part == "estimates")
  rows <- list()
  prev <- NULL
  for (r in est) {
    label <- df$term[r]
    st <- df$statistic[r]
    k <- if (identical(st, "estimate")) (if (shows_est) 0L else 1L) else as.integer(gsub("[^0-9]", "", st))
    first <- !identical(label, prev) || identical(st, "estimate")
    prev <- label
    row <- list(label = if (first) label else "", cells = unname(cells[r, ]), kind = if (first) "estimate" else "uncertainty")
    sp <- if (k >= 1L && k <= length(sparks)) sparks[[k]] else NULL
    if (!is.null(sp)) {
      names_ <- names(coef_map)[coef_map == label]
      sp$marks <- lapply(seq_len(n), function(j) {
        t <- tidies[[j]]
        at <- match(names_, t$term)
        at <- at[!is.na(at)]
        if (!length(at)) return(list())  # the column lacks the term: its 0 rule only
        v <- c(t$conf.low[at[1]], t$estimate[at[1]], t$conf.high[at[1]])
        if (length(v) != 3L || !all(is.finite(v))) return(NULL)
        list(low = v[1], estimate = v[2], high = v[3])
      })
      row$sparkline <- sp
    }
    rows <- c(rows, list(row))
  }
  rows <- .tab_spark_domains(rows)
  manual <- which(df$part == "manual")
  for (r in utils::tail(manual, nstat))
    rows <- c(rows, list(list(label = df$term[r], cells = unname(cells[r, ]), kind = "stat")))
  rows
}

# The heading rows as the Python reference's _head_rows: kind, cells and, for column groups,
# spans (columns counted from 0).
.tab_head_rows <- function(spec, cols, found, tidies) {
  groups <- spec$spanners %||% list()
  kinds <- if ("head" %in% names(spec)) as.character(unlist(spec$head))
           else c(if (length(groups)) "spanner", "number", "response")
  .tab_head(spec, cols, found, tidies)  # checks `head`
  out <- list()
  for (k in kinds) {
    if (k == "spanner") {
      if (!length(groups)) next
      n <- length(cols)
      cl <- rep("", n)
      gs <- groups[order(vapply(groups, function(g) as.numeric(g$columns[[1]]), 0))]
      spans <- lapply(gs, function(g) {
        first <- as.integer(g$columns[[1]]) - 1L; last <- as.integer(g$columns[[2]]) - 1L
        cl[first + 1L] <<- g$label
        list(label = g$label, first = first, last = last)
      })
      out <- c(out, list(list(kind = "spanner", cells = cl, spans = spans)))
      next
    }
    one <- spec; one$head <- list(k)
    cells <- .tab_head(one, cols, found, tidies)  # a response or label row blank in every column goes
    if (length(cells)) out <- c(out, list(list(kind = k, cells = cells[[1]])))
  }
  out
}

# the stars' note: "* p < 0.1, ** p < 0.05, *** p < 0.01", and where the stars' p-values
# come from when not the coefficients' own
.tab_stars_note <- function(spec, views) {
  stars <- unlist(spec$stars)
  sym <- unlist((spec$format %||% list())$star_symbols) %||% strrep("*", seq_along(stars))
  paste0(paste(sprintf("%s p < %s", sym, format(stars, scientific = FALSE, drop0trailing = TRUE, trim = TRUE)), collapse = ", "),
         .tab_sig_note(views))
}

# ------------------------------------------------------------------ the Word file

.dx_xml <- '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
.dx_ns <- paste(
  'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
  'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"',
  'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
  'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
  'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
  'xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
  'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"')
# line widths in EMU: 1, 1.3, 0.9, 1.1 and 1.2 px, rounded half up
.dx_w <- c(rule = 9525, line = 12383, end = 8573, est = 10478, ring = 11430)
.spark_w <- 80L
.spark_h <- 16L

.dx_i <- function(x) sprintf("%.0f", x)

# text for XML: escaped, without the control characters XML 1.0 forbids
.dx <- function(s) {
  s <- gsub("[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f]", "", s, perl = TRUE)
  s <- gsub("&", "&amp;", s, fixed = TRUE); s <- gsub("<", "&lt;", s, fixed = TRUE)
  s <- gsub(">", "&gt;", s, fixed = TRUE); gsub("\"", "&quot;", s, fixed = TRUE)
}

.dx_ln <- function(w, color, cap = FALSE) {
  if (is.null(color)) return("<a:ln><a:noFill/></a:ln>")
  paste0('<a:ln w="', .dx_i(w), '"', if (cap) ' cap="rnd"', '><a:solidFill><a:srgbClr val="', color, '"/></a:solidFill></a:ln>')
}

.dx_fill <- function(color, alpha = 0) {
  if (is.null(color)) return("<a:noFill/>")
  paste0('<a:solidFill><a:srgbClr val="', color, '">', if (alpha) paste0('<a:alpha val="', .dx_i(alpha), '"/>'), "</a:srgbClr></a:solidFill>")
}

# one mark as a shape covering the whole drawing, the mark a path in its child coordinates
.dx_shape <- function(n, w, h, path, fill, ln, filled = TRUE) {
  paste0('<wps:wsp><wps:cNvPr id="', n, '" name="Shape ', n, '"/><wps:cNvSpPr/><wps:spPr>',
         '<a:xfrm><a:off x="0" y="0"/><a:ext cx="', .dx_i(w), '" cy="', .dx_i(h), '"/></a:xfrm>',
         '<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l="0" t="0" r="r" b="b"/>',
         '<a:pathLst><a:path w="', .dx_i(w), '" h="', .dx_i(h), '"', if (!filled) ' fill="none"', ">", path, "</a:path></a:pathLst>",
         "</a:custGeom>", fill, ln, "</wps:spPr><wps:bodyPr/></wps:wsp>")
}

.dx_pt <- function(x, y) paste0('<a:pt x="', .dx_i(x), '" y="', .dx_i(y), '"/>')
.dx_segment <- function(x1, y1, x2, y2) paste0("<a:moveTo>", .dx_pt(x1, y1), "</a:moveTo><a:lnTo>", .dx_pt(x2, y2), "</a:lnTo>")
.dx_circle <- function(x, y, r)
  paste0("<a:moveTo>", .dx_pt(x + r, y), "</a:moveTo>", '<a:arcTo wR="', r, '" hR="', r, '" stAng="0" swAng="21600000"/><a:close/>')

# where v falls across a drawing `width` pixels wide, in tenths of a pixel, rounded half up
.dx_x <- function(m, v, width) {
  lo <- m$domain[1]; hi <- m$domain[2]
  pad <- 4
  floor((pad + (v - lo) / (hi - lo) * (width - 2 * pad)) * 10 + 0.5)
}

# a sparkline as an inline group of DrawingML shapes (a run); `ids` holds the document's
# last drawing id
.dx_spark <- function(ids, m, color, label, height = .spark_h, mid = NULL, rule_only = FALSE, width = .spark_w) {
  if (is.null(m)) return("")
  if (is.null(m$estimate) && !isTRUE(m$reference)) rule_only <- TRUE
  nid <- function() { ids$n <- ids$n + 1L; ids$n }
  frame <- nid()
  ww <- width * 10; hh <- height * 10
  y <- if (is.null(mid)) height * 5 else mid
  lc <- toupper(substring(color, 2)); d <- toupper(substring(.tab_dark(color), 2))
  x0 <- .dx_x(m, 0, width)
  shape <- function(path, fill, ln, filled = TRUE) .dx_shape(nid(), ww, hh, path, fill, ln, filled)
  dot <- function(x, r, fill, w, line) shape(.dx_circle(x, y, r), .dx_fill(fill), .dx_ln(w, line))
  shapes <- shape(.dx_segment(x0, 0, x0, hh), .dx_fill(NULL), .dx_ln(.dx_w[["rule"]], "555555"), filled = FALSE)
  if (!rule_only && !is.null(m$estimate)) {
    xl <- .dx_x(m, m$low, width); xe <- .dx_x(m, m$estimate, width); xh <- .dx_x(m, m$high, width)
    if (xh > xl) {
      band <- paste0("<a:moveTo>", .dx_pt(xl, y), "</a:moveTo>",
                     "<a:quadBezTo>", .dx_pt(xe, y - 60), .dx_pt(xh, y), "</a:quadBezTo>",
                     "<a:quadBezTo>", .dx_pt(xe, y + 60), .dx_pt(xl, y), "</a:quadBezTo><a:close/>")
      shapes <- c(shapes, shape(band, .dx_fill(lc, 22000), .dx_ln(0, NULL)))
    }
    shapes <- c(shapes, shape(.dx_segment(xl, y, xh, y), .dx_fill(NULL), .dx_ln(.dx_w[["line"]], lc, cap = TRUE), filled = FALSE),
                dot(xl, 19, lc, .dx_w[["end"]], "FFFFFF"), dot(xh, 19, lc, .dx_w[["end"]], "FFFFFF"),
                dot(xe, 29, d, .dx_w[["est"]], "FFFFFF"))
  } else if (!rule_only) {
    shapes <- c(shapes, dot(x0, 26, "FFFFFF", .dx_w[["ring"]], d))
  }
  ex <- width * 9525; ey <- height * 9525
  descr <- if (rule_only) "" else .dx(if (nzchar(label)) label else if (isTRUE(m$reference)) "reference or omitted" else "")
  paste0('<w:r><mc:AlternateContent><mc:Choice Requires="wpg"><w:drawing>',
         '<wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="', .dx_i(ex), '" cy="', .dx_i(ey), '"/>',
         '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
         '<wp:docPr id="', frame, '" name="Sparkline ', frame, '" descr="', descr, '"/><wp:cNvGraphicFramePr/>',
         '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
         "<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr>",
         '<a:xfrm><a:off x="0" y="0"/><a:ext cx="', .dx_i(ex), '" cy="', .dx_i(ey), '"/>',
         '<a:chOff x="0" y="0"/><a:chExt cx="', .dx_i(ww), '" cy="', .dx_i(hh), '"/></a:xfrm></wpg:grpSpPr>',
         paste(shapes, collapse = ""),
         "</wpg:wgp></a:graphicData></a:graphic></wp:inline></w:drawing></mc:Choice>",
         "<mc:Fallback/></mc:AlternateContent></w:r>")
}

# a paragraph: `runs` (XML) at `sz` half-points
.dx_p <- function(runs, sz, align = "left", before = 0, after = 0, bold = FALSE) {
  rpr <- paste0("<w:rPr>", if (bold) "<w:b/>", '<w:sz w:val="', sz, '"/><w:szCs w:val="', sz, '"/></w:rPr>')
  paste0('<w:p><w:pPr><w:spacing w:before="', before, '" w:after="', after, '"/><w:jc w:val="', align, '"/>', rpr, "</w:pPr>",
         runs, "</w:p>")
}

.dx_run <- function(text, sz, bold = FALSE, italic = FALSE) {
  if (!nzchar(text)) return("")
  paste0("<w:r><w:rPr>", if (bold) "<w:b/>", if (italic) "<w:i/>", '<w:sz w:val="', sz, '"/><w:szCs w:val="', sz,
         '"/></w:rPr><w:t xml:space="preserve">', .dx(text), "</w:t></w:r>")
}

# a cell: `width` twips (NULL: auto), borders in eighths of a point, `mar` (top, left, right)
# margins in twips instead of the table's
.dx_tc <- function(body, width, span = 1, vmerge = "", top = 0, bottom = 0, mar = NULL, valign = "center") {
  pr <- if (!is.null(width)) paste0('<w:tcW w:w="', .dx_i(width), '" w:type="dxa"/>') else '<w:tcW w:w="0" w:type="auto"/>'
  if (span > 1) pr <- paste0(pr, '<w:gridSpan w:val="', span, '"/>')
  if (nzchar(vmerge)) pr <- paste0(pr, if (vmerge == "restart") '<w:vMerge w:val="restart"/>' else "<w:vMerge/>")
  if (top || bottom) {
    pr <- paste0(pr, "<w:tcBorders>",
                 if (top) paste0('<w:top w:val="single" w:sz="', top, '" w:space="0" w:color="auto"/>'),
                 if (bottom) paste0('<w:bottom w:val="single" w:sz="', bottom, '" w:space="0" w:color="auto"/>'),
                 "</w:tcBorders>")
  }
  pr <- paste0(pr, "<w:noWrap/>")
  if (!is.null(mar))
    pr <- paste0(pr, '<w:tcMar><w:top w:w="', .dx_i(mar[1]), '" w:type="dxa"/><w:left w:w="', .dx_i(mar[2]),
                 '" w:type="dxa"/><w:right w:w="', .dx_i(mar[3]), '" w:type="dxa"/></w:tcMar>')
  paste0("<w:tc><w:tcPr>", pr, '<w:vAlign w:val="', valign, '"/></w:tcPr>', body, "</w:tc>")
}

.dx_rule <- function(pt) if (identical(pt, "1.5pt")) 12L else if (identical(pt, ".75pt")) 6L else 0L

# How a table with a sparkline beside the estimates is laid out, as the Python reference's
# _beside_plan, with rows counted from 1: start[[row]] = (drawn row, rows spanned, block end
# + 1), skip (rows drawn beside), inside[[row]] = drawn row, label[[row]] (from a skipped
# first row). NULL without such a line.
.tab_beside_plan <- function(rows) {
  side_of <- function(r) identical((r$sparkline %||% list())$place, "beside")
  b <- vapply(rows, side_of, TRUE)
  if (!any(b)) return(NULL)
  plan <- list(align = rows[[which(b)[1]]]$sparkline$align %||% "estimate", start = list(), skip = integer(), inside = list(), label = list())
  i <- 1L
  while (i <= length(rows)) {
    if (rows[[i]]$kind %in% c("stat", "panel")) { i <- i + 1L; next }
    j <- i + 1L
    while (j <= length(rows) && rows[[j]]$kind == "uncertainty") j <- j + 1L
    ks <- i:(j - 1L)
    side <- ks[b[ks]]; rest <- ks[!b[ks]]
    if (length(side) && length(rest)) {
      plan$start[[as.character(rest[1])]] <- c(side[1], length(rest), j)
      plan$skip <- c(plan$skip, side[1])
      for (k in rest[-1]) plan$inside[[as.character(k)]] <- side[1]
      if (side[1] == i) plan$label[[as.character(rest[1])]] <- rows[[i]]$label
    }
    i <- j
  }
  plan
}

.tab_row_kind <- function(rows, plan, i) if (!is.null(plan) && !is.null(plan$label[[as.character(i)]])) "estimate" else rows[[i]]$kind

# Column widths for a table `width` inches wide, in tenths of a point (the Python
# reference's _word_widths)
.tab_word_widths <- function(t, plan, width, font) {
  total <- floor(width * 720 + 0.5)
  n <- length(t$header)
  rows <- t$rows
  lab <- max(c(vapply(rows, function(r) nchar(r$label), 0L), 0L))
  label <- min(max(floor(font * 5 + 0.5) * lab + 108, 360), (total * 2) %/% 5)
  col <- (total - label) %/% n
  out <- list(total = total, label = total - col * n, col = col, below_px = max(((col - 108) * 4) %/% 30, 1))
  if (!is.null(plan)) {
    at <- c(as.integer(names(plan$start)), as.integer(names(plan$inside)))
    numc <- max(c(unlist(lapply(rows[at], function(r) nchar(r$cells))), 0L))
    num <- if (col >= 440) min(max(floor(font * 5.5 + 0.5) * numc + 108, 200), col - 240) else col %/% 2
    out$num <- num; out$side <- col - num; out$side_px <- max(((col - num) * 4) %/% 30, 1)
  }
  out
}

# a spanner row as (label, columns spanned) cells left to right
.tab_spanner_cells <- function(h, n) {
  starts <- list()
  for (g in h$spans) starts[[as.character(g$first)]] <- g
  out <- list(); j <- 0L
  while (j < n) {
    g <- starts[[as.character(j)]]
    if (!is.null(g)) { out <- c(out, list(list(g$label, g$last - g$first + 1L))); j <- g$last + 1L }
    else { out <- c(out, list(list("", 1L))); j <- j + 1L }
  }
  out
}

.tab_docx_document <- function(t, width = NULL, font = 10, term_space = NULL) {
  rows <- t$rows
  plan <- .tab_beside_plan(rows)
  sz <- floor(font * 2 + 0.5)
  line_px <- floor(font * 1.6 + 0.5)
  if (is.null(term_space)) term_space <- !any(vapply(rows, function(r) !is.null(r$sparkline), TRUE))
  pad_px <- if (term_space) floor(font * 0.4 + 0.5) else 0
  W <- if (!is.null(width)) .tab_word_widths(t, plan, width, font)
  spw <- if (!is.null(W)) W$below_px else .spark_w
  sidew <- if (!is.null(W) && !is.null(plan)) W$side_px else .spark_w
  n <- length(t$header)
  if (!is.null(W)) {
    grid <- c(W$label, rep(if (!is.null(plan)) c(W$num, W$side) else W$col, n))
  } else {  # a guide for the autofit table: about 5 pt a character, the drawings' width
    lab <- max(c(vapply(rows, function(r) nchar(r$label), 0L), 0L))
    numc <- max(c(unlist(lapply(c(rows, t$head), function(r) nchar(r$cells))), 0L))
    num <- max(floor(font * 5.5 + 0.5) * numc + 108, 200)
    if (any(vapply(rows, function(r) !is.null(r$sparkline) && !identical(r$sparkline$place, "beside"), TRUE)))
      num <- max(num, (.spark_w * 15) %/% 2 + 108)
    grid <- c(max(floor(font * 5 + 0.5) * lab + 108, 360), rep(if (!is.null(plan)) c(num, (.spark_w * 15) %/% 2) else num, n))
  }
  grid <- grid * 2  # tenths of a point -> twips
  tw <- function(k, span = 1) if (!is.null(W)) sum(grid[k + seq_len(span)])  # k counted from 0
  ids <- new.env(); ids$n <- 0L
  body <- character()
  if (length(t$title) && nzchar(t$title)) body <- c(body, .dx_p(.dx_run(t$title, sz, bold = TRUE), sz, after = 120, bold = TRUE))
  total <- sum(grid)
  tblw <- if (!is.null(W)) paste0('<w:tblW w:w="', .dx_i(total), '" w:type="dxa"/>') else '<w:tblW w:w="0" w:type="auto"/>'
  out <- paste0("<w:tbl><w:tblPr>", tblw, if (!is.null(W)) '<w:tblLayout w:type="fixed"/>',
                '<w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>',
                '<w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar>',
                '<w:tblLook w:val="0000" w:firstRow="0" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="1" w:noVBand="1"/>',
                "</w:tblPr><w:tblGrid>", paste0('<w:gridCol w:w="', .dx_i(grid), '"/>', collapse = ""), "</w:tblGrid>")
  per <- if (!is.null(plan)) 2L else 1L
  nh <- length(t$head)
  for (k in seq_len(nh)) {
    hr <- t$head[[k]]
    top <- if (k == 1L) 12L else 0L
    bottom <- if (k == nh) 6L else 0L
    cells <- .dx_tc(.dx_p("", sz), width = tw(0), top = top, bottom = bottom)
    if (hr$kind == "spanner") {
      col <- 1L
      for (lk in .tab_spanner_cells(hr, n)) {
        span <- lk[[2]] * per
        cells <- c(cells, .dx_tc(.dx_p(.dx_run(lk[[1]], sz), sz, "center"), width = tw(col, span), span = span, top = top,
                                 bottom = if (nzchar(lk[[1]]) || bottom) 6L else 0L))
        col <- col + span
      }
    } else {
      for (j in seq_along(hr$cells))
        cells <- c(cells, .dx_tc(.dx_p(.dx_run(hr$cells[[j]], sz), sz, "center"), width = tw(1 + per * (j - 1L), per),
                                 span = per, top = top, bottom = bottom))
    }
    out <- c(out, paste0("<w:tr><w:trPr><w:cantSplit/><w:tblHeader/></w:trPr>", paste(cells, collapse = ""), "</w:tr>"))
  }
  prev <- NULL
  last <- length(rows)
  shown <- setdiff(seq_along(rows), if (!is.null(plan)) plan$skip)
  first <- if (length(shown)) shown[1] else 1L
  pads <- function(i) pad_px > 0 && .tab_row_kind(rows, plan, i) == "estimate" && i > first && is.null(rows[[i]]$sparkline)
  row_px <- function(i) line_px + if (pads(i)) pad_px else 0
  for (i in shown) {
    r <- rows[[i]]
    kind <- .tab_row_kind(rows, plan, i)
    top <- if ((kind == "stat" && (!identical(prev, "stat") || isTRUE(r$rule))) || (kind == "panel" && !is.null(prev))) ".75pt" else ""
    if (i == first && !nh) top <- "1.5pt"
    bottom <- if (i == last) "1.5pt" else ""
    bt <- .dx_rule(top); bb <- .dx_rule(bottom)
    if (kind == "panel") {
      para <- .dx_p(.dx_run(r$label, sz, italic = TRUE), sz)
      out <- c(out, paste0("<w:tr><w:trPr><w:cantSplit/></w:trPr>",
                           .dx_tc(para, width = tw(0, length(grid)), span = length(grid), top = bt, bottom = bb), "</w:tr>"))
      prev <- kind
      next
    }
    sp <- r$sparkline
    mar <- if (pads(i)) c(pad_px * 15, 108, 108)
    key <- as.character(i)
    label <- if (!is.null(plan) && !is.null(plan$label[[key]])) plan$label[[key]] else r$label
    in_start <- !is.null(plan) && !is.null(plan$start[[key]])
    in_inside <- !is.null(plan) && !is.null(plan$inside[[key]])
    trpr <- paste0("<w:cantSplit/>", if (in_start || in_inside) paste0('<w:trHeight w:val="', .dx_i(row_px(i) * 15), '" w:hRule="exact"/>'))
    cells <- .dx_tc(.dx_p(.dx_run(label, sz), sz), width = tw(0), top = bt, bottom = bb, mar = mar)
    for (cc in seq_along(r$cells)) {
      x <- r$cells[[cc]]
      col <- 1L + per * (cc - 1L)
      many <- !is.null(plan) && !in_start && !in_inside
      para <- if (!is.null(sp)) .dx_p(.dx_spark(ids, sp$marks[[cc]], sp$color, x, width = spw), 2, "center")
              else .dx_p(.dx_run(x, sz), sz, "center")
      span <- if (many) 2L else 1L
      cells <- c(cells, .dx_tc(para, width = tw(col, span), span = span, top = bt, bottom = bb, mar = mar))
      if (!is.null(plan) && plan$align == "estimate" && (in_start || in_inside)) {
        k <- if (in_start) plan$start[[key]][1] else plan$inside[[key]]
        ssp <- rows[[k]]$sparkline
        px <- row_px(i)
        drawing <- .dx_spark(ids, ssp$marks[[cc]], ssp$color, rows[[k]]$cells[[cc]], px,
                             mid = (px - line_px) * 10 + line_px * 5, rule_only = !in_start, width = sidew)
        cells <- c(cells, .dx_tc(.dx_p(drawing, 2, "center"), width = tw(col + 1L), top = bt, bottom = bb, mar = c(0, 0, 0), valign = "top"))
      } else if (in_start) {
        s <- plan$start[[key]]
        ssp <- rows[[s[1]]]$sparkline
        q <- setdiff(i:(s[3] - 1L), plan$skip)
        height <- sum(vapply(q, row_px, 0))
        drawing <- .dx_spark(ids, ssp$marks[[cc]], ssp$color, rows[[s[1]]]$cells[[cc]], height, width = sidew)
        cells <- c(cells, .dx_tc(.dx_p(drawing, 2, "center"), width = tw(col + 1L), vmerge = "restart", top = bt, bottom = bb,
                                 mar = c(0, 0, 0), valign = "top"))
      } else if (!is.null(plan) && plan$align == "middle" && in_inside) {
        cells <- c(cells, .dx_tc(.dx_p("", 2), width = tw(col + 1L), vmerge = "continue", top = bt, bottom = bb, mar = c(0, 0, 0)))
      }
    }
    out <- c(out, paste0("<w:tr><w:trPr>", trpr, "</w:trPr>", paste(cells, collapse = ""), "</w:tr>"))
    prev <- kind
  }
  out <- c(out, "</w:tbl>")
  body <- c(body, paste(out, collapse = ""))
  nsz <- floor((font - 1) * 2 + 0.5)
  for (note in t$notes) body <- c(body, .dx_p(.dx_run(note, nsz), nsz, before = 60))
  if (!length(t$notes)) body <- c(body, .dx_p("", sz))  # Word wants a paragraph between a table and the section's end
  page <- max(12240, total + 2880)
  paste0(.dx_xml, "<w:document ", .dx_ns, "><w:body>", paste(body, collapse = ""),
         '<w:sectPr><w:pgSz w:w="', .dx_i(page), '" w:h="15840"/>',
         '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>',
         "</w:sectPr></w:body></w:document>")
}

.tab_docx_styles <- function(sz) {
  paste0(.dx_xml, '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
         '<w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="', sz, '"/><w:szCs w:val="', sz, '"/></w:rPr></w:rPrDefault>',
         '<w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>',
         '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>',
         '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>',
         '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr>',
         '<w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>',
         '<w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>',
         "</w:styles>")
}

.tab_docx_static <- list(
  "[Content_Types].xml" = paste0(.dx_xml, '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Override PartName="/word/document.xml" ',
    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '<Override PartName="/word/styles.xml" ',
    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>',
    "</Types>"),
  "_rels/.rels" = paste0(.dx_xml, '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" ',
    'Target="word/document.xml"/></Relationships>'),
  "word/_rels/document.xml.rels" = paste0(.dx_xml, '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" ',
    'Target="styles.xml"/></Relationships>'))

# CRC-32 (zip's), on signed 32-bit integers as R keeps them
.tab_crc_table <- local({
  tab <- NULL
  function() {
    if (is.null(tab)) {
      poly <- -306674912L  # 0xEDB88320
      tab <<- vapply(0:255, function(n) {
        c <- n
        for (k in 1:8) c <- if (bitwAnd(c, 1L)) bitwXor(poly, bitwShiftR(c, 1L)) else bitwShiftR(c, 1L)
        c
      }, 0L)
    }
    tab
  }
})
.tab_crc32 <- function(bytes) {
  tab <- .tab_crc_table()
  c <- -1L  # 0xFFFFFFFF
  for (b in as.integer(bytes)) c <- bitwXor(tab[bitwAnd(bitwXor(c, b), 255L) + 1L], bitwShiftR(c, 8L))
  bitwNot(c)
}

# a zip of `files` (name -> raw) stored uncompressed, dated 1980-01-01, as the Python
# reference and the viewer write it
.tab_zip_stored <- function(files) {
  u32 <- function(x) writeBin(as.integer(x), raw(), size = 4L, endian = "little")
  u16 <- function(x) writeBin(as.integer(x), raw(), size = 2L, endian = "little")
  out <- raw(); central <- raw()
  for (name in names(files)) {
    data <- files[[name]]
    nb <- charToRaw(enc2utf8(name))
    crc <- .tab_crc32(data)
    off <- length(out)
    out <- c(out, u32(67324752L), u16(20), u16(0), u16(0), u16(0), u16(0x21), u32(crc), u32(length(data)), u32(length(data)),
             u16(length(nb)), u16(0), nb, data)
    central <- c(central, u32(33639248L), u16(20), u16(20), u16(0), u16(0), u16(0), u16(0x21), u32(crc), u32(length(data)),
                 u32(length(data)), u16(length(nb)), u16(0), u16(0), u16(0), u16(0), u32(0), u32(off), nb)
  }
  start <- length(out)
  c(out, central, u32(101010256L), u16(0), u16(0), u16(length(files)), u16(length(files)), u32(length(central)), u32(start), u16(0))
}

# The Word file's bytes, as the Python reference's render(t, "docx", width, font, term_space)
.tab_render_docx <- function(t, width = NULL, font = 10, term_space = NULL) {
  sz <- floor(font * 2 + 0.5)
  parts <- c(.tab_docx_static, list("word/document.xml" = .tab_docx_document(t, width, font, term_space),
                                    "word/styles.xml" = .tab_docx_styles(sz)))
  .tab_zip_stored(lapply(parts, function(s) charToRaw(enc2utf8(s))))
}

# render_table(output = "x.docx"): `width` (inches, a fixed-width table; NULL fits the
# contents), `font` (points) and `term_space` from render_table's `...`
.tab_docx_save <- function(t, output, dots) {
  bytes <- .tab_render_docx(t, width = dots$width, font = dots$font %||% 10, term_space = dots$term_space)
  writeBin(bytes, output)
  invisible(output)
}
