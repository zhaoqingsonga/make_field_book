# =============================================================================
# File: R/cli/cli_core.R
# Role: CLI infrastructure - width-aware tables, arg parser, JSON, errors
# Deps: base R only (jsonlite optional, used if available)
# =============================================================================

# ---- Display width ---------------------------------------------------------

#' Display width (CJK wide chars count as 2)
cli_width <- function(s) {
  w <- suppressWarnings(nchar(as.character(s), type = "width", allowNA = TRUE))
  w[is.na(w)] <- 0L
  as.integer(w)
}

#' Right-pad to display width
cli_pad <- function(s, width) {
  w <- cli_width(s)
  ifelse(w >= width, s, paste0(s, strrep(" ", pmax(0, width - w))))
}

#' Truncate by display width, appending "~" when cut
cli_trunc <- function(s, width) {
  out <- character(length(s))
  for (i in seq_along(s)) {
    x <- s[i]
    if (cli_width(x) <= width) { out[i] <- x; next }
    chars <- strsplit(x, "", fixed = TRUE)[[1]]
    acc <- character(0); used <- 0
    for (ch in chars) {
      cw <- cli_width(ch)
      if (used + cw > width - 1) break
      acc <- c(acc, ch); used <- used + cw
    }
    out[i] <- paste0(paste(acc, collapse = ""), "~")
  }
  out
}

# ---- Color output ----------------------------------------------------------

cli_use_color <- function(no_color = FALSE) {
  if (isTRUE(no_color)) return(FALSE)
  if (nzchar(Sys.getenv("NO_COLOR"))) return(FALSE)
  if (identical(Sys.getenv("TERM"), "dumb")) return(FALSE)
  TRUE
}

cli_c <- function(s, color = NULL, no_color = FALSE) {
  if (is.null(color) || !cli_use_color(no_color)) return(s)
  codes <- c(red="31", green="32", yellow="33", blue="34",
             magenta="35", cyan="36", grey="90", bold="1", dim="2")
  code <- codes[[color]]
  if (is.null(code)) return(s)
  paste0("\033[", code, "m", s, "\033[0m")
}

cli_out <- function(...) cat(paste0(..., collapse = ""), "\n", sep = "")
cli_err <- function(...) {
  msg <- paste0(..., collapse = "")
  cat(cli_c(paste0(msg, "\n"), "red", getOption("fieldbook.no_color", FALSE)),
      file = stderr(), sep = "")
}

cli_die <- function(msg, code = 1L) {
  cli_err(msg)
  quit(save = "no", status = as.integer(code), runLast = FALSE)
}

cli_usage_error <- function(msg) cli_die(paste0("参数错误：", msg), 2L)

cli_human_size <- function(bytes) {
  if (is.na(bytes)) return("-")
  units <- c("B", "KB", "MB", "GB")
  i <- 1; v <- as.numeric(bytes)
  while (v >= 1024 && i < length(units)) { v <- v / 1024; i <- i + 1 }
  sprintf("%.2f %s", v, units[i])
}

# ---- Argument parser -------------------------------------------------------

#' Parse argv supporting: --key val, --key=val, --flag, --no-flag, -x val, --
#' Repeated --key aggregates into a vector.
cli_parse <- function(argv, spec = list(), aliases = list()) {
  opt <- list(); pos <- character(0)
  canon <- function(x) gsub("-", "_", x, fixed = TRUE)
  spec <- lapply(spec, identity); names(spec) <- canon(names(spec))
  long <- c(names(spec), "help", "version", canon(names(aliases)))
  alias <- names(aliases)
  alias_map <- stats::setNames(canon(unlist(aliases)), canon(alias))
  i <- 1; after_dd <- FALSE

  set_opt <- function(key, value) {
    opt[[key]] <<- if (is.null(opt[[key]])) value else c(opt[[key]], value)
  }

  while (i <= length(argv)) {
    a <- argv[i]
    if (after_dd) { pos <- c(pos, a); i <- i + 1; next }
    if (identical(a, "--")) { after_dd <- TRUE; i <- i + 1; next }
    if (grepl("^--no-[A-Za-z]", a)) {
      key <- canon(sub("^--no-", "", a))
      if (key %in% long) {
        if (!identical(spec[[key]], "flag")) {
          cli_usage_error(paste0("选项 --", gsub("_", "-", key, fixed = TRUE), " 不支持 --no- 形式"))
        }
        set_opt(key, FALSE); i <- i + 1; next
      }
    }
    if (grepl("^--", a)) {
      body <- sub("^--", "", a)
      if (grepl("=", body, fixed = TRUE)) {
        key <- canon(sub("=.*$", "", body))
        val <- sub("^[^=]*=", "", body)
        if (!key %in% long) cli_usage_error(paste0("未知选项 --", key))
        if (identical(spec[[key]], "flag")) set_opt(key, TRUE) else set_opt(key, val)
        i <- i + 1; next
      }
      body <- canon(body)
      if (!body %in% long) cli_usage_error(paste0("未知选项 --", body))
      if (identical(spec[[body]], "value")) {
        if (i == length(argv)) cli_usage_error(paste0("选项 --", body, " 需要取值"))
        set_opt(body, argv[i + 1]); i <- i + 2
      } else { set_opt(body, TRUE); i <- i + 1 }
      next
    }
    if (grepl("^-[A-Za-z]", a)) {
      key <- alias_map[[sub("^-", "", a)]]
      if (is.null(key)) cli_usage_error(paste0("未知选项 ", a))
      if (identical(spec[[key]], "value")) {
        if (i == length(argv)) cli_usage_error(paste0("选项 -", key, " 需要取值"))
        set_opt(key, argv[i + 1]); i <- i + 2
      } else { set_opt(key, TRUE); i <- i + 1 }
      next
    }
    pos <- c(pos, a); i <- i + 1
  }
  list(pos = pos, opt = opt)
}

