#!/bin/bash
set -euo pipefail

# ==============================================
# 配置参数 - 默认值（可通过命令行覆盖）
# ==============================================
TEST_DIR="/mnt/test_disk/fio_test"
RESULT_DIR="./results"
TEST_FILE_SIZE="100G"
RUNTIME=300
RAMP_TIME=30
IODEPTH=32
NUMJOBS=8
KEEP_TEST_FILE=false
INVALIDATE_CACHE=1
RAW_DEVICE=""
CONFIG_FILE=""

# ==============================================
# 测试场景定义
# 格式: 场景名:读写模式:块大小
# ==============================================
declare -a TEST_SCENARIOS=(
    "4k-randread:randread:4k"
    "4k-randwrite:randwrite:4k"
    "4m-seqread:read:4m"
    "4m-seqwrite:write:4m"
)

# ==============================================
# 颜色定义
# ==============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

AUTO_MODE=false
DAEMON_MODE=false

# ==============================================
# 工具函数
# ==============================================
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 分隔线，让输出更清晰
separator() { echo "────────────────────────────────────────"; }

# 秒数转 mm:ss
format_time() {
    local s=$1
    printf "%dm%02ds" $((s / 60)) $((s % 60))
}

# ==============================================
# 前置检查
# ==============================================
check_prerequisites() {
    local failures=0

    # 1. fio 是否安装
    if ! command -v fio &> /dev/null; then
        warn "fio 未安装"
        echo "   Linux:   sudo apt install fio  或  sudo yum install fio"
        echo "   macOS:   brew install fio"
        failures=$((failures + 1))
    fi

    # 2. fio 版本（建议 3.x 以上）
    if command -v fio &> /dev/null; then
        local fio_ver
        fio_ver=$(fio --version 2>/dev/null | grep -oP '^fio-\K[0-9]+\.[0-9]+' || echo "0")
        if (( $(echo "$fio_ver < 3.0" | bc -l 2>/dev/null || echo 1) )); then
            warn "fio 版本过低 ($(fio --version 2>/dev/null))，建议升级到 3.0+"
        else
            info "fio 版本: $(fio --version 2>/dev/null)"
        fi
    fi

    # 3. libaio ioengine 是否可用
    if command -v fio &> /dev/null; then
        if ! fio --name=probe --filename=/dev/null --ioengine=libaio --runtime=0 --size=1M --output=/dev/null 2>/dev/null; then
            warn "libaio I/O 引擎不可用，将回退到 sync (psync)"
            echo "   Linux 安装: sudo apt install libaio-dev 或 sudo yum install libaio"
            # Record the fallback for later use
            FALLBACK_IOENGINE="${FALLBACK_IOENGINE:-sync}"
        else
            info "libaio I/O 引擎可用"
        fi
    fi

    # 4. bc 是否安装（用于进度计算）
    if ! command -v bc &> /dev/null; then
        warn "bc 未安装，进度百分比将不可用"
        echo "   Linux:   sudo apt install bc 或 sudo yum install bc"
        echo "   macOS:   已预装"
    fi
    if [ -z "$RAW_DEVICE" ]; then
        # 5. TEST_DIR 是否可写
        if ! mkdir -p "$TEST_DIR" 2>/dev/null; then
            warn "测试目录 ($TEST_DIR) 创建失败，请检查路径和权限"
            echo "   提示: 通常需要挂载点有写权限，或使用 sudo"
            failures=$((failures + 1))
        else
            if ! touch "$TEST_DIR/.fio_write_test" 2>/dev/null; then
                warn "测试目录 ($TEST_DIR) 不可写"
                failures=$((failures + 1))
            else
                rm -f "$TEST_DIR/.fio_write_test"
            fi
        fi
    fi

    # 6. RESULT_DIR 是否可写
    if ! mkdir -p "$RESULT_DIR" 2>/dev/null; then
        warn "结果目录 ($RESULT_DIR) 创建失败"
        failures=$((failures + 1))
    else
        if ! touch "$RESULT_DIR/.fio_write_test" 2>/dev/null; then
            warn "结果目录 ($RESULT_DIR) 不可写"
            failures=$((failures + 1))
        else
            rm -f "$RESULT_DIR/.fio_write_test"
        fi
    fi

    if [ -z "$RAW_DEVICE" ]; then
        check_disk_space
    fi

    if (( failures > 0 )); then
        error "前置检查未通过 ($failures 项失败)，请修复后重试"
    fi
    info "前置检查全部通过"
}

