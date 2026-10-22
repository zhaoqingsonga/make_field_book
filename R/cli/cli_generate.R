# =============================================================================
# File: R/cli/cli_generate.R
# Role: generate <type> <excel> -- non-Shiny port of the three doGenerate paths
# Mirrors shared/mod_*.R doGenerate() without reactiveValues / shinyjs
# =============================================================================

cli_cmds_generate <- function() {
  list(
    cmd_def(
      path = c("generate", "population"),
      usage = paste0("generate population <excel>",
                     " [--sheet=] [--min-f=] [--max-f=] [--ck=] [--interval=]",
                     " [--ck-rows=] [--rp=] [--digits=] [--rows=] [--prefix=]",
                     " [--location=] [--startN=] [--ckfixed] [--out=]"),
      summary = "群体记录本生成（F1-F7 → planting）",
      opts = list(
        sheet = "value", min_f = "value", max_f = "value",
        ck = "value", interval = "value", ck_rows = "value",
        rp = "value", digits = "value", rows = "value",
        prefix = "value", location = "value", startN = "value",
        ckfixed = "flag", out = "value"
      ),
      examples = c(
        "fieldbook generate population data/pop_2025.xlsx --min-f=2 --max-f=6 --out=out/pop.xlsx"
      ),
      handler = function(ctx) do_generate_population(ctx)
    ),
    cmd_def(
      path = c("generate", "line-selection"),
      usage = paste0("generate line-selection <excel>",
                     " [--sheet=] [--ck=] [--interval=] [--rp=] [--digits=]",
                     " [--rows=] [--prefix=] [--location=] [--startN=]",
                     " [--ckfixed] [--out=]"),
      summary = "株行记录本生成（sele>0 → get_plant | get_line → planting）",
      opts = list(
        sheet = "value", ck = "value", interval = "value",
        rp = "value", digits = "value", rows = "value",
        prefix = "value", location = "value", startN = "value",
        ckfixed = "flag", out = "value"
      ),
      examples = c(
        "fieldbook generate line-selection data/lines.xlsx --out=out/lines.xlsx"
      ),
      handler = function(ctx) do_generate_line_selection(ctx)
    ),
    cmd_def(
      path = c("generate", "yield-test"),
      usage = paste0("generate yield-test <excel>",
                     " [--sheet=] [--promote=] [--target-stage=] [--ck=] [--interval=]",
                     " [--rp=] [--digits=] [--rows=] [--prefix=] [--location=]",
                     " [--startN=] [--ckfixed] [--out=]"),
      summary = "产比记录本生成（杂交组合 → get_primary → planting）",
      opts = list(
        sheet = "value", promote = "value", target_stage = "value",
        ck = "value", interval = "value",
        rp = "value", digits = "value", rows = "value",
        prefix = "value", location = "value", startN = "value",
        ckfixed = "flag", out = "value"
      ),
      examples = c(
        "fieldbook generate yield-test data/yield.xlsx --promote='初级产比' --out=out/yield.xlsx"
      ),
      handler = function(ctx) do_generate_yield_test(ctx)
    )
  )
}

# =============================================================================
# Common helpers
# =============================================================================

#' Read Excel data (returns data.frame). Trim column names.
cli_read_excel <- function(excel, sheet = NULL) {
  if (!file.exists(excel)) cli_die(paste0("文件不存在：", excel), 1L)
  sh <- if (is.null(sheet)) NULL else sheet
  df <- cli_quiet(openxlsx::read.xlsx(excel, sheet = sh, colNames = TRUE))
  names(df) <- trimws(names(df))
  df
}

#' Lowercase + manual canonical column mapping for size-insensitive matches
cli_normalize_names <- function(df, required) {
  for (field in required) {
    idx <- which(tolower(names(df)) == tolower(field))
    if (length(idx) > 0 && names(df)[idx[1]] != field) {
      names(df)[idx[1]] <- field
    }
  }
  df
}

