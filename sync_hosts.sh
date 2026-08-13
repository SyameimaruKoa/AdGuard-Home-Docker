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

# 起動直後の Tailscale ソケット・ステータス接続待機ループ
echo "Waiting for Tailscale service to initialize..."
while true; do
    if [ -S /tmp/tailscaled.sock ]; then
        STATUS_JSON=$(tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null || true)
        if echo "$STATUS_JSON" | grep -q '"TailscaleIPs"' && echo "$STATUS_JSON" | grep -q '"BackendState": "Running"'; then
            echo "Tailscale service is ready."
            break
        fi
    fi
    echo "Tailscale service not ready yet. Retrying in 5 seconds..."
    sleep 5
done

while true; do
    # tailscale status --json から IPv4 / IPv6 およびホスト名・FQDNを完全抽出
    tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | awk '
        function expand_ipv6(ip,   a, n, i, zero_count, res, p, val) {
            if (index(ip, ":") == 0) return ip;
            n = split(ip, a, ":")
            zero_count = 8 - n + 1
            res = ""
            for (i = 1; i <= n; i++) {
                if (a[i] == "") {
                    for (p = 0; p < zero_count; p++) {
                        res = (res == "") ? "0000" : res ":0000"
                    }
                } else {
                    val = sprintf("%04s", a[i])
                    gsub(/ /, "0", val)
                    res = (res == "") ? val : res ":" val
                }
            }
            return res
        }

        function output_node() {
            dns_short = ""
            if (dns != "") {
                split(dns, d, ".")
                dns_short = tolower(d[1])
                gsub(/[^a-zA-Z0-9_-]/, "-", dns_short)
                gsub(/^-+|-+$/, "", dns_short)
            }

            if (hn == "" && dns_short != "") {
                hn = dns_short
            }

            if (hn != "") {
                gsub(/[^a-zA-Z0-9_-]/, "-", hn)
                hn = tolower(hn)
                gsub(/^-+|-+$/, "", hn)
            }

            if (hn != "") {
                for (i in ips) {
                    if (ips[i] != "") {
                        if (dns_short != "" && dns_short != hn && dns != "") {
                            names = hn "\t" dns_short "\t" dns
                        } else if (dns != "") {
                            names = hn "\t" dns
                        } else {
                            names = hn
                        }

                        print ips[i] "\t" names

                        # IPv6 の場合、AdGuard Home の ip6.arpa 逆引き対応のため展開形式も出力
                        if (index(ips[i], ":") > 0) {
                            exp_ip = expand_ipv6(ips[i])
                            if (exp_ip != ips[i]) {
                                print exp_ip "\t" names
                            }
                        }
                    }
                }
            }
            hn = ""
            dns = ""
            delete ips
            ip_count = 0
        }

        /"HostName":/ {
            output_node()
            split($0, a, "\"")
            hn = a[4]
        }
        /"DNSName":/ {
            split($0, a, "\"")
            dns = a[4]
            sub(/\.$/, "", dns)
        }
        /"TailscaleIPs":/ {
            in_ips = 1
            next
        }
        in_ips && /]/ {
            in_ips = 0
        }
        in_ips && /"/ {
            split($0, a, "\"")
            ip_count++
            ips[ip_count] = a[2]
        }
        END {
            output_node()
        }
    ' > /opt/adguardhome/work/hosts.tmp 2>/dev/null || true

    # バリデーション: hosts.tmp に有効な IP アドレスマッピングが含まれているか検証
    if [ -s /opt/adguardhome/work/hosts.tmp ] && grep -qE '^[0-9a-fA-F:.]+[[:space:]]+[a-zA-Z0-9_-]' /opt/adguardhome/work/hosts.tmp; then
        # 既存ファイルと変更がある場合のみ更新
        if ! cmp -s /opt/adguardhome/work/hosts.tmp /opt/adguardhome/work/hosts 2>/dev/null; then
            echo "Updating /opt/adguardhome/work/hosts with new Tailscale hosts..."
            cat /opt/adguardhome/work/hosts.tmp > /opt/adguardhome/work/hosts 2>/dev/null || true
        fi
    else
        echo "WARN: Generated hosts.tmp is empty or invalid. Skipping update."
    fi

    sleep "$INTERVAL"
done
