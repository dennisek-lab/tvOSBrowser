#!/usr/bin/env python3
"""Bettet tools/cookie_consent.js als Objective-C-Stringliteral in BrowserCookieConsentBlocker.m ein.

Ersetzt den Bereich zwischen den Markierungen BEGIN-COOKIE-SCRIPT und END-COOKIE-SCRIPT.
Aufruf: python3 tools/embed_cookie_script.py
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
JS = ROOT / "tools" / "cookie_consent.js"
M = ROOT / "_Project" / "Browser" / "BrowserCookieConsentBlocker.m"


def literal(line: str) -> str:
    esc = line.replace("\\", "\\\\").replace('"', '\\"')
    return f'    @"{esc}\\n"'


def main():
    lines = [l.rstrip("\n") for l in JS.read_text().splitlines() if l.strip()]
    body = "\n".join(literal(l) for l in lines) + ";"
    text = M.read_text()
    pattern = re.compile(r"(// BEGIN-COOKIE-SCRIPT\n).*?(\n// END-COOKIE-SCRIPT)", re.S)
    new = pattern.sub(lambda m: m.group(1) + "    return\n" + body + m.group(2), text)
    M.write_text(new)
    print(f"{len(lines)} Zeilen eingebettet")


if __name__ == "__main__":
    main()
