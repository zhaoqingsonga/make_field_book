# =============================================================================
# File: R/cli/dispatch.R
# Role: command registry, context, main entry
# =============================================================================

#' Null-coalesce
`%||%` <- function(a, b) if (is.null(a)) b else a

#' Command definition builder
cmd_def <- function(path, usage, summary, opts = list(), aliases = list(),
                    handler, examples = character(0)) {
  list(
    path = path,
    usage = usage,
    summary = summary,
    opts = opts,
    aliases = aliases,
    handler = handler,
    examples = examples,
    name = path[length(path)],
    group = if (length(path) > 1) path[1] else NA_character_
  )
}

#' Build the full command registry
cli_registry <- function() {
  groups <- list(
    cli_cmds_generate(),
    cli_cmds_db()
  )
  out <- list()
  for (g in groups) {
    for (item in g) {
      if (!is.list(item) || is.null(item$name)) next
      out[[length(out) + 1L]] <- item
    }
  }
  out
}

#' Build execution context: inject global flags, parse opts
cli_ctx <- function(cmd, argv) {
  spec <- cmd$opts
  spec$db         <- "value"
  spec$json       <- "flag"
  spec$yes        <- "flag"
  spec$no_color   <- "flag"
  spec$empty_dash <- "flag"
  parsed <- cli_parse(argv, spec, cmd$aliases)
  options(fieldbook.no_color = isTRUE(cli_get(parsed, "no_color", FALSE)))
  list(
    cmd = cmd,
    pos = parsed$pos,
    opt = parsed$opt,
    parsed = parsed,
    db = cli_get_last(parsed, "db", fieldbook_db_path()),
    json = isTRUE(cli_get(parsed, "json", FALSE)),
    yes = isTRUE(cli_get(parsed, "yes", FALSE)),
    no_color = isTRUE(cli_get(parsed, "no_color", FALSE))
  )
}

#' Emit a data frame: --json mode or human table
cli_emit <- function(ctx, df, headers = NULL, max_width = 28) {
  if (isTRUE(ctx$json)) {
    cli_out(cli_json_or_null(df))
    return(invisible(NULL))
  }
  na <- if (isTRUE(ctx$opt$empty_dash)) "" else "-"
  cli_table(df, headers = headers, max_width = max_width, na_str = na)
}

#' Greyed info note (suppressed in --json)
cli_note <- function(ctx, msg) {
  if (isTRUE(ctx$json)) return(invisible(NULL))
  cli_out(cli_c(msg, "grey", ctx$no_color))
}

#' Success line (OK prefix)
cli_ok <- function(ctx, msg, payload = NULL) {
  if (isTRUE(ctx$json)) {
    cli_out(cli_json_or_null(payload %||% list(ok = TRUE, message = msg)))
  } else {
    cli_out(cli_c("OK", "green", ctx$no_color), "  ", msg)
  }
  invisible(NULL)
}

#' Render --key as --key-name (a_b -> --a-b)
cli_flag_name <- function(key) gsub("_", "-", key, fixed = TRUE)

#' Help for a single command
cli_help_cmd <- function(cmd) {
  cli_out(cli_c("用法", "bold", FALSE), ": ", "fieldbook ", cmd$usage)
  cli_out(cli_c("说明", "bold", FALSE), ": ", cmd$summary)
  if (length(cmd$opts)) {
    cli_out("")
    cli_out(cli_c("选项", "bold", FALSE), ":")
    for (k in names(cmd$opts)) {
      kind <- if (identical(cmd$opts[[k]], "flag")) "" else " <值>"
      cli_out("  --", cli_flag_name(k), kind)
    }
  }
  if (length(cmd$examples)) {
    cli_out("")
    cli_out(cli_c("示例", "bold", FALSE), ":")
    for (e in cmd$examples) cli_out("  ", e)
  }
  cli_out("")
  cli_out(cli_c("全局选项", "bold", FALSE),
          ": --db <路径>  --json  --yes  --no-color  --empty-dash")
}

#' Top-level / grouped help
cli_help_group <- function(reg, group = NULL) {
  title <- if (is.null(group)) "田间记录本生成器 CLI" else paste0("fieldbook ", group)
  cli_out(cli_c(title, "bold", FALSE))
  cli_out("")
  if (is.null(group)) {
    cli_out("用法: fieldbook <命令组> <子命令> [选项]")
    cli_out("")
    groups <- unique(stats::na.omit(vapply(reg, function(x) x$group, character(1))))
    for (g in sort(groups)) {
      items <- Filter(function(x) identical(x$group, g), reg)
      cli_out(cli_c(g, "cyan", FALSE))
      for (it in items) cli_out(sprintf("  %-22s %s", it$name, it$summary))
      cli_out("")
    }
  } else {
    items <- Filter(function(x) identical(x$group, group), reg)
    if (!length(items)) cli_die(paste0("未知命令组：", group), 2L)
    cli_out(paste0("用法: fieldbook ", group, " <子命令> [选项]"))
    cli_out("")
    for (it in items) cli_out(sprintf("  %-22s %s", it$name, it$summary))
    cli_out("")
  }
  cli_out("查看详情: fieldbook <命令组> <子命令> --help")
  cli_out("全局选项: --db <路径>  --json  --yes  --no-color")
}

#' Main CLI entrypoint
cli_main <- function(argv) {
  argv <- as.character(argv)
  reg <- cli_registry()

  if (!length(argv)) { cli_help_group(reg); return(invisible(NULL)) }
  if (argv[1] %in% c("-h", "--help", "help")) {
    cli_help_group(reg); return(invisible(NULL))
  }
  if (argv[1] %in% c("-v", "--version", "version")) {
    cli_out("fieldbook ", FIELDBOOK_CLI_VERSION); return(invisible(NULL))
  }

  lead <- character(0)
  for (a in argv) {
    if (startsWith(a, "-")) break
    lead <- c(lead, a)
  }
  if (!length(lead)) { cli_help_group(reg); return(invisible(NULL)) }

  wanted <- utils::head(lead, 2)
  match_i <- which(vapply(reg, function(x) {
    identical(as.character(x$path), as.character(wanted))
  }, logical(1)))
  if (!length(match_i)) {
    if (lead[1] %in% unique(stats::na.omit(vapply(reg, function(x) x$group, character(1))))) {
      cli_help_group(reg, lead[1]); return(invisible(NULL))
    }
    cli_die(paste0("未知命令：", lead[1]), 2L)
  }

  cmd <- reg[[match_i[1]]]
  consumed <- length(wanted)
  rest <- argv[-seq_len(consumed)]
  if ("--help" %in% rest || "-h" %in% rest) {
    cli_help_cmd(cmd); return(invisible(NULL))
  }
  ctx <- cli_ctx(cmd, rest)
  cmd$handler(ctx)
}
