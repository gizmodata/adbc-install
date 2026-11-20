# Load an installed GizmoData ADBC driver by name from R, through adbcdrivermanager: the R twin of
# check_driver_by_name.py. On Windows, R and its packages are built with MinGW (Rtools), so its
# driver manager looks up Driver.shared.windows_<arch>_mingw in the manifest, where Python's (built
# with MSVC) looks up windows_<arch>.
#
#   Rscript check_driver_by_name.R load <name> <uri> <text>   # <name> loads; connecting to <uri>
#                                                             # fails with <text> in the error
#   Rscript check_driver_by_name.R no-arch <name> <arch key>  # <name>'s manifest has no entry for
#                                                             # <arch key>: loading must say so
#
# <uri> points at 127.0.0.1:1, where nothing listens, and <text> is only that driver's own error
# (check_driver_by_name.py --print-probe prints both), so a pass proves R loaded the right library.
args <- commandArgs(trailingOnly = TRUE)
mode <- args[1]
name <- args[2]
suppressPackageStartupMessages(library(adbcdrivermanager))
cat("R", as.character(getRversion()), "adbcdrivermanager", as.character(packageVersion("adbcdrivermanager")), "\n")

message_of <- function(expr) tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))

if (mode == "no-arch") {
  key <- args[3]
  msg <- message_of(adbc_driver(name))
  if (is.null(msg)) { cat("'", name, "' loaded, but its manifest has no ", key, " entry\n", sep = ""); quit(status = 1) }
  want <- paste0("for current architecture '", key, "'")
  if (!grepl(want, msg, fixed = TRUE)) { cat("'", name, "' failed, but not with \"", want, "\": ", msg, "\n", sep = ""); quit(status = 1) }
  cat("'", name, "' without a ", key, " entry is refused, as expected\n", sep = "")
  quit(status = 0)
}

if (mode != "load") { cat("unknown mode", mode, "\n"); quit(status = 2) }
uri <- args[3]
text <- args[4]
msg <- message_of(adbc_driver(name))
if (!is.null(msg)) { cat("'", name, "' does not load from R: ", msg, "\n", sep = ""); quit(status = 1) }
msg <- message_of({
  db <- adbc_database_init(adbc_driver(name), uri = uri)
  con <- adbc_connection_init(db)
  stmt <- adbc_statement_init(con)
  adbc_statement_set_sql_query(stmt, "SELECT 1")
  adbc_statement_execute_query(stmt)
})
if (is.null(msg)) { cat("'", name, "' connected to 127.0.0.1:1, where nothing should listen\n", sep = ""); quit(status = 1) }
if (!grepl(text, msg, fixed = TRUE)) { cat("'", name, "' loaded, but its error is not that driver's: ", substr(msg, 1, 400), "\n", sep = ""); quit(status = 1) }
cat("'", name, "' loads by name from R\n", sep = "")
quit(status = 0)
