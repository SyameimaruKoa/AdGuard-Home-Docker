#!/bin/bash
set -e

# ============================================================
# Tailscale 端末 (IPv4/IPv6) 自動同期 & hosts 生成スクリプト
# ============================================================

show_help() {
    echo "Usage: ./sync_tailscale_hosts.sh [OPTIONS]"
    echo ""
    echo "Tailscale 端末 (IPv4 / IPv6) 自動同期 & AdGuard Home hosts ファイル生成スクリプト"
    echo ""
    echo "Options:"
    echo "  -h, --help        このヘルプメッセージを表示して終了します。"
    echo "  --out <FILE_PATH> 出力先の hosts ファイルパスを指定します (デフォルト: ./hosts)。"
    echo "  --quiet           ログ出力を抑止する静音モードで実行します。"
    echo ""
    echo "説明:"
    echo "  Tailscale コンテナから 'tailscale status --json' を取得し、"
    echo "  Tailnet 内の全デバイスの IPv4 アドレスおよび IPv6 アドレスとホスト名のマッピングを抽出します。"
    echo "  抽出したマッピングを AdGuard Home 用の hosts ファイルへ全自動で出力・反映します。"
    exit 0
}

# ------------------------------------------------------------
# 引数解析
# ------------------------------------------------------------
OUT_FILE="./hosts"
QUIET=false

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        --out)
            if [ -n "$2" ]; then
                OUT_FILE="$2"
                shift 2
            else
                echo "ERROR: --out に指定するファイルパスが必要です。"
                exit 1
            fi
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        *)
            echo "不明なオプション: $1"
            show_help
            ;;
    esac
done

if [ "$QUIET" = false ]; then
    echo "============================================================"
    echo " Tailscale 端末 (IPv4 / IPv6) 自動抽出 & hosts 生成"
    echo "============================================================"
fi

# 親ディレクトリの存在確認
mkdir -p "$(dirname "$OUT_FILE")" 2>/dev/null || true

# Python3 を使用して Tailscale JSON ステータスを解析
python3 -c '
import json, sys, subprocess

try:
    res = subprocess.run(["docker", "exec", "adguard-tailscale", "tailscale", "status", "--json"], capture_output=True, text=True, check=True)
    data = json.loads(res.stdout)
except Exception as e:
    sys.stderr.write(f"ERROR: Tailscale ステータスの取得に失敗しました: {e}\n")
    sys.exit(1)

nodes = []
if "Self" in data:
    nodes.append(data["Self"])
if "Peer" in data:
    nodes.extend(data["Peer"].values())

output_lines = [
    "# ============================================================\n",
    "# Auto-generated Tailscale Host Mappings (IPv4 & IPv6)\n",
    "# ============================================================\n"
]

count = 0
for node in nodes:
    hn = node.get("HostName", "").strip()
    dns = node.get("DNSName", "").strip().rstrip(".")
    ips = node.get("TailscaleIPs", [])
    if hn and ips:
        clean_hn = hn.replace(" ", "-").lower()
        for ip in ips:
            output_lines.append(f"{ip}\t{clean_hn}\t{dns}\n")
            count += 1

out_path = sys.argv[1]
with open(out_path, "w", encoding="utf-8") as f:
    f.writelines(output_lines)

print(f"SUCCESS:{count}")
' "$OUT_FILE" > /tmp/sync_tailscale_hosts.tmp 2>&1 || {
    cat /tmp/sync_tailscale_hosts.tmp
    exit 1
}

RESULT=$(cat /tmp/sync_tailscale_hosts.tmp)
rm -f /tmp/sync_tailscale_hosts.tmp

if [ "$QUIET" = false ]; then
    echo "出力ファイル : $OUT_FILE"
    echo "生成状態     : $RESULT"
    echo "============================================================"
fi
