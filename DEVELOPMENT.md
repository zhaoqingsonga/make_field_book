# 田间记录本生成器 - 技术文档

## 项目概述

田间记录本生成器是一个基于 R Shiny 的 Web 应用，用于处理作物育种试验数据，生成田间种植记录本。

### 三种记录本类型

| 类型 | 模块 | 数据来源 | 核心函数 |
|------|------|----------|----------|
| 群体记录本 | mod_population | 上代种植计划（群体） | get_population() → planting() |
| 株行记录本 | mod_line_selection | 上代 planting 结果 | get_plant() → get_line() → planting() |
| 产比记录本 | mod_yield_test | 杂交组合数据 | get_primary() → planting() |

---

## 目录结构

```
make_field_book/
├── app.R                    # 主程序（类型选择界面）
├── README.md                 # 用户说明文档
├── DEPLOYMENT.md            # 部署说明文档
├── DEVELOPMENT.md           # 本文档（开发者技术文档）
├── shared/
│   ├── helpers.R            # 共享辅助函数
│   ├── db_persistence.R      # SQLite 数据库操作
│   ├── mod_population.R      # 群体记录本模块
│   ├── mod_line_selection.R  # 株行记录本模块
│   └── mod_yield_test.R     # 产比记录本模块
├── data/                     # 数据目录（SQLite 数据库）
└── www/
    └── styles.css           # 样式文件
```

---

## 核心数据流程

### 1. 群体记录本流程

```
上传Excel → rv$materials → 世代筛选 → get_population()
                                        ↓
                                  mydata (升级后)
                                        ↓
                                  planting()
                                        ↓
                                  planted_loc
                                        ↓
                                  合并字段（merge）
                                        ↓
                                  计算 rows/line_number
                                        ↓
                                  输出记录本
```

### 2. 数据字段说明

#### 上传数据必需字段

| 字段 | 说明 | 适用于 |
|------|------|--------|
| name | 材料名称 | 全部 |
| ma | 母本 | 全部 |
| pa | 父本 | 全部 |
| f | 世代 | 群体 |
| stageid | 阶段ID | 全部 |
| new_rows | 种植行数 | 群体 |
| next_stage | 下一阶段 | 群体 |

#### planting() 输出字段

| 字段 | 说明 |
|------|------|
| fieldid | 田间ID |
| id | 材料ID |
| name | 材料名称 |
| ma | 母本 |
| pa | 父本 |
| source | 来源（原始name） |
| rows | 种植行数 |
| line_number | 行号范围（如"1-4"） |
| is_ck | 是否对照行（1=对照，0=材料） |
| place | 试验地点 |
| rp | 重复号 |

---

## planting() 参数说明

| 参数 | 说明 | 默认值 | 适用 |
|------|------|--------|------|
| ck | 对照品种（空格分隔多个） | NULL | 全部 |
| interval | 对照间隔数 | 999（不起作用） | 全部 |
| ck_rows | 对照行数 | 4 | 群体 |
| rows | 材料种植行数 | 4 | 产比 |
| rp | 重复数 | 1 | 全部 |
| digits | 编号位数 | 3 | 全部 |
| prefix | 材料前缀 | "N25F2P" | 群体 |
| location | 试验地点 | "安徽宿州" | 全部 |
| ckfixed | 对照是否固定 | TRUE | 全部 |
| startN | 起始编号 | 1 | 全部 |

---

## 核心函数调用

### get_population()

```r
mydata <- get_population(mydata)
```

- 功能：升级群体到下一阶段
- 输入：包含 `name`, `next_stage`, `f`, `ma`, `pa` 等字段的数据框
- 输出：新数据框，`source` 保存原始 `name`，`f` 加1

### planting()

```r
planted <- mydata %>% planting(
  interval = 19,
  s_prefix = "GC",
  place = "安徽宿州",
  rp = 2,
  digits = 3,
  ck = c("冀豆12", "冀豆17"),
  ckfixed = TRUE,
  restartfid = TRUE,
  startN = 1
)
```

- 功能：生成田间种植计划
- 输入：材料数据框
- 输出：包含种植计划的数据框，自动插入对照行

---

## 关键实现细节

### 1. merge 操作会覆盖列

**问题：** 在 mod_population.R 中，使用 merge 合并 extra_cols 时，merge 会覆盖 `is_ck` 列。

**原因：** merge 使用 `all.x = TRUE` 时，会产生 NA 行用于匹配。

**解决方案：**
```r
# 1. 保存原始 is_ck
original_is_ck <- planted_loc$is_ck

# 2. 执行 merge
planted_loc <- merge(planted_loc, mydata[, c(merge_keys, extra_cols), drop = FALSE],
                     by = merge_keys, all.x = TRUE, sort = FALSE)

# 3. 恢复 is_ck（不被 merge 覆盖）
planted_loc$is_ck <- original_is_ck
```

### 2. 对照行与材料行的区分

