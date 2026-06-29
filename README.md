# FIO 磁盘性能自动化测试工具

基于 [fio](https://github.com/axboe/fio)（Flexible I/O Tester）的磁盘性能自动化测试与报告生成工具集，支持一键执行标准测试并生成可读性好的性能报告。

## 概览

本工具包含两个脚本：

| 脚本                 | 作用                                  |
| ------------------ | ----------------------------------- |
| `fio_auto_test.sh` | 磁盘性能测试执行器，按预设参数运行 4 项标准 FIO 基准测试    |
| `fio_summary.sh`   | 结果汇总报告生成器，扫描 JSON 结果并输出易读的文本/CSV 报告 |

测试结果以 JSON 格式按场景存放，汇总报告输出到独立目录，结构清晰便于归档对比。

## 环境要求

### 前置依赖

| 工具    | 用途               | 安装                                                                   |
| ----- | ---------------- | -------------------------------------------------------------------- |
| `fio` | 磁盘 I/O 性能测试      | `sudo apt install fio` / `sudo yum install fio` / `brew install fio` |
| `jq`  | JSON 解析（仅汇总脚本需要） | `sudo apt install jq` / `sudo yum install jq`                        |
| `bc`  | 浮点数计算（通常预装）      | `sudo apt install bc`                                                |

## 快速开始

```bash
# 文件系统测试 — 默认参数
./fio_auto_test.sh --test-dir /data/test/fio -y

# 裸设备测试 — 直接测整块磁盘
./fio_auto_test.sh --raw-device /dev/sdb -y

# 轻量测试 — 自定义参数
./fio_auto_test.sh --runtime 60 --size 10G -y

# 自定义场景 — 只跑需要的测试
./fio_auto_test.sh --scenarios "4k-randread:randread:4k,128k-seqwrite:write:128k"

# 配置文件 — 避免每次手改参数
./fio_auto_test.sh --config fio_test.conf -y

# 后台运行 — 退出 Shell 不中断
./fio_auto_test.sh --daemon --raw-device /dev/nvme0n1 -y

# 查看完整帮助
./fio_auto_test.sh -h
```

### 查看结果

```bash
# 扫描默认目录并输出到终端
./fio_summary.sh

# 同时生成 CSV 报告（可导入 Excel）
./fio_summary.sh -c

# 指定其他结果目录
./fio_summary.sh -d ./fio_results/hdd-vfs-cache-full
```

---

## fio_auto_test.sh — 测试执行器

执行标准 FIO 基准测试，涵盖随机/顺序读写的常见场景。场景定义在 `TEST_SCENARIOS` 数组中，可自由增删。

### 默认测试项

| 测试名称         | I/O 模式 | 块大小 | 衡量指标         |
| ------------ | ------ | --- | ------------ |
| 4k-randread  | 随机读    | 4KB | 随机读 IOPS 与延迟 |
| 4k-randwrite | 随机写    | 4KB | 随机写 IOPS 与延迟 |
| 4m-seqread   | 顺序读    | 4MB | 顺序读带宽        |
| 4m-seqwrite  | 顺序写    | 4MB | 顺序写带宽        |

通过 `--scenarios` 可覆盖为任意场景组合，格式 `名称:读写模式:块大小[:读占比]`。
读占比为可选字段（1~99），仅在 `randrw` / `rw` 模式下生效，默认 50（即读写各半）。

### 用法

```
用法: ./fio_auto_test.sh [选项]

选项:
  -y, --yes                自动模式，跳过确认直接执行
  -h, --help               显示此帮助信息
  --daemon                 守护模式，后台运行，退出 Shell 后不中断
  --config <文件>          从配置文件加载参数（默认: ./fio_test.conf）

  测试参数覆盖:
  --runtime <秒>           每项测试运行时长 (默认: 300)
  --ramp-time <秒>         预热时长 (默认: 30)
  --size <N>               测试文件大小 (默认: 100G, 如 50G)
  --iodepth <N>            I/O 队列深度 (默认: 32)
  --numjobs <N>            并发作业数 (默认: 8)
  --test-dir <路径>        测试文件存放目录 (默认: /mnt/test_disk/fio_test)
  --result-dir <路径>      结果文件存放目录 (默认: ./fio_results)
  --keep-test-file         测试完成后保留测试文件

  裸设备模式:
  --raw-device <路径>      直接测试裸设备（如 /dev/sdb），跳过文件系统检查
                           启用后 --test-dir、--keep-test-file 和空间检查失效

  场景选择:
  --scenarios <列表>       自定义测试场景，逗号分隔
                           格式: 场景名:读写模式:块大小[:读占比(1-99)]
                           示例: "4k-randread:randread:4k,4k-randrw-70:randrw:4k:70"
                           读占比默认 50，仅在 randrw/rw 下生效
                           (默认包含 4k-randread, 4k-randwrite, 4m-seqread, 4m-seqwrite)

示例:
  ./fio_auto_test.sh -y
  ./fio_auto_test.sh --runtime 60 --size 10G --keep-test-file
  ./fio_auto_test.sh --scenarios "4k-randread:randread:4k,128k-seqwrite:write:128k"
  ./fio_auto_test.sh --runtime 120 --iodepth 64 --numjobs 16
  ./fio_auto_test.sh --raw-device /dev/nvme0n1 --runtime 60 --iodepth 128 -y
  ./fio_auto_test.sh --config ./my_test.conf -y
  ./fio_auto_test.sh --scenarios "4k-randrw-70:randrw:4k:70,128k-seqwrite:write:128k" -y
```

### 配置参数

脚本顶部的参数块提供默认值，所有参数均可通过命令行覆盖：

```bash
TEST_DIR="/mnt/test_disk/fio_test"    # 测试文件路径（必须在待测磁盘上）
RESULT_DIR="./fio_results"            # JSON 结果输出目录
TEST_FILE_SIZE="100G"                 # 测试文件大小（建议 ≥ 内存的 2 倍）
RUNTIME=300                           # 每项测试持续时间（秒）
RAMP_TIME=30                          # 预热时长（秒，稳定后开始记录）
IODEPTH=32                            # I/O 队列深度
NUMJOBS=8                             # 并发作业数
KEEP_TEST_FILE=false                  # 是否保留测试文件
INVALIDATE_CACHE=1                    # 测试前清除缓存（避免缓存影响结果）
```

### 输出

每项测试生成一个独立的 JSON 文件，命名格式为 `fio_{场景名}_{时间戳}.json`：

```
fio_results/
  fio_4k-randread_20260518_182509.json
  fio_4k-randwrite_20260518_182509.json
  fio_4m-seqread_20260518_182509.json
  fio_4m-seqwrite_20260518_182509.json
  _env_20260518_182509.json            # ← 环境元数据，自动生成
```

#### 环境元数据文件

每轮测试自动生成 `_env_{时间戳}.json`，记录完整环境信息，便于不同机器间结果对比：

- 主机名、内核版本、fio 版本
- CPU 型号、逻辑核数
- 内存容量
- 被测目标信息：文件测试模式下记录设备名、文件系统类型；裸设备模式下直接记录设备路径和型号
- 本次测试的所有 FIO 参数和场景列表

每项测试的 JSON 结果中也通过 `--description` 嵌入了 `run={时间戳}` 字段，支持跨文件关联。

### 守护模式（后台运行）

长时间测试（如默认 300 秒 × 4 项 ≈ 20 分钟）担心终端断开？使用 `--daemon` 让脚本自己进后台：

```bash
# 后台运行，关闭终端后继续
./fio_auto_test.sh --daemon --raw-device /dev/nvme0n1 -y

# 查看实时日志
tail -f ./daemon_logs/fio_auto_*.log

# 手动停止
kill -TERM $(cat ./daemon_logs/fio_auto_*.pid)
```

工作方式：

- 脚本自动用 `nohup` 重新启动自身，所有输出重定向到 `fio_results/fio_auto_{时间戳}.log`
- PID 写入 `fio_results/fio_auto_{时间戳}.pid`
- `--daemon` 会自动添加 `-y`（跳过确认），无需额外指定

### 配置文件

将常用参数写进配置文件，避免每次在命令行手敲或修改脚本。配置文件格式为 `KEY=VALUE`，支持注释和留空行：

```bash
# fio_test.conf — 示例配置
TEST_DIR=/data/test/fio          # 测试文件路径
TEST_FILE_SIZE=200G               # 测试文件大小
RUNTIME=120                       # 每项测试时长（秒）
RAMP_TIME=30                      # 预热时长
IODEPTH=64                        # I/O 队列深度
NUMJOBS=16                        # 并发作业数
KEEP_TEST_FILE=false              # 是否保留测试文件

# 测试场景（逗号分隔，支持反斜线续行，覆盖默认的 4 项）
TEST_SCENARIOS=4k-randread:randread:4k, \
               4k-randwrite:randwrite:4k, \
               1m-seqread:read:1m, \
               1m-seqwrite:write:1m

# 裸设备（可选，设置后自动启用裸设备模式）
# RAW_DEVICE=/dev/nvme0n1
```

**续行规则：** 配置行末尾加 `\` 可续行到下一行，续行的前导空格自动忽略。适用于 `TEST_SCENARIOS` 等长值。

**加载方式（按优先级降序）：**

1. **默认自动发现** — 脚本同级目录有 `fio_test.conf` 则自动加载
2. **手动指定** — `--config <文件>` 显式指定配置路径
3. **命令行覆盖** — 任何 CLI 参数都会覆盖配置文件中的同名值

```bash
# 自动发现同级目录的 fio_test.conf
./fio_auto_test.sh -y

# 手动指定配置文件
./fio_auto_test.sh --config /path/to/my_test.conf -y

# 配置文件 + 临时覆盖（runtime 用 60 替代配置中的 120）
./fio_auto_test.sh --config fio_test.conf --runtime 60 -y
```

**模板文件：** `config/fio_test_hdd.conf`（机械盘）和 `config/fio_test_ssd.conf`（固态盘）可直接使用或参考修改。

### 裸设备模式

裸设备（如 `/dev/sdb`、`/dev/nvme0n1`）是没有文件系统的原始块设备。使用 `--raw-device` 启用后：

- `--filename` 直接设为设备路径，不拼接 `/fio_test_file`
- 跳过 `mkdir -p`、`df` 空间检查、`touch` 写测试、文件清理等文件系统相关操作
- 元数据采集改用 `lsblk` / `smartctl` 直接查询设备信息
- I/O 引擎自动探测：`libaio` 不可用时回退到 `sync`

```bash
# 测试整块 NVMe 固态盘
./fio_auto_test.sh --raw-device /dev/nvme0n1 --runtime 60 --iodepth 128 --numjobs 4 -y

# 测试特定分区
./fio_auto_test.sh --raw-device /dev/sdb1 --size 50G -y

# 结合自定义场景
./fio_auto_test.sh --raw-device /dev/nvme0n1 --scenarios "128k-seqwrite:write:128k" --size 200G -y
```

### 进度显示

测试过程中实时显示进度：

```
[INFO] 进度: [1/4] 25.0%  剩余约 12m30s
```

- 每项测试开始前显示当前进度和预估剩余时间
- FIO `--status-interval=30` 每 30 秒输出一次中间状态
- 每项测试完成后报告实际耗时
- 全部完成后输出总耗时

### I/O 引擎自动适配

默认使用 `libaio`，若不可用（如部分内核或 macOS）自动回退到 `sync (psync)`，不中断测试。

### 工作流程

1. **前置检查** — 统一检查以下项目，问题一次性报出：
   - fio 是否安装
   - fio 版本是否 ≥ 3.0
   - libaio I/O 引擎是否可用
   - bc 是否安装
   - 文件测试模式：TEST_DIR 和 RESULT_DIR 是否可创建/写入、磁盘剩余空间
   - 裸设备模式：跳过上述文件系统检查
2. 创建结果目录
3. 收集环境元数据
4. 确认（自动模式跳过）
5. 依次执行各场景测试（显示进度）
6. 文件测试模式清理测试文件；裸设备模式跳过清理
7. 显示结果文件列表

---

## fio_summary.sh — 结果汇总报告生成器

扫描 FIO JSON 结果文件，解析并生成结构化的性能报告。

### 提取的指标

针对每项测试的读/写操作，分别提取：

- **带宽** — 吞吐量，单位 MB/s
- **IOPS** — 每秒 I/O 操作数
- **平均延迟** — 平均响应时间，单位 ms
- **95% 延迟** — P95 百分位延迟
- **99% 延迟** — P99 百分位延迟

### 用法

```
用法: ./fio_summary.sh [选项]

选项:
  -d, --dir <目录>    指定 FIO 结果文件所在目录 (默认: ./fio_results)
  -o, --output <文件> 指定输出报告文件名
  -q, --quiet          不在终端显示报告，只保存到文件
  -n, --no-sort        不按文件名排序
  -c, --csv            同时生成 CSV 格式报告（可导入 Excel）
  -l, --latest         自动选择结果目录中最新的一次测试
  --debug              启用调试模式，显示 JSON 结构细节
  -h, --help           显示帮助信息
```

### 示例

```bash
# 基本用法：扫描默认目录并显示文本报告
./fio_summary.sh

# 自动选择最新一次测试结果
./fio_summary.sh --latest

# 指定子目录
./fio_summary.sh -d ./fio_results/ssd-vfs-cache-full

# 文本 + CSV 报告（含环境信息 CSV）
./fio_summary.sh -c

# 最新结果 + CSV
./fio_summary.sh --latest -c

# 静默模式，只保存报告文件
./fio_summary.sh -q -o quick_check.txt
```

### 输出

- **文本报告** — 保存在 `./reports/` 目录下（可通过 `-o` 指定），命名格式为 `fio_summary_{时间戳}.txt`
- **CSV 报告** — 启用 `-c` 时生成，与文本报告同名但后缀为 `.csv`，可直接导入 Excel 进行对比分析
- **环境信息 CSV** — 启用 `-c` 时额外生成 `fio_summary_{时间戳}_env.csv`，记录测试环境元数据（主机名、CPU、内存、磁盘等）

---

## 典型工作流

```bash
# 1. 文件系统基准测试（默认参数）
./fio_auto_test.sh -y
./fio_summary.sh -c

# 2. 裸设备快速验证
./fio_auto_test.sh --raw-device /dev/nvme0n1 --runtime 60 --size 10G --scenarios "4k-randread:randread:4k" -y
./fio_summary.sh -c

# 3. 对比不同磁盘
./fio_summary.sh -d ./fio_results/ssd-vfs-cache-full
./fio_summary.sh -d ./fio_results/hdd-vfs-cache-full

# 4. 深度测试某块盘（后台运行）
./fio_auto_test.sh --daemon --raw-device /dev/sdb --iodepth 128 --numjobs 16 --scenarios \
  "4k-randread:randread:4k,4k-randwrite:randwrite:4k,1m-seqread:read:1m,1m-seqwrite:write:1m" -y
```

---

## 项目结构

```
fiotool/
  ├── fio_auto_test.sh           # 测试执行脚本
  ├── fio_summary.sh             # 报告生成脚本
  ├── README.md                  # 本文档
  ├── .gitignore
  ├── results/               # JSON 测试结果（按场景子目录分组）
  │   ├── _env_*.json            # 环境元数据（自动生成）
  │   ├── ssd-vfs-cache-full/
  │   ├── ssd-vfs-cache-writes/
  │   ├── hdd-vfs-cache-full/
  │   └── hdd-vfs-cache-writes/
  └── reports/                   # 汇总报告输出目录
```

---

## 注意事项

- **数据安全**：写测试会覆盖测试目标路径或裸设备上的数据。确保目标上无重要数据，裸设备模式下确认设备名正确。
- **磁盘负载**：测试期间磁盘会处于高 I/O 负载状态，可能影响同一主机上运行的其他应用。
- **测试文件大小**：文件测试模式下建议设为系统内存的 2 倍以上，以绕过文件系统缓存的影响；裸设备模式下 `--size` 限制写入范围，无需超过设备容量。
- **预热阶段**：`RAMP_TIME` 使测试数据在预热期稳定后再开始记录，避免冷启动阶段的波动。
- **I/O 引擎**：默认使用 `libaio`，Linux 上需安装 `libaio-dev`；macOS 或其他无 libaio 的环境会自动回退到 `sync`。
- **裸设备权限**：测试裸设备通常需要 `root` 权限或用 `sudo` 执行。
- **环境元数据**：结果目录中的 `_env_*.json` 文件记录测试环境的完整信息，归档时请一并保留。
- **Git 忽略**：`results/` 和 `reports/` 已在 `.gitignore` 中排除，避免大量数据和生成文件纳入版本管理。

---

## License

MIT
