#!/bin/bash
set -e

# ============================================================
# AdGuard Home + Tailscale - ネットワーク自動検出・.env生成スクリプト
# ============================================================

show_help() {
    echo "Usage: ./setup.sh [OPTIONS]"
    echo ""
    echo "AdGuard Home + Tailscale - ネットワーク自動検出・.env生成・リセットスクリプト"
    echo ""
    echo "Options:"
    echo "  -h, --help               このヘルプメッセージを表示して終了します。"
    echo "  --reset                  既存の設定・Dockerコンテナ・ネットワークをリセットして初期化します。"
    echo "  --lan-only, --skip-wifi  Wi-Fi ネットワークの検出・自動作成をスキップし、有線LANのみの構成にします。"
    echo "  --dhcp                   有線LAN側で DHCP / 自動IP割り当てモードを使用します。"
    echo "  --static-ip <IP_ADDRESS> 有線LAN側のコンテナに設定する固定IPアドレスを指定します。"
    echo "  --wifi-if <INTERFACE>    使用するWi-Fi物理インターフェース名（例: wlp2s0, wlan0）を指定します。"
    echo "  --wifi-ip <IP_ADDRESS>    Wi-Fi側のコンテナに設定する固定IPアドレスを指定します。"
    echo "  --wifi-connect           対話型（インタラクティブ）でWi-Fi（WPA2/WPA3）のSSID/パスワードを設定・接続します。"
    echo ""
    echo "使用例:"
    echo "  1. 設定をリセットして有線LANのみ（無線無効化）に変更する場合:"
    echo "     ./setup.sh --reset --lan-only"
    echo ""
    echo "  2. 有線LANのみで固定IPを設定する場合:"
    echo "     ./setup.sh --static-ip 192.168.200.250 --lan-only"
    echo ""
    echo "  3. 有線LAN + Wi-Fi のデュアルネットワークで完全自動セットアップする場合:"
    echo "     ./setup.sh --dhcp"
    echo ""
    echo "説明:"
    echo "  引数なしで実行すると、Linuxのsysfs / iw / nmcli / ip link を用いて物理インターフェースを自動検出し、"
    echo "  すべての設定項目（有線/無線固定IP、WPA3接続設定等）を対話型プロンプトで設定できます。"
    echo "  --reset オプションを指定すると、実行中の Docker コンテナの停止 (docker compose down) および"
    echo "  旧 Docker ネットワークの削除を行い、新しい環境変数・構成ファイルをクリアな状態から再生成します。"
    exit 0
}

