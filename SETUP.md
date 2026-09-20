# 手動セットアップ(setup.sh を使わない場合)

ふつうは `./setup.sh` を実行するだけで済みます([README](README.md))。ここでは、同じことを1つずつ手で行う手順を書きます。

## 1. 前提

- Apple Silicon の Mac、macOS 14(Sonoma)以降
- Xcode Command Line Tools: `xcode-select --install`
- Homebrew: https://brew.sh

## 2. 文字起こし・整形の部品

```bash
brew install whisper-cpp llama.cpp
which whisper-cli llama-completion
# /opt/homebrew/bin/whisper-cli
# /opt/homebrew/bin/llama-completion
```

`llama-completion` が無い場合は、llama.cpp が古い版です(`brew upgrade llama.cpp`)。
新しい `llama-cli` は対話専用になり、ロゴや入力文まで出力するため、このアプリでは使いません。

## 3. モデル

```bash
./scripts/download_models.sh          # 推奨(約1.7GB)
./scripts/download_models.sh full     # 予備モデルも(合計約2.7GB)
```

取得元・サイズ・チェックサムは [Models/manifest.tsv](Models/manifest.tsv) にあります。

## 4. ビルドと起動

```bash
./scripts/build_app.sh
open LocalVoiceInput.app
```

メニューバーに 🎙️ が出ます。

## 5. 権限

1. マイク: 初回の録音時の確認で「許可」(システム設定 > プライバシーとセキュリティ > マイク)
2. アクセシビリティ: システム設定 > プライバシーとセキュリティ > アクセシビリティ で `LocalVoiceInput` をオン

再ビルドすると、アクセシビリティの許可は無効になります(仮の署名が毎回変わるため)。
`tccutil reset Accessibility local.voiceinput.LocalVoiceInput` を実行してから、許可し直してください。

## 6. ログイン時の自動起動(任意)

```bash
./scripts/install_login_item.sh              # 自動起動する
./scripts/install_login_item.sh --uninstall  # やめる
```

`~/Library/LaunchAgents/<バンドルID>.plist` を作り、ログイン時にアプリを起動します。

## 7. ビルドの設定(任意)

リポジトリ直下に `build.local.env` を置くと、ビルドの設定を変えられます(公開・コミットの対象外)。

```bash
LVI_BUNDLE_ID=com.example.LocalVoiceInput     # アプリのID
LVI_SIGN_IDENTITY="LocalVoiceInput Dev"       # コード署名用の証明書名(再ビルドしても権限が外れなくなる)
```
