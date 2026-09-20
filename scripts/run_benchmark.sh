#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="$ROOT_DIR/Models"

echo "======================================================="
echo "  LocalVoice Live Performance Benchmark"
echo "======================================================="
echo "Hardware: Apple Silicon $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
echo "Memory: $(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024)) GB"
echo ""

WHISPER_CLI="/opt/homebrew/bin/whisper-cli"
LLAMA_CLI="/opt/homebrew/bin/llama-completion"

if [ ! -x "$WHISPER_CLI" ]; then
    echo "Error: whisper-cli not found at $WHISPER_CLI"
    exit 1
fi

if [ ! -x "$LLAMA_CLI" ]; then
    echo "Error: llama-completion not found at $LLAMA_CLI"
    exit 1
fi

TEMP_WAV="/tmp/localvoiceinput_bench_30s.wav"
# Generate real Japanese speech (~30s) with macOS text-to-speech, 16kHz mono
SPEECH="えーっと、来週の火曜日、いや水曜日の10時から田中さんとGoogle Workspaceの打ち合わせをします。費用は100万円です。"
say -v Kyoko --file-format=WAVE --data-format=LEI16@16000 -o "$TEMP_WAV" "$SPEECH $SPEECH $SPEECH $SPEECH"

echo "--- [1] Whisper Benchmark (30s Audio) ---"
for model in "$MODELS_DIR"/ggml-*.bin; do
    if [ -f "$model" ]; then
        model_name="$(basename "$model")"
        echo "Testing $model_name..."
        
        START_TIME=$(python3 -c "import time; print(time.time())")
        "$WHISPER_CLI" -m "$model" -f "$TEMP_WAV" -l ja -t 4 --no-timestamps -nt > /dev/null 2>&1 || true
        END_TIME=$(python3 -c "import time; print(time.time())")
        
        ELAPSED=$(python3 -c "print(f'{$END_TIME - $START_TIME:.2f}')")
        echo "  Result: ${ELAPSED}s for 30s audio"
    fi
done

echo ""
echo "--- [2] LLM Rewriting Benchmark (Qwen GGUF) ---"

SAMPLE_PROMPT="<|im_start|>system
あなたは音声入力の整文エンジンです。
入力はユーザーが実際に話した内容の文字起こしです。
内容を要約したり、新しい情報を追加したりしてはいけません。
次の処理だけをしてください。
- 不要なフィラーを削除
- 明確な言い直しを反映
- 重複を削除
- 句読点を追加
次は絶対に変更しないでください。
- 数字
- 日付
- 時刻
- URL
- メールアドレス
- 固有名詞
意味や情報量を変えず、完成した文章だけを返してください。
<|im_end|>
<|im_start|>user
えーっと、来週の、あー、火曜日、いや水曜日の10時から田中さんとGoogle Workspaceの打ち合わせをします。費用は100万円です。
<|im_end|>
<|im_start|>assistant"

for model in "$MODELS_DIR"/*.gguf; do
    if [ -f "$model" ]; then
        model_name="$(basename "$model")"
        echo "Testing $model_name..."
        
        START_TIME=$(python3 -c "import time; print(time.time())")
        OUTPUT=$("$LLAMA_CLI" -m "$model" -p "$SAMPLE_PROMPT" -c 1024 -t 4 -n 128 --temp 0.2 -no-cnv --no-display-prompt --no-warmup < /dev/null 2>/dev/null || true)
        END_TIME=$(python3 -c "import time; print(time.time())")
        
        ELAPSED=$(python3 -c "print(f'{$END_TIME - $START_TIME:.2f}')")
        CLEANED=$(echo "$OUTPUT" | sed 's/<|im_end|>//g' | sed 's/<|endoftext|>//g' | tr '\n' ' ' | sed 's/  */ /g')
        echo "  Output: $CLEANED"
        echo "  Time: ${ELAPSED}s"
    fi
done

echo ""
echo "======================================================="
echo "  Benchmark completed successfully"
echo "======================================================="
rm -f "$TEMP_WAV"
