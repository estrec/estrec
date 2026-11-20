\name{to_estimation}
\alias{to_estimation}
\alias{to_estimation.fixest}
\alias{to_estimation.fixest_multi}
\alias{to_estimation.lm}
\alias{to_estimation.glm}
\alias{to_estimation.list}
\alias{to_estimation.default}
\alias{is_estimation_record}
\title{Convert a fitted model to an estimation record}
\description{
Returns the record as a list, in the estrec format (\code{estrec/0.1}):
parameters, metrics, vcov with its small-sample correction, sample drops by reason, fixed
effects, and provenance. A \code{fixest_multi} gives a list of records, one per model.

A plain list of fits (or records) gives a flat list of records, named as the list is; a
\code{fixest_multi} element contributes one record per model, named \code{<name>.1},
\code{<name>.2}, ... A record passes through unchanged.
}
\usage{
to_estimation(fit, ...)

\method{to_estimation}{fixest}(fit, data = NULL, vcov = NULL, conf_level = 0.95,
  tests = NULL, title = NULL, notes = NULL, tags = NULL, publication = NULL, call = TRUE,
  identifying = TRUE, digest = NULL, level = NULL, purpose = NULL, program = NULL,
  data_info = NULL, ...)

\method{to_estimation}{lm}(fit, data = NULL, vcov = NULL, conf_level = 0.95,
  tests = NULL, title = NULL, notes = NULL, tags = NULL, publication = NULL, call = TRUE,
  identifying = TRUE, digest = NULL, level = NULL, purpose = NULL, program = NULL,
  data_info = NULL, ...)

\method{to_estimation}{glm}(fit, data = NULL, vcov = NULL, conf_level = 0.95,
  tests = NULL, title = NULL, notes = NULL, tags = NULL, publication = NULL, call = TRUE,
  identifying = TRUE, digest = NULL, level = NULL, purpose = NULL, program = NULL,
  data_info = NULL, ...)

is_estimation_record(x)
}
\arguments{
\item{fit}{a fitted model: a \code{fixest} \code{feols} (OLS or IV), \code{feglm} or \code{fepois} fit, or a \code{fixest_multi};
an \code{lm} or \code{glm} fit (not a matrix response or \code{MASS::glm.nb}); or a list of them.}
\item{data}{the data the model was fitted on, to split sample drops by reason (missing,
non-finite, zero weights, singletons and, for GLMs, separated). By default it is recovered from the fit's call
environment; without it, drops are recorded as \code{other}.}
\item{vcov}{\code{NULL} for the fit's own vcov, or a list of \code{vcov} arguments for
\code{summary.fixest} (e.g. \code{list("hetero", ~firm)}). Each is recorded; the first is
the default and gives the parameters' standard errors. For \code{lm} and \code{glm}:
\code{"iid"} (the model-based vcov, the default), \code{"HC0"} to \code{"HC5"} or
\code{"hetero"} (HC1) through \code{sandwich::vcovHC}, or a formula of cluster variables
through \code{sandwich::vcovCL} (type HC1, recorded as CRV1). The model-based vcov keeps
\code{summary()}'s tests; a sandwich vcov uses \code{lmtest::coeftest()}'s (t on the
residual df for \code{lm}, z for \code{glm}). Intervals are Wald intervals.}
\item{conf_level}{confidence level of \code{conf_low}/\code{conf_high}.}
\item{tests}{test results to add, one or a \code{list()} of them, as for \code{\link{add_test}}
(\code{fixest::wald()}, \code{marginaleffects::hypotheses()}, ...). The record always has
fixest's joint Wald test of the coefficients, and for IV the first-stage,
weak-identification, endogeneity and overidentification tests. An \code{lm} record has
\code{summary.lm}'s F test.}
\item{title, notes, tags}{user labels for \code{meta}. Without a \code{title}, one is made
from the formula at level 3 or more.}
\item{publication}{optional \code{publication} section: where the result appears in a paper.}
\item{call}{include the call as written.}
\item{identifying}{include the user, host and command line, at level 5 (removable later with
\code{estrec redact}).}
\item{level}{disclosure level, 1 to 5 (spec 4.9): the most the record discloses. 1: estimates,
standard errors, p-values, intervals, N, df. 2: the other metrics, the vcovs (without cluster
names and counts), tests. 3: the specification, fixed-effect and cluster counts. 4 (the
default): R, fixest and estrec with their versions, data names, numerics. 5: every loaded
package, the environment, the command line, user and host. Profiles the level makes the
record fail are not claimed, with a \code{profile_not_claimed} message (and a warning).}
\item{purpose}{purpose profiles the record is for, e.g. \code{"dcas/0.1"} (journals following the Data and Code Availability Standard). Each
is claimed, and \code{level} defaults to the lowest one they allow; a lower \code{level} is an
error. Whether the record meets them is for the validator: \code{estrec validate}.}
\item{data_info}{a list describing the data input (\code{provenance.data}): \code{name}
(by default the \code{data} argument as written in the call), \code{version},
\code{source}, \code{checksum}, \code{publication} (a data citation), \code{location}.}
\item{program}{the program in the replication package that ran the fit
(\code{specification.program}): a path relative to the package root, or
\code{list(path = , line = )}. Its sha256 is added when the file is found and
\code{openssl} is installed.}
\item{digest}{write \code{meta.core_digest} (spec 7.2). By default it is written when the
\code{openssl} package is installed; \code{TRUE} requires it, \code{FALSE} leaves it out.}
\item{x}{an object.}
\item{...}{passed to methods.}
}
\value{A record (a list), or a list of records.}
\examples{
if (requireNamespace("fixest", quietly = TRUE)) {
  fit <- fixest::feols(mpg ~ wt | cyl, mtcars)
  rec <- to_estimation(fit, vcov = list("hetero", "iid"))
  rec$parameters[[1]]$std_error
  recs <- to_estimation(list(base = fit, full = fixest::feols(mpg ~ wt + hp | cyl, mtcars)))
  names(recs)
}
rec <- to_estimation(glm(am ~ wt, binomial, mtcars))
rec$meta$estimator$link
}
