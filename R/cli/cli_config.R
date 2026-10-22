# =============================================================================
# File: R/cli/cli_config.R
# Role: shared constants (DB path, default planting parameters)
# =============================================================================

FIELDBOOK_CLI_VERSION <- "0.1.0"

# DB path resolution: env > arg > default relative to project root
fieldbook_db_path <- function() {
  env <- Sys.getenv("FIELDBOOK_DB", unset = NA)
  if (!is.na(env) && nzchar(env)) return(env)
  file.path(fieldbook_project_root(), "data", "field_book.sqlite")
}

# Locate project root by looking for the data/ dir upward
fieldbook_project_root <- function() {
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(fa)) return(dirname(dirname(normalizePath(sub("^--file=", "", fa[1])))))
  wd <- normalizePath(getwd(), winshal = "/", mustWork = FALSE)
  d <- wd
  for (i in 1:5) {
    if (dir.exists(file.path(d, "data")) &&
        dir.exists(file.path(d, "shared"))) return(d)
    parent <- dirname(d)
    if (identical(parent, d)) break
    d <- parent
  }
  wd
}

# Default planting parameters (mirrors helpers.R)
DEFAULT_LOCATION        <- "安徽宿州"
INTERVAL_DISABLED       <- 999
FIELDID_DELAY_SECONDS   <- 1.2
PLACEHOLDER_CK          <- "中黄301"

# Default numeric parameters per type
DEFAULT_DIGITS <- 3L
DEFAULT_RP     <- 1L
DEFAULT_ROWS   <- 4L
DEFAULT_CK_ROWS <- 4L

# Type -> field-record table suffix mapping
TYPE_TO_TABLE <- list(
  population     = c(records = "population_records",
                     field   = "population_field_records"),
  line_selection = c(records = "line_selection_records",
                     field   = "line_selection_field_records"),
  yield_test     = c(records = "yield_test_records",
                     field   = "yield_test_field_records")
)

TYPE_TO_EXP_PREFIX <- list(
  population     = "POP",
  line_selection = "LINE",
  yield_test     = "YIELD"
)

# Cycle color (for status messages)
status_color <- function(state) {
  switch(state,
    "0"      = list("yellow"),
    "1"      = list("green"),
    "已生成" = list("green"),
    "未生成" = list("yellow"),
    "OK"     = list("green"),
    "FAIL"   = list("red"),
    list("white")
  )[[1]]
}
