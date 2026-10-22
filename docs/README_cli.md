# 田间记录本生成器 - CLI

田间记录本生成器的命令行版本，与 Shiny 应用功能等价，可在终端或脚本里批量调度。

## 安装

依赖已在 `app.R` 同名包中声明：`shiny`, `bslib`, `shinyjs`, `DT`, `dplyr`, `openxlsx`,
`soyplant`（GitHub 私有包）、`DBI`, `RSQLite`, `jsonlite`（可选）。

## 启动

```sh
# 进入项目根目录
cd /path/to/make_field_book

# 帮助
./bin/fieldbook

# 详细命令
./bin/fieldbook <group> <command> --help
```

任何子目录下都可以执行 — 启动器会向上查找 `data/` 与 `shared/` 定位项目根。

## 全局选项

| 选项 | 含义 |
|------|------|
| `--db <path>` | 数据库路径（默认 `data/field_book.sqlite`，也可用 `FIELDBOOK_DB` 环境变量覆盖） |
| `--json` | 输出 JSON，禁用彩色与装饰文字（适合管道） |
| `--yes` | 对确认提示自动回答 yes（非交互环境也会通过） |
| `--no-color` | 关闭 ANSI 颜色 |
| `--empty-dash` | 缺失值显示为空字符串而不是 `-` |

## 命令一览

```
db
  info                 数据库概览（路径、大小、表、记录数）
  check                数据库完整性检查（PRAGMA integrity_check）
  migrate              同步旧分类表到 unified_records / unified_materials

list
  experiments          列出试验记录（可按 --type 过滤）
  field-records        列出已生成的田试记录（planting + 88 性状）

show
  experiment           查看一次试验的元信息 + 材料明细

delete
  experiment           删除试验记录（联动删除 field_records / 不可恢复）
  field-record         只删除田试记录（不删试验元信息），并重置 has_generated

generate
  population           群体记录本生成（F1-F7 → planting）
  line-selection       株行记录本生成（sele>0 → get_plant | get_line → planting）
  yield-test           产比记录本生成（杂交组合 → get_primary → planting）
```

## 完整示例

### 群体记录本生成

```sh
./bin/fieldbook generate population data/pop_2025.xlsx \
  --min-f=2 --max-f=6 \
  --ck="中黄301" --interval=20 \
  --rp=1 --rows=2 --prefix=N25F2P \
  --location="安徽宿州 山东济宁" \
  --out=out/pop_2025.xlsx
```

### 株行记录本生成

```sh
./bin/fieldbook generate line-selection data/lines_2025.xlsx \
  --ck="冀豆12 冀豆17" --rp=1 --rows=1 \
  --prefix=N25bL --location="安徽宿州" \
  --out=out/lines_2025.xlsx
```

### 产比记录本（按地点独立 ck 与行数）

```sh
./bin/fieldbook generate yield-test data/yield_2025.xlsx \
  --promote="初级产比" --target-stage="高级产比" \
  --ck="(中黄301 皖豆37) 齐黄34" \
  --rows="4 4" \
  --rp=2 --interval=19 \
  --out=out/yield_2025.xlsx
```

`--ck="(中黄301 皖豆37) 齐黄34"` 含义：地点 1 用双对照（中黄301 + 皖豆37），地点 2 用齐黄34。
`--rows="4 4"`：`generate yield-test` 每地点可独立指定行数。

### 查询 / 审计 / 删除

```sh
# 列出所有试验
./bin/fieldbook list experiments

# 只看群体试验（JSON）
./bin/fieldbook list experiments --type=population --json

# 查看一次试验的 116 行材料
./bin/fieldbook show experiment --exp-id=POP_20260416164450_2336

# 仅导出已生成的田试（CSV / Excel 由 --json 替代）
./bin/fieldbook list field-records --type=population --exp-id=POP_20260416164450_2336

# 删除田试记录但不删试验（重置 has_generated=0）
./bin/fieldbook delete field-record --exp-id=POP_20260416164450_2336 --yes

# 完全删除试验
./bin/fieldbook delete experiment --exp-id=POP_20260413143038_5979 --yes
```

### 脚本化管道

```sh
# 循环处理某目录所有 Excel
for f in data/pop_batches/*.xlsx; do
  ./bin/fieldbook generate population "$f" \
    --ck="中黄301" --location="安徽宿州" \
    --out="out/$(basename "$f" .xlsx).xlsx"
done

# 批量重置未生成记录
./bin/fieldbook list experiments --json --no-color \
  | python3 -c '
import json,sys,subprocess
for e in json.load(sys.stdin):
    if e["generated"] == "未生成":
        subprocess.check_call(
            ["./bin/fieldbook","delete","experiment",
             f"--exp-id={e[\"experiment_id\"]}","--yes"])'
```

## 实现要点

- **不引入新依赖**：与 Shiny 共用 `shared/db_persistence.R`（WAL + busy_timeout 复用）
- **剥离 Shiny 反应层**：原 `doGenerate()` 收到 `input$xxx`、`rv$yyy`、`updateXxxInput()`；
  CLI 改为纯函数 `do_generate_population()` 等
- **与 Shiny 共用核心修复**：`merge_extra_cols()` 是 DEVELOPMENT.md 中提到的"备份 is_ck、merge 后恢复"
  防御，所有 generate 命令都引用同一段
- **行的三键兜底**：仅群体模块需要，`recompute_rows_population()` 按 `source → name → code`
  优先级回溯 `new_rows`，CK 行（`is_ck==1 && is.na(source)`）使用 `ck_rows`（默认 4）
- **多地点**：`Sys.sleep(1.2)` 在两次 `planting()` 之间防 fieldid 冲突
- **唯一 ID**：`POP_YYYYMMDDHHMMSS_NNNN` / `LINE_` / `YIELD_`，与 Shiny `saveXxxRecord()` 一致

## 测试

```sh
Rscript tests/test_cli.R
```

- 在临时目录创建测试 DB（拷贝自 `data/field_book.sqlite`），不会污染真实数据
- 覆盖：参数解析、帮助/版本、未知命令/选项的退出码、JSON 输出、表渲染、db info/check/list/show
- **不测试 generate 命令** — 需要真实 Excel，会写库，在专用集成环境里另外做

## 已知限制

| 限制 | 备注 |
|------|------|
| 字段映射 modal | 不支持 — Excel 列必须匹配必填字段名（见命令说明）。Shiny 里的字段映射对话框需要交互，CLI 不实现 |
| 选择数拆分 | 株行的"sele=0 自动跳过"等价于 Shiny 行为；CLI 不弹选择 |
| 编辑已生成 | 先用 `delete field-record --exp-id=...` 重置，再 regenerate |
| 进度条 | CLI 无进度条；多地点时静默等待 `planting()` 返回 |

## 与 soy_cross_v2 的关系

本 CLI 完全自包含，与 `~/GitHub/soy_cross_v2/R/cli/` 没有代码共享。结构与命名约定
（`cli_core.R` 工具、`dispatch.R` 注册表、`cli_env` 局部命名空间、`bin/<cmd>` 入口）有意
对齐，便于作者在两个项目间切换维护。
