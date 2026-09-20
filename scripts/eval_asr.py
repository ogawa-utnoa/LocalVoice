#!/usr/bin/env python3
"""Whisper model / prompt accuracy comparison for LocalVoice.

Generates Japanese speech with macOS `say` (several voices), transcribes it with every
ggml Whisper model in Models/ (with and without the vocabulary prompt), and reports:
  - CER  : character error rate vs. the expected text (punctuation / spaces ignored)
  - Terms: how many product names came out spelled exactly as expected
  - Time : average whisper-cli wall time per utterance

Usage: python3 scripts/eval_asr.py [--models small,large-v3-turbo-q5_0] [--voices Kyoko,Eddy]
No text is sent anywhere; everything runs locally.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "Models")
WHISPER = "/opt/homebrew/bin/whisper-cli"

# (what the TTS voice reads, what we expect in the final text, product names that must be exact)
CASES = [
    ("アンチグラビティは制限に達したので、すべてこの後クロードでやる予定です。",
     "Antigravityは制限に達したので、すべてこの後Claudeでやる予定です。", ["Antigravity", "Claude"]),
    ("来週の水曜日の10時から、田中さんとグーグルワークスペースの打ち合わせをします。",
     "来週の水曜日の10時から、田中さんとGoogle Workspaceの打ち合わせをします。", ["Google Workspace"]),
    ("ジェミニとノートブックエルエムを使って、営業資料を作り直しました。",
     "GeminiとNotebookLMを使って、営業資料を作り直しました。", ["Gemini", "NotebookLM"]),
    ("クロードコードとコーデックスを併用して、タスク管理のページを更新しています。",
     "Claude CodeとCodexを併用して、タスク管理のページを更新しています。", ["Claude Code", "Codex"]),
    ("見積もりは月額3万円で、10月1日から問い合わせフォームの営業を始めます。",
     "見積もりは月額3万円で、10月1日から問い合わせフォームの営業を始めます。", []),
    ("タイプレスと同じくらいの精度を、ローカルで実現したいと考えています。",
     "Typelessと同じくらいの精度を、ローカルで実現したいと考えています。", ["Typeless"]),
    ("チャットジーピーティーで議事録を要約してから、共有ドライブに保存しておいてください。",
     "ChatGPTで議事録を要約してから、共有ドライブに保存しておいてください。", ["ChatGPT"]),
]

DICTIONARY_SWIFT = os.path.join(ROOT, "Sources", "Core", "Storage", "UserDictionary.swift")


PERSONAL_DICT = os.path.join(os.path.expanduser("~"), ".localvoice", "dictionary.json")


def load_dictionary(include_personal=False):
    """Reads UserDictionary.defaultEntries straight from the Swift source, so the evaluation always
    uses exactly what the app ships: the Whisper prompt and the spelling fixes.
    With include_personal, the personal dictionary file is added too (personal words first, as the app does)."""
    src = open(DICTIONARY_SWIFT, encoding="utf-8").read()
    block = src[src.index("defaultEntries: [UserDictionaryEntry] = ["):]
    block = block[:block.index("\n    ]")]
    entries = re.findall(r'UserDictionaryEntry\(word: "([^"]+)", reading: "([^"]*)"\)', block)
    if include_personal:
        try:
            personal = [(e["word"], e.get("reading", "")) for e in json.load(open(PERSONAL_DICT, encoding="utf-8"))]
        except (OSError, ValueError, KeyError, TypeError):
            personal = []
        merged = {w: r for w, r in entries}
        for w, r in personal:
            merged[w] = ", ".join(dict.fromkeys(re.split(r"[,、，]", (merged.get(w, "") + "," + r)))).strip(", ")
        entries = [(w, merged[w]) for w, _ in entries] + [(w, merged[w]) for w, _ in personal if w not in dict(entries)]
    prompt = ""
    for word, _ in entries:  # same rule as generateWhisperPrompt()
        nxt = word if not prompt else prompt + "、" + word
        if len(nxt) > 150:
            break
        prompt = nxt
    pairs = [(v.strip(), w) for w, r in entries for v in re.split(r"[,、，]", r) if v.strip() and v.strip() != w]
    pairs.sort(key=lambda p: -len(p[0]))
    return prompt + "。", pairs


PROMPT, PAIRS = load_dictionary("--personal" in sys.argv)


def _latin(c): return c.isascii() and c.isalpha()
def _kata(c): return "\u30a0" <= c <= "\u30ff"


def fix_vocabulary(text: str) -> str:
    """Python port of VocabularyNormalizer: whole-word replacement of known misrecognitions."""
    for variant, word in PAIRS:
        out, i = "", 0
        while True:
            k = text.find(variant, i)
            if k < 0:
                text = out + text[i:]
                break
            before = text[k - 1] if k > 0 else None
            after = text[k + len(variant)] if k + len(variant) < len(text) else None
            bad = any(n and ((_latin(e) and _latin(n)) or (_kata(e) and _kata(n)))
                      for e, n in ((variant[0], before), (variant[-1], after)))
            out += text[i:k] + (variant if bad else word)
            i = k + len(variant)
    return text


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s).lower()
    return re.sub(r"[\s、。,.!?！？「」・]", "", s)


def cer(ref: str, hyp: str) -> float:
    r, h = norm(ref), norm(hyp)
    prev = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        cur = [i] + [0] * len(h)
        for j, hc in enumerate(h, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rc != hc))
        prev = cur
    return prev[-1] / max(1, len(r))


def transcribe(model: str, wav: str, prompt: str | None) -> tuple[str, float]:
    args = [WHISPER, "-m", model, "-f", wav, "-l", "ja", "-t", "4", "-nt"]
    if prompt:
        args += ["--prompt", prompt]
    t0 = time.time()
    out = subprocess.run(args, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
    return out.stdout.strip(), time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="", help="comma separated substrings of model file names")
    ap.add_argument("--voices", default="Kyoko,Eddy (日本語（日本）),Flo (日本語（日本）),Reed (日本語（日本）)")
    ap.add_argument("--show", action="store_true", help="print every transcription")
    ap.add_argument("--personal", action="store_true", help="also use ~/.localvoice/dictionary.json")
    a = ap.parse_args()

    models = sorted(glob.glob(os.path.join(MODELS, "ggml-*.bin")))
    if a.models:
        keys = a.models.split(",")
        models = [m for m in models if any(k in os.path.basename(m) for k in keys)]
    voices = [v for v in a.voices.split(",") if v]

    tmp = tempfile.mkdtemp(prefix="lvi_eval_")
    wavs = []
    for vi, voice in enumerate(voices):
        for ci, (spoken, expected, terms) in enumerate(CASES):
            path = os.path.join(tmp, f"v{vi}_c{ci}.wav")
            subprocess.run(["say", "-v", voice, "--file-format=WAVE", "--data-format=LEI16@16000",
                            "-o", path, spoken], check=True)
            wavs.append((voice, path, expected, terms))

    print(f"{len(wavs)} utterances ({len(voices)} voices x {len(CASES)} sentences)\n")
    print(f"{'model':36} {'setup':22} {'CER':>6} {'terms':>7} {'sec':>5}")
    n = len(wavs)
    for model in models:
        for use_prompt in (False, True):
            rows = {"plain": [0.0, 0], "fixed": [0.0, 0]}
            want, secs = 0, 0.0
            for voice, path, expected, terms in wavs:
                text, dt = transcribe(model, path, PROMPT if use_prompt else None)
                secs += dt
                want += len(terms)
                for key, t in (("plain", text), ("fixed", fix_vocabulary(text))):
                    rows[key][0] += cer(expected, t)
                    rows[key][1] += sum(1 for term in terms if term in t)
                if a.show:
                    print(f"   [{os.path.basename(model)}|{'P' if use_prompt else '-'}|{voice.split(' ')[0]}] {text}")
            labels = [("plain", "prompt" if use_prompt else "none")]
            if use_prompt:
                labels.append(("fixed", "prompt + dictionary"))
            for key, label in labels:
                c, hit = rows[key]
                print(f"{os.path.basename(model):36} {label:22} {c / n * 100:5.1f}% {hit:>3}/{want:<3} {secs / n:5.2f}")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
