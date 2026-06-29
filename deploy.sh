#!/usr/bin/env bash
#
# deploy.sh — 将项目同步到远程测试服务器
#
# 用法:
#   ./deploy.sh --host root@10.0.0.5 [--dir /root/fio-tool] [--dry-run]
#   ./deploy.sh [--dir /opt/fio-tool] [--dry-run]        # 使用配置文件
#   ./deploy.sh --setup-ssh                              # 配置 SSH 免密登录
#
# 配置文件 .deployrc（项目根目录）:
#   DEPLOY_HOST=root@10.0.0.5
#   REMOTE_DIR=/opt/fio-tool
#
# 优先级: --host/--dir 参数 > 环境变量 > .deployrc 配置文件

set -euo pipefail

REMOTE_DIR="/root/fio-tool"
HOST=""
DRY_RUN=""
SETUP_SSH=""

# 加载项目配置文件
CONFIG_FILE="$(cd "$(dirname "$0")" && pwd)/.deployrc"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --host)
            if [ -z "${2:-}" ]; then
                echo "错误: --host 需要参数" >&2
                exit 1
            fi
            HOST="$2"
            shift 2
            ;;
        --dir)
            if [ -z "${2:-}" ]; then
                echo "错误: --dir 需要参数" >&2
                exit 1
            fi
            REMOTE_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="--dry-run"
            shift
            ;;
        --setup-ssh)
            SETUP_SSH=1
            shift
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "部署选项:"
            echo "  --host <host>       SSH 目标 (user@hostname)"
            echo "  --dir  <path>       远程目录，默认 /root/fio-tool"
            echo "  --dry-run           预览模式，不实际传输"
            echo "  --setup-ssh         配置 SSH 免密登录（生成密钥 + 拷贝到服务器）"
            echo "  --help              显示此帮助"
            echo ""
            echo "免密配置:"
            echo "  1. 运行 $0 --setup-ssh 引导配置"
            echo "  2. 或手动: ssh-copy-id user@host"
            echo "  3. 在 .deployrc 文件中写入目标主机地址"
            echo ""
            echo "配置文件 .deployrc 示例:"
            echo "  DEPLOY_HOST=root@10.0.0.5"
            echo "  REMOTE_DIR=/opt/fio-tool"
            echo ""
            echo "优先级: --host/--dir 参数 > 环境变量 > .deployrc"
            exit 0
            ;;
        *)
            echo "错误: 未知参数 '$1'，使用 --help 查看用法" >&2
            exit 1
            ;;
    esac
done

# --setup-ssh 单独处理，不执行同步
if [ -n "$SETUP_SSH" ]; then
    TARGET_HOST="${HOST:-${DEPLOY_HOST:-}}"
    if [ -z "$TARGET_HOST" ]; then
        echo "指定要配置的目标主机:"
        echo "  $0 --setup-ssh --host user@hostname"
        echo "  或 export DEPLOY_HOST=user@hostname && $0 --setup-ssh"
        exit 1
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  配置 SSH 免密登录 → $TARGET_HOST"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
        echo "1. 未检测到 SSH 密钥，生成 ed25519 密钥..."
        ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" || true
    else
        echo "1. 检测到已有 SSH 密钥，跳过生成"
    fi

    echo "2. 拷贝公钥到服务器（需要输入服务器密码）..."
    echo ""
    ssh-copy-id "$TARGET_HOST"
    echo ""
    echo "✔ SSH 免密配置完成！现在可以直接运行 ./deploy.sh 了"
    exit 0
fi

# 优先级: --host 参数 > DEPLOY_HOST 环境变量 > .deployrc 配置
HOST="${HOST:-${DEPLOY_HOST:-}}"

if [ -z "$HOST" ]; then
    echo "错误: 未指定目标主机" >&2
    echo "用法: $0 --host <user@host> [--dir <路径>] [--dry-run]" >&2
    echo "  或: export DEPLOY_HOST=user@host && $0" >&2
    echo "  或: 在 .deployrc 中配置 DEPLOY_HOST" >&2
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Source:  $PROJECT_DIR"
echo "  Target:  $HOST:$REMOTE_DIR"
echo "  Dry-run: ${DRY_RUN:-no}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rsync -avz --delete --progress \
    --filter=':- .gitignore' \
    --exclude='.DS_Store' \
    --exclude='.git' \
    $DRY_RUN \
    -e ssh \
    "$PROJECT_DIR/" "$HOST:$REMOTE_DIR"

echo ""
if [ -n "$DRY_RUN" ]; then
    echo "✔ dry-run 完成（上面是预计传输的文件）"
else
    echo "✔ 同步完成 → $HOST:$REMOTE_DIR"
fi
