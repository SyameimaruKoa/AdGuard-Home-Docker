#!/bin/sh
set -e

show_help() {
    echo "Usage: ./sync_hosts.sh [OPTIONS]"
    echo ""
    echo "Tailscale 端末 (IPv4 / IPv6) 自動同期スクリプト (コンテナ内部実行用)"
    echo ""
    echo "Options:"
    echo "  -h, --help            このヘルプメッセージを表示して終了します。"
    echo "  --interval <SECONDS>  同期更新間隔（秒）を指定します (デフォルト: 3600 秒 = 1時間)。"
    echo ""
    echo "説明:"
    echo "  Tailscale のローカルソケット (/tmp/tailscaled.sock) から"
    echo "  Tailnet 内の全デバイスの IPv4/IPv6 アドレスとホスト名を自動取得し、"
    echo "  AdGuard Home のワークディレクトリ (/opt/adguardhome/work/hosts) に"
    echo "  マッピングファイルを自動生成・更新し続けます。"
    exit 0
}

INTERVAL="${SYNC_INTERVAL:-3600}"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        --interval)
            if [ -n "$2" ]; then
                INTERVAL="$2"
                shift 2
            else
                echo "ERROR: --interval に指定する秒数が必要です。"
                exit 1
            fi
            ;;
        *)
            shift
            ;;
    esac
done

echo "Tailscale Hosts Sync Service started. (Update Interval: ${INTERVAL}s)"

# ワークディレクトリの準備
mkdir -p /opt/adguardhome/work

while true; do
    # Tailnet のドメイン名を取得 (例: bass-uaru.ts.net)
    TS_DOMAIN=$(tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | awk -F'"' '/"MagicDNSSuffix":/ {if ($4 != "") {print $4; exit}}' | tr -d '\r\n')

    # status テキスト出力から IP とホスト名を安全に抽出
    tailscale --socket=/tmp/tailscaled.sock status 2>/dev/null | awk -v domain="$TS_DOMAIN" '
        NF >= 2 && ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $1 ~ /^[0-9a-fA-F:]+$/) {
            ip = $1
            host = tolower($2)
            if (ip != "" && host != "" && host != "-") {
                if (domain != "") {
                    print ip "\t" host "\t" host "." domain
                } else {
                    print ip "\t" host
                }
            }
        }
    ' > /opt/adguardhome/work/hosts.tmp 2>/dev/null || true

    if [ -s /opt/adguardhome/work/hosts.tmp ]; then
        # bind mount の inode 破損を防ぐため cat で上書き
        cat /opt/adguardhome/work/hosts.tmp > /opt/adguardhome/work/hosts 2>/dev/null || true
    fi

    sleep "$INTERVAL"
done



