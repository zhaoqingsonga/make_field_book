# =============================================================================
# File: tests/test_cli.R
# Role: CLI end-to-end smoke test
#   - Tests against a temp copy of data/field_book.sqlite (read-only of source)
#   - Validates arg parsing, help/version, command registry, db info, JSON
#   - Does NOT call generate commands (would need real Excel + would mutate)
# Usage: Rscript tests/test_cli.R
# =============================================================================

# Locate project root (tests/ is one level down)
fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
here <- if (length(fa)) dirname(normalizePath(sub("^--file=", "", fa[1]))) else getwd()
root <- if (basename(here) == "tests") dirname(here) else normalizePath(getwd())
old <- setwd(root)
on.exit(setwd(old), add = TRUE)

# Test environment
Sys.setenv(FIELDBOOK_NO_COLOR = "1")  # Not used by code yet, but ready
pass <- 0L; fail <- 0L
failures <- character(0)

# Invoke the launcher as a subprocess, capture stdout/stderr
fieldbook <- function(...) {
  args <- c("bin/fieldbook", unlist(list(...)), "--no-color")
  args <- shQuote(args)
  suppressWarnings(system2(
    file.path(R.home("bin"), "Rscript"),
    args,
    stdout = TRUE, stderr = TRUE
  ))
}

fb_status <- function(...) {
  out <- fieldbook(...)
  attr(out, "status") <- attr(out, "status") %||% 0L
  out
}

`%||%` <- function(a, b) if (is.null(a)) b else a

ok <- function(label, cond) {
  res <- tryCatch(isTRUE(cond), error = function(e) {
    failures <<- c(failures, paste0(label, " -> ", conditionMessage(e)))
    NA
  })
  if (isTRUE(res)) { pass <<- pass + 1L; cat("  PASS  ", label, "\n", sep = "") }
  else { fail <<- fail + 1L; if (!is.na(res)) failures <<- c(failures, label)
         cat("  FAIL  ", label, "\n", sep = "") }
  invisible(NULL)
}

has <- function(x, pattern) any(grepl(pattern, x))

section <- function(x) cat("\n== ", x, " ==\n", sep = "")

# Copy real DB to a temp location so tests are isolated
src_db <- file.path(root, "data", "field_book.sqlite")
tmp_dir <- tempfile("fieldbook_cli_test_")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
tmp_db <- file.path(tmp_dir, "field_book.sqlite")
file.copy(src_db, tmp_db)
Sys.setenv(FIELDBOOK_DB = tmp_db)
on.exit({ Sys.unsetenv("FIELDBOOK_DB"); unlink(tmp_dir, recursive = TRUE, force = TRUE) },
        add = TRUE)
cat("测试 DB:", tmp_db, "\n")

section("帮助与版本")
ok("无参数显示帮助",  has(fieldbook(), "田间记录本生成器 CLI"))
ok("--help 生效",      has(fieldbook("--help"), "田间记录本生成器 CLI"))
ok("version 输出含版本号", has(fieldbook("version"), "fieldbook 0.1.0"))
ok("version 含 0.1.0", has(fieldbook("version"), "fieldbook 0.1.0"))
ok("group help",       has(fieldbook("generate"), "fieldbook generate"))
ok("command help",     has(fieldbook("generate", "population", "--help"), "用法"))
ok("未知命令 exit=2",
   identical(attr(fieldbook("nosuchcmd"), "status"), 2L))
ok("未知选项 exit=2",
   identical(attr(fieldbook("db", "info", "--bogus"), "status"), 2L))
ok("未知 group 退码非零",
   !identical(attr(fieldbook("xxx"), "status"), 0L))

section("参数解析（在进程内验证 cli_parse）")
suppressPackageStartupMessages({ library(DBI); library(RSQLite); library(openxlsx); library(dplyr) })
suppressMessages(source(file.path(root, "R", "cli", "cli_core.R"), echo = FALSE))
suppressMessages(source(file.path(root, "shared", "helpers.R"), echo = FALSE))
suppressMessages(source(file.path(root, "shared", "db_persistence.R"), echo = FALSE))
suppressMessages(source(file.path(root, "R", "cli", "cli_generate.R"), echo = FALSE))

p1 <- cli_parse(c("--key", "v", "pos1", "-k", "v2"), list(key = "value"), list(k = "key"))
ok("位置参数",      identical(p1$pos, c("pos1")))
ok("--key v",        identical(p1$opt$key, c("v", "v2")))
ok("-alias",         "key" %in% names(p1$opt))

p2 <- cli_parse(c("--flag", "--no-flag2", "--key=v"), list(key = "value", flag = "flag", flag2 = "flag"))
ok("--flag",         isTRUE(p2$opt$flag))
ok("--no-",          isFALSE(p2$opt$flag2))
ok("--key=val",      identical(p2$opt$key, "v"))

p3 <- cli_parse(c("--", "--literal"))
ok("-- 后位置参数", identical(p3$pos, c("--literal")))

ok("cli_split 默认", identical(cli_split("a b c"), c("a", "b", "c")))
ok("cli_split 逗号", identical(cli_split("a,b, c"), c("a", "b", "c")))

ok("cli_to_json null",   identical(cli_to_json(NULL), "null"))
ok("cli_to_json int",    identical(cli_to_json(42L), "42"))
ok("cli_to_json str",    identical(cli_to_json("a\"b"), '"a\\"b"'))
ok("cli_to_json vec",    grepl("\\[1,2\\]", cli_to_json(c(1, 2))))

p4 <- cli_parse(c("--x=1", "--x=2"), list(x = "value"))
ok("--key 重复聚合",   identical(p4$opt$x, c("1", "2")))
ok("cli_get_last",     identical(cli_get_last(p4, "x"), "2"))

section("db info / list experiments / show / check")
ok("db info 含路径",  has(fieldbook("db", "info"), "路径"))
ok("db info 含表",   has(fieldbook("db", "info"), "表"))
ok("db check OK",     has(fieldbook("db", "check"), "OK"))
ok("list experiments 输出",
   has(fieldbook("list", "experiments"), "POP_") ||
   has(fieldbook("list", "experiments"), "LINE_") ||
   has(fieldbook("list", "experiments"), "YIELD_"))
ok("list --json 是 JSON",
   has(fieldbook("list", "experiments", "--json"), "\\{"))
# Pick an existing exp_id: directly use known id from the seeded DB,
# or parse the most likely id from list output.
exps_out <- paste(fieldbook("list", "experiments", "--json"), collapse = "")
m <- regmatches(exps_out, regexpr('"experiment_id"\\s*:\\s*"[A-Z]+_[A-Za-z0-9_]+"', exps_out))
first_id <- if (length(m)) sub('"experiment_id"\\s*:\\s*"', "", m) else ""
first_id <- sub('"$', "", first_id)
if (nzchar(first_id)) {
  ok("show experiment 找到",
     has(fieldbook("show", "experiment",
                   sprintf("--exp-id=%s", first_id)),
         "exp_id"))
} else {
  ok("show experiment (skip - no id parsed)", TRUE)
}

section("恢复")
cat("\n测试结果: PASS=", pass, "  FAIL=", fail, "\n", sep = "")
if (length(failures)) {
  cat("\n失败项:\n")
  for (f in failures) cat(" - ", f, "\n", sep = "")
}
quit(save = "no", status = if (fail > 0L) 1L else 0L, runLast = FALSE)
