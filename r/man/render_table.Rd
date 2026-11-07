\name{render_table}
\alias{render_table}
\title{Render a table spec with modelsummary}
\description{
Renders an \code{estrec-table/0.1} table spec (spec/table.md): a saved layout for a
regression table from records, such as the record viewer saves. The spec names its columns'
records by \code{meta.id}; \code{render_table} finds them in the spec's \code{sources} and in
\code{records}, builds each column from the record's \code{\link{tidy.estimation_record}} (with
the column's vcov), and passes the result to \code{modelsummary::modelsummary()}, so the
output formats and themes are modelsummary's.
}
\usage{
render_table(spec, output = "default", records = NULL, base_dir = NULL, ...)
}
\arguments{
\item{spec}{a path to an \code{*.estrec-table.json} file, or the spec as a list.}
\item{output}{passed to \code{modelsummary()}: \code{"default"}, \code{"latex"},
\code{"markdown"}, \code{"html"}, \code{"data.frame"}, a file name, ...}
\item{records}{records the spec can use: a record, a list of them, or the result of
\code{\link{read_collection}}.}
\item{base_dir}{the folder the spec's \code{sources} are relative to; by default the spec
file's folder.}
\item{...}{passed to \code{modelsummary()}.}
}
\details{
Statistics rows (metrics, the vcov type or cluster counts, fixed effects, tests and text rows)
are computed by the spec's rules and added with \code{add_rows}; modelsummary's own
goodness-of-fit rows are left out. Rounding is R's, so the last digit may differ from the
browser viewer's on exact ties.

Sparkline lines (\code{{"sparkline": {color, scale}}}) are drawn for modelsummary's
tinytable outputs (\code{"default"}, \code{"tinytable"}, \code{"html"}, \code{"latex"},
\code{"markdown"}, \code{"typst"} and \code{.html}, \code{.tex}, \code{.md}, \code{.typ}
files): an SVG in HTML and a TikZ picture in LaTeX (the document needs
\code{\\usepackage\{tikz\}}), the same as the Python reference and the browser viewer draw,
on the same axes. Other formats (Markdown, Typst, \code{"data.frame"}, other packages'
tables, PDF, PNG and Word files) show the interval as \code{[low, high]}.
}
\examples{
\dontrun{
render_table("table2.estrec-table.json", output = "latex")
render_table(spec, records = read_collection("table2.estrec-collection.json"))
}
}