# 磁盘空间检查
check_disk_space() {
    [ -n "$RAW_DEVICE" ] && return
    local size_num
    size_num=$(echo "$TEST_FILE_SIZE" | sed 's/[GgMmKk]$//')
    local size_unit
    size_unit=$(echo "$TEST_FILE_SIZE" | grep -o '[GgMmKk]$' || echo "G")

    local required_kb=0
    case "$size_unit" in
        [Gg]) required_kb=$((size_num * 1024 * 1024)) ;;
        [Mm]) required_kb=$((size_num * 1024)) ;;
        [Kk]) required_kb=$size_num ;;
        *)    required_kb=$((size_num * 1024 * 1024)) ;; # 默认当作 G
    esac

    local available_kb
    case "$(uname)" in
        Darwin)
            # macOS: df 输出列: Filesystem 512-blocks Used Available Capacity iused ifile %iused Mounted on
            available_kb=$(df "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print ($2 / 2) - ($3 / 2) }')
            ;;
        *)
            available_kb=$(df -P "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
            ;;
    esac

    if [ -z "$available_kb" ] || [ "$available_kb" -lt "$required_kb" ]; then
        local available_g
        available_g=$(echo "scale=1; $available_kb / 1024 / 1024" | bc -l 2>/dev/null || echo "?")
        error "磁盘空间不足！需要至少 $TEST_FILE_SIZE，可用空间约 ${available_g}G"
    fi
}

