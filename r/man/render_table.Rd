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

A spec with \code{panels} (Panel A, Panel B) renders each panel through modelsummary as a
table of its own and stacks them: \code{output = "data.frame"} gives the cells with each
panel's label on a row of its own; other outputs give a tinytable whose row groups are the
panels (a file output is written with \code{tinytable::save_tt()}). Sparklines in panels show
as the interval in text.

Column groups (\code{spanners}) are a first row of labels in \code{output = "data.frame"} and
tinytable column groups (\code{tinytable::group_tt()}) otherwise, always on top; a file output
is then written from the tinytable.

\code{significance} takes the stars' p-values from the rows' adjusted or resampling p-values
or a test about each term (spec/table.md 5.1); a term without one shows no stars, and
\code{\{star_p\}} in a line shows the p-value used. modelsummary leaves out a line that is
blank in every column, which the Python reference keeps.

Sparkline lines (\code{{"sparkline": {color, scale}}}) are drawn for modelsummary's
tinytable outputs (\code{"default"}, \code{"tinytable"}, \code{"html"}, \code{"latex"},
\code{"markdown"}, \code{"typst"} and \code{.html}, \code{.tex}, \code{.md}, \code{.typ}
files): an SVG in HTML and a TikZ picture in LaTeX (the document needs
\code{\\usepackage\{tikz\}}), the same as the Python reference and the browser viewer draw,
on the same axes. Other formats (Markdown, Typst, \code{"data.frame"}, other packages'
tables, PDF, PNG and Word files) show the interval as \code{[low, high]}.

A Word file (\code{output = "table.docx"}) needs the R package pandoc. It is written from
tinytable's Markdown with a cell that starts like a list item (a column number such as
\code{(1)}, or the stars note \code{* p < 0.1}) escaped, which tinytable's own Word output
turns into an empty list. For the Word export with sparklines drawn, use the browser viewer's
Save .docx or the Python \code{render(t, "docx")}.
}
\examples{
\dontrun{
render_table("table2.estrec-table.json", output = "latex")
render_table(spec, records = read_collection("table2.estrec-collection.json"))
}
}