#' Backup is_ck, merge extra columns from mydata into planted_loc, restore is_ck
#' Matches the documented fix in DEVELOPMENT.md so CK rows are not overwritten.
merge_extra_cols <- function(planted_loc, mydata) {
  original_is_ck <- planted_loc$is_ck
  extra_cols <- setdiff(names(mydata), names(planted_loc))
  if (length(extra_cols) > 0) {
    if ("code" %in% names(planted_loc) && "code" %in% names(mydata)) {
      keys <- c("code", "ma", "pa")
      keys <- keys[keys %in% names(planted_loc) & keys %in% names(mydata)]
      if (length(keys)) {
        planted_loc <- merge(
          planted_loc,
          mydata[, c(keys, extra_cols), drop = FALSE],
          by = keys, all.x = TRUE, sort = FALSE
        )
      }
    }
  }
  planted_loc$is_ck <- original_is_ck
  planted_loc
}

#' Split "中黄301 齐黄34" / "4 5" style strings into character vector
parse_space_separated <- function(x) {
  if (is.null(x) || !nzchar(x)) return(character(0))
  trimws(strsplit(as.character(x), " +")[[1]])
}

#' Per-location list: a single value cycles, parentheses denote multi-ck
#'   "(中黄301 皖豆37) 齐黄34" -> list(c("中黄301","皖豆37"), "齐黄34")
parse_per_location <- function(x, n_places) {
  if (!length(x)) {
    out <- vector("list", n_places)
    if (length(out)) out[[1]] <- character(0)
    return(out)
  }
  out <- vector("list", n_places)
  for (i in seq_len(n_places)) {
    if (i > length(x)) { out[[i]] <- x[[1]]; next }
    item <- x[i]
    if (grepl("^\\(.+\\)$", item)) {
      inner <- gsub("^\\(|\\)$", "", item)
      out[[i]] <- trimws(strsplit(inner, " +")[[1]])
    } else {
      out[[i]] <- item
    }
  }
  out
}

#' Per-location numeric rows from "4" or "4 5 4"
parse_per_location_int <- function(x, n_places, default = 4L) {
  if (!length(x)) return(rep(default, n_places))
  if (length(x) == 1L) return(rep(x[[1]], n_places))
  out <- rep(x[1], n_places)
  for (i in seq_len(min(length(x), n_places))) out[i] <- x[i]
  out
}

#' Sys.sleep factor when generating across locations to keep fieldid unique
sleep_between_locations <- function(location_vec) {
  if (length(location_vec) > 1L) Sys.sleep(FIELDID_DELAY_SECONDS)
}

# =============================================================================
# generate population
# =============================================================================

