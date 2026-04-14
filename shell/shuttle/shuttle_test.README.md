# shuttle_test.sh — Shuttle 多维度组网测试脚本

基于 Shuttle 工具的多机多维度 InfiniBand 组网带宽测试，自动遍历 **场景类型 × 模式 × QP** 全组合，收集汇总结果。

## 前置条件

- 所有节点已部署 `shuttle` 二进制（可使用 `deploy_shuttle.sh`）
- 所有节点已部署 `perftest`（config.ini 中 `cmds` 指定的工具路径需可执行）
- 主节点到所有 slave 节点已配置 SSH 免密登录
- 配置文件 `config.ini.incast`、`config.ini.m2n`、`config.ini.all2all` 已准备好
- GDR 测试需节点安装 GPU 驱动（nvidia / ppu），且 perftest 支持 `--use_cuda`

## 配置文件

配置文件格式示例（`config.ini.incast`）：

```ini
[SHUTTLE]
hosts=10.36.33.110:mlx5_bond_2,...
servers=1

[CONTINUOUS]
cmds=/opt/pg1-tests/perftest/bin/ib_write_bw -x 3 -F --tclass=16 --report_gbits
qp=1
duration=30
gdr=false
```

关键字段：
- `cmds`：底层 perftest 命令，GDR 测试时脚本自动追加 `--use_cuda=<gpu_id>`
- `qp`：QP 数量，由脚本动态修改
- `duration`：测试时长，由脚本动态修改
- `gdr`：保持 `false`，GDR 功能由 `cmds` 中的 `--use_cuda` 参数控制

## 命令行选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-t, --type TYPE` | 测试场景：`incast` / `m2n` / `all2all` / `all` | `all` |
| `-m, --mode MODE` | 测试模式：`mem` / `gdr` / `all` | `all` |
| `-q, --qp-list LIST` | QP 列表，逗号分隔 | `1,4,8,16,32,64,128,256,512` |
| `-d, --duration SEC` | 每个 case 的持续时间（秒） | `30` |
| `-s, --shuttle PATH` | shuttle 二进制路径 | `./shuttle` |
| `-c, --config-dir DIR` | 配置文件目录 | `.` (当前目录) |
| `-r, --result-dir DIR` | 结果输出目录 | `./shuttle_result` |
| `--no-bind` | 禁用网卡绑核（默认启用 `-bind`） | 启用 |
| `--no-numa` | 禁用 NUMA 亲和绑定 | 启用 |
| `--dry-run` | 仅显示命令，不实际运行 | — |

## 用法示例

```bash
# 执行所有测试（3场景 × 2模式 × 9个QP = 54个case）
./shuttle_test.sh

# 仅 incast 内存测试
./shuttle_test.sh -t incast -m mem

# all2all 场景，指定 QP 列表
./shuttle_test.sh -t all2all -q "16,32,64"

# m2n 显存测试
./shuttle_test.sh -t m2n -m gdr -q "8,16"

# 预览所有要执行的命令（不实际运行）
./shuttle_test.sh --dry-run

# 每个 case 测试 60 秒
./shuttle_test.sh -d 60
```

## 测试场景说明

| 场景 | 说明 | 典型拓扑 |
|------|------|----------|
| `incast` | N→1 汇聚 | 多 client → 1 server |
| `m2n` | M→N 多对多 | 多 client → 多 server |
| `all2all` | 全互联 | 所有节点两两互联 |

每个场景分别在 **Mem（内存）** 和 **GDR（显存）** 模式下运行，遍历所有指定的 QP 数量。

## 输出结果

### 控制台

每个 case 输出实时带宽结果（从 `report.csv` 的 `sum(rx)` 提取），多个 server 用 `/` 分隔：

```
--- 1/18 Mem QP=1 ---
220.11/218.26/221.47/225.27 Gbps (耗时: 35s)
```

测试结束后输出纵向汇总表：

```
========== shuttle m2n 测试结果汇总 ==========
--- Mem ---
QP=1       220.11/218.26/221.47/225.27
QP=4       225.87/226.03/226.14/226.32
...

--- GDR ---
QP=1       196.90/226.44/226.52/226.42
...
```

### 文件

结果保存在 `./shuttle_result/` 目录：

- `shuttle_<场景>_result_<时间>.txt` — 汇总结果文件
- `shuttle_<场景>_raw_<时间>.log` — 包含每个 case 的 shuttle stdout 原始输出

## NUMA & GPU 亲和

- **NUMA 绑定**：默认启用，自动检测 IB 设备所在 NUMA 节点，通过 `bash -c 'numactl --cpunodebind=N --membind=N <cmd>'` 包装 cmds
- **GPU 亲和**：GDR 模式下，自动检测与 IB 设备亲和的 GPU ID（通过 `ppu-smi topo -m` / `nvidia-smi topo -m`），若无亲和 GPU 则默认使用 GPU 0
- **绑核**：默认启用 shuttle 的 `-bind` 选项，保证每张网卡使用亲和的 CPU