# ==============================================
# 环境元数据收集
# ==============================================
collect_metadata() {
    local meta_file="$1"
    local timestamp_iso
    timestamp_iso=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

    info "正在收集环境信息..."

    # 磁盘设备信息
    local disk_device="" disk_fstype="" disk_size=""
    if [ -n "$RAW_DEVICE" ]; then
        disk_device="$RAW_DEVICE"
        disk_fstype="raw_device"
        case "$(uname)" in
            Darwin)
                local disk_name
                disk_name=$(echo "$RAW_DEVICE" | sed 's/^\/dev\///; s/s[0-9]*$//')
                if command -v diskutil &> /dev/null; then
                    local disk_info
                    disk_info=$(diskutil info "$disk_name" 2>/dev/null || true)
                    disk_size=$(echo "$disk_info" | grep -i "Total Size" | sed 's/.*://' | xargs || "")
                fi
                ;;
            *)
                if command -v lsblk &> /dev/null; then
                    local base_dev
                    base_dev=$(echo "$RAW_DEVICE" | sed 's/[0-9]*$//')
                    local rot
                    rot=$(lsblk -d -o ROTA "$base_dev" 2>/dev/null | tail -1 || echo "")
                    if [ "$rot" = "0" ]; then disk_size="${disk_size} (SSD)"; fi
                    if [ "$rot" = "1" ]; then disk_size="${disk_size} (HDD)"; fi
                    local dev_size
                    dev_size=$(lsblk -d -o SIZE "$base_dev" 2>/dev/null | tail -1 || echo "")
                    [ -n "$dev_size" ] && disk_size="${dev_size}"
                fi
                if command -v smartctl &> /dev/null; then
                    local model
                    model=$(smartctl -i "$RAW_DEVICE" 2>/dev/null | grep -i "Device Model\|Model Number" | sed 's/.*: *//' || echo "")
                    [ -n "$model" ] && disk_device="${RAW_DEVICE} ($model)"
                fi
                ;;
        esac
    else
        case "$(uname)" in
            Darwin)
                local dev_str
                dev_str=$(df "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $1}')
                disk_device="$dev_str"
                # macOS 用 diskutil 获取型号
                if command -v diskutil &> /dev/null && [ -n "$dev_str" ]; then
                    local disk_name
                    disk_name=$(echo "$dev_str" | sed 's/^\/dev\///; s/s[0-9]*$//')
                    local disk_info
                    disk_info=$(diskutil info "$disk_name" 2>/dev/null || true)
                    disk_size=$(echo "$disk_info" | grep -i "Total Size" | sed 's/.*://' | xargs || echo "")
                fi
                # macOS df 没有 -T，用 stat 获取文件系统类型
                disk_fstype=$(stat -f "%T" "$TEST_DIR" 2>/dev/null || echo "unknown")
                ;;
            *)
                disk_device=$(df --output=source "$TEST_DIR" 2>/dev/null | tail -1 || df "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $1}')
                disk_fstype=$(df -T "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $2}' || stat -f -c '%T' "$TEST_DIR" 2>/dev/null || echo "unknown")
                # 尝试获取 SSD/HDD 类型
                if command -v lsblk &> /dev/null && [ -n "$disk_device" ]; then
                    local base_dev
                    base_dev=$(echo "$disk_device" | sed 's/[0-9]*$//')
                    local rot
                    rot=$(lsblk -d -o ROTA "$base_dev" 2>/dev/null | tail -1 || echo "")
                    if [ "$rot" = "0" ]; then disk_size="${disk_size} (SSD)"; fi
                    if [ "$rot" = "1" ]; then disk_size="${disk_size} (HDD)"; fi
                fi
                if command -v smartctl &> /dev/null && [ -n "$disk_device" ]; then
                    local model
                    model=$(smartctl -i "$disk_device" 2>/dev/null | grep -i "Device Model\|Model Number" | sed 's/.*: *//' || echo "")
                    [ -n "$model" ] && disk_device="${disk_device} ($model)"
                fi
                ;;
        esac
    fi

    # CPU 信息
    local cpu_model="" cpu_cores=""
    case "$(uname)" in
        Darwin)
            cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
            cpu_cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "unknown")
            ;;
        *)
            cpu_model=$(lscpu 2>/dev/null | grep 'Model name' | sed 's/.*: *//' | head -1 || echo "unknown")
            cpu_cores=$(nproc 2>/dev/null || echo "unknown")
            ;;
    esac

    # 内存
    local memory_gb=""
    case "$(uname)" in
        Darwin)
            memory_gb=$(echo "scale=1; $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824" | bc -l)
            ;;
        *)
            memory_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "unknown")
            ;;
    esac

    cat > "$meta_file" << EOF
{
  "tool_version": "1.0.0",
  "timestamp": "$timestamp_iso",
  "hostname": "$(hostname 2>/dev/null || hostname -s 2>/dev/null || echo 'unknown')",
  "kernel": "$(uname -a 2>/dev/null || echo 'unknown')",
  "fio_version": "$(fio --version 2>/dev/null || echo 'unknown')",
  "cpu": {
    "model": "$cpu_model",
    "logical_cores": "$cpu_cores"
  },
  "memory_gb": "$memory_gb",
    "test_dir": "${RAW_DEVICE:-$TEST_DIR}",
    "device_type": "${RAW_DEVICE:+raw_device}${RAW_DEVICE:-file}",
    "device": "$disk_device",
    "filesystem": "$disk_fstype",
    "disk_details": "$disk_size"
  },
  "fio_params": {
    "size": "$TEST_FILE_SIZE",
    "runtime": $RUNTIME,
    "ramp_time": $RAMP_TIME,
    "iodepth": $IODEPTH,
    "numjobs": $NUMJOBS,
    "invalidate_cache": $INVALIDATE_CACHE
  },
  "test_scenarios": [
EOF

    # 追加场景列表（保持 JSON 合法性）
    local count=${#TEST_SCENARIOS[@]}
    local idx=0
    for scenario in "${TEST_SCENARIOS[@]}"; do
        idx=$((idx + 1))
        IFS=':' read -ra sp <<< "$scenario"
    local name="${sp[0]}" mode="${sp[1]}" bs="${sp[2]}" rwmixread="${sp[3]:-}"
        local comma=","
        [ "$idx" -eq "$count" ] && comma=""
        echo "    { \"name\": \"$name\", \"rw\": \"$mode\", \"bs\": \"$bs\" }$comma" >> "$meta_file"
    done

    cat >> "$meta_file" << EOF
  ]
}
EOF
    info "环境信息已保存到 $meta_file"
}

