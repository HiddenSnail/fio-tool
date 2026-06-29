#!/bin/bash
set -euo pipefail

# ==============================================
# 默认配置参数
# ==============================================
DEFAULT_RESULT_DIR="./results"
DEFAULT_OUTPUT_FILE=""  # 空值表示自动生成带时间戳的文件名
DEFAULT_OUTPUT_DIR="./reports" # 专用报告输出目录
SHOW_IN_TERMINAL=true
SORT_RESULTS=true
GENERATE_CSV=false      # 默认不生成CSV，需要通过--csv选项启用
LATEST_MODE=false       # --latest 模式，自动选择最新时间戳子目录
DEBUG_MODE=false        # 调试模式，显示详细的JSON结构信息

# ==============================================
# 颜色定义
# ==============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==============================================
# 全局变量（用于安全传递文件名数组）
# ==============================================
JSON_FILES=()

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

debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# 检查依赖
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        error "jq 未安装，请先安装：sudo apt install jq 或 sudo yum install jq"
    fi
}

# 显示帮助信息
show_help() {
    echo "FIO JSON结果汇总脚本"
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -d, --dir <目录>      指定FIO结果文件所在目录 (默认: $DEFAULT_RESULT_DIR)"
    echo "  -o, --output <文件>   指定输出报告文件 (默认: 自动生成带时间戳的文件名)"
    echo "  -q, --quiet           不在终端显示报告，只保存到文件"
    echo "  -n, --no-sort         不按测试类型排序结果"
    echo "  -c, --csv             同时生成CSV格式报告（可导入Excel）"
    echo "  -l, --latest          自动选择结果目录中最新的一次测试"
    echo "  --debug               启用调试模式，显示详细信息"
    echo "  -h, --help            显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0                          # 扫描默认目录并显示文本报告"
    echo "  $0 -c                       # 生成文本报告+CSV报告"
    echo "  $0 -d ./my_results -c       # 扫描指定目录并生成两种格式"
    echo "  $0 --latest                 # 自动解析最新的一次测试结果"
    echo "  $0 --debug                  # 调试模式，查看JSON结构"
    exit 0
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                RESULT_DIR="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -q|--quiet)
                SHOW_IN_TERMINAL=false
                shift
                ;;
            -n|--no-sort)
                SORT_RESULTS=false
                shift
                ;;
            -c|--csv)
                GENERATE_CSV=true
                shift
                ;;
            -l|--latest)
                LATEST_MODE=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                error "未知选项: $1。使用 -h 查看帮助"
                ;;
        esac
    done

    # 设置默认值
    RESULT_DIR="${RESULT_DIR:-$DEFAULT_RESULT_DIR}"
    OUTPUT_FILE="${OUTPUT_FILE:-$DEFAULT_OUTPUT_FILE}"
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
}

# 验证目录存在
validate_directory() {
    if [ ! -d "$RESULT_DIR" ]; then
        error "目录不存在: $RESULT_DIR"
    fi
    info "正在扫描目录: $RESULT_DIR"
}

