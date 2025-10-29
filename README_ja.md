# linvpsliteinit（日本語）

[English](./README.md) | [中文](./README_zh.md)

`linvpsliteinit` は **Debian / Ubuntu VPS** 向けの **軽量・対話型** 初期設定ツールです。

---

## 特徴
- ホスト名、タイムゾーン、UFW、Fail2Ban、SWAP、BBR を一括設定  
- コンポーネントを後から安全に追加可能  
- Debian 11 では SWAP の重複を回避、Debian 12 はデフォルト動作を保持  

---

## 使い方
```bash
git clone https://github.com/tonysbb/linvpsliteinit.git
cd linvpsliteinit
chmod +x vps_init_final_ChatGPT.sh add_components_ChatGPT.sh
sudo ./vps_init_final_ChatGPT.sh
sudo ./add_components_ChatGPT.sh
```

---

## ライセンス
MIT（[LICENSE](./LICENSE) を参照）