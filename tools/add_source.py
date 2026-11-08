#!/usr/bin/env python3
"""Fügt Quelldateien (.h/.m) der Gruppe 'Browser' und der Sources-Phase des App-Targets hinzu.

Aufruf: tools/add_source.py Name.h Name.m ...
Die Dateien müssen bereits in _Project/Browser/ liegen. Bereits eingetragene Dateien werden übersprungen.
Als Anker dient BrowserWebView.m bzw. BrowserWebView.h, deren Gruppe und Sources-Phase genutzt werden.
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBX = ROOT / "_Project" / "Browser.xcodeproj" / "project.pbxproj"
ANCHOR_REF = "A1B49A622D6A3800001D58A1 /* BrowserWebView.m */"
ANCHOR_BUILD = "A1B49A632D6A3800001D58A1 /* BrowserWebView.m in Sources */"


def make_id(seed: str) -> str:
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def main(names):
    text = PBX.read_text()
    for name in names:
        if not (ROOT / "_Project" / "Browser" / name).exists():
            sys.exit(f"Datei fehlt: _Project/Browser/{name}")
        if f"path = {name};" in text:
            print(f"übersprungen (schon drin): {name}")
            continue
        is_source = name.endswith((".m", ".mm", ".c", ".swift"))
        ftype = {".h": "sourcecode.c.h", ".m": "sourcecode.c.objc", ".mm": "sourcecode.cpp.objcpp",
                 ".c": "sourcecode.c.c", ".swift": "sourcecode.swift"}[pathlib.Path(name).suffix]
        ref_id = make_id("ref:" + name)
        ref = f"{ref_id} /* {name} */"
        ref_line = (f"\t\t{ref} = {{isa = PBXFileReference; lastKnownFileType = {ftype}; "
                    f"path = {name}; sourceTree = \"<group>\"; }};\n")
        # Dateireferenz
        marker = "/* End PBXFileReference section */"
        text = text.replace(marker, ref_line + marker, 1)
        # Gruppe: direkt vor dem Anker in der Kinderliste
        group_anchor = f"\t\t\t\t{ANCHOR_REF},\n"
        assert group_anchor in text, "Gruppenanker nicht gefunden"
        text = text.replace(group_anchor, f"\t\t\t\t{ref},\n" + group_anchor, 1)
        if is_source:
            build_id = make_id("build:" + name)
            build = f"{build_id} /* {name} in Sources */"
            build_line = f"\t\t{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};\n"
            marker = "/* End PBXBuildFile section */"
            text = text.replace(marker, build_line + marker, 1)
            phase_anchor = f"\t\t\t\t{ANCHOR_BUILD},\n"
            assert phase_anchor in text, "Sources-Anker nicht gefunden"
            text = text.replace(phase_anchor, phase_anchor + f"\t\t\t\t{build},\n", 1)
        print(f"hinzugefügt: {name}")
    PBX.write_text(text)


if __name__ == "__main__":
    main(sys.argv[1:])
