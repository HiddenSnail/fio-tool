#!/bin/bash
set -euo pipefail

# ==============================================
# 配置参数 - 请根据你的实际情况修改
# ==============================================
TEST_DIR="/mnt/test_disk/fio_test"  # 测试文件存放目录（必须在要测试的磁盘上）
RESULT_DIR="./fio_results"          # 结果文件存放目录
TEST_FILE_SIZE="20G"                # 测试文件大小（建议为内存的2倍以上）
RUNTIME="300"                       # 每个测试运行时间（秒）
IODEPTH="32"                        # I/O队列深度
NUMJOBS="1"                         # 并发作业数
KEEP_TEST_FILE="false"              # 测试完成后是否保留测试文件（true/false）

# ==============================================
# 颜色定义
# ==============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================
# 函数定义
# ==============================================
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# 检查fio是否安装
check_fio_installed() {
    if ! command -v fio &> /dev/null; then
        error "fio 未安装，请先安装：sudo apt install fio 或 sudo yum install fio"
    fi
}

# 检查磁盘空间
check_disk_space() {
    local required_space=$(echo "$TEST_FILE_SIZE" | sed 's/G//')
    required_space=$((required_space * 1024 * 1024)) # 转换为KB
    
    local available_space=$(df -P "$TEST_DIR" | tail -1 | awk '{print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        error "磁盘空间不足！需要至少 $TEST_FILE_SIZE，可用空间为 $(($available_space / 1024 / 1024))G"
    fi
}

# 运行单个测试
run_fio_test() {
    local test_name="$1"
    local rw_mode="$2"
    local block_size="$3"
    local output_file="$4"
    
    info "开始测试: $test_name"
    info "参数: rw=$rw_mode, bs=$block_size, size=$TEST_FILE_SIZE, runtime=${RUNTIME}s"
    
    fio \
        --name="$test_name" \
        --filename="$TEST_DIR/fio_test_file" \
        --ioengine=libaio \
        --direct=1 \
        --rw="$rw_mode" \
        --bs="$block_size" \
        --size="$TEST_FILE_SIZE" \
        --numjobs="$NUMJOBS" \
        --iodepth="$IODEPTH" \
        --runtime="$RUNTIME" \
        --time_based \
        --group_reporting \
        --output-format=json \
        --output="$output_file"
    
    info "测试完成: $test_name，结果已保存到 $output_file"
    echo "----------------------------------------"
}

# ==============================================
# 主程序
# ==============================================
echo "========================================"
echo "        FIO 磁盘性能自动化测试脚本"
echo "========================================"

# 前置检查
check_fio_installed

# 创建目录
mkdir -p "$TEST_DIR"
mkdir -p "$RESULT_DIR"

# 生成时间戳
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
info "本次测试时间戳: $TIMESTAMP"

# 检查磁盘空间
check_disk_space

# 警告信息
warn "写测试会覆盖数据！请确保 $TEST_DIR 目录中没有重要数据"
warn "测试过程中磁盘会处于高负载状态，可能影响其他应用"
read -p "确认继续运行测试？(y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "用户取消测试"
    exit 0
fi

# 运行所有测试
echo
info "开始运行所有测试..."
echo "----------------------------------------"

run_fio_test "4k-randread" "randread" "4k" "$RESULT_DIR/fio_4k_randread_$TIMESTAMP.json"
run_fio_test "4k-randwrite" "randwrite" "4k" "$RESULT_DIR/fio_4k_randwrite_$TIMESTAMP.json"
run_fio_test "4m-seqread" "read" "4m" "$RESULT_DIR/fio_4m_seqread_$TIMESTAMP.json"
run_fio_test "4m-seqwrite" "write" "4m" "$RESULT_DIR/fio_4m_seqwrite_$TIMESTAMP.json"

# 清理测试文件
if [ "$KEEP_TEST_FILE" = "false" ]; then
    info "正在清理测试文件..."
    rm -f "$TEST_DIR/fio_test_file"
    info "测试文件已删除"
else
    warn "测试文件已保留在: $TEST_DIR/fio_test_file"
fi

# 完成提示
echo
echo "========================================"
info "所有测试已完成！"
info "结果文件保存在: $RESULT_DIR"
ls -lh "$RESULT_DIR"/*"$TIMESTAMP"*
echo "========================================"