do_generate_population <- function(ctx) {
  pos <- ctx$pos; if (!length(pos)) cli_usage_error("必须提供 <excel>")
  excel <- pos[1]
  df <- cli_read_excel(excel, sheet = cli_get_last(ctx$parsed, "sheet"))

  # Required fields; case-insensitive rename
  required <- c("name", "next_stage", "f", "new_rows")
  df <- cli_normalize_names(df, required)
  missing <- setdiff(required, names(df))
  if (length(missing)) cli_die(
    paste0("Excel 缺少必填列：", paste(missing, collapse = ", ")), 1L)

  # Save experiment first (so we have a stable exp_id)
  exp_name <- cli_get_last(ctx$parsed, "name") %||%
              tools::file_path_sans_ext(basename(excel))
  if (!nzchar(exp_name)) exp_name <- paste0("群体_", format(Sys.time(), "%Y%m%d%H%M%S"))

  exp_id <- cli_quiet({
    savePopulationRecord(experiment_name = exp_name,
                         materials_df = df, db_path = ctx$db)
  })$experiment_id
  cli_note(ctx, paste0("已保存试验：", exp_id))

  # Strip DB columns, ensure columns for get_population
  db_cols <- c("material_id", "experiment_id", "created_at")
  mydata <- df[, !names(df) %in% db_cols, drop = FALSE]

  if ("f" %in% names(mydata)) mydata$f <- as.integer(mydata$f)

  if (!"next_stage" %in% names(mydata)) {
    mydata$next_stage <- ifelse(grepl("F", as.character(mydata$stageid)),
                                "群体", mydata$stageid)
  }
  if (!"mapa" %in% names(mydata)) {
    mydata$mapa <- paste(mydata$ma, mydata$pa, sep = " x ")
  }
  mydata$process <- mydata$name
  mydata$path    <- mydata$name

  # Remove planting-output leftovers
  leftover <- c("rows", "line_number", "is_ck", "fieldid", ".actual_rows")
  leftover <- intersect(leftover, names(mydata))
  if (length(leftover)) mydata <- mydata[, !names(mydata) %in% leftover, drop = FALSE]

  # min_f / max_f
  min_f <- as.integer(cli_get_last(ctx$parsed, "min_f") %||% 0L)
  max_f <- as.integer(cli_get_last(ctx$parsed, "max_f") %||% 6L)
  if ("f" %in% names(mydata)) {
    mydata <- mydata[mydata$f >= min_f & mydata$f <= max_f, , drop = FALSE]
  }

  mydata$ma <- as.character(mydata$ma)
  mydata$pa <- as.character(mydata$pa)

  # new_rows filter (preserve order)
  if (!"new_rows" %in% names(mydata)) mydata$new_rows <- NA_real_
  new_rows_vals <- as.numeric(mydata$new_rows)
  valid_mask <- !is.na(new_rows_vals) & new_rows_vals > 0
  n_before <- nrow(mydata)
  mydata <- mydata[valid_mask, , drop = FALSE]
  new_rows_vals <- new_rows_vals[valid_mask]
  if (nrow(mydata) == 0) cli_die(
    "筛选后无可用材料：请检查世代范围与 new_rows>0 的记录", 1L)
  if (n_before > nrow(mydata)) cli_note(ctx,
    paste0("已过滤 ", n_before - nrow(mydata), " 条 new_rows<=0 的记录"))
  new_rows_vals[is.na(new_rows_vals) | new_rows_vals <= 0] <- 1

  # Build pre-name map before get_population (which changes shape)
  pre_name_to_rows <- setNames(new_rows_vals, as.character(mydata$name))

  if (!"seeds" %in% names(mydata)) mydata$seeds <- 0

  # Validate
  required_in <- c("ma", "pa", "stageid", "name")
  miss2 <- setdiff(required_in, names(mydata))
  if (length(miss2)) cli_die(
    paste0("缺少必要列：", paste(miss2, collapse = ", ")), 1L)
  if (all(is.na(mydata$ma)) || all(nchar(mydata$ma) == 0))
    cli_die("母本(ma)列全部为空，请检查数据", 1L)
  if (all(is.na(mydata$pa)) || all(nchar(mydata$pa) == 0))
    cli_die("父本(pa)列全部为空，请检查数据", 1L)

  cli_note(ctx, "正在调用 get_population...")
  mydata <- cli_quiet(soyplant::get_population(mydata))

  if (is.character(mydata) && grepl("No selected population", mydata))
    cli_die("get_population 未找到有效的群体数据", 1L)
  if (!is.data.frame(mydata) || nrow(mydata) == 0)
    cli_die("get_population 返回无效数据", 1L)
  if ("f" %in% names(mydata)) mydata$f <- as.integer(mydata$f)

  # Restore .actual_rows via source → name
  source_key <- as.character(mydata$source)
  mydata$.actual_rows <- as.numeric(pre_name_to_rows[source_key])
  missing_rows <- is.na(mydata$.actual_rows)
  if (any(missing_rows)) {
    mydata$.actual_rows[missing_rows] <-
      as.numeric(pre_name_to_rows[as.character(mydata$name[missing_rows])])
  }
  mydata$.actual_rows[is.na(mydata$.actual_rows) | mydata$.actual_rows <= 0] <- 1

  source_to_rows <- setNames(mydata$.actual_rows, as.character(mydata$source))
  name_to_rows   <- setNames(mydata$.actual_rows, as.character(mydata$name))
  code_to_rows <- if ("code" %in% names(mydata))
    setNames(mydata$.actual_rows, as.character(mydata$code)) else numeric(0)

  # CK + locations
  ck_vec  <- parse_space_separated(cli_get_last(ctx$parsed, "ck"))
  ck_rows_val <- as.integer(cli_get_last(ctx$parsed, "ck_rows") %||% DEFAULT_CK_ROWS)
  location_vec <- parse_space_separated(cli_get_last(ctx$parsed, "location"))
  if (!length(location_vec)) cli_die("请提供 --location", 1L)
  interval_val <- as.integer(cli_get_last(ctx$parsed, "interval") %||% INTERVAL_DISABLED)
  rp_val       <- as.integer(cli_get_last(ctx$parsed, "rp") %||% DEFAULT_RP)
  digits_val   <- as.integer(cli_get_last(ctx$parsed, "digits") %||% DEFAULT_DIGITS)
  prefix_val   <- cli_get_last(ctx$parsed, "prefix") %||% "N25F2P"
  startN_val   <- as.integer(cli_get_last(ctx$parsed, "startN") %||% 1L)
  ckfixed_val  <- !identical(ctx$opt$ckfixed, FALSE)

  all_planted <- list()
  for (i in seq_along(location_vec)) {
    planted_loc <- cli_quiet({
      mydata %>% planting(
        interval   = interval_val, s_prefix   = prefix_val,
        place      = location_vec[i], rp = rp_val, digits = digits_val,
        ck         = ck_vec, ckfixed = ckfixed_val,
        restartfid = TRUE, startN = startN_val
      )
    })
    planted_loc <- merge_extra_cols(planted_loc, mydata)

    # Manual rows + line_number (population-specific: 3-key fallback)
    planted_loc <- recompute_rows_population(
      planted_loc, source_to_rows, name_to_rows, code_to_rows, ck_rows_val)

    all_planted[[i]] <- planted_loc
    sleep_between_locations(location_vec)
  }
  planted <- do.call(rbind, all_planted)
  if (!nrow(planted)) cli_die("planting 返回 0 行", 1L)
  if ("is_ck" %in% names(planted)) planted$is_ck <- as.integer(planted$is_ck)

  # Persist field records
  planted_to_save <- addTraitColumns(planted)
  cli_quiet({
    savePopulationFieldRecord(experiment_id = exp_id, experiment_name = exp_name,
                              planting_df = planted_to_save, db_path = ctx$db)
    markPopulationGenerated(exp_id, db_path = ctx$db)
  })

  # Optional output Excel
  out_path <- cli_get_last(ctx$parsed, "out")
  saved <- NA
  if (!is.null(out_path)) {
    dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
    cli_quiet({
      soyplant::savewb(
        origin = mydata, planting = planted,
        myview = planted[, intersect(c(FIELD_VIEW_COLS, "ma", "pa"), names(planted)),
                         drop = FALSE],
        combi_matrix = combination_matrix(mydata),
        filename = out_path, overwrite = TRUE
      )
    })
    saved <- normalizePath(out_path, mustWork = FALSE)
  }

  payload <- list(
    experiment_id = exp_id,
    experiment_name = exp_name,
    origin_rows = nrow(mydata),
    planted_rows = nrow(planted),
    output_file = saved,
    locations = length(location_vec),
    materials_with_new_rows = nrow(mydata)
  )
  if (isTRUE(ctx$json)) {
    cli_out(cli_json_or_null(payload))
  } else {
    cli_ok(ctx, paste0(
      "群体记录本生成完成：exp=", exp_id,
      "，原始 ", nrow(mydata), " 行 / 种植 ", nrow(planted), " 行",
      if (!is.na(saved)) paste0(" / 输出 ", saved) else ""
    ), payload)
  }
  invisible(NULL)
}