# ==============================================
# 运行单个测试
# ==============================================
run_fio_test() {
    local test_name="$1"
    local rw_mode="$2"
    local block_size="$3"
    local output_file="$4"
    local rwmixread="${5:-}"
    local ioengine="${FALLBACK_IOENGINE:-libaio}"

    separator
    info "开始测试: ${test_name}"
    echo "  模式:      ${rw_mode}"
    echo "  块大小:    ${block_size}"
    echo "  文件大小:  ${TEST_FILE_SIZE}"
    echo "  运行时长:  $(format_time $RUNTIME)"
    echo "  I/O引擎:   ${ioengine}"
    if [ -n "$rwmixread" ]; then
        echo "  读占比:    ${rwmixread}%"
    fi
    separator

    # 记录开始时间
    local start_ts
    start_ts=$(date +%s)

    local time_based_flag=""
    if [ "$RUNTIME" -gt 0 ]; then
        time_based_flag="--time_based"
    fi
    local rwmixread_flag=""
    if [ -n "$rwmixread" ]; then
        rwmixread_flag="--rwmixread=$rwmixread"
    fi

    fio \
        --filename="${RAW_DEVICE:-$TEST_DIR/fio_test_file}" \
        --name="$test_name" \
        --ioengine="$ioengine" \
        --direct=1 \
        --invalidate=$INVALIDATE_CACHE \
        --rw="$rw_mode" \
        --bs="$block_size" \
        --size="$TEST_FILE_SIZE" \
        --numjobs="$NUMJOBS" \
        --iodepth="$IODEPTH" \
        --runtime="$RUNTIME" \
        --ramp_time="$RAMP_TIME" \
        $time_based_flag \
        $rwmixread_flag \
        --group_reporting \
        --description="run=${TIMESTAMP}|size=${TEST_FILE_SIZE}|iodepth=${IODEPTH}|numjobs=${NUMJOBS}|ioengine=${ioengine}" \
        --output-format=json \
        --output="$output_file"

    local end_ts
    end_ts=$(date +%s)
    local elapsed=$((end_ts - start_ts))

    info "测试完成: ${test_name}  (耗时 $(format_time $elapsed))"
    echo "  结果:  ${output_file}"
}

# ==============================================
# 用法说明
# ==============================================
usage() {
    cat << EOF
用法: $0 [选项]

选项:
  -y, --yes                自动模式，跳过确认直接执行
  -h, --help               显示此帮助信息
  --daemon                 守护模式，后台运行，退出 Shell 后不中断
  --config <文件>          从配置文件加载参数（默认: ./fio_test.conf）

  测试参数覆盖:
  --runtime <秒>           每项测试运行时长 (默认: ${RUNTIME})
  --ramp-time <秒>         预热时长 (默认: ${RAMP_TIME})
  --size <N>               测试文件大小 (默认: ${TEST_FILE_SIZE}, 如 50G)
  --iodepth <N>            I/O 队列深度 (默认: ${IODEPTH})
  --numjobs <N>            并发作业数 (默认: ${NUMJOBS})
  --test-dir <路径>        测试文件存放目录 (默认: ${TEST_DIR})
  --keep-test-file         测试完成后保留测试文件
  --raw-device <路径>     直接测试裸设备（如 /dev/sdb），跳过文件系统检查
                          启用后 --test-dir 和 --keep-test-file 参数无效

  场景选择:
  --scenarios <列表>       自定义测试场景，逗号分隔
                           格式: 场景名:读写模式:块大小[:读占比(1-99)]
                           示例: --scenarios "4k-randread:randread:4k,4k-randrw-70:randrw:4k:70"
                           读占比默认 50（写=100-读占比），仅在 randrw/rw 下生效
                           (默认包含 4k-randread, 4k-randwrite, 4m-seqread, 4m-seqwrite)

示例:
  $0 -y
  $0 --runtime 60 --size 10G --keep-test-file
  $0 --scenarios "4k-randread:randread:4k,128k-seqwrite:write:128k"
  $0 --runtime 120 --iodepth 64 --numjobs 16

EOF
    exit 0
}

# ==============================================
# 参数解析