# ------------------------------------------------------------
# 無線物理インターフェースの多角的高精度自動検出関数
# ------------------------------------------------------------
detect_wifi_interface() {
    local iface=""

    # 1. sysfs から物理無線デバイスを確認 (/sys/class/net/*/wireless または phy80211)
    for sys_path in /sys/class/net/*; do
        if [ -d "$sys_path/wireless" ] || [ -d "$sys_path/phy80211" ]; then
            iface=$(basename "$sys_path")
            break
        fi
    done

    # 2. iw dev コマンドから抽出試行
    if [ -z "$iface" ] && command -v iw >/dev/null 2>&1; then
        iface=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')
    fi

    # 3. NetworkManager (nmcli) から wifi デバイスを抽出試行
    if [ -z "$iface" ] && command -v nmcli >/dev/null 2>&1; then
        iface=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep ':wifi$' | cut -d: -f1 | head -n 1)
    fi

    # 4. ip link のインターフェース名パターン (wl*, wlan*) から抽出試行
    if [ -z "$iface" ]; then
        iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(wl|wlan)' | head -n 1)
    fi

    echo "$iface"
}

# ------------------------------------------------------------
# 引数解析
# ------------------------------------------------------------
STATIC_IP=""
USE_DHCP=false
WIFI_IF_ARG=""
WIFI_IP_ARG=""
WIFI_CONNECT=false
SKIP_WIFI=false
DO_RESET=false

HAS_ARGS=false
if [ $# -gt 0 ]; then
    HAS_ARGS=true
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        --reset)
            DO_RESET=true
            shift
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
        --wifi-if)
            if [ -n "$2" ]; then
                WIFI_IF_ARG="$2"
                shift 2
            else
                echo "ERROR: --wifi-if に指定するインターフェース名が必要です。"
                exit 1
            fi
            ;;
        --wifi-ip)
            if [ -n "$2" ]; then
                WIFI_IP_ARG="$2"
                shift 2
            else
                echo "ERROR: --wifi-ip に指定するIPアドレスが必要です。"
                exit 1
            fi
            ;;
        --wifi-connect)
            WIFI_CONNECT=true
            shift
            ;;
        --lan-only|--skip-wifi)
            SKIP_WIFI=true
            shift
            ;;
        *)
            echo "不明なオプション: $1"
            show_help
            ;;
    esac
done

if [ "$DO_RESET" = true ]; then
    echo "============================================================"
    echo " 設定および Docker ネットワークのリセットを実行中..."
    echo "============================================================"
    
    if command -v docker >/dev/null 2>&1; then
        echo "実行中の Docker コンテナを停止・削除しています..."
        docker compose down --remove-orphans 2>/dev/null || true
        docker rm -f adguard-tailscale adguard-home adguard-hosts-sync 2>/dev/null || true

        echo "既存の Docker ネットワークを削除しています..."
        docker network rm macvlan_lan ipvlan_wifi 2>/dev/null || true
    fi

    echo "リセット処理が完了しました。"
    echo ""
fi

echo "============================================================"
echo " AdGuard Home + Tailscale - 物理ネットワーク自動検出 & 設定"
echo "============================================================"

# ------------------------------------------------------------
# 1. 有線LAN（Macvlan）物理ネットワークの検出
# ------------------------------------------------------------
PARENT_IF=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
GATEWAY_IP=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}')
GATEWAY_IP6=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}')

if [ -z "$PARENT_IF" ] || [ -z "$GATEWAY_IP" ]; then
    echo "ERROR: デフォルトルートが見つかりませんでした。ネットワーク接続を確認してください。"
    exit 1
fi

SUBNET_CIDR=$(ip route show dev "$PARENT_IF" 2>/dev/null | grep '/' | awk '{print $1; exit}')
SUBNET_CIDR6=$(ip -6 route show dev "$PARENT_IF" 2>/dev/null | grep -v 'fe80' | awk '/\/[0-9]+/{print $1; exit}')

if [ -z "$SUBNET_CIDR" ]; then
    echo "ERROR: インターフェース $PARENT_IF のサブネットが検出できませんでした。"
    exit 1
fi

echo "検出されたプライマリ（有線LAN）物理ネットワーク環境:"
echo "  - 物理インターフェース: $PARENT_IF"
echo "  - 物理IPv4ゲートウェイ  : $GATEWAY_IP"
echo "  - 物理IPv4サブネット    : $SUBNET_CIDR"
if [ -n "$SUBNET_CIDR6" ]; then
    echo "  - 物理IPv6サブネット    : $SUBNET_CIDR6"
fi
echo ""

# ------------------------------------------------------------
# 2. Docker Macvlan ネットワークの自動検索・作成
# ------------------------------------------------------------
EXISTING_NET=$(docker network ls --filter driver=macvlan --format '{{.Name}}' 2>/dev/null | head -n 1)

if [ -n "$EXISTING_NET" ] && [ "$DO_RESET" = false ]; then
    MACVLAN_NET_NAME="$EXISTING_NET"
    echo "既存の Docker Macvlan ネットワークを検出しました: '$MACVLAN_NET_NAME'"
    echo "プール重複エラー防止のため、このネットワークを再利用します。"
else
    MACVLAN_NET_NAME="macvlan_lan"
    echo "Docker Macvlan ネットワークが見つかりません。新規作成します: '$MACVLAN_NET_NAME'"
    docker network rm "$MACVLAN_NET_NAME" 2>/dev/null || true
    
    CREATE_ARGS=("network" "create" "-d" "macvlan" "--ipv6" "--subnet=$SUBNET_CIDR" "--gateway=$GATEWAY_IP")
    if [ -n "$SUBNET_CIDR6" ]; then
        CREATE_ARGS+=("--subnet=$SUBNET_CIDR6")
        if [ -n "$GATEWAY_IP6" ] && [[ ! "$GATEWAY_IP6" =~ ^fe80: ]]; then
            CREATE_ARGS+=("--gateway=$GATEWAY_IP6")
        fi
    fi
    CREATE_ARGS+=("-o" "parent=$PARENT_IF" "$MACVLAN_NET_NAME")

    docker "${CREATE_ARGS[@]}" || true
fi

echo ""

# 有線LAN固定IPモードの処理
if [ "$USE_DHCP" = true ]; then
    MACVLAN_IP_VALUE=""
    echo "有線LANモード: DHCP / 自動IP割り当て"
elif [ -n "$STATIC_IP" ]; then
    MACVLAN_IP_VALUE="$STATIC_IP"
    echo "有線LANモード: 固定IP ($MACVLAN_IP_VALUE)"
else
    if [ -t 0 ]; then
        echo "------------------------------------------------------------"
        echo "【設定 1/2】有線LAN IP割り当てモードを選択してください:"
        echo "  1) DHCP / 自動IP割り当て (デフォルト)"
        echo "  2) 固定IP指定"
        read -p "選択 [1/2]: " CHOICE
        if [ "$CHOICE" = "2" ]; then
            EXPECTED_PREFIX=$(echo "$SUBNET_CIDR" | sed -E 's/\.[0-9]+\/[0-9]+$//')
            read -p "  -> 有線LANの固定IPv4アドレスを入力してください (例: ${EXPECTED_PREFIX}.250): " INPUT_IP
            INPUT_PREFIX=$(echo "$INPUT_IP" | sed -E 's/\.[0-9]+$//')
            if [ -n "$INPUT_IP" ] && [ "$INPUT_PREFIX" != "$EXPECTED_PREFIX" ]; then
                echo "【警告】入力された IP ($INPUT_IP) は、検出された有線LANサブネット ($SUBNET_CIDR) と一致しません。"
                echo "        Docker の起動エラー防止のため、${EXPECTED_PREFIX}.x の範囲のアドレスを指定してください。"
            fi
            MACVLAN_IP_VALUE="$INPUT_IP"
        else
            MACVLAN_IP_VALUE=""
        fi
    else
        MACVLAN_IP_VALUE=""
    fi
fi

echo ""

# ------------------------------------------------------------
# 3. 対話型 Wi-Fi (WPA2/WPA3) 接続処理関数
# ------------------------------------------------------------
wifi_interactive_connect() {
    local wifi_if="$1"
    echo "============================================================"
    echo " 対話型 Wi-Fi (WPA2/WPA3) 接続セットアップ"
    echo "============================================================"
    
    if ! command -v nmcli >/dev/null 2>&1; then
        echo "ERROR: NetworkManager (nmcli) が見つかりませんでした。"
        echo "Wi-Fi の自動接続設定には nmcli が必要です。"
        return 1
    fi

    SUDO_CMD=""
    if [ "$(id -u)" -ne 0 ]; then
        SUDO_CMD="sudo"
    fi

    echo "周囲の Wi-Fi アクセスポイントをスキャンしています..."
    $SUDO_CMD nmcli dev wifi rescan ifname "$wifi_if" 2>/dev/null || true
    sleep 2
    $SUDO_CMD nmcli dev wifi list ifname "$wifi_if" || true
    echo ""

    read -p "接続する Wi-Fi SSID を入力してください: " TARGET_SSID
    if [ -z "$TARGET_SSID" ]; then
        echo "SSID が入力されませんでした。接続設定をスキップします。"
        return 0
    fi

    read -s -p "Wi-Fi パスワードを入力してください (WPA2/WPA3-SAE対応): " TARGET_PASS
    echo ""

    echo "Wi-Fi '$TARGET_SSID' に接続を試行しています..."
    if $SUDO_CMD nmcli dev wifi connect "$TARGET_SSID" password "$TARGET_PASS" ifname "$wifi_if"; then
        echo "SUCCESS: Wi-Fi '$TARGET_SSID' に正常に接続しました。"

        if [ -t 0 ]; then
            echo ""
            echo "【コンテナ専有化設定】"
            echo "ホスト OS 側の IPv4/IPv6 アドレス割り当てを無効化し、"
            echo "コンテナ専用（L2 物理リンクのみ維持）として設定しますか？"
            read -p "ホスト OS の IP を無効化してコンテナ専有にする [y/N]: " DISABLE_HOST_IP
            if [ "$DISABLE_HOST_IP" = "y" ] || [ "$DISABLE_HOST_IP" = "Y" ]; then
                echo "ホスト OS 側の IP 割り当てを無効化しています..."
                $SUDO_CMD nmcli connection modify "$TARGET_SSID" ipv4.method disabled ipv6.method ignore || true
                $SUDO_CMD nmcli connection up "$TARGET_SSID" || true
                echo "ホスト OS 側の IP 割り当てが無効化され、物理 L2 リンクのみ維持されました。"
            fi
        fi
    else
        echo "ERROR: Wi-Fi 接続に失敗しました。SSID およびパスワードを確認してください。"
        return 1
    fi
}

# ------------------------------------------------------------
# 4. Wi-Fi 物理ネットワークの自動検出・対話型フル設定 (IPvlan L2構成)
# ------------------------------------------------------------
WIFI_PARENT_IF=""
WIFI_SUBNET_CIDR=""
WIFI_IP_VALUE=""

# 無線物理インターフェースの高精度自動検出
DETECTED_WIFI_IF=$(detect_wifi_interface)

if [ -n "$WIFI_IF_ARG" ]; then
    WIFI_PARENT_IF="$WIFI_IF_ARG"
elif [ -n "$DETECTED_WIFI_IF" ]; then
    WIFI_PARENT_IF="$DETECTED_WIFI_IF"
fi

if [ -n "$WIFI_PARENT_IF" ]; then
    echo "自動検出された Wi-Fi 物理インターフェース: $WIFI_PARENT_IF"
else
    echo "INFO: ホスト上に物理 Wi-Fi インターフェースが検出されませんでした。"
fi

# 引数なし（対話モード）の全設定カスタマイズプロンプト
if [ "$HAS_ARGS" = false ] && [ -t 0 ]; then
    echo "------------------------------------------------------------"
    echo "【設定 2/2】Wi-Fi（無線ネットワーク）の設定"
    read -p "Wi-Fi ネットワークのセットアップを行いますか？ [Y/n]: " DO_WIFI_SETUP
    if [ "$DO_WIFI_SETUP" = "n" ] || [ "$DO_WIFI_SETUP" = "N" ]; then
        SKIP_WIFI=true
    fi
fi

if [ "$SKIP_WIFI" = false ]; then
    if [ -n "$WIFI_PARENT_IF" ] || [ "$HAS_ARGS" = false ]; then
        if [ -t 0 ] && [ "$HAS_ARGS" = false ]; then
            read -p "使用する Wi-Fi インターフェース名を確認してください [${WIFI_PARENT_IF:-wlp2s0}]: " INPUT_WIFI_IF
            if [ -n "$INPUT_WIFI_IF" ]; then
                WIFI_PARENT_IF="$INPUT_WIFI_IF"
            fi
        fi

        if [ -n "$WIFI_PARENT_IF" ]; then
            echo "使用する Wi-Fi インターフェース: $WIFI_PARENT_IF"

            # 対話型 Wi-Fi 接続の実施選択
            if [ "$WIFI_CONNECT" = true ]; then
                wifi_interactive_connect "$WIFI_PARENT_IF" || true
            elif [ -t 0 ] && [ "$HAS_ARGS" = false ]; then
                read -p "Wi-Fi の接続設定（WPA2/WPA3 対話型スキャン＆接続）を行いますか？ [y/N]: " DO_CONNECT
                if [ "$DO_CONNECT" = "y" ] || [ "$DO_CONNECT" = "Y" ]; then
                    wifi_interactive_connect "$WIFI_PARENT_IF" || true
                fi
            fi

            # 対話型 Wi-Fi 側 IP 割り当て指定
            if [ -t 0 ] && [ "$HAS_ARGS" = false ]; then
                echo ""
                echo "Wi-Fi 側のコンテナ IP 割り当てを選択してください:"
                echo "  1) 自動割り当て / 空設定 (デフォルト)"
                echo "  2) 固定IP指定"
                read -p "選択 [1/2]: " WIFI_IP_CHOICE
                if [ "$WIFI_IP_CHOICE" = "2" ]; then
                    read -p "  -> Wi-Fi 側の固定IPv4アドレスを入力してください (例: 192.168.55.250): " INPUT_WIFI_IP
                    WIFI_IP_VALUE="$INPUT_WIFI_IP"
                fi
            elif [ -n "$WIFI_IP_ARG" ]; then
                WIFI_IP_VALUE="$WIFI_IP_ARG"
            fi
            
            # サブネットの取得 (ルーティングテーブル -> 入力IP補正 -> 対話プロンプト)
            WIFI_SUBNET_CIDR=$(ip route show dev "$WIFI_PARENT_IF" 2>/dev/null | grep '/' | awk '{print $1; exit}')

            # ホストOSのIPが無効化されている場合、設定された固定IPからサブネットを補正自動抽出
            if [ -z "$WIFI_SUBNET_CIDR" ] && [ -n "$WIFI_IP_VALUE" ]; then
                WIFI_SUBNET_CIDR=$(echo "$WIFI_IP_VALUE" | sed -E 's/\.[0-9]+$/\.0\/24/')
            fi

            # それでも取得できない場合は対話入力または標準補完
            if [ -z "$WIFI_SUBNET_CIDR" ]; then
                if [ -t 0 ]; then
                    read -p "Wi-Fi 側のサブネット CIDR を入力してください [192.168.55.0/24]: " INPUT_WIFI_SUBNET
                    WIFI_SUBNET_CIDR="${INPUT_WIFI_SUBNET:-192.168.55.0/24}"
                else
                    WIFI_SUBNET_CIDR="192.168.55.0/24"
                fi
            fi

            # Wi-Fi NIC の安定動作ドライバ (ipvlan L2) を設定
            NET_DRIVER="ipvlan"
            NET_MODE_OPT=("-o" "ipvlan_mode=l2")
            IPVLAN_NET_NAME="ipvlan_wifi"
            echo "ネットワークモード: IPvlan L2 モード (Wi-Fi最適化構成)"

            # 古いエラーの原因となる macvlan_wifi_passthru が存在する場合は削除
            docker network rm macvlan_wifi_passthru 2>/dev/null || true

            if [ -n "$WIFI_SUBNET_CIDR" ]; then
                echo "  - Wi-Fi IPv4 サブネット   : $WIFI_SUBNET_CIDR"
                echo "  - デフォルトゲートウェイ : なし (DNS・ローカルL2通信専用)"

                # 既存 Docker ネットワークの確認
                EXISTING_WIFI_NET=$(docker network ls --filter name="$IPVLAN_NET_NAME" --format '{{.Name}}' 2>/dev/null | head -n 1)
                if [ -n "$EXISTING_WIFI_NET" ]; then
                    echo "既存の Docker ネットワークを検出しました: '$IPVLAN_NET_NAME'"
                else
                    echo "Docker ネットワーク ($NET_DRIVER, gatewayなし) を作成します: '$IPVLAN_NET_NAME'"
                    docker network create -d "$NET_DRIVER" \
                        --subnet="$WIFI_SUBNET_CIDR" \
                        -o parent="$WIFI_PARENT_IF" \
                        "${NET_MODE_OPT[@]}" \
                        "$IPVLAN_NET_NAME" || true
                fi

            else
                echo "WARN: Wi-Fi インターフェース $WIFI_PARENT_IF のサブネットが自動検出できませんでした。"
                echo "Wi-Fi に正常に接続されているか確認してください。"
            fi
        else
            echo "INFO: 指定可能な Wi-Fi インターフェースが見つかりませんでした。スキップします。"
        fi
    fi
fi

if [ -n "$WIFI_PARENT_IF" ] && [ "$SKIP_WIFI" = false ]; then
    cat << 'EOF' > docker-compose.override.yml
services:
    tailscale:
        networks:
            ipvlan_wifi:
                ipv4_address: ${IPVLAN_WIFI_IP}

networks:
    ipvlan_wifi:
        name: ${IPVLAN_WIFI_NET_NAME:-ipvlan_wifi}
        external: true
EOF
    echo "Wi-Fi 構成用の docker-compose.override.yml を自動生成しました。"
else
    if [ -f "docker-compose.override.yml" ]; then
        rm -f docker-compose.override.yml
        echo "LAN単体構成のため docker-compose.override.yml を削除しました。"
    fi
    IPVLAN_NET_NAME="ipvlan_wifi"
    docker network rm "$IPVLAN_NET_NAME" 2>/dev/null || true
fi

echo ""

# ------------------------------------------------------------
# 5. .env ファイルの更新/作成
# ------------------------------------------------------------
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

sed -i '/^IPVLAN_WIFI_NET_NAME=/d' "$ENV_FILE"
sed -i '/^IPVLAN_WIFI_PARENT=/d' "$ENV_FILE"
sed -i '/^IPVLAN_WIFI_SUBNET=/d' "$ENV_FILE"
sed -i '/^IPVLAN_WIFI_GATEWAY=/d' "$ENV_FILE"
sed -i '/^IPVLAN_WIFI_IP=/d' "$ENV_FILE"

echo "MACVLAN_NETWORK_NAME=$MACVLAN_NET_NAME" >> "$ENV_FILE"
echo "MACVLAN_PARENT=$PARENT_IF" >> "$ENV_FILE"
echo "MACVLAN_SUBNET=$SUBNET_CIDR" >> "$ENV_FILE"
echo "MACVLAN_GATEWAY=$GATEWAY_IP" >> "$ENV_FILE"
echo "MACVLAN_IP=$MACVLAN_IP_VALUE" >> "$ENV_FILE"
echo "MACVLAN_IP6=" >> "$ENV_FILE"

echo "IPVLAN_WIFI_NET_NAME=$IPVLAN_NET_NAME" >> "$ENV_FILE"
echo "IPVLAN_WIFI_PARENT=$WIFI_PARENT_IF" >> "$ENV_FILE"
echo "IPVLAN_WIFI_SUBNET=$WIFI_SUBNET_CIDR" >> "$ENV_FILE"
echo "IPVLAN_WIFI_GATEWAY=" >> "$ENV_FILE"
echo "IPVLAN_WIFI_IP=$WIFI_IP_VALUE" >> "$ENV_FILE"

echo "============================================================"
echo " .env ファイルの更新が完了しました！"
echo "  有線LANネットワーク: $MACVLAN_NET_NAME (parent: $PARENT_IF)"
if [ -n "$MACVLAN_IP_VALUE" ]; then
    echo "    設定IPv4        : 固定IP ($MACVLAN_IP_VALUE)"
else
    echo "    設定IPv4        : 自動割り当て / 空設定"
fi

if [ -n "$WIFI_PARENT_IF" ] && [ "$SKIP_WIFI" = false ]; then
    echo "  Wi-Fiネットワーク  : ${IPVLAN_NET_NAME:-ipvlan_wifi} (parent: $WIFI_PARENT_IF, mode: ${NET_DRIVER:-ipvlan})"
    if [ -n "$WIFI_IP_VALUE" ]; then
        echo "    設定IPv4        : 固定IP ($WIFI_IP_VALUE)"
    else
        echo "    設定IPv4        : 自動割り当て / 空設定"
    fi
    echo "    ゲートウェイ    : 未設定 (デフォルトルート排除・直通L2通信のみ)"
fi

echo ""
echo " 次のコマンドでコンテナを起動できます:"
echo "   docker compose up -d"
echo "============================================================"
