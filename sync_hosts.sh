#!/bin/sh
set -e

show_help() {
    echo "Usage: ./sync_hosts.sh [OPTIONS]"
    echo ""
    echo "Tailscale 端末 (IPv4 / IPv6) 自動同期スクリプト (コンテナ内部実行用)"
    echo ""
    echo "Options:"
    echo "  -h, --help    このヘルプメッセージを表示して終了します。"
    echo ""
    echo "説明:"
    echo "  Tailscale のローカルソケット (/tmp/tailscaled.sock) から"
    echo "  Tailnet 内の全デバイスの IPv4/IPv6 アドレスとホスト名を自動取得し、"
    echo "  AdGuard Home のワークディレクトリ (/opt/adguardhome/work/hosts) に"
    echo "  マッピングファイルを自動生成・更新し続けます。"
    exit 0
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
fi

echo "Tailscale Hosts Sync Service started."

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
    sleep 15
done
