# AdGuard Home + Tailscale Docker Environment

Macvlan ネットワーク（IPv4/IPv6 デュアルスタック）上で動作し、Tailscale 内のプライマリ DNS サーバーとしても機能する AdGuard Home の Docker Compose セットアップ環境です。

---

## 🌟 特徴

- **100% 完全コンテナ化（ゼロ設定）**: Tailnet デバイスの自動同期サービス (`hosts-sync`) が Docker Compose 内で完結します。AdGuard Home Web UI での手動設定（`100.100.100.100` の登録など）は**一切不要**です。`docker compose up -d` を実行するだけで、全 Tailnet 端末の IPv4 / IPv6 逆引き（ホスト名表示）および正引きが即座に完了します。
- **ホスト汚染ゼロ**: ホスト OS 側の Cron 設定や外部スクリプトの常駐は不要です。`docker compose down` でコンテナを削除すればすべてが綺麗に消去・クリーンアップされます。
- **ゼロビルド（サイドカー構成）**: カスタム Dockerfile 不要。公式イメージ (`adguard/adguardhome:latest` および `tailscale/tailscale:latest`) を直接 `pull` して使用します。
- **Macvlan 独立ネットワーク**: 物理 LAN 上の専用 IP アドレス（DHCP または 固定 IP）で起動し、ポート衝突を防ぎます。
- **IPv4 / IPv6 デュアルスタック対応**: SLAAC (`accept_ra=2`) 対応および IPv6 サブネット自動検出に対応しています。
- **Tailnet DNS 特化**: `--accept-dns=false` を標準指定し、コンテナ内での DNS ループを防ぎつつ Tailnet 内の DNS サーバーとして機能します。
- **認証キー期限切れ耐性**: `./data_tailscale` の永続化により、Initial Auth Key が期限切れになっても再起動時に認証が維持されます。
- **全自動環境構築 (`setup.sh`)**: ホストの物理ネットワーク環境（NIC名、サブネット、ゲートウェイ）を自動検出し、`.env` を生成します。

---

## 📂 ディレクトリ構成

```text
.
├── docker-compose.yml   # コンテナ構成定義（Tailscale + AdGuard Home + Hosts Sync）
├── setup.sh             # 物理ネットワーク自動検出 & .env 生成スクリプト
├── sync_hosts.sh        # コンテナ内部用 Tailnet 端末 (IPv4/IPv6) 自動同期スクリプト
├── .env.example         # 環境変数テンプレート
├── .gitignore           # 永続化データ・設定ファイルの除外設定
├── README.md            # 本ドキュメント
├── config/              # [自動生成] AdGuard Home 設定ディレクトリ
├── work/                # [自動生成] AdGuard Home データベース・作業ログ
└── data_tailscale/      # [自動生成] Tailscale 認証ステート永続化ディレクトリ
```

---

## 🚀 クイックスタート

### 1. ネットワーク自動検出と `.env` 生成

`setup.sh` を実行して物理ネットワークを検出します。

```bash
# ヘルプ表示
./setup.sh -h

# DHCP / 自動IP割り当てモード（推奨）
./setup.sh --dhcp

# 固定IPアドレスを指定する場合
./setup.sh --static-ip 192.168.1.250

# または対話型で実行
./setup.sh
```

### 2. Tailscale 認証キーの設定

生成された `.env` ファイルを編集し、`TS_AUTHKEY` に Tailscale Admin Console から取得した Auth Key を入力します。

```bash
# .env ファイルを編集
nano .env

# 設定例:
# TS_AUTHKEY=tskey-auth-xxxx-xxxx
```

### 3. コンテナの起動

```bash
docker compose up -d
```

起動後、指定した IP アドレス（または Tailscale IP）の `http://<IP>:80` にアクセスして AdGuard Home の初期セットアップ画面を開きます。
Tailnet 内の全デバイス（IPv4 / IPv6）の逆引き・ホスト名マッピングは、`hosts-sync` コンテナによって全自動で AdGuard Home に反映されます。

---

## 🤖 自動同期の仕組み (`adguard-hosts-sync`)

Tailscale 側の仕様として、MagicDNS (`100.100.100.100`) 単体では IPv6 の逆引き (`.ip6.arpa`) に回答できません (`SERVFAIL`)。

本構成では `adguard-hosts-sync` コンテナがバックグラウンドで全自動動作し、Tailscale のローカルソケットから全端末の **IPv4 および IPv6 アドレスとホスト名** を抽出し、AdGuard Home の `/etc/hosts` に書き込みます。

- **Web UI 上での `100.100.100.100` 登録は不要です**（登録時に発生する `Error 400` の心配もありません）。
- **更新間隔の変更**: デフォルトでは 1時間（3,600秒）おきに更新されます。変更する場合は `.env` ファイルに `SYNC_INTERVAL=1800` （30分）などのように記述してください。

---

## ⚙️ 環境変数 (`.env`)

| 環境変数名 | 説明 | デフォルト / 設定例 |
| :--- | :--- | :--- |
| `TS_AUTHKEY` | Tailscale 認証キー (初回起動時のみ必要) | `tskey-auth-xxxx-xxxx` |
| `TS_HOSTNAME` | Tailnet 内でのデバイス名 | `adguard-home` |
| `TZ` | タイムゾーン | `Asia/Tokyo` |
| `SYNC_INTERVAL` | Tailnet 端末の自動同期更新間隔 (秒) | `3600` (1時間) |
| `MACVLAN_NETWORK_NAME` | 利用する Docker Macvlan ネットワーク名 | `macvlan_lan` |
| `MACVLAN_PARENT` | 物理ネットワークインターフェース名 | `eth0`, `enp1s0` |
| `MACVLAN_SUBNET` | 物理 IPv4 サブネット CIDR | `192.168.1.0/24` |
| `MACVLAN_GATEWAY` | 物理 IPv4 ルーターゲートウェイ | `192.168.1.1` |
| `MACVLAN_IP` | 割当 IPv4 アドレス (空指定で DHCP / 自動割当) | `192.168.1.250` |
| `MACVLAN_IP6` | 割当 IPv6 アドレス (空指定で SLAAC / 自動割当) | `240d:1a:xxxx::250` |

---

## 🛠️ トラブルシューティング

### 1. Macvlan ネットワークのプール重複エラー (`Pool overlaps with other one...`)
同一ホスト上で旧設定の Macvlan ネットワークが残っている場合に発生します。

```bash
# 既存の Macvlan ネットワークを削除
docker compose down
docker network rm <旧ネットワーク名>

# setup.sh を再実行してコンテナ起動
./setup.sh --dhcp
docker compose up -d
```

### 2. AdGuard Home 起動時に `bind: cannot assign requested address` エラー
過去に移動前の古い IP アドレスが `config/AdGuardHome.yaml` に固定記録されている場合に発生します。

```bash
# 0.0.0.0 (全インターフェース対象) に修正
sed -i 's/100\.[0-9]*\.[0-9]*\.[0-9]*/0.0.0.0/g' ./config/AdGuardHome.yaml
docker compose restart adgrd
```
