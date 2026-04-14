# ib_lat_test.sh — InfiniBand 时延测试脚本

点对点 InfiniBand RDMA 时延测试，支持内存和 GDR（显存）场景，使用 `-a` 模式一次性测试所有消息大小。

## 前置条件

- Client 和 Server 均已安装 `perftest`（或通过 `--perftest-path` 指定自定义路径）
- Client 到 Server 已配置 SSH 免密登录
- 安装 `pssh`（用于远程进程管理）
- IB 设备已配置并可用

## 使用前配置

编辑脚本顶部「配置区域」：

```bash
SERVER_IP="10.36.33.111"     # Server 管理IP（SSH登录用）
SERVER_USER="root"
IB_DEV="mlx5_bond_2"        # IB 设备名
TCLASS="16"
GID_INDEX="3"
ITERATIONS="10000"           # 每种消息大小的迭代次数
```

## 命令行选项

| 选项 | 说明 |
|------|------|
| `-t TYPE` | 测试类型：`all`(默认) / `write` / `read` / `send` |
| `--gdr` | 启用 GDR 时延测试（默认仅内存测试） |
| `--no-numa` | 禁用 NUMA 亲和绑定（默认启用） |
| `--no-gpu-affinity` | 禁用网卡-显卡亲和检测，GDR 使用 GPU 0 |
| `--perftest-path PATH` | 指定 perftest 工具目录 |

## 用法示例

```bash
# 全部测试（仅内存）
bash ib_lat_test.sh

# 全部测试（内存 + GDR）
bash ib_lat_test.sh --gdr

# 仅 write 时延
bash ib_lat_test.sh -t write

# 仅 read 时延 + GDR
bash ib_lat_test.sh -t read --gdr

# 使用自定义 perftest 路径，不绑定 NUMA
bash ib_lat_test.sh --perftest-path /opt/pg1-tests/perftest/bin --no-numa
```

## 测试模式

使用 perftest 的 `-a -F` 参数，一次性测试所有消息大小（2B ~ 8MB，共 23 种），无需逐个 size 启停 server。

每种工具（write/read/send）执行：

| # | 场景 | 说明 |
|---|------|------|
| 1 | Mem | 内存时延测试（默认执行） |
| 2 | GDR | 显存时延测试（需 `--gdr` 开启） |

## 输出文件

结果保存在 `./ib_lat_result/` 目录：

- `perf_<clientIP>_<serverIP>_ib_<type>_lat_result_<时间>.txt` — 格式化的时延结果
- `perf_<clientIP>_<serverIP>_ib_<type>_lat_raw_<时间>.log` — 原始 perftest 输出

## 输出指标

| 列名 | 说明 |
|------|------|
| `#bytes` | 消息大小 |
| `#iterations` | 迭代次数 |
| `t_min` | 最小时延 (μs) |
| `t_max` | 最大时延 (μs) |
| `t_typical` | 典型时延 (μs) |
| `t_avg` | 平均时延 (μs) |
| `t_stdev` | 标准差 (μs) |
| `99%` | P99 时延 (μs) |
| `99.9%` | P99.9 时延 (μs) |
