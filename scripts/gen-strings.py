#!/usr/bin/env python3
"""ソース中の L("...") を集め、Resources/{en,ja}.lproj/Localizable.strings を生成する。
未翻訳のキーがあればエラーにする。"""
import glob, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from strings_ja import JA, INFOPLIST

root = os.path.join(os.path.dirname(__file__), "..")
keys = set()
pat = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')
for f in glob.glob(os.path.join(root, "Sources/SnipReel/*.swift")):
    keys |= set(m.encode().decode("unicode_escape").encode("latin1").decode("utf-8")
                for m in pat.findall(open(f, encoding="utf-8").read()))
# PenSettings / OutputFormat などで L(変数) に渡す英語名
keys |= {k for k in JA if k not in keys}

missing = sorted(k for k in keys if k not in JA)
if missing:
    sys.exit("未翻訳のキー:\n  " + "\n  ".join(missing))

def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"')
def write(lang, table, name):
    path = os.path.join(root, f"Resources/{lang}.lproj/{name}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("/* scripts/gen-strings.py で生成。直接編集しないこと */\n")
        for k in sorted(table):
            f.write(f'"{esc(k)}" = "{esc(table[k])}";\n')

write("en", {k: k for k in keys}, "Localizable.strings")
write("ja", {k: JA[k] for k in keys}, "Localizable.strings")
for lang, t in INFOPLIST.items():
    write(lang, t, "InfoPlist.strings")
print(f"{len(keys)} keys written")