#' Manual rows/line_number recomputation for population module.
#' Rules:
#'   CK row   = is_ck==1 AND is.na(source) -> use ck_rows_val
#'   Material = otherwise -> lookup source -> name -> code, default 1
recompute_rows_population <- function(planted, source_map, name_map, code_map,
                                       ck_rows_val) {
  is_ck_v  <- if ("is_ck" %in% names(planted)) planted$is_ck else integer(nrow(planted))
  if (!is.numeric(is_ck_v)) is_ck_v <- as.integer(is_ck_v)
  is_ck_v[is.na(is_ck_v)] <- 0L
  source_v <- if ("source" %in% names(planted))
    as.character(planted$source) else rep(NA_character_, nrow(planted))
  name_v <- if ("name" %in% names(planted))
    as.character(planted$name) else rep(NA_character_, nrow(planted))
  code_v <- if ("code" %in% names(planted))
    as.character(planted$code) else rep(NA_character_, nrow(planted))

  rows_v     <- integer(nrow(planted))
  linen_v    <- character(nrow(planted))
  pos <- 1L
  for (idx in seq_len(nrow(planted))) {
    is_ck_i <- is_ck_v[idx]
    src     <- source_v[idx]
    if (is_ck_i == 1L && is.na(src)) {
      actual_rows <- ck_rows_val
    } else {
      actual_rows <- NA_real_
      src_chr <- if (!is.na(src) && nzchar(src)) src else NA_character_
      if (!is.na(src_chr) && src_chr %in% names(source_map))
        actual_rows <- as.numeric(source_map[[src_chr]])
      if (is.na(actual_rows) && !is.na(name_v[idx]) && nzchar(name_v[idx]) &&
          name_v[idx] %in% names(name_map))
        actual_rows <- as.numeric(name_map[[name_v[idx]]])
      if (is.na(actual_rows) && !is.na(code_v[idx]) && nzchar(code_v[idx]) &&
          code_v[idx] %in% names(code_map))
        actual_rows <- as.numeric(code_map[[code_v[idx]]])
      if (is.na(actual_rows) || actual_rows <= 0) actual_rows <- 1
    }
    rows_v[idx]  <- as.integer(actual_rows)
    linen_v[idx] <- paste0(pos, "-", pos + actual_rows - 1)
    pos <- pos + actual_rows
  }
  planted$rows        <- rows_v
  planted$line_number <- linen_v
  planted
}

