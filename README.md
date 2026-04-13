# 田间记录本生成器 - Shiny 版本

基于 soyplant 库的田间试验规划 Shiny 应用，分为三种类型。

## 目录结构

```
shiny_version/
├── app.R                    # 主程序（类型选择界面）
├── shared/
│   └── helpers.R            # 共享辅助函数
├── www/
│   └── styles.css           # 样式文件
├── line_selection/          # 株行记录本
│   └── app.R
├── population/              # 群体记录本
│   └── app.R
├── yield_test/              # 初级产比记录本
│   └── app.R
└── README.md
```

## 三种记录本类型

### 1. 株行记录本 (line_selection)
- **功能**: 从上代种植计划或产比数据中选择单株，生成株行种植记录本
- **数据来源**: planting表（上代结果）
- **筛选条件**: `sele > 0` 的单株
- **处理函数**: `get_plant()` → `get_line()`
- **田间参数**: `interval=999, rp=1, rows=1`

### 2. 群体记录本 (population)
- **功能**: 处理群体数据（F1-F7），生成群体种植记录本
- **数据来源**: 包含世代(f)列的材料清单
- **特殊处理**: 行数(poprows)、种子数(seeds)
- **处理函数**: `get_population()`
- **田间参数**: `interval=999, rp=1, rows=2`

### 3. 初级产比记录本 (yield_test)
- **功能**: 处理杂交组合数据，生成初级产比及以上种植记录本
- **数据来源**: 包含母本(ma)、父本(pa)的杂交组合
- **特殊处理**: 对照品种(ck)
- **处理函数**: `get_primary()`
- **田间参数**: `interval=19, rp=2, rows=4`

## 安装依赖

```r
install.packages(c("shiny", "shinyjs", "dplyr", "openxlsx", "DT"))
devtools::install_github("zhaoqingsonga/soyplant")
```

## 运行方式

### 运行主程序（类型选择）
```r
setwd("shiny_version")
shiny::runApp()
```

### 直接运行特定类型
```r
setwd("shiny_version/line_selection")
shiny::runApp()

setwd("shiny_version/population")
shiny::runApp()

setwd("shiny_version/yield_test")
shiny::runApp()
```

## 输入数据格式

### 株行记录本
| 列名 | 说明 |
|------|------|
| fieldid | 材料田间ID |
| code | 材料编号 |
| ma | 母本 |
| pa | 父本 |
| stageid | 阶段 |
| name | 名称 |
| rows | 行数 |
| line_number | 行号范围 |
| rp | 重复数 |
| sele | 选择数 |

### 群体记录本
| 列名 | 说明 |
|------|------|
| fieldid | 材料田间ID |
| code | 材料编号 |
| ma | 母本 |
| pa | 父本 |
| f | 世代 |
| stageid | 阶段 |
| 实际种行数 | 实际种植行数 |
| 收获粒数 | 收获种子数(可选) |

### 产比记录本
| 列名 | 说明 |
|------|------|
| fieldid | 材料田间ID |
| code | 材料编号 |
| ma | 母本 |
| pa | 父本 |
| stageid | 阶段 |
| name | 名称 |
| rows | 行数 |

## 输出文件

### 株行记录本
- **origin**: 原始数据
- **material**: 处理后的材料数据
- **planting**: 种植计划
- **myview**: 视图
- **combi_matrix**: 组合矩阵

### 群体记录本 / 产比记录本
- **origin**: 原始数据
- **planting**: 种植计划
- **myview**: 视图
- **combi_matrix**: 组合矩阵
