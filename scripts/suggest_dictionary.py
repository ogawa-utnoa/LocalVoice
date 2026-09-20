#!/usr/bin/env python3
"""Suggests dictionary words from what YOU typed into Claude Code / Codex, and merges approved entries.

  python3 scripts/suggest_dictionary.py                 # print candidate words (JSON)
  python3 scripts/suggest_dictionary.py --days 365      # look further back (default 180 days)
  python3 scripts/suggest_dictionary.py --apply new.json  # merge [{"word": ..., "reading": ...}] into your dictionary

Privacy:
  - Reads only local files: ~/.claude/history.jsonl, ~/.claude/projects/**/*.jsonl, ~/.codex/sessions/**/*.jsonl
  - Uses only messages YOU typed (no AI replies, no tool output, no pasted logs or code blocks)
  - Counts words only on lines that contain Japanese, i.e. words you actually say in your sentences
  - Prints only words and counts, never sentences. Nothing is sent anywhere by this script.
The personal dictionary lives outside the repository: ~/.localvoice/dictionary.json
"""
import argparse
import collections
import glob
import json
import os
import re
import sys
import time

HOME = os.path.expanduser("~")
DICT_PATH = os.path.join(HOME, ".localvoice", "dictionary.json")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULTS_SWIFT = os.path.join(ROOT, "Sources", "Core", "Storage", "UserDictionary.swift")

# Injected / machine text that is not something the person typed
SKIP_PREFIXES = ("<", "Caveat:", "[Request interrupted", "# AGENTS.md", "# CLAUDE.md", "This session is being continued")

# Common words that are not worth a dictionary entry (Whisper already spells them well)
COMMON = set("""
a an the and or but if then else of to in on at by for with from as is are was were be been it this that these those
i you he she we they me my your our their not no yes ok okay so do does did done can could will would should may
please thanks thank hi hello just also only all any some more most very really
api url pdf csv json html css js ts id ui ux ai llm os mac ios iphone ipad pc cpu gpu ram ssd usb wifi
http https www com jp co org net app apps web file files folder data text code test tests error errors log logs
readme todo md txt png jpg jpeg gif mp4 mp3 wav zip dm ceo cto etc vs eg ie ok ng
""".split())


def within(ts_seconds, since):
    return ts_seconds is None or ts_seconds >= since


def iso_to_epoch(value):
    if not value:
        return None
    try:
        return time.mktime(time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return None


def user_texts(days):
    """Yields (source, text) for messages the person typed."""
    since = time.time() - days * 86400
    counts = collections.Counter()

    # Claude Code prompt history
    path = os.path.join(HOME, ".claude", "history.jsonl")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="ignore"):
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = d.get("timestamp")
            ts = ts / 1000 if isinstance(ts, (int, float)) and ts > 1e11 else ts
            if isinstance(d.get("display"), str) and within(ts, since):
                counts["claude-history"] += 1
                yield d["display"]

    # Claude Code session transcripts
    for path in glob.glob(os.path.join(HOME, ".claude", "projects", "*", "*.jsonl")):
        if os.path.getmtime(path) < since:
            continue
        for line in open(path, encoding="utf-8", errors="ignore"):
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") != "user" or d.get("isMeta") or d.get("isSidechain") or d.get("toolUseResult"):
                continue
            if not within(iso_to_epoch(d.get("timestamp")), since):
                continue
            content = (d.get("message") or {}).get("content")
            if isinstance(content, list):
                if any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
                    continue
                content = "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
            if isinstance(content, str) and content.strip():
                counts["claude-sessions"] += 1
                yield content

    # Codex session transcripts
    for path in glob.glob(os.path.join(HOME, ".codex", "sessions", "**", "*.jsonl"), recursive=True):
        if os.path.getmtime(path) < since:
            continue
        for line in open(path, encoding="utf-8", errors="ignore"):
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            p = d.get("payload")
            if d.get("type") != "response_item" or not isinstance(p, dict):
                continue
            if p.get("type") != "message" or p.get("role") != "user":
                continue
            text = "\n".join(c.get("text", "") for c in p.get("content") or [] if isinstance(c, dict))
            if text.strip():
                counts["codex-sessions"] += 1
                yield text

    user_texts.counts = counts


JAPANESE = re.compile(r"[ぁ-んァ-ヴ一-龥]")
MAX_CHARS = 600  # longer messages are pasted logs / documents, not something you would say


