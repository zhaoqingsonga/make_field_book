# =============================================================================
# File: R/cli/cli_db.R
# Role: experiment list / show / delete + db info / check
# Depends: shared/db_persistence.R (loaded by bin/fieldbook)
# =============================================================================

# ---- Generate commands table per type ------------------------------------

cli_cmds_db <- function() {
  list(
    cmd_def(
      path = c("db", "info"),
      usage = "db info",
      summary = "数据库概览（路径、大小、表、记录数）",
      handler = function(ctx) {
        i <- fieldbook_db_info(ctx$db)
        if (isTRUE(ctx$json)) {
          cli_out(cli_json_or_null(list(
            path = i$path, size_bytes = i$size_bytes,
            tables = i$tables, counts = i$counts
          )))
          return(invisible(NULL))
        }
        cli_kv_out(list(
          "路径" = i$path,
          "大小" = cli_human_size(i$size_bytes),
          "表"   = paste(i$tables, collapse = ", "),
          "群体 _records"     = i$counts$population_records %||% 0,
          "群体_field_records"= i$counts$population_field_records %||% 0,
          "株行 _records"     = i$counts$line_selection_records %||% 0,
          "株行 _field_records"= i$counts$line_selection_field_records %||% 0,
          "产比 _records"     = i$counts$yield_test_records %||% 0,
          "产比 _field_records"= i$counts$yield_test_field_records %||% 0
        ))
      }
    ),
    cmd_def(
      path = c("db", "check"),
      usage = "db check",
      summary = "数据库完整性检查（PRAGMA integrity_check）",
      handler = function(ctx) {
        ok <- fieldbook_db_check(ctx$db)
        if (!isTRUE(ok)) cli_die("数据库完整性检查未通过", 1L)
        if (isTRUE(ctx$json)) cli_out(cli_json_or_null(list(integrity = "ok")))
        else cli_ok(ctx, "数据库完好")
      }
    ),
    cmd_def(
      path = c("list", "experiments"),
      usage = "list experiments [--type=population|line-selection|yield-test]",
      summary = "列出试验记录（元信息 + 是否已生成田试）",
      opts = list(type = "value"),
      handler = function(ctx) {
        type <- cli_get_last(ctx$parsed, "type")
        if (is.null(type)) {
          df <- rbind_safe(
            fieldbook_list_experiments(ctx$db, "population"),
            fieldbook_list_experiments(ctx$db, "line_selection"),
            fieldbook_list_experiments(ctx$db, "yield_test")
          )
        } else {
          t <- fieldbook_alias_type(type)
          df <- fieldbook_list_experiments(ctx$db, t)
        }
        if (is.null(df) || !nrow(df)) {
          cli_out(cli_c("(无记录)", "grey", ctx$no_color))
          return(invisible(NULL))
        }
        # Render: short, human-friendly columns
        out <- data.frame(
          experiment_id   = df$experiment_id,
          type            = df$experiment_type,
          name            = df$experiment_name,
          total_rows      = df$total_rows,
          generated       = ifelse(df$has_generated == 1, "已生成", "未生成"),
          created_at      = substr(df$created_at, 1, 19),
          stringsAsFactors = FALSE
        )
        cli_emit(ctx, out, headers = c("exp_id","type","name","rows","status","created_at"))
      },
      examples = c(
        "fieldbook list experiments",
        "fieldbook list experiments --type=population --json"
      )
    ),
    cmd_def(
      path = c("list", "field-records"),
      usage = "list field-records --type=<type> [--exp-id=<id>]",
      summary = "列出已生成的田试记录（planting + 88 性状）",
      opts = list(type = "value", exp_id = "value"),
      handler = function(ctx) {
        type_arg <- cli_get_last(ctx$parsed, "type")
        exp_id   <- cli_get_last(ctx$parsed, "exp_id")
        if (is.null(type_arg)) cli_usage_error("必须提供 --type")
        t <- fieldbook_alias_type(type_arg)
        if (!is.null(exp_id)) {
          df <- fieldbook_get_field_records(ctx$db, t, exp_id)
          if (is.null(df) || !nrow(df)) {
            cli_out(cli_c("(无记录)", "grey", ctx$no_color))
            return(invisible(NULL))
          }
          cli_emit(ctx, df, max_width = 40)
        } else {
          # All generated for this type
          meta <- fieldbook_list_experiments(ctx$db, t)
          if (!nrow(meta)) { cli_out("(无)"); return(invisible(NULL)) }
          gens <- meta[meta$has_generated == 1, , drop = FALSE]
          if (!nrow(gens)) { cli_out("(无)"); return(invisible(NULL)) }
          res <- lapply(gens$experiment_id, function(eid) {
            d <- fieldbook_get_field_records(ctx$db, t, eid)
            if (!is.null(d) && nrow(d)) d else NULL
          })
          if (!length(res)) { cli_out("(无)"); return(invisible(NULL)) }
          combined <- do.call(rbind, res)
          cli_emit(ctx, combined, max_width = 40)
        }
      },
      examples = c(
        "fieldbook list field-records --type=population",
        "fieldbook list field-records --type=population --exp-id=POP_..."
      )
    ),
    cmd_def(
      path = c("show", "experiment"),
      usage = "show experiment --exp-id=<id>",
      summary = "查看一次试验的元信息 + 材料明细",
      opts = list(exp_id = "value"),
      handler = function(ctx) {
        eid <- cli_get_last(ctx$parsed, "exp_id")
        if (is.null(eid)) cli_usage_error("必须提供 --exp-id")
        type <- fieldbook_find_exp_type(ctx$db, eid)
        if (is.null(type)) cli_die(paste0("未找到试验：", eid), 1L)
        meta <- fieldbook_get_experiment(ctx$db, type, eid)
        if (is.null(meta) || !nrow(meta)) cli_die(paste0("未找到试验：", eid), 1L)
        if (isTRUE(ctx$json)) {
          mats <- fieldbook_get_materials(ctx$db, type, eid)
          cli_out(cli_json_or_null(list(meta = meta, materials = mats)))
          return(invisible(NULL))
        }
        # Human: meta + brief stats + first 8 material rows
        m <- meta[1, ]
        cli_kv_out(list(
          "exp_id"   = m$experiment_id,
          "type"     = type,
          "name"     = m$experiment_name,
          "total_rows" = m$total_rows,
          "generated"  = ifelse(m$has_generated == 1, "已生成", "未生成"),
          "created"    = substr(m$created_at, 1, 19)
        ))
        mats <- fieldbook_get_materials(ctx$db, type, eid)
        cli_note(ctx, paste0("材料 ", nrow(mats), " 行"))
        if (nrow(mats)) {
          nshow <- min(8L, nrow(mats))
          cli_table(mats[seq_len(nshow), , drop = FALSE], max_width = 24)
          if (nrow(mats) > nshow) cli_note(ctx, paste0("... 省略 ", nrow(mats) - nshow, " 行"))
        }
      }
    ),
    cmd_def(
      path = c("delete", "experiment"),
      usage = "delete experiment --exp-id=<id> [--yes]",
      summary = "删除试验记录（联动删除 field_records / 不可恢复）",
      opts = list(exp_id = "value"),
      handler = function(ctx) {
        eid <- cli_get_last(ctx$parsed, "exp_id")
        if (is.null(eid)) cli_usage_error("必须提供 --exp-id")
        type <- fieldbook_find_exp_type(ctx$db, eid)
        if (is.null(type)) cli_die(paste0("未找到试验：", eid), 1L)
        if (!cli_confirm(paste0("确认删除试验 ", eid, "(", type, ")？此操作不可恢复"),
                         assume_yes = ctx$yes)) {
          cli_out("已取消")
          return(invisible(NULL))
        }
        fieldbook_delete_experiment(ctx$db, type, eid)
        cli_ok(ctx, paste0("已删除：", eid), list(deleted = eid))
      }
    ),
    cmd_def(
      path = c("delete", "field-record"),
      usage = "delete field-record --exp-id=<id> [--type=<type>] [--yes]",
      summary = "只删除田试记录（不删试验元信息），并重置 has_generated",
      opts = list(exp_id = "value", type = "value"),
      handler = function(ctx) {
        eid <- cli_get_last(ctx$parsed, "exp_id")
        if (is.null(eid)) cli_usage_error("必须提供 --exp-id")
        type_arg <- cli_get_last(ctx$parsed, "type")
        if (is.null(type_arg)) {
          type <- fieldbook_find_exp_type(ctx$db, eid)
          if (is.null(type)) cli_die(paste0("未找到试验：", eid), 1L)
        } else {
          type <- fieldbook_alias_type(type_arg)
        }
        if (!cli_confirm(paste0("确认删除 ", type, " 田试记录 ", eid, "？"),
                         assume_yes = ctx$yes)) {
          cli_out("已取消")
          return(invisible(NULL))
        }
        fieldbook_delete_field_record(ctx$db, type, eid)
        fieldbook_reset_generated(ctx$db, type, eid)
        cli_ok(ctx, paste0("已重置：", eid), list(reset = eid))
      }
    ),
    cmd_def(
      path = c("db", "migrate"),
      usage = "db migrate",
      summary = "同步旧分类表到 unified_records / unified_materials",
      handler = function(ctx) {
        n <- fieldbook_sync_unified(ctx$db)
        if (isTRUE(ctx$json)) cli_out(cli_json_or_null(n))
        else cli_ok(ctx, paste0("已同步 ", n$synced, " 条记录到广表"))
      }
    )
  )
}

