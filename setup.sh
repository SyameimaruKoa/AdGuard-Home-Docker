#!/bin/bash
set -e

# ============================================================
# AdGuard Home + Tailscale - ネットワーク自動検出・.env生成スクリプト
# ============================================================

show_help() {
    echo "Usage: ./setup.sh [OPTIONS]"
    echo ""
    echo "AdGuard Home + Tailscale - ネットワーク自動検出・.env生成スクリプト"
    echo ""
    echo "Options:"
    echo "  -h, --help               このヘルプメッセージを表示して終了します。"
    echo "  --dhcp                   DHCP / 自動IP割り当てモードを使用します（固定IP未指定）。"
    echo "  --static-ip <IP_ADDRESS> コンテナに設定する固定IPアドレスを指定します。"
    echo ""
    echo "説明:"
    echo "  現在のLinuxホストのデフォルトルートから、物理インターフェース名、"
    echo "  ゲートウェイ、サブネット情報を自動検出して .env ファイルを生成します。"
    echo "  DHCP（自動割当）または固定IP設定の両方に対応しています。"
    exit 0
}

# ------------------------------------------------------------
# 引数解析
# ------------------------------------------------------------
STATIC_IP=""
USE_DHCP=false

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        --dhcp)
            USE_DHCP=true
            shift
            ;;
        --static-ip)
            if [ -n "$2" ]; then
                STATIC_IP="$2"
                shift 2
            else
                echo "ERROR: --static-ip に指定するIPアドレスが必要です。"
                exit 1
            fi
            ;;
        *)
            echo "不明なオプション: $1"
            show_help
            ;;
    esac
done

echo "============================================================"
echo " AdGuard Home + Tailscale - 物理ネットワーク自動検出"
echo "============================================================"

# デフォルトインターフェースとゲートウェイの自動検出
PARENT_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
GATEWAY_IP=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')

if [ -z "$PARENT_IF" ] || [ -z "$GATEWAY_IP" ]; then
    echo "ERROR: デフォルトルートが見つかりませんでした。ネットワーク接続を確認してください。"
    exit 1
fi

SUBNET_CIDR=$(ip route show dev "$PARENT_IF" 2>/dev/null | grep '/' | awk '{print $1; exit}')

if [ -z "$SUBNET_CIDR" ]; then
    echo "ERROR: インターフェース $PARENT_IF のサブネットが検出できませんでした。"
    exit 1
fi

echo "検出されたネットワーク環境:"
echo "  - 物理インターフェース (MACVLAN_PARENT): $PARENT_IF"
echo "  - 物理ゲートウェイ       (MACVLAN_GATEWAY): $GATEWAY_IP"
echo "  - 物理サブネット         (MACVLAN_SUBNET) : $SUBNET_CIDR"
echo ""

# IP設定モードの選択（対話モードまたは引数指定）
if [ "$USE_DHCP" = true ]; then
    MACVLAN_IP_VALUE=""
    echo "モード: DHCP / 自動IP割り当て"
elif [ -n "$STATIC_IP" ]; then
    MACVLAN_IP_VALUE="$STATIC_IP"
    echo "モード: 固定IP ($MACVLAN_IP_VALUE)"
else
    # 端末で対話的に入力要求（パイプ実行時等のフォールバック付）
    if [ -t 0 ]; then
        echo "IP割り当てモードを選択してください:"
        echo "  1) DHCP / 自動IP割り当て (デフォルト)"
        echo "  2) 固定IP指定"
        read -p "選択 [1/2]: " CHOICE
        if [ "$CHOICE" = "2" ]; then
            read -p "固定IPアドレスを入力してください (例: 192.168.1.250): " INPUT_IP
            MACVLAN_IP_VALUE="$INPUT_IP"
        else
            MACVLAN_IP_VALUE=""
        fi
    else
        MACVLAN_IP_VALUE=""
    fi
fi

# .env ファイルの更新/作成
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    if [ -f ".env.example" ]; then
        cp .env.example "$ENV_FILE"
        echo ".env.example から .env を作成しました。"
    else
        touch "$ENV_FILE"
    fi
fi

# 検出したパラメータを .env に反映
sed -i '/^MACVLAN_PARENT=/d' "$ENV_FILE"
sed -i '/^MACVLAN_SUBNET=/d' "$ENV_FILE"
sed -i '/^MACVLAN_GATEWAY=/d' "$ENV_FILE"
sed -i '/^MACVLAN_IP=/d' "$ENV_FILE"

echo "MACVLAN_PARENT=$PARENT_IF" >> "$ENV_FILE"
echo "MACVLAN_SUBNET=$SUBNET_CIDR" >> "$ENV_FILE"
echo "MACVLAN_GATEWAY=$GATEWAY_IP" >> "$ENV_FILE"
echo "MACVLAN_IP=$MACVLAN_IP_VALUE" >> "$ENV_FILE"

echo "============================================================"
echo " .env ファイルの更新が完了しました！"
if [ -n "$MACVLAN_IP_VALUE" ]; then
    echo "  設定IP: 固定IP ($MACVLAN_IP_VALUE)"
else
    echo "  設定IP: DHCP / 自動割当 (MACVLAN_IPは空設定)"
fi
echo " 次のコマンドでコンテナを起動できます:"
echo "   docker compose up -d"
echo "============================================================"
