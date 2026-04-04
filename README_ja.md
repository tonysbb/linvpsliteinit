# linvpsliteinit（日本語）

[English](./README.md) | [🇨🇳 中文](./README_zh.md)

`linvpsliteinit` は **Debian / Ubuntu / Alpine Linux** 向けの **軽量・対話型** VPS 初期設定ツールです。  
一回限りの初期化スクリプトと、再実行可能なコンポーネントインストーラーを提供します。

---

## ✨ 特徴
- **一度の初期化、自由にスキップ**：ホスト名、タイムゾーン、ファイアウォール、Fail2Ban、SWAP、BBR
- **後からコンポーネントを安全に追加**：何度でも再実行可能
- **スマート SWAP**：適切なデフォルト値；Debian 11 では重複マウントを回避
- **セキュリティ基盤**：インバウンド拒否・アウトバウンド許可がデフォルト；SSH ポートのみ開放
- **Alpine 対応**：iptables ファイアウォール、OpenRC サービス管理、bash 不要（POSIX sh）
- **動作確認済み**：Debian 11/12、Ubuntu LTS、Alpine 3.22+

---

## 🚀 使い方

```bash
git clone https://github.com/tonysbb/linvpsliteinit.git
cd linvpsliteinit
chmod +x vps_init.sh add_components.sh
sudo ./vps_init.sh
sudo ./add_components.sh
```

### ☝️ ワンライナー（注意して使用）

```bash
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/vps_init.sh | sudo sh
curl -fsSL https://raw.githubusercontent.com/tonysbb/linvpsliteinit/main/add_components.sh | sudo sh
```

---

## 🧩 モジュール

### 1) 初期化スクリプト `vps_init.sh`
- ホスト名・タイムゾーン設定（RFC 1123 準拠）
- SWAP：動的サイジング、Debian 11 の重複回避
- ファイアウォール：Debian/Ubuntu は UFW + Fail2Ban；Alpine は iptables
- BBR：カーネルが対応している場合に有効化

初期化中、ホスト名とタイムゾーンは別々に確認されます。
Debian/Ubuntu では、ファイアウォール手順を選ぶと UFW をそのまま設定し、その後 Fail2Ban を有効化するか確認します。

### 2) コンポーネントスクリプト `add_components.sh`
再実行可能なメニュー形式のインストーラー：
- SWAP 設定
- ファイアウォール（UFW + Fail2Ban / iptables）
- BBR
- ホスト名・タイムゾーン
- Docker（Debian/Ubuntu は公式リポジトリ；Alpine はシステムパッケージ）
- tmux
- mosh（必要に応じて既定 UDP 範囲 `60000-61000` を開放）
- FRPS（Alpine は OpenRC；Debian/Ubuntu は systemd）

Guided Install では「ホスト名・タイムゾーン」手順に直接入り、それぞれ個別にスキップできます。

---

## 🛠️ 動作環境

| OS | バージョン | ファイアウォール | サービス管理 |
|----|-----------|----------------|------------|
| Debian | 11 / 12 | UFW + Fail2Ban | systemd |
| Ubuntu | 20.04 / 22.04 / 24.04 LTS | UFW + Fail2Ban | systemd |
| Alpine | 3.22+ | iptables | OpenRC |

> **cloud-init**：一部の VPS イメージは起動時にホスト名やネットワーク設定を上書きします。  
> Debian/Ubuntu では `/etc/cloud/cloud.cfg` の `preserve_hostname` を確認してください。  
> Alpine の NAT VPS では、ホストがホスト名を注入する場合があります。スクリプトは `/etc/local.d/hostname.start` で自動的に対応します。

> **NAT VPS**：10000 番以上のポートを使用する場合、プロバイダーのポートマッピングとスクリプトの設定が一致していることを確認してください。

---

## 🔒 セキュリティ
- root 権限が必要
- ホスト名は RFC 1123 に準拠すること
- **Debian/Ubuntu**：UFW はインバウンド拒否・アウトバウンド許可；Fail2Ban で SSH ブルートフォースを防御
- **Alpine**：iptables でインバウンド DROP；`vps_init.sh` で鍵認証のみに設定
- 秘密鍵はサーバー側で生成・一度だけ表示されます。確認後すぐに削除されるため、必ず保存してください

---

## 📜 ライセンス
MIT（[LICENSE](./LICENSE) 参照）