# 查找所有JSON结果文件
find_json_files() {
    JSON_FILES=()
    local temp_files=()
    
    # 查找所有JSON文件
    while IFS= read -r -d $'\0' file; do
        temp_files+=("$file")
    done < <(find "$RESULT_DIR" -maxdepth 2 -type f -name "*.json" -print0)
    
    if [ ${#temp_files[@]} -eq 0 ]; then
        error "在 $RESULT_DIR 目录中未找到任何JSON文件"
    fi
    
    info "找到 ${#temp_files[@]} 个JSON文件，正在验证..."
    
    # 筛选出有效的FIO结果文件
    for file in "${temp_files[@]}"; do
        if jq -e 'has("jobs") and (.jobs | length > 0)' "$file" &> /dev/null; then
            JSON_FILES+=("$file")
            info "✓ 有效: $(basename "$file")"
            
            # 调试模式：显示JSON结构
            if [ "$DEBUG_MODE" = true ]; then
                debug "JSON结构:"
                jq 'keys' "$file"
                debug "第一个job的keys:"
                jq '.jobs[0] | keys' "$file"
                if jq -e '.jobs[0].job_options' "$file" &> /dev/null; then
                    debug "job_options存在，包含以下参数:"
                    jq '.jobs[0].job_options | keys' "$file" | head -20
                fi
                if jq -e '.global_options' "$file" &> /dev/null; then
                    debug "global_options存在，包含以下参数:"
                    jq '.global_options | keys' "$file" | head -20
                fi
            fi
        else
            warn "✗ 跳过: $(basename "$file") (不是有效的FIO结果文件)"
        fi
    done
    
    if [ ${#JSON_FILES[@]} -eq 0 ]; then
        error "在 $RESULT_DIR 目录中未找到有效的FIO JSON结果文件"
    fi
    
    # 按文件名排序（按时间戳）
    if [ "$SORT_RESULTS" = true ]; then
        info "正在按文件名排序..."
        IFS=$'\n' JSON_FILES=($(sort <<<"${JSON_FILES[*]}"))
        unset IFS
    fi
    
    info "共找到 ${#JSON_FILES[@]} 个有效的FIO结果文件"
}

# 通用参数提取函数（兼容所有FIO版本）
get_fio_param() {
    local json_file="$1"
    local param_name="$2"
    local default_value="${3:-未知}"
    # 兼容多种FIO JSON字段命名："job options" / job_options / "global options" / global_options / 直接字段
    local value
    value=$(jq -r --arg p "$param_name" '(.jobs[0]["job options"][$p] // .jobs[0].job_options[$p] // .global_options[$p] // .["global options"][$p] // .jobs[0][$p]) // ""' "$json_file" 2>/dev/null)

    # 返回默认值（如果为空）
    if [ -z "$value" ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

# 提取测试信息（完全重写版）
extract_test_info() {
    local json_file="$1"
    
    # 提取测试名称
    local test_name=$(jq -r '.jobs[0].jobname' "$json_file")
    
    # 提取测试参数（使用通用函数，兼容所有版本）
    local bs=$(get_fio_param "$json_file" "bs")
    local rw=$(get_fio_param "$json_file" "rw")
    local iodepth=$(get_fio_param "$json_file" "iodepth")
    local numjobs=$(get_fio_param "$json_file" "numjobs")
    local runtime=$(get_fio_param "$json_file" "runtime")
    
    # 特殊处理：有些版本runtime是数字，有些是字符串带单位
    if [[ "$runtime" =~ ^[0-9]+$ ]]; then
        runtime="${runtime}s"
    fi
    
    # 提取文件修改时间
    # 优先从JSON本身获取时间（跨平台），如果不存在再回退到文件系统时间
    local file_time=$(jq -r '.time // ""' "$json_file" 2>/dev/null)
    if [ -z "$file_time" ] || [ "$file_time" = "null" ]; then
        if stat -c "%y" "$json_file" &> /dev/null; then
            file_time=$(stat -c "%y" "$json_file" | cut -d. -f1)
        else
            # macOS stat fallback
            file_time=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$json_file" 2>/dev/null || echo "")
        fi
    fi
    
    # 调试信息
    debug "提取的参数: bs=$bs, rw=$rw, iodepth=$iodepth, numjobs=$numjobs, runtime=$runtime"
    
    # 输出测试信息
    echo "=== $test_name ==="
    echo "文件: $(basename "$json_file")"
    echo "时间: $file_time"
    echo "参数: bs=$bs, rw=$rw, iodepth=$iodepth, numjobs=$numjobs, runtime=$runtime"
    echo ""
}

# 提取读性能指标
extract_read_metrics() {
    local json_file="$1"
    
    if jq -e '.jobs[0].read.io_bytes > 0' "$json_file" &> /dev/null; then
        local bw_kb=$(jq '.jobs[0].read.bw' "$json_file")
        local bw_mb=$(echo "scale=2; $bw_kb / 1024" | bc -l)
        local iops=$(jq '.jobs[0].read.iops' "$json_file")
        local lat_mean_ns=$(jq '.jobs[0].read.lat_ns.mean' "$json_file")
        local lat_mean_ms=$(echo "scale=2; $lat_mean_ns / 1000000" | bc -l)
        
        # 处理可能不存在的百分位数据
        local lat_p95_ns=$(jq '.jobs[0].read.lat_ns.percentile."95.000000" // 0' "$json_file")
        local lat_p95_ms=$(echo "scale=2; $lat_p95_ns / 1000000" | bc -l)
        local lat_p99_ns=$(jq '.jobs[0].read.lat_ns.percentile."99.000000" // 0' "$json_file")
        local lat_p99_ms=$(echo "scale=2; $lat_p99_ns / 1000000" | bc -l)
        
        echo "📖 读性能指标:"
        echo "  带宽:     $bw_mb MB/s"
        echo "  IOPS:     $(printf "%.2f" "$iops")"
        echo "  平均延迟: $lat_mean_ms ms"
        echo "  95%延迟:  $lat_p95_ms ms"
        echo "  99%延迟:  $lat_p99_ms ms"
        echo ""
    fi
}

# 提取写性能指标
extract_write_metrics() {
    local json_file="$1"
    
    if jq -e '.jobs[0].write.io_bytes > 0' "$json_file" &> /dev/null; then
        local bw_kb=$(jq '.jobs[0].write.bw' "$json_file")
        local bw_mb=$(echo "scale=2; $bw_kb / 1024" | bc -l)
        local iops=$(jq '.jobs[0].write.iops' "$json_file")
        local lat_mean_ns=$(jq '.jobs[0].write.lat_ns.mean' "$json_file")
        local lat_mean_ms=$(echo "scale=2; $lat_mean_ns / 1000000" | bc -l)
        
        # 处理可能不存在的百分位数据
        local lat_p95_ns=$(jq '.jobs[0].write.lat_ns.percentile."95.000000" // 0' "$json_file")
        local lat_p95_ms=$(echo "scale=2; $lat_p95_ns / 1000000" | bc -l)
        local lat_p99_ns=$(jq '.jobs[0].write.lat_ns.percentile."99.000000" // 0' "$json_file")
        local lat_p99_ms=$(echo "scale=2; $lat_p99_ns / 1000000" | bc -l)
        
        echo "✏️  写性能指标:"
        echo "  带宽:     $bw_mb MB/s"
        echo "  IOPS:     $(printf "%.2f" "$iops")"
        echo "  平均延迟: $lat_mean_ms ms"
        echo "  95%延迟:  $lat_p95_ms ms"
        echo "  99%延迟:  $lat_p99_ms ms"
        echo ""
    fi
}

# 生成CSV格式报告
generate_csv_summary() {
    local csv_file="${OUTPUT_FILE%.txt}.csv"
    
    info "正在生成CSV报告: $csv_file"

    # 确保输出目录存在
    mkdir -p "$(dirname "$csv_file")"
    
# 写入CSV表头（标准逗号分隔，UTF-8编码）
    echo "测试名称,测试时间,块大小,读写模式,队列深度,并发数,读带宽(MB/s),读IOPS,读平均延迟(ms),读95%延迟(ms),读99%延迟(ms),写带宽(MB/s),写IOPS,写平均延迟(ms),写95%延迟(ms),写99%延迟(ms)" > "$csv_file"
    
    # 处理每个JSON文件
    for json_file in "${JSON_FILES[@]}"; do
        local test_name=$(jq -r '.jobs[0].jobname' "$json_file")
        local file_time=$(jq -r '.time // ""' "$json_file" 2>/dev/null)
        if [ -z "$file_time" ] || [ "$file_time" = "null" ]; then
            if stat -c "%y" "$json_file" &> /dev/null; then
                file_time=$(stat -c "%y" "$json_file" | cut -d. -f1)
            else
                file_time=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$json_file" 2>/dev/null || echo "")
            fi
        fi
        local bs=$(get_fio_param "$json_file" "bs" "")
        local rw=$(get_fio_param "$json_file" "rw" "")
        local iodepth=$(get_fio_param "$json_file" "iodepth" "")
        local numjobs=$(get_fio_param "$json_file" "numjobs" "")
        
        # 读指标（空值处理）
        local read_bw="" read_iops="" read_lat_mean="" read_lat_p95="" read_lat_p99=""
        if jq -e '.jobs[0].read.io_bytes > 0' "$json_file" &> /dev/null; then
            read_bw=$(echo "scale=2; $(jq '.jobs[0].read.bw' "$json_file") / 1024" | bc -l)
            read_iops=$(printf "%.2f" $(jq '.jobs[0].read.iops' "$json_file"))
            read_lat_mean=$(echo "scale=2; $(jq '.jobs[0].read.lat_ns.mean' "$json_file") / 1000000" | bc -l)
            read_lat_p95=$(echo "scale=2; $(jq '.jobs[0].read.lat_ns.percentile."95.000000" // 0' "$json_file") / 1000000" | bc -l)
            read_lat_p99=$(echo "scale=2; $(jq '.jobs[0].read.lat_ns.percentile."99.000000" // 0' "$json_file") / 1000000" | bc -l)
        fi
        
        # 写指标（空值处理）
        local write_bw="" write_iops="" write_lat_mean="" write_lat_p95="" write_lat_p99=""
        if jq -e '.jobs[0].write.io_bytes > 0' "$json_file" &> /dev/null; then
            write_bw=$(echo "scale=2; $(jq '.jobs[0].write.bw' "$json_file") / 1024" | bc -l)
            write_iops=$(printf "%.2f" $(jq '.jobs[0].write.iops' "$json_file"))
            write_lat_mean=$(echo "scale=2; $(jq '.jobs[0].write.lat_ns.mean' "$json_file") / 1000000" | bc -l)
            write_lat_p95=$(echo "scale=2; $(jq '.jobs[0].write.lat_ns.percentile."95.000000" // 0' "$json_file") / 1000000" | bc -l)
            write_lat_p99=$(echo "scale=2; $(jq '.jobs[0].write.lat_ns.percentile."99.000000" // 0' "$json_file") / 1000000" | bc -l)
        fi
        
        # 写入CSV行（处理可能包含逗号的字段）
        echo "\"$test_name\",\"$file_time\",\"$bs\",\"$rw\",\"$iodepth\",\"$numjobs\",\"$read_bw\",\"$read_iops\",\"$read_lat_mean\",\"$read_lat_p95\",\"$read_lat_p99\",\"$write_bw\",\"$write_iops\",\"$write_lat_mean\",\"$write_lat_p95\",\"$write_lat_p99\"" >> "$csv_file"
    done
    
    info "CSV报告生成成功: $csv_file"
}

# 生成环境信息CSV（单独文件）
generate_env_summary() {
    local env_csv="${OUTPUT_FILE%.txt}_env.csv"
    local env_file
    env_file=$(find "$RESULT_DIR" -maxdepth 1 -name "_env_*.json" 2>/dev/null | head -1)
    
    if [ -z "$env_file" ] || [ ! -f "$env_file" ]; then
        return 0
    fi
    
    info "正在生成环境信息CSV: $env_csv"
    echo "项目,值" > "$env_csv"
    
    local field label value
    for field in hostname kernel fio_version tool_version cpu.model cpu.logical_cores memory_gb test_target.test_dir test_target.device test_target.device_type test_target.disk_details test_target.filesystem; do
        case "$field" in
            hostname)              label="主机名" ;;
            kernel)                label="内核版本" ;;
            fio_version)           label="FIO版本" ;;
            tool_version)          label="工具版本" ;;
            cpu.model)             label="CPU型号" ;;
            cpu.logical_cores)     label="CPU核数" ;;
            memory_gb)             label="内存(GB)" ;;
            test_target.test_dir)  label="测试路径" ;;
            test_target.device)    label="测试设备" ;;
            test_target.device_type) label="设备类型" ;;
            test_target.disk_details) label="磁盘容量" ;;
            test_target.filesystem) label="文件系统" ;;
            *)                     label="$field" ;;
        esac
        value=$(jq -r "(.$field // .\"${field#*.}\") // \"\"" "$env_file" 2>/dev/null | head -1) || true
        echo ""$label","$value"" >> "$env_csv"
    done
    
    info "环境信息CSV已生成: $env_csv"
}

