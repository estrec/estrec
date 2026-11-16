\name{write_table}
\alias{write_table}
\alias{new_table}
\title{Make and write a table spec}
\description{
\code{new_table()} makes a table spec (\code{estrec-table/0.1}, spec/table.md) with one
column per record, as the Python reference's \code{estrec.table.new_table()} does: the
records' terms, the lines under each estimate, stars, and statistics rows, plus a row for
each fixed effect any record has.

\code{write_table()} writes a spec as JSON, ready for \code{\link{render_table}}, the
\code{estrec table} command or the viewer. A spec without \code{schema} or \code{meta} gets
them (a new id, the time, this package as producer). Fields the format has as arrays
(\code{head}, \code{keep}, \code{drop}, \code{stars}, \code{notes}, a row's \code{terms})
are written as arrays even with one entry.
}
\usage{
new_table(records, ..., headers = NULL, rows = NULL,
  stats = list("nobs", "r2", list(vcov = "type")), uncertainty = "std_error",
  stars = c(0.1, 0.05, 0.01), title = NULL, sources = NULL, pin = FALSE,
  fixed_effects = TRUE)

write_table(spec, path)
}
\arguments{
\item{records}{a record, a list of records, or \code{\link{read_collection}}'s result.}
\item{headers}{the column labels; by default the list's names, when every record has one.
They show in the heading when \code{head} includes \code{"label"} (pass
\code{head = c("label", "number")}); the default heading is the column number and the
dependent variable.}
\item{rows}{the terms to show, in order: term names, or lists such as
\code{list(term = "wt", label = "Weight")} or \code{list(terms = list("x", "x_iv"))}.}
\item{stats}{statistics rows: metric names, or lists such as \code{list(vcov = "type")}.}
\item{uncertainty}{the lines under each estimate: a name (\code{"std_error"}), a template, a
sparkline (\code{list(sparkline = list(scale = "column"))}), a list of these, or \code{NULL}.}
\item{stars}{p-value thresholds, largest first; \code{NULL} for none.}
\item{title}{the table's caption.}
\item{sources}{where to find the records: a list of \code{list(id, path)}, paths relative to
the spec's folder.}
\item{pin}{\code{TRUE}: each column carries its record's SHA-256, so a renderer can warn when
the record changes (needs \pkg{openssl}).}
\item{fixed_effects}{add a \code{FE: name} row for each fixed effect.}
\item{...}{other top-level spec fields (\code{head}, \code{estimate}, \code{keep},
\code{format}, ...), added as given. The arguments after \code{...} must be named in full.}
\item{spec}{a table spec as a list.}
\item{path}{the file to write, \code{<name>.estrec-table.json}.}
}
\value{\code{new_table()}: the spec as a list. \code{write_table()}: \code{path}, invisibly.}
\examples{
\dontrun{
fits <- list(Base = fit1, Full = fit2)
recs <- lapply(fits, to_estimation)
spec <- new_table(recs, sources = list(list(id = "r", path = "records")),
                  rows = list(list(term = "wt", label = "Weight")))
write_table(spec, "table2.estrec-table.json")
render_table("table2.estrec-table.json", output = "table2.html")
}
}