# =============================================================================
# generate line-selection
# =============================================================================

do_generate_line_selection <- function(ctx) {
  pos <- ctx$pos; if (!length(pos)) cli_usage_error("必须提供 <excel>")
  excel <- pos[1]
  df <- cli_read_excel(excel, sheet = cli_get_last(ctx$parsed, "sheet"))

  required <- c("name", "sele", "f")
  df <- cli_normalize_names(df, required)
  missing <- setdiff(required, names(df))
  if (length(missing)) cli_die(
    paste0("Excel 缺少必填列：", paste(missing, collapse = ", ")), 1L)
  if ("sele" %in% names(df)) df$sele <- suppressWarnings(as.numeric(df$sele))

  exp_name <- tools::file_path_sans_ext(basename(excel))
  exp_id <- cli_quiet({
    saveLineSelectionRecord(experiment_name = exp_name,
                            materials_df = df, db_path = ctx$db)
  })$experiment_id
  cli_note(ctx, paste0("已保存试验：", exp_id))

  db_cols <- c("material_id", "experiment_id", "created_at")
  origin <- df[, !names(df) %in% db_cols, drop = FALSE]

  # Filter sele > 0
  if ("sele" %in% names(origin)) {
    origin <- origin[!is.na(origin$sele) & origin$sele > 0, , drop = FALSE]
  }
  if (!nrow(origin)) cli_die("筛选后没有数据，请检查 sele 列是否 > 0", 1L)

  origin$ma[is.na(origin$ma)] <- "未知"
  origin$pa[is.na(origin$pa)] <- "未知"
  origin$ma <- as.character(origin$ma)
  origin$pa <- as.character(origin$pa)
  if ("f" %in% names(origin)) origin$f <- as.integer(origin$f) else origin$f <- 1L
  if (!"path" %in% names(origin)) origin$path    <- origin$name
  if (!"process" %in% names(origin)) origin$process <- origin$name

  cli_note(ctx, "正在调用 get_plant | get_line...")
  mydata <- cli_quiet({
    origin |> soyplant::get_plant() |> soyplant::get_line()
  })
  if (!is.data.frame(mydata) || nrow(mydata) == 0)
    cli_die("get_line 返回 0 行，请检查数据格式", 1L)

  ck_vec      <- parse_space_separated(cli_get_last(ctx$parsed, "ck"))
  location_vec <- parse_space_separated(cli_get_last(ctx$parsed, "location"))
  if (!length(location_vec)) cli_die("请提供 --location", 1L)
  interval_val <- as.integer(cli_get_last(ctx$parsed, "interval") %||% INTERVAL_DISABLED)
  rp_val       <- as.integer(cli_get_last(ctx$parsed, "rp") %||% DEFAULT_RP)
  digits_val   <- as.integer(cli_get_last(ctx$parsed, "digits") %||% 4L)
  rows_val     <- as.integer(cli_get_last(ctx$parsed, "rows") %||% 1L)
  prefix_val   <- cli_get_last(ctx$parsed, "prefix") %||% "N25bL"
  startN_val   <- as.integer(cli_get_last(ctx$parsed, "startN") %||% 1L)
  ckfixed_val  <- !identical(ctx$opt$ckfixed, FALSE)

  all_planted <- list()
  for (i in seq_along(location_vec)) {
    planted_loc <- cli_quiet({
      mydata %>% planting(
        interval = interval_val, s_prefix = prefix_val,
        place = location_vec[i], rp = rp_val, digits = digits_val,
        ck = ck_vec, rows = rows_val, ckfixed = ckfixed_val,
        restartfid = TRUE, startN = startN_val
      )
    })
    planted_loc <- merge_extra_cols(planted_loc, mydata)
    all_planted[[i]] <- planted_loc
    sleep_between_locations(location_vec)
  }
  planted <- do.call(rbind, all_planted)
  if (!nrow(planted)) cli_die("planting 返回 0 行", 1L)
  if ("is_ck" %in% names(planted)) planted$is_ck <- as.integer(planted$is_ck)

  planted_to_save <- addTraitColumns(planted)
  cli_quiet({
    saveLineSelectionFieldRecord(experiment_id = exp_id, experiment_name = exp_name,
                                 planting_df = planted_to_save, db_path = ctx$db)
    markLineSelectionGenerated(exp_id, db_path = ctx$db)
  })

  # Ensure 'sele' is lowercase
  if (any(tolower(names(planted)) == "sele")) {
    idx <- which(tolower(names(planted)) == "sele")[1]
    if (names(planted)[idx] != "sele") names(planted)[idx] <- "sele"
  }

  out_path <- cli_get_last(ctx$parsed, "out")
  saved <- NA
  if (!is.null(out_path)) {
    dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
    cli_quiet({
      soyplant::savewb(
        origin = origin, material = mydata, planting = planted,
        myview = planted[, intersect(c(FIELD_VIEW_COLS, "ma", "pa", "sele"),
                                       names(planted)), drop = FALSE],
        combi_matrix = combination_matrix(mydata),
        filename = out_path, overwrite = TRUE
      )
    })
    saved <- normalizePath(out_path, mustWork = FALSE)
  }

  payload <- list(
    experiment_id = exp_id, experiment_name = exp_name,
    origin_rows = nrow(origin), material_rows = nrow(mydata),
    planted_rows = nrow(planted), output_file = saved,
    locations = length(location_vec)
  )
  if (isTRUE(ctx$json)) {
    cli_out(cli_json_or_null(payload))
  } else {
    cli_ok(ctx, paste0(
      "株行记录本生成完成：exp=", exp_id,
      "，原始 ", nrow(origin), " / 材料 ", nrow(mydata),
      " / 种植 ", nrow(planted),
      if (!is.na(saved)) paste0(" / 输出 ", saved) else ""
    ), payload)
  }
  invisible(NULL)
}

