\name{record_process}
\alias{record_process}
\title{Record a PROCESS run}
\description{
Runs a call of \code{process()} (Andrew F. Hayes's PROCESS macro for mediation, moderation
and conditional process models) and returns its estimation record: each equation's
coefficients (\code{response} names the equation's outcome), the direct, indirect, total and
conditional effects and indices of moderated mediation as rows tagged \code{mediation}, the
model tests, each equation's fit in \code{structures.equations}, and the bootstrap settings.
It claims \code{mediation/0.1} when the model has mediators.

estrec doesn't include PROCESS: get it from \url{https://www.afhayes.com/download.html} and
\code{source()} it first.

The call runs with \code{save = 2} added (\code{save = 1} becomes \code{3}), so the numbers come
from PROCESS's matrix at full precision; the labels come from its printed output, which is
printed as usual. \code{save = 2} also makes PROCESS probe every interaction, as
\code{intprobe = 1} does. PROCESS's own result is the record's \code{"process"} attribute.
A PROCESS version other than 5.0 or 5.1.1 gets a warning in the record: PROCESS changes its
output between minor versions, so compare the record with its output.
}
\usage{
record_process(expr, title = NULL, identifying = FALSE, digest = NULL, envir = parent.frame())
}
\arguments{
\item{expr}{a call of \code{process()}.}
\item{title}{the record's title (default \code{"PROCESS model <n>"}).}
\item{identifying}{also record the user, host and command line.}
\item{digest}{add \code{meta.core_digest} (needs the \code{openssl} package; by default when
it is installed).}
\item{envir}{where to evaluate the call.}
}
\value{The record (a list); write it with \code{\link{write_estimation}}.}
\examples{
\dontrun{
source("process.R")   # from https://www.afhayes.com/download.html
rec <- record_process(process(data = d, y = "y", x = "x1", m = "x2", model = 4, seed = 1))
write_estimation(rec, "mediation.estrec.json")
}
}
