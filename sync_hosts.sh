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

while true; do
    tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | awk '
        /"HostName":/ { split($0, a, "\""); hn = tolower(a[4]); gsub(/ /, "-", hn); }
        /"DNSName":/ { split($0, a, "\""); dns = a[4]; sub(/\.$/, "", dns); }
        /"TailscaleIPs":/ { in_ips = 1; next }
        in_ips && /]/ { in_ips = 0 }
        in_ips && /"/ {
            split($0, a, "\"")
            ip = a[2]
            if (ip != "" && hn != "") {
                print ip "\t" hn "\t" dns
            }
        }
    ' > /opt/adguardhome/work/hosts.tmp 2>/dev/null && mv /opt/adguardhome/work/hosts.tmp /opt/adguardhome/work/hosts 2>/dev/null || true
    sleep "$INTERVAL"
done