# =============================================================================
# generate yield-test
# =============================================================================

do_generate_yield_test <- function(ctx) {
  pos <- ctx$pos; if (!length(pos)) cli_usage_error("必须提供 <excel>")
  excel <- pos[1]
  df <- cli_read_excel(excel, sheet = cli_get_last(ctx$parsed, "sheet"))

  required <- c("name", "next_stage", "f")
  df <- cli_normalize_names(df, required)
  missing <- setdiff(required, names(df))
  if ("name" %in% missing) cli_die("Excel 缺少必填列：name", 1L)
  if ("next_stage" %in% missing) df$next_stage <- "初级产比"
  if ("f" %in% missing) df$f <- 9L

  exp_name <- tools::file_path_sans_ext(basename(excel))
  exp_id <- cli_quiet({
    saveYieldTestRecord(experiment_name = exp_name,
                        materials_df = df, db_path = ctx$db)
  })$experiment_id
  cli_note(ctx, paste0("已保存试验：", exp_id))

  db_cols <- c("material_id", "experiment_id", "created_at")
  mydata <- df[, !names(df) %in% db_cols, drop = FALSE]

  if (!"ma" %in% names(mydata)) mydata$ma <- "未知" else
    mydata$ma[is.na(mydata$ma)] <- "未知"
  if (!"pa" %in% names(mydata)) mydata$pa <- "未知" else
    mydata$pa[is.na(mydata$pa)] <- "未知"
  mydata$ma <- as.character(mydata$ma)
  mydata$pa <- as.character(mydata$pa)
  if ("rows" %in% names(mydata)) mydata$rows <- as.numeric(mydata$rows)

  promote_val <- cli_get_last(ctx$parsed, "promote") %||% "初级产比"
  target_val  <- cli_get_last(ctx$parsed, "target_stage") %||% "高级产比"

  if (!"f" %in% names(mydata)) mydata$f <- 1L else
    mydata$f <- as.integer(mydata$f)
  if (!"path" %in% names(mydata)) mydata$path    <- mydata$name
  if (!"process" %in% names(mydata)) mydata$process <- mydata$name

  cli_note(ctx, "正在调用 get_primary...")
  mydata <- cli_quiet({
    soyplant::get_primary(mydata, next_stage = promote_val,
                         target_stage = target_val)
  })
  if (!is.data.frame(mydata) || nrow(mydata) == 0)
    cli_die("get_primary 返回无效数据", 1L)
  if (!"is_ck" %in% names(mydata)) mydata$is_ck <- 0L

  ck_str  <- cli_get_last(ctx$parsed, "ck") %||% PLACEHOLDER_CK
  rows_str <- cli_get_last(ctx$parsed, "rows") %||% "4"
  location_str <- cli_get_last(ctx$parsed, "location") %||% DEFAULT_LOCATION

  ck_vec       <- parse_space_separated(ck_str)
  rows_tokens  <- parse_space_separated(rows_str)
  location_vec <- parse_space_separated(location_str)
  if (!length(location_vec)) cli_die("请提供 --location", 1L)

  interval_val <- as.integer(cli_get_last(ctx$parsed, "interval") %||% 19L)
  rp_val       <- as.integer(cli_get_last(ctx$parsed, "rp") %||% 2L)
  digits_val   <- as.integer(cli_get_last(ctx$parsed, "digits") %||% DEFAULT_DIGITS)
  prefix_val   <- cli_get_last(ctx$parsed, "prefix") %||% "N25E"
  startN_val   <- as.integer(cli_get_last(ctx$parsed, "startN") %||% 1L)
  ckfixed_val  <- !identical(ctx$opt$ckfixed, FALSE)

  ck_by_place <- parse_per_location(ck_vec, length(location_vec))
  rows_by_place <- parse_per_location_int(rows_tokens, length(location_vec), 4L)

  all_planted <- list()
  for (i in seq_along(location_vec)) {
    rows_i <- as.integer(rows_by_place[i])
    planted_loc <- cli_quiet({
      mydata %>% planting(
        interval = interval_val, s_prefix = prefix_val,
        place = location_vec[i], rp = rp_val, digits = digits_val,
        ck = ck_by_place[[i]], rows = rows_i, ckfixed = ckfixed_val,
        restartfid = TRUE, startN = startN_val
      )
    })
    planted_loc <- merge_extra_cols(planted_loc, mydata)
    all_planted[[i]] <- planted_loc
    sleep_between_locations(location_vec)
  }
  planted <- do.call(rbind, all_planted)
  if (!nrow(planted)) cli_die("planting 返回 0 行", 1L)

  planted_to_save <- addTraitColumns(planted)
  cli_quiet({
    saveYieldTestFieldRecord(experiment_id = exp_id, experiment_name = exp_name,
                             planting_df = planted_to_save, db_path = ctx$db)
    markYieldTestGenerated(exp_id, db_path = ctx$db)
  })

  out_path <- cli_get_last(ctx$parsed, "out")
  saved <- NA
  if (!is.null(out_path)) {
    dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
    cli_quiet({
      soyplant::savewb(
        origin = mydata, planting = planted,
        myview = planted[, intersect(c(FIELD_VIEW_COLS, "ma", "pa"),
                                       names(planted)), drop = FALSE],
        combi_matrix = combination_matrix(mydata),
        filename = out_path, overwrite = TRUE
      )
    })
    saved <- normalizePath(out_path, mustWork = FALSE)
  }

  payload <- list(
    experiment_id = exp_id, experiment_name = exp_name,
    plant_rows = nrow(mydata), planted_rows = nrow(planted),
    output_file = saved, locations = length(location_vec)
  )
  if (isTRUE(ctx$json)) {
    cli_out(cli_json_or_null(payload))
  } else {
    cli_ok(ctx, paste0(
      "产比记录本生成完成：exp=", exp_id,
      "，材料 ", nrow(mydata), " / 种植 ", nrow(planted),
      if (!is.na(saved)) paste0(" / 输出 ", saved) else ""
    ), payload)
  }
  invisible(NULL)
}
