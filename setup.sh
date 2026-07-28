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
    echo "  IPv4/IPv6 ゲートウェイ、サブネット情報を自動検出して .env ファイルを生成します。"
    echo "  ホスト上に既存の Docker Macvlan ネットワークが存在する場合は自動再利用し、"
    echo "  存在しない場合は 'macvlan_lan' ネットワークを IPv4/IPv6 デュアルスタックで自動作成します。"
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

# デフォルトインターフェースと IPv4/IPv6 ゲートウェイの自動検出
PARENT_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
GATEWAY_IP=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
GATEWAY_IP6=$(ip -6 route show default 2>/dev/null | awk '/default/{print $3; exit}')

if [ -z "$PARENT_IF" ] || [ -z "$GATEWAY_IP" ]; then
    echo "ERROR: デフォルトルートが見つかりませんでした。ネットワーク接続を確認してください。"
    exit 1
fi

SUBNET_CIDR=$(ip route show dev "$PARENT_IF" 2>/dev/null | grep '/' | awk '{print $1; exit}')
SUBNET_CIDR6=$(ip -6 route show dev "$PARENT_IF" 2>/dev/null | grep 'inet6' | grep -v 'fe80' | grep 'scope global' | awk '{print $2; exit}')

if [ -z "$SUBNET_CIDR" ]; then
    echo "ERROR: インターフェース $PARENT_IF のサブネットが検出できませんでした。"
    exit 1
fi

echo "検出された物理ネットワーク環境:"
echo "  - 物理インターフェース: $PARENT_IF"
echo "  - 物理IPv4ゲートウェイ  : $GATEWAY_IP"
echo "  - 物理IPv4サブネット    : $SUBNET_CIDR"
if [ -n "$SUBNET_CIDR6" ]; then
    echo "  - 物理IPv6ゲートウェイ  : ${GATEWAY_IP6:-自動/SLAAC}"
    echo "  - 物理IPv6サブネット    : $SUBNET_CIDR6"
fi
echo ""

# ------------------------------------------------------------
# 既存 Docker Macvlan ネットワークの自動検索・IPv4/IPv6対応作成
# ------------------------------------------------------------
EXISTING_NET=$(docker network ls --filter driver=macvlan --format '{{.Name}}' 2>/dev/null | head -n 1)

if [ -n "$EXISTING_NET" ]; then
    MACVLAN_NET_NAME="$EXISTING_NET"
    echo "既存の Docker Macvlan ネットワークを検出しました: '$MACVLAN_NET_NAME'"
    echo "プール重複エラー防止のため、このネットワークを再利用します。"
else
    MACVLAN_NET_NAME="macvlan_lan"
    echo "Docker Macvlan ネットワークが見つかりません。新規作成します: '$MACVLAN_NET_NAME'"
    
    CREATE_ARGS=("-d" "macvlan" "--enable-ipv6" "--subnet=$SUBNET_CIDR" "--gateway=$GATEWAY_IP")
    if [ -n "$SUBNET_CIDR6" ]; then
        CREATE_ARGS+=("--subnet=$SUBNET_CIDR6")
        if [ -n "$GATEWAY_IP6" ]; then
            CREATE_ARGS+=("--gateway=$GATEWAY_IP6")
        fi
    fi
    CREATE_ARGS+=("-o" "parent=$PARENT_IF" "$MACVLAN_NET_NAME")

    docker network create "${CREATE_ARGS[@]}" || true
fi

echo ""

# IP設定モードの選択
if [ "$USE_DHCP" = true ]; then
    MACVLAN_IP_VALUE=""
    echo "モード: DHCP / 自動IP割り当て"
elif [ -n "$STATIC_IP" ]; then
    MACVLAN_IP_VALUE="$STATIC_IP"
    echo "モード: 固定IP ($MACVLAN_IP_VALUE)"
else
    if [ -t 0 ]; then
        echo "IP割り当てモードを選択してください:"
        echo "  1) DHCP / 自動IP割り当て (デフォルト)"
        echo "  2) 固定IP指定"
        read -p "選択 [1/2]: " CHOICE
        if [ "$CHOICE" = "2" ]; then
            read -p "固定IPv4アドレスを入力してください (例: 192.168.1.250): " INPUT_IP
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
sed -i '/^MACVLAN_NETWORK_NAME=/d' "$ENV_FILE"
sed -i '/^MACVLAN_PARENT=/d' "$ENV_FILE"
sed -i '/^MACVLAN_SUBNET=/d' "$ENV_FILE"
sed -i '/^MACVLAN_GATEWAY=/d' "$ENV_FILE"
sed -i '/^MACVLAN_IP=/d' "$ENV_FILE"
sed -i '/^MACVLAN_IP6=/d' "$ENV_FILE"

echo "MACVLAN_NETWORK_NAME=$MACVLAN_NET_NAME" >> "$ENV_FILE"
echo "MACVLAN_PARENT=$PARENT_IF" >> "$ENV_FILE"
echo "MACVLAN_SUBNET=$SUBNET_CIDR" >> "$ENV_FILE"
echo "MACVLAN_GATEWAY=$GATEWAY_IP" >> "$ENV_FILE"
echo "MACVLAN_IP=$MACVLAN_IP_VALUE" >> "$ENV_FILE"
echo "MACVLAN_IP6=" >> "$ENV_FILE"

echo "============================================================"
echo " .env ファイルの更新が完了しました！"
echo "  使用ネットワーク: $MACVLAN_NET_NAME (external)"
if [ -n "$MACVLAN_IP_VALUE" ]; then
    echo "  設定IPv4      : 固定IP ($MACVLAN_IP_VALUE)"
else
    echo "  設定IPv4      : DHCP / 自動割当 (MACVLAN_IPは空設定)"
fi
echo " 次のコマンドでコンテナを起動できます:"
echo "   docker compose up -d"
echo "============================================================"
