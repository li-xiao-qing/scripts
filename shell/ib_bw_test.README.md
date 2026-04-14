# ib_bw_test.sh — InfiniBand 带宽测试脚本

点对点 InfiniBand RDMA 带宽测试，支持内存 / GDR（显存）/ 双卡场景，自动检测 NUMA 和 GPU 亲和。

## 前置条件

- Client 和 Server 均已安装 `perftest`（或通过 `--perftest-path` 指定自定义路径）
- Client 到 Server 已配置 SSH 免密登录
- 安装 `pssh`（用于远程进程管理）
- IB 设备已配置并可用（`ibdev2netdev` 可查看）

## 使用前配置

编辑脚本顶部「配置区域」：

```bash
SERVER_IP="10.36.33.111"     # Server 管理IP（SSH登录用）
SERVER_USER="root"
IB_DEV="mlx5_bond_2"        # IB 设备名
TCLASS="16"
GID_INDEX="3"
DURATION="5"                 # 每个QP测试持续时间(秒)
MSG_SIZE="65536"             # 消息大小(bytes)
```

## 命令行选项

| 选项 | 说明 |
|------|------|
| `-t TYPE` | 测试类型：`all`(默认) / `write` / `read` / `send` |
| `--dual-gpu` | 启用双卡 GDR 测试（同 bond 下 2 张 GPU 并行，带宽求和） |
| `--no-numa` | 禁用 NUMA 亲和绑定（默认启用 `numactl --cpunodebind --membind`） |
| `--no-gpu-affinity` | 禁用网卡-显卡亲和检测，GDR 使用 GPU 0 |
| `--perftest-path PATH` | 指定 perftest 工具目录（如 `/opt/pg1-tests/perftest/bin`） |

## 用法示例

```bash
# 全部测试（write/read/send × 内存&GDR × 单向&双向 × CM&非CM）
bash ib_bw_test.sh

# 仅 write 测试
bash ib_bw_test.sh -t write

# 使用自定义 perftest 路径
bash ib_bw_test.sh --perftest-path /opt/pg1-tests/perftest/bin

# 全部测试 + 双卡 GDR 场景
bash ib_bw_test.sh --dual-gpu

# 不绑定 NUMA，GDR 使用 GPU 0
bash ib_bw_test.sh --no-numa --no-gpu-affinity
```

## 测试场景

每种工具（write/read/send）默认执行 8 个场景，QP 遍历 1/4/16/64/128/256/512/1024：

| # | 场景 | 方向 | 模式 | CM |
|---|------|------|------|----|
| 1 | Uni-Mem | 单向 | 内存 | 否 |
| 2 | Uni-Mem-CM | 单向 | 内存 | 是 |
| 3 | Uni-GDR | 单向 | 显存 | 否 |
| 4 | Uni-GDR-CM | 单向 | 显存 | 是 |
| 5 | Bidi-Mem | 双向 | 内存 | 否 |
| 6 | Bidi-Mem-CM | 双向 | 内存 | 是 |
| 7 | Bidi-GDR | 双向 | 显存 | 否 |
| 8 | Bidi-GDR-CM | 双向 | 显存 | 是 |

使用 `--dual-gpu` 时额外增加场景 9-12（双卡 GDR）。

GPU 不可用时自动跳过 GDR 相关场景（3-4, 7-8）。

## 输出文件

结果保存在 `./ib_bw_result/` 目录：

- `perf_<clientIP>_<serverIP>_ib_<type>_bw_result_<时间>.txt` — 格式化的带宽结果
- `perf_<clientIP>_<serverIP>_ib_<type>_bw_raw_<时间>.log` — 原始 perftest 输出

## 亲和性说明

- **NUMA 绑定**：默认启用，自动检测 IB 设备所在 NUMA 节点，使用 `numactl --cpunodebind=N --membind=N` 绑定所有测试（内存 + GDR）
- **GPU 亲和**：默认启用，通过 `ppu-smi topo -m` / `nvidia-smi topo -m` 解析 PIX 关系，选择与 IB 设备亲和的 GPU