# ---- Helpers (depend on shared/db_persistence.R) --------------------------

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Return alias -> canonical type
fieldbook_alias_type <- function(x) {
  m <- c(population = "population",
         pop        = "population",
         line       = "line_selection",
         lines      = "line_selection",
         line_selection = "line_selection",
         yield      = "yield_test",
         yields     = "yield_test",
         yield_test = "yield_test")
  out <- m[match.arg(x, names(m), several.ok = FALSE)]
  unname(out)
}

#' List experiments by type
fieldbook_list_experiments <- function(db, type) {
  table <- TYPE_TO_TABLE[[type]][["records"]]
  con   <- fieldbook_connect(db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  df <- DBI::dbGetQuery(con,
    sprintf("SELECT *, '%s' AS experiment_type FROM %s ORDER BY created_at DESC",
            type, table))
  if (!nrow(df)) return(df)
  df
}

#' Which type does this exp_id belong to?
fieldbook_find_exp_type <- function(db, eid) {
  for (t in names(TYPE_TO_TABLE)) {
    con <- fieldbook_connect(db)
    on.exit(DBI::dbDisconnect(con), add = TRUE)
    n <- DBI::dbGetQuery(con,
      sprintf("SELECT 1 FROM %s WHERE experiment_id = ? LIMIT 1",
              TYPE_TO_TABLE[[t]][["records"]]),
      params = list(eid))
    if (nrow(n) > 0) return(t)
  }
  NULL
}

#' Get experiment meta row
fieldbook_get_experiment <- function(db, type, eid) {
  table <- TYPE_TO_TABLE[[type]][["records"]]
  con <- fieldbook_connect(db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbGetQuery(con,
    sprintf("SELECT * FROM %s WHERE experiment_id = ?", table),
    params = list(eid))
}

#' Get raw materials (parsed from JSON raw_data column)
fieldbook_get_materials <- function(db, type, eid) {
  fun <- list(population     = getPopulationMaterials,
              line_selection = getLineSelectionMaterials,
              yield_test     = getYieldTestMaterials)[[type]]
  fun(eid, db_path = db)
}

#' Get generated field records
fieldbook_get_field_records <- function(db, type, eid) {
  table <- TYPE_TO_TABLE[[type]][["field"]]
  con <- fieldbook_connect(db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbGetQuery(con,
    sprintf("SELECT * FROM %s WHERE experiment_id = ? ORDER BY rowid", table),
    params = list(eid))
}

#' Delete an experiment (and its field records via foreign keys / manual)
fieldbook_delete_experiment <- function(db, type, eid) {
  fun <- list(population     = deletePopulationRecord,
              line_selection = deleteLineSelectionRecord,
              yield_test     = deleteYieldTestRecord)[[type]]
  fun(eid, db_path = db)
}

#' Delete field record only, and reset has_generated
fieldbook_delete_field_record <- function(db, type, eid) {
  fun <- list(population     = deletePopulationFieldRecord,
              line_selection = deleteLineSelectionFieldRecord,
              yield_test     = deleteYieldTestFieldRecord)[[type]]
  fun(eid, db_path = db)
}

fieldbook_reset_generated <- function(db, type, eid) {
  fun <- list(population     = resetPopulationGenerated,
              line_selection = resetLineSelectionGenerated,
              yield_test     = resetYieldTestGenerated)[[type]]
  fun(eid, db_path = db)
}

fieldbook_sync_unified <- function(db) {
  con <- fieldbook_connect(db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  syncToUnifiedTable(db_path = db)
}

#' DB info: tables + counts + size
fieldbook_db_info <- function(db) {
  if (!file.exists(db)) {
    return(list(path = db, size_bytes = NA_real_, tables = character(0),
                counts = list()))
  }
  con <- fieldbook_connect(db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  tabs <- DBI::dbListTables(con)
  counts <- list()
  for (t in tabs) {
    n <- DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", t))$n
    counts[[t]] <- n
  }
  list(path = normalizePath(db, mustWork = FALSE),
       size_bytes = file.info(db)$size,
       tables = tabs,
       counts = counts)
}

fieldbook_db_check <- function(db) {
  if (!file.exists(db)) return(FALSE)
  con <- fieldbook_connect(db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  r <- DBI::dbGetQuery(con, "PRAGMA integrity_check")$integrity_check
  identical(r, "ok")
}

#' Connection helper (delegates to shared/db_persistence.R connectDb)
fieldbook_connect <- function(db) connectDb(db)

#' Safe rbind that handles empty / different-cols frames
rbind_safe <- function(...) {
  dfs <- list(...)
  dfs <- dfs[!vapply(dfs, function(x) is.null(x) || !nrow(x), logical(1))]
  if (!length(dfs)) return(data.frame())
  Reduce(function(a, b) {
    # union of columns
    cn <- union(names(a), names(b))
    for (col in setdiff(cn, names(a))) a[[col]] <- NA
    for (col in setdiff(cn, names(b))) b[[col]] <- NA
    rbind(a[, cn, drop = FALSE], b[, cn, drop = FALSE])
  }, dfs)
}