# ==============================================
# 配置文件加载
# ==============================================
load_config() {
    local config_file="$1"
    if [ ! -f "$config_file" ]; then
        error "配置文件不存在: $config_file"
    fi
    info "加载配置文件: $config_file"

    while IFS= read -r line || [ -n "$line" ]; do
        # 行尾反斜线续行
        while [[ "$line" =~ \\[[:space:]]*$ ]]; do
            line="${line%\\}"
            IFS= read -r next_line || break
            # 去掉续行前导空格
            next_line="${next_line#"${next_line%%[![:space:]]*}"}"
            line="$line$next_line"
        done

        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # 按第一个 = 分割
        key="${line%%=*}"
        val="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"  # trim leading
        key="${key%"${key##*[![:space:]]}"}"  # trim trailing
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        [ -z "$key" ] && continue

        # 去掉值的首尾引号
        case "$val" in
            '*'|"*") val="${val:1:-1}" ;;
        esac

        case "$key" in
            TEST_DIR)           TEST_DIR="$val" ;;
            RESULT_DIR)         RESULT_DIR="$val" ;;
            TEST_FILE_SIZE)     TEST_FILE_SIZE="$val" ;;
            RUNTIME)            RUNTIME="$val" ;;
            RAMP_TIME)          RAMP_TIME="$val" ;;
            IODEPTH)            IODEPTH="$val" ;;
            NUMJOBS)            NUMJOBS="$val" ;;
            KEEP_TEST_FILE)     KEEP_TEST_FILE="$val" ;;
            INVALIDATE_CACHE)   INVALIDATE_CACHE="$val" ;;
            RAW_DEVICE)         RAW_DEVICE="$val" ;;
            TEST_SCENARIOS)
                TEST_SCENARIOS=()
                IFS=',' read -ra CUSTOM_SCENARIOS <<< "$val"
                for s in "${CUSTOM_SCENARIOS[@]}"; do
                    TEST_SCENARIOS+=("$s")
                done
                ;;
        esac
    done < "$config_file"
}
# ==============================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)           AUTO_MODE=true; shift ;;
            -h|--help)          usage ;;
            --runtime)          RUNTIME="$2"; shift 2 ;;
            --ramp-time)        RAMP_TIME="$2"; shift 2 ;;
            --size)             TEST_FILE_SIZE="$2"; shift 2 ;;
            --iodepth)          IODEPTH="$2"; shift 2 ;;
            --numjobs)          NUMJOBS="$2"; shift 2 ;;
            --test-dir)         TEST_DIR="$2"; shift 2 ;;
            --result-dir)       RESULT_DIR="$2"; shift 2 ;;
            --keep-test-file)   KEEP_TEST_FILE=true; shift ;;
            --daemon)           DAEMON_MODE=true; shift ;;
            --scenarios)
                # 解析逗号分隔的场景: "name:rw:bs,name:rw:bs"
                IFS=',' read -ra CUSTOM_SCENARIOS <<< "$2"
                TEST_SCENARIOS=()
                for s in "${CUSTOM_SCENARIOS[@]}"; do
                    TEST_SCENARIOS+=("$s")
                done
                shift 2
                ;;
            --raw-device)       RAW_DEVICE="$2"; shift 2 ;;
            *)
                error "未知参数: $1，使用 -h 查看帮助"
                ;;
        esac
    done
}

# ==============================================
# 主程序
# ==============================================
# 提前扫描 --config 参数
CONFIG_ARG=""
for arg in "$@"; do
    if [ "$CONFIG_ARG" = "__NEXT__" ]; then CONFIG_FILE="$arg"; CONFIG_ARG=""; break; fi
    [ "$arg" = "--config" ] && CONFIG_ARG="__NEXT__"
done

# 未指定时查找默认配置
if [ -z "$CONFIG_FILE" ]; then
    [ -f "./fio_test.conf" ] && CONFIG_FILE="./fio_test.conf"
fi

# 加载配置
if [ -n "$CONFIG_FILE" ]; then
    load_config "$CONFIG_FILE"
fi

# 重新构建参数（移除 --config 及其值）
CLEAN_ARGS=()
SKIP_NEXT=false
for arg in "$@"; do
    if [ "$SKIP_NEXT" = true ]; then SKIP_NEXT=false; continue; fi
    if [ "$arg" = "--config" ]; then SKIP_NEXT=true; continue; fi
    CLEAN_ARGS+=("$arg")
done

parse_args "${CLEAN_ARGS[@]}"

# ==============================================
# 守护模式处理
# ==============================================
if [ "$DAEMON_MODE" = true ]; then
    # 自动启用 -y 模式，后台运行
    LOG_DIR="./daemon_logs"
    mkdir -p "$LOG_DIR"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$LOG_DIR/fio_auto_${TIMESTAMP}.log"
    PID_FILE="$LOG_DIR/fio_auto_${TIMESTAMP}.pid"

    # 构建新参数：移除 --daemon，添加 -y
    NEW_ARGS=()
    ADDED_Y=false
    for arg in "$@"; do
        if [ "$arg" = "--daemon" ]; then
            continue
        fi
        if [ "$arg" = "-y" ] || [ "$arg" = "--yes" ]; then
            ADDED_Y=true
        fi
        NEW_ARGS+=("$arg")
    done
    if [ "$ADDED_Y" = false ]; then
        NEW_ARGS+=("-y")
    fi

    nohup bash "$0" "${NEW_ARGS[@]}" > "$LOG_FILE" 2>&1 &
    BGPID=$!
    echo "$BGPID" > "$PID_FILE"

    echo "========================================"
    echo "  FIO 在后台启动 (PID: $BGPID)"
    echo "========================================"
    echo "日志文件: $LOG_FILE"
    echo "PID 文件: $PID_FILE"
    echo
    echo "查看实时日志:  tail -f $LOG_FILE"
    echo "停止测试:      kill -TERM $BGPID"
    exit 0