# 生成文本汇总报告
generate_text_summary() {
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    
    # 确定输出文件
    # 确保输出目录存在
    mkdir -p "$OUTPUT_DIR"

    if [ -z "$OUTPUT_FILE" ]; then
        OUTPUT_FILE="$OUTPUT_DIR/fio_summary_$timestamp.txt"
    else
        # 如果用户提供的是带路径的文件名，确保父目录存在；如果只是文件名，则放到 OUTPUT_DIR
        if [[ "$OUTPUT_FILE" == */* ]]; then
            mkdir -p "$(dirname "$OUTPUT_FILE")"
        else
            OUTPUT_FILE="$OUTPUT_DIR/$OUTPUT_FILE"
        fi
    fi
    
    info "正在生成文本报告..."
    info "文本报告将保存到: $OUTPUT_FILE"
    echo
    
    # 写入报告头部
    {
        echo "========================================"
        echo "        FIO 磁盘性能测试汇总报告"
        echo "========================================"
        echo "生成时间: $(date)"
        echo "结果目录: $RESULT_DIR"
        echo "文件数量: ${#JSON_FILES[@]}"
        echo "========================================"
        echo
    } > "$OUTPUT_FILE"
    
    # 处理每个JSON文件
    for json_file in "${JSON_FILES[@]}"; do
        info "处理文件: $(basename "$json_file")"
        
        {
            extract_test_info "$json_file"
            extract_read_metrics "$json_file"
            extract_write_metrics "$json_file"
            echo "----------------------------------------"
            echo
        } >> "$OUTPUT_FILE"
    done
    
    # 添加报告尾部
    {
        echo "========================================"
        echo "报告生成完成"
        echo "========================================"
    } >> "$OUTPUT_FILE"
    
    echo
    info "文本报告生成成功！"
    
    # 在终端显示报告
    if [ "$SHOW_IN_TERMINAL" = true ]; then
        echo
        echo "========================================"
        echo "            报告内容预览"
        echo "========================================"
        echo
        cat "$OUTPUT_FILE"
    fi
}

# ==============================================
# 主程序
# ==============================================
check_dependencies
parse_arguments "$@"
validate_directory

# 自动选择最新测试结果
if [ "$LATEST_MODE" = true ]; then
    latest_dir=$(find "$RESULT_DIR" -maxdepth 1 -type d -name "[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_*" | sort -rn | head -1)
    if [ -z "$latest_dir" ]; then
        error "在 $RESULT_DIR 下未找到时间戳子目录（--latest 模式）"
    fi
    RESULT_DIR="$latest_dir"
    info "自动选择最新测试: $(basename "$RESULT_DIR")"
fi

find_json_files

generate_text_summary

# 如果启用了CSV选项，生成CSV报告
if [ "$GENERATE_CSV" = true ]; then
    echo
    generate_csv_summary
    generate_env_summary
fi

echo
echo "========================================"
info "所有报告生成完成！"
echo "========================================"