```r
# 对照行：is_ck == 1 且 source 是 NA
# 材料行：否则（包括 is_ck == 0 或 is_ck == 1 但 source 有值）

if (is_ck_i == 1L && is.na(src)) {
  # 对照行：用 ck_rows_val
} else {
  # 材料行：用 source_to_rows 查找 new_rows
}
```

### 3. new_rows 的保存与恢复

```r
# 1. 保存 new_rows 向量
.new_rows_vec <- as.numeric(mydata[[rows_col]])
.new_rows_vec[is.na(.new_rows_vec) | .new_rows_vec <= 0] <- 1

# 2. 过滤后按位置匹配恢复
if (length(.new_rows_vec) == nrow(mydata)) {
  mydata$.actual_rows <- .new_rows_vec
}

# 3. 创建 source -> new_rows 映射
source_to_rows <- setNames(mydata$.actual_rows, mydata$source)
```

---

## 数据库表结构

### population_records（群体记录表）

| 字段 | 类型 | 说明 |
|------|------|------|
| record_id | INTEGER | 主键 |
| experiment_id | TEXT | 试验ID |
| experiment_name | TEXT | 试验名称 |
| total_rows | REAL | 总行数 |
| has_generated | INTEGER | 是否已生成 |
| raw_data | TEXT | JSON 格式原始数据 |
| generated_at | TEXT | 生成时间 |
| created_at | TEXT | 创建时间 |
| updated_at | TEXT | 更新时间 |

### 田试记录表

- `population_field_records`：群体田试记录
- `line_selection_field_records`：株行田试记录
- `yield_test_field_records`：产比田试记录

包含字段：fieldid, id, user, stageid, name, ma, pa, mapa, memo, stage, next_stage, f, sele, process, path, source, former_fieldid, former_stageid, code, rp, treatment, place, rows, line_number, is_ck, 88个性状字段

---

## 常见问题与解决方案

### 1. merge 覆盖 is_ck

**现象：** 加对照后所有行的 is_ck 都变成 1

**解决：** 在 merge 前保存 is_ck，merge 后恢复

### 2. new_rows 过滤无效

**现象：** new_rows > 0 的过滤没有生效

**原因：** 之前代码先把 <=0 的值替换成 1，再做过滤，导致过滤条件失效

**解决：** 先过滤，再替换：
```r
# 错误：
.new_rows_vec[is.na(x) | x <= 0] <- 1  # 先替换
mydata <- mydata[x > 0, ]               # 过滤失效

# 正确：
valid_mask <- !is.na(x) & x > 0        # 先过滤
mydata <- mydata[valid_mask, ]
.new_rows_vec <- .new_rows_vec[valid_mask]
```

### 3. is_ck 是浮点数

**现象：** is_ck 显示为 1.0、0.0 而不是 1、0

**解决：** 在 soyplant 包的 planting.R 和 zzz_patch.R 中使用整数：
```r
# 错误：
df_list$is_ck <- ifelse(is.na(df_list$is_ck), 0, 1)

# 正确：
df_list$is_ck <- ifelse(is.na(df_list$is_ck), 0L, 1L)
```

### 4. 88个性状列丢失

**现象：** 生成的田试记录中没有88个性状列

**原因：** soyplant 包中各函数的列保留行为不同：

| 函数 | 行处理方式 | 列保留 |
|------|-----------|--------|
| `get_primary()` | `subset()` 筛选行 | **保留**所有列 |
| `get_plant()` | `expand_rows()` 扩展行 | **保留**所有列 |
| `get_line()` | `subset()` 筛选行 | **保留**所有列 |
| `get_population()` | 创建新数据框，只复制特定列 | **丢失**88列 |

只有 `get_population()` 会丢失88个性状列，需要额外处理。

**解决：** 在 `get_population()` 之前保存88列，之后用 `source` 作为键 merge 回来：
```r
# 1. 保存88个性状列（在 get_population 之前）
trait_cols <- c("XiaoQuShiShouMianJi", "XiaoQuChanLiang", ...)
trait_cols_exist <- trait_cols[trait_cols %in% names(mydata)]
if (length(trait_cols_exist) > 0) {
  origin_for_trait <- mydata[, c("name", trait_cols_exist), drop = FALSE]
  names(origin_for_trait)[1] <- "source"  # 重命名，用于后续 merge
} else {
  origin_for_trait <- NULL
}

# 2. 调用 get_population（会丢失 trait 列）
mydata <- soyplant::get_population(mydata)

# 3. planting 生成田间布局

# 4. 合并88个性状列（用 source 作为键）
if (!is.null(origin_for_trait) && "source" %in% names(planted_loc)) {
  planted_loc <- merge(planted_loc, origin_for_trait,
                       by = "source", all.x = TRUE, sort = FALSE)
}
```

**各模块的处理：**
- **群体模块**：需要 trait 处理（`get_population()` 丢失列）
- **产比模块**：不需要（`get_primary()` 保留列）
- **株行模块**：不需要（`get_plant()/get_line()` 保留列）

