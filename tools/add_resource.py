#!/usr/bin/env python3
"""Trägt einen Ordner aus _Project/Browser/ als Ordnerreferenz (blaue Ordner) in die Resources-Phase ein.

Aufruf: tools/add_resource.py ContentBlocker [weitere Argumente werden ignoriert]
Der Ordner landet samt Inhalt im App-Paket. Neue oder geänderte Dateien darin brauchen keine
weitere Projektänderung. Bereits eingetragene Ordner werden übersprungen.
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBX = ROOT / "_Project" / "Browser.xcodeproj" / "project.pbxproj"
ANCHOR_REF = "B002B8711BAE420500C744AF /* Assets.xcassets */"
ANCHOR_BUILD = "B002B8721BAE420500C744AF /* Assets.xcassets in Resources */"


def make_id(seed: str) -> str:
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def main(name):
    if not (ROOT / "_Project" / "Browser" / name).is_dir():
        sys.exit(f"Ordner fehlt: _Project/Browser/{name}")
    text = PBX.read_text()
    if f"path = {name}; sourceTree" in text:
        print(f"übersprungen (schon drin): {name}")
        return
    ref_id, build_id = make_id("folderref:" + name), make_id("folderbuild:" + name)
    ref = f"{ref_id} /* {name} */"
    build = f"{build_id} /* {name} in Resources */"
    ref_line = (f"\t\t{ref} = {{isa = PBXFileReference; lastKnownFileType = folder; "
                f"path = {name}; sourceTree = \"<group>\"; }};\n")
    marker = "/* End PBXFileReference section */"
    text = text.replace(marker, ref_line + marker, 1)
    group_anchor = f"\t\t\t\t{ANCHOR_REF},\n"
    assert group_anchor in text, "Gruppenanker nicht gefunden"
    text = text.replace(group_anchor, group_anchor + f"\t\t\t\t{ref},\n", 1)
    build_line = f"\t\t{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};\n"
    marker = "/* End PBXBuildFile section */"
    text = text.replace(marker, build_line + marker, 1)
    phase_anchor = f"\t\t\t\t{ANCHOR_BUILD},\n"
    assert phase_anchor in text, "Resources-Anker nicht gefunden"
    text = text.replace(phase_anchor, phase_anchor + f"\t\t\t\t{build},\n", 1)
    PBX.write_text(text)
    print(f"hinzugefügt: {name}")


if __name__ == "__main__":
    main(sys.argv[1])
