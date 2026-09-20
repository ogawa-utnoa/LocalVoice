# モデル

モデルはリポジトリに含めません(サイズとライセンスのため)。`./scripts/download_models.sh` が、[manifest.tsv](manifest.tsv) に書かれた公式の配布元から取得し、チェックサム(SHA-256)で改ざんや破損がないか確かめます。

| ファイル | 役割 | サイズ | ライセンス |
| :--- | :--- | :--- | :--- |
| `ggml-large-v3-turbo-q5_0.bin` | 文字起こし(推奨) | 574MB | MIT |
| `qwen2.5-1.5b-instruct-q4_k_m.gguf` | 文章の整形(推奨) | 1.1GB | Apache 2.0 |
| `ggml-small.bin` | 文字起こし(メモリが少ないとき) | 488MB | MIT |
| `qwen2.5-0.5b-instruct-q4_k_m.gguf` | 文章の整形(メモリが少ないとき) | 491MB | Apache 2.0 |

- `./scripts/download_models.sh` → 推奨の2つ(約1.7GB)
- `./scripts/download_models.sh full` → 4つすべて(約2.7GB)

置き場所は `Models/`(アプリの隣)か `~/.localvoiceinput/models/`。どちらにあっても自動で見つけます。

## メモリに応じた自動切り替え

処理のたびに空きメモリを見て、使うモデルを選びます。モデルは処理中だけ読み込み、終わるとメモリを返します。

| モード | 空きメモリ | 文字起こし | 整形 |
| :--- | :--- | :--- | :--- |
| Normal | 3.5GB 以上 | large-v3-turbo(無ければ medium / small) | Qwen2.5 1.5B |
| Low Memory | 1.5〜3.5GB | small | Qwen2.5 0.5B |
| Emergency | 1.5GB 未満 | small | AIを使わない整形のみ |

別のモデルを使いたいときは、ファイルを `Models/` に置いてから 🎙️ >「設定…」>「モデル」で選びます(ファイル名が `ggml-*.bin` なら文字起こし用、`*.gguf` なら整形用として認識)。