---

## 开发注意事项

### 1. 数据过滤顺序

1. 世代筛选（min_f, max_f）
2. new_rows > 0 筛选
3. get_population() 筛选（next_stage == "群体"）
4. planting() 添加对照行

### 2. 列名规范

- 统一使用 `new_rows`（复数），不要使用 `new_row`
- `is_ck` 使用整数 0/1，不要使用浮点数

### 3. merge 操作规范

如果需要 merge 且结果中包含被覆盖的列，必须在 merge 前保存，merge 后恢复。

---

## 依赖包

```r
install.packages(c("shiny", "shinyjs", "dplyr", "openxlsx", "DT", "DBI", "RSQLite", "jsonlite"))
devtools::install_github("zhaoqingsonga/soyplant")
```

---

## macOS / PM2 踩坑（经验教训，2026-10-22 整理）

### 症状

在 macOS 上跑 PM2 会反复遇到：

1. `pm2 start ecosystem.config.js` 看似成功（daemon 进程创建、`App launched` 打印），但紧接的 `pm2 list` / `pm2 ping` / `pm2 save` 立刻报：
   ```
   connect EPERM /Users/m4/.pm2/rpc.sock
   Error: EPERM: operation not permitted, open '/Users/m4/.pm2/pm2.log'
   ```
2. daemon 进程存在但僵死：不响应 RPC，新调用阻塞到挂死
3. 已经 fork 出去的子进程（如 R Shiny on 3636）能继续处理旧 TCP 连接，但 PM2 客户端全部失效

### 根因

macOS Sonoma+ 会自动给 **未签名 node 进程新建的文件** 打上 `com.apple.provenance` xattr。被标记后，**后续同二进制再次写入** 即返回 EPERM。复现：

```sh
$ xattr /Users/m4/.pm2/pm2.log
com.apple.provenance

$ node -e 'require("fs").appendFileSync("/Users/m4/.pm2/pm2.log", "x")'
Error: EPERM: operation not permitted, open '/Users/m4/.pm2/pm2.log'
```

触发条件 **对路径不敏感**——`~/.pm2/` 还是项目内的 `./.pm2-runtime/` 都一样被打标。nvm 装的 node（`/Users/m4/.nvm/versions/node/.../bin/node`）属于"未签名"类别。

影响面：

- `pm2 start ecosystem.config.js`（首次）：daemon 内部日志阻塞，看似在线
- `pm2 list` / `pm2 save` 等后续 client 调用：EPERM，挂死
- `pm2 startup` 提示的 `sudo env ... pm2 startup launchd -u m4 --hp /Users/m4`：写 `/Library/LaunchDaemons/`，需要 sudo 密码
- 修改/删除 `~/Library/LaunchAgents/pm2.m4.plist`：macOS 锁该路径，`Operation not permitted` 拒所有变更
- 在沙箱 / 受限 shell 中 `kill` 跨进程的 PM2 子进程：沙箱禁跨进程信号

### 推荐方案（按可靠性递减）

1. **不用 PM2**，用 `./run.sh` 直接拉起 Shiny。开发机足够，端口冲突时改 `run.sh` 里 `PORT=3636` 即可。
2. **换成 homebrew 装的 node + pm2**：`brew install node` 然后 `npm i -g pm2`。homebrew 安装的二进制有合法 `codesign`，可能规避 provenance xattr。代价：放弃 nvm 那一套环境。
3. **手动 `pm2 resurrect`**：开机后在 shell 里跑一次。可以在 `~/.zshrc` 加一行 alias：
   ```sh
   alias pm2live='pm2 resurrect 2>/dev/null || pm2 start /Users/m4/GitHub/make_field_book/ecosystem.config.js'
   ```
4. **完全放弃开机自启**：本项目只有一个进程，宕机时手敲 `bash run.sh` 也只多 5 秒。

### 死透后的清理步骤

如果遇到 daemon 僵死：

```sh
# 1. 找 zombie 子进程（如 Shiny R）
lsof -iTCP:3636 -sTCP:LISTEN

# 2. 强制结束（拿不到 sudo 时换无沙箱的 shell）
sudo kill -9 <pid>

# 3. 删 dangling Unix socket
rm -f /Users/m4/.pm2/{rpc,pub}.sock

# 4. 重新拉起
pm2 start ecosystem.config.js
pm2 save
```

注意：第 3 步只解 socket 阻塞，xattr 后续仍会触发。要彻底解决按"推荐方案"做。

### 已落地的好习惯

- `bin/fieldbook` 的 `+x` 位由 `run.sh` 启动时 `chmod` 防御（提交 `bf52e07`）
- `ecosystem.config.js` 的 `cwd` 修正为真实项目路径（提交 `dc699ef`）
- CLI 与 Shiny 共用 `data/field_book.sqlite`，CLI 自带 `--json` 模式——批处理场景不必依赖 PM2