def clean(text):
    text = text.strip()
    if text.startswith(SKIP_PREFIXES) or len(text) > MAX_CHARS:
        return ""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)       # code blocks
    text = re.sub(r"`[^`]*`", " ", text)                      # inline code
    text = re.sub(r"<[^>]{1,80}>", " ", text)                 # tags
    text = re.sub(r"https?://\S+|\S+@\S+", " ", text)         # URLs, emails
    text = re.sub(r"[~./\\]?[\w.-]*[/\\][\w./\\-]*", " ", text)  # paths
    lines = [l for l in text.splitlines()
             if JAPANESE.search(l)                                   # only lines you wrote in Japanese
             and not re.search(r"[{};=|]|^\s*[$#>]|\w+\(.*\)", l)   # skip code / tables
             and "  " not in l.strip()]                              # skip column-aligned output
    return "\n".join(lines)


LATIN_TOKEN = r"[A-Za-z][A-Za-z0-9+#&'-]*(?:\.[0-9]+)?"
PHRASE = re.compile(rf"{LATIN_TOKEN}(?: {LATIN_TOKEN}){{0,2}}")
KATAKANA = re.compile(r"[ァ-ヴー]{3,}")


def brandlike(token):
    return any(c.isupper() for c in token) or any(c.isdigit() for c in token)


def candidates(texts):
    """Counts how many of your messages contain each term (not raw occurrences, so one pasted
    block cannot inflate a word)."""
    latin, kata = collections.Counter(), collections.Counter()
    for raw in texts:
        text = clean(raw)
        if not text:
            continue
        seen_latin, seen_kata = set(), set()
        for m in PHRASE.finditer(text):
            words = m.group(0).split(" ")
            if len(words) > 1 and all(w[0].isupper() for w in words):
                seen_latin.add(" ".join(words))
            for w in words:
                if len(w) >= 2 and brandlike(w) and w.lower() not in COMMON:
                    seen_latin.add(w)
        for m in KATAKANA.finditer(text):
            seen_kata.add(m.group(0))
        latin.update(seen_latin)
        kata.update(seen_kata)
    return latin, kata


def known_words():
    words = set()
    try:
        src = open(DEFAULTS_SWIFT, encoding="utf-8").read()
        words |= set(re.findall(r'UserDictionaryEntry\(word: "([^"]+)"', src))
    except OSError:
        pass
    for e in load_dictionary():
        words.add(e["word"])
    return words


def load_dictionary():
    try:
        data = json.load(open(DICT_PATH, encoding="utf-8"))
        return [e for e in data if isinstance(e, dict) and e.get("word")]
    except (OSError, json.JSONDecodeError):
        return []


def split_variants(reading):
    return [v.strip() for v in re.split(r"[,、，]", reading or "") if v.strip()]


def apply(path):
    new = json.load(open(path, encoding="utf-8"))
    if not isinstance(new, list):
        sys.exit("--apply expects a JSON array of {\"word\": ..., \"reading\": ...}")
    current = load_dictionary()
    by_word = {e["word"]: e for e in current}
    added, extended = 0, 0
    for item in new:
        word = str(item.get("word", "")).strip()
        if not word:
            continue
        variants = [v for v in split_variants(item.get("reading", "")) if v != word]
        if word in by_word:
            old = split_variants(by_word[word].get("reading", ""))
            merged = old + [v for v in variants if v not in old]
            if merged != old:
                by_word[word]["reading"] = ", ".join(merged)
                extended += 1
        else:
            entry = {"word": word, "reading": ", ".join(variants)}
            current.append(entry)
            by_word[word] = entry
            added += 1
    os.makedirs(os.path.dirname(DICT_PATH), exist_ok=True)
    if os.path.exists(DICT_PATH):
        with open(DICT_PATH + ".bak", "w", encoding="utf-8") as f:
            f.write(open(DICT_PATH, encoding="utf-8").read())
    tmp = DICT_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(current, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, DICT_PATH)
    print(json.dumps({"dictionary": DICT_PATH, "added": added, "extended": extended, "total": len(current)},
                     ensure_ascii=False))
    print("Restart LocalVoice to load the new words.", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=180)
    ap.add_argument("--min-count", type=int, default=3)
    ap.add_argument("--top", type=int, default=80)
    ap.add_argument("--apply", metavar="JSON")
    a = ap.parse_args()

    if a.apply:
        apply(a.apply)
        return

    latin, kata = candidates(user_texts(a.days))
    known = known_words()
    known_lower = {w.lower() for w in known}

    def top(counter, limit):
        return [[w, c] for w, c in counter.most_common()
                if c >= a.min_count and w.lower() not in known_lower][:limit]

    print(json.dumps({
        "messages_read": dict(getattr(user_texts, "counts", {})),
        "already_in_dictionary": sorted(known),
        "latin_terms": top(latin, a.top),
        "katakana_terms": top(kata, a.top // 2),
    }, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