cli_get <- function(parsed, key, default = NULL) {
  v <- parsed$opt[[key]]
  if (is.null(v) || !length(v)) return(default); v
}

#' Last value if --key given multiple times
cli_get_last <- function(parsed, key, default = NULL) {
  v <- cli_get(parsed, key, default)
  if (is.null(v)) return(default); v[length(v)]
}

cli_get_int <- function(parsed, key, default = NULL) {
  v <- cli_get_last(parsed, key)
  if (is.null(v)) return(default)
  n <- suppressWarnings(as.integer(v))
  if (is.na(n)) cli_usage_error(paste0("--", gsub("_", "-", key, fixed = TRUE),
                                       " 需要整数，收到：", v))
  n
}

#' Split a string by whitespace and/or commas
cli_split <- function(x, sep = "[ ,]+") {
  if (is.null(x) || !length(x)) return(character(0))
  if (length(x) > 1L) x <- paste(x, collapse = " ")
  parts <- trimws(strsplit(as.character(x), sep, perl = TRUE)[[1]])
  parts[nzchar(parts)]
}

# ---- JSON serializer -------------------------------------------------------

cli_json_escape <- function(s) {
  s <- gsub("\\", "\\\\", s, fixed = TRUE)
  s <- gsub('"', '\\"', s, fixed = TRUE)
  s <- gsub("\n", "\\n", s, fixed = TRUE)
  s <- gsub("\r", "\\r", s, fixed = TRUE)
  s <- gsub("\t", "\\t", s, fixed = TRUE)
  paste0('"', s, '"')
}

cli_to_json <- function(x) {
  if (is.null(x)) return("null")
  if (is.data.frame(x)) {
    if (!nrow(x)) return("[]")
    rows <- apply(x, 1, function(r) {
      objs <- vapply(seq_along(r), function(j) {
        paste0(cli_json_escape(names(x)[j]), ":", cli_to_json(r[[j]]))
      }, character(1))
      paste0("{", paste(objs, collapse = ","), "}")
    })
    return(paste0("[", paste(rows, collapse = ","), "]"))
  }
  if (is.list(x)) {
    nms <- names(x)
    if (!is.null(nms) && all(nzchar(nms))) {
      items <- vapply(seq_along(x), function(i) {
        paste0(cli_json_escape(nms[i]), ":", cli_to_json(x[[i]]))
      }, character(1))
      return(paste0("{", paste(items, collapse = ","), "}"))
    }
    vals <- vapply(x, cli_to_json, character(1))
    return(paste0("[", paste(vals, collapse = ","), "]"))
  }
  if (is.factor(x)) x <- as.character(x)
  if (length(x) != 1L) {
    vals <- vapply(x, cli_to_json, character(1))
    return(paste0("[", paste(vals, collapse = ","), "]"))
  }
  if (is.na(x)) return("null")
  if (is.logical(x)) return(if (x) "true" else "false")
  if (is.numeric(x)) return(format(x, scientific = FALSE, trim = TRUE))
  cli_json_escape(as.character(x))
}

cli_json_or_null <- function(x) {
  if (requireNamespace("jsonlite", quietly = TRUE)) {
    return(as.character(jsonlite::toJSON(x, auto_unbox = TRUE, na = "null", pretty = 2)))
  }
  cli_to_json(x)
}

# ---- Table renderer --------------------------------------------------------

cli_table <- function(df, headers = NULL, max_width = 28, na_str = "-") {
  nc <- getOption("fieldbook.no_color", FALSE)
  if (is.null(df)) df <- data.frame()
  if (!is.data.frame(df)) df <- data.frame(value = df)
  if (!nrow(df)) { cli_out(cli_c("(无记录)", "grey", nc)); return(invisible(NULL)) }
  if (is.null(headers)) headers <- names(df)

  cells <- lapply(seq_len(ncol(df)), function(j) {
    col <- df[[j]]
    if (is.numeric(col) && !is.integer(col)) col <- round(col, 4)
    v <- as.character(col); v[is.na(col)] <- na_str
    cli_trunc(v, max_width)
  })

  widths <- vapply(seq_along(cells), function(j) {
    max(c(cli_width(headers[j]), cli_width(cells[[j]])))
  }, integer(1))

  head_line <- paste(cli_pad(headers, widths), collapse = "  ")
  rule_line <- paste(strrep("-", widths), collapse = "  ")
  cli_out(cli_c(head_line, "bold", nc))
  cli_out(cli_c(rule_line, "grey", nc))
  for (i in seq_len(nrow(df))) {
    row <- vapply(seq_along(cells), function(j) cli_pad(cells[[j]][i], widths[j]), character(1))
    cli_out(paste(row, collapse = "  "))
  }
  invisible(NULL)
}

cli_kv_out <- function(x, headers = c("项", "值")) {
  df <- data.frame(k = names(x), v = as.character(unlist(x, use.names = FALSE)),
                   stringsAsFactors = FALSE)
  names(df) <- headers
  cli_table(df, max_width = 64)
}

cli_confirm <- function(msg, assume_yes = FALSE) {
  if (isTRUE(assume_yes)) return(TRUE)
  if (!interactive()) return(FALSE)
  ans <- readline(paste0(msg, " [y/N] "))
  tolower(trimws(ans)) %in% c("y", "yes")
}

cli_quiet <- function(expr) suppressMessages(suppressWarnings(expr))