fi

separator
echo "  FIO 磁盘性能自动化测试  v1.0"
separator

# 前置检查
echo
check_prerequisites

# 创建目录
if [ -z "$RAW_DEVICE" ]; then
    mkdir -p "$TEST_DIR"
fi
mkdir -p "$RESULT_DIR"

# 测试标识
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
info "本次测试标识: $TIMESTAMP"
RESULT_SUBDIR="$RESULT_DIR/$TIMESTAMP"
mkdir -p "$RESULT_SUBDIR"
info "结果将保存到: $RESULT_SUBDIR"

# 收集环境元数据
ENV_FILE="$RESULT_SUBDIR/_env_${TIMESTAMP}.json"
collect_metadata "$ENV_FILE"

# 确认
echo
total_estimate=$(( ${#TEST_SCENARIOS[@]} * (RUNTIME + RAMP_TIME) ))
warn "即将运行 ${#TEST_SCENARIOS[@]} 项测试，预估总耗时约 $(format_time $total_estimate)"
if [ -n "$RAW_DEVICE" ]; then
    warn "写测试会覆盖裸设备 $RAW_DEVICE 中的数据，请确认该设备上的数据已备份"
else
    warn "写测试会覆盖 $TEST_DIR 中的数据，请注意备份"
fi
warn "测试期间磁盘将处于高负载，可能影响其他应用"
echo

if [ "$AUTO_MODE" = false ]; then
    read -p "确认开始？(y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "用户取消"
        exit 0
    fi
else
    info "自动模式，跳过确认"
fi

# 运行测试
echo
separator
info "开始运行 ${#TEST_SCENARIOS[@]} 项测试..."
separator
echo

total=${#TEST_SCENARIOS[@]}
current=0
scenario_start_ts=$(date +%s)
elapsed_total=0
avg_per_test=0
eta_remaining=""

for scenario in "${TEST_SCENARIOS[@]}"; do
    IFS=':' read -ra sp <<< "$scenario"
    test_name="${sp[0]}"
    rw_mode="${sp[1]}"
    block_size="${sp[2]}"
    rwmixread="${sp[3]:-}"
    current=$((current + 1))

    # 累计进度
    if [ "$current" -gt 1 ]; then
        now_ts=$(date +%s)
        avg_per_test=$((elapsed_total / current))
        elapsed_total=$((now_ts - scenario_start_ts))
    fi
    pct=$(echo "scale=1; $current * 100 / $total" | bc -l 2>/dev/null || echo "?")
    if [ "$current" -lt "$total" ] && [ "$current" -gt 0 ]; then
        eta_remaining=$(( (total - current) * avg_per_test ))
        eta_remaining="剩余约 $(format_time $eta_remaining)"
    else
        eta_remaining=""
    fi

    info "进度: [${current}/${total}] ${pct}%  ${eta_remaining}"
    echo

    run_fio_test "$test_name" "$rw_mode" "$block_size" \
        "$RESULT_SUBDIR/fio_${test_name}_${TIMESTAMP}.json" "$rwmixread"

    echo
done

# 清理测试文件
if [ -z "$RAW_DEVICE" ]; then
    if [ "$KEEP_TEST_FILE" = false ]; then
        info "正在清理测试文件..."
        rm -f "$TEST_DIR/fio_test_file"
        info "测试文件已删除"
    else
        warn "测试文件保留在: $TEST_DIR/fio_test_file"
    fi
fi
# 完成
total_duration=$(( $(date +%s) - scenario_start_ts ))
echo
separator
info "全部完成！总耗时 $(format_time $total_duration)"
info "结果目录: $RESULT_SUBDIR"
echo
ls -lh "$RESULT_SUBDIR"/*.json 2>/dev/null
echo
info "运行 $(basename "$0") -h 查看后续步骤"
separator
