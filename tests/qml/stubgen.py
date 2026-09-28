#!/usr/bin/env python3
"""Emit member-only QML stubs from upstream qs.Ui / qs.Commons files.

Usage: stubgen.py OMARCHY_SHELL_DIR OUT_DIR REVISION

OMARCHY_SHELL_DIR is the shell/ directory of a basecamp/omarchy checkout at
REVISION; OUT_DIR is tests/qml/imports. Only the types this plugin uses (and
their bases) are emitted, into qs/Ui and qs/Commons with a qmldir each; the
Quickshell stubs beside them are hand-written.

Keeps each root object's property/signal/function declarations (and nested
`property QtObject x: QtObject { ... }` groups), drops every body and binding.
Object-typed properties become `var`, so qmllint checks member names on the
stubbed types themselves but not through a property holding another object.
"""
import re
import sys
from pathlib import Path

UP = Path(sys.argv[1])
OUT = Path(sys.argv[2])
REV = sys.argv[3]

DEFAULTS = {"bool": "false", "int": "0", "real": "0", "double": "0",
            "string": '""', "color": '"transparent"', "url": '""'}

BASES = {  # upstream root type -> stub root type
    "Item": "Item", "Rectangle": "Rectangle", "QtObject": "QtObject", "BorderSurface": "BorderSurface",
    "PanelWindow": "Item", "TextField": "T.TextField", "ToolTip": "T.ToolTip",
}

DECL = re.compile(r"^(?:(?:readonly|required|default)\s+)*property\s+(\S+)\s+(\w+)")
SIG = re.compile(r"^signal\s+(\w+)\s*(\([^)]*\))?")
FUNC = re.compile(r"^function\s+(\w+)\s*\(([^)]*)\)")


def strip(src):
    """Blank out comments and string contents so braces can be counted."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2) + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j])); i = j
        elif c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(c + re.sub(r"[^\n]", " ", src[i + 1:j]) + c); i = j + 1
        else:
            out.append(c); i += 1
    return "".join(out)


def members(lines, clean, start, depth):
    """Collect declarations at `depth` from line `start` until the block closes."""
    got, level, i = [], depth, start
    while i < len(lines):
        text = clean[i].strip()
        if level == depth and text:
            m = DECL.match(text)
            if m:
                ptype, name = m.groups()
                if "alias" == ptype:
                    ptype = "var"
                if ptype == "QtObject" and re.search(r":\s*QtObject\s*\{", text):
                    inner, i = members(lines, clean, i + 1, depth + 1)
                    got.append(("group", name, inner))
                    level = depth
                    i += 1
                    continue
                got.append(("prop", name, ptype, "readonly" in text.split("property")[0]))
            elif SIG.match(text):
                got.append(("signal", lines[i].strip().rstrip("{").strip()))
            elif FUNC.match(text):
                fn, args = FUNC.match(text).groups()
                args = ", ".join(a.split(":")[0].strip() for a in args.split(",") if a.strip())
                got.append(("func", fn, args))
        level += clean[i].count("{") - clean[i].count("}")
        if level < depth:
            return got, i
        i += 1
    return got, i


def emit(items, indent):
    pad = " " * indent
    out = []
    for it in items:
        if it[0] == "prop":
            _, name, ptype, ro = it
            if ptype[0].isupper() and ptype != "Item":
                ptype = "var"
            value = DEFAULTS.get(ptype, "null")
            out.append(f"{pad}{'readonly ' if ro else ''}property {ptype} {name}: {value}")
        elif it[0] == "signal":
            out.append(f"{pad}{it[1]}")
        elif it[0] == "func":
            out.append(f"{pad}function {it[1]}({it[2]}) {{}}")
        else:
            out.append(f"{pad}readonly property var {it[1]}: QtObject {{")
            out.extend(emit(it[2], indent + 2))
            out.append(f"{pad}}}")
    return out


def stub(module, name):
    src = (UP / module / f"{name}.qml").read_text()
    lines, clean = src.split("\n"), strip(src).split("\n")
    root = next(i for i, l in enumerate(clean) if re.match(r"^[A-Z][\w.]*\s*\{", l))
    base = BASES[re.match(r"^([\w.]+)", clean[root]).group(1)]
    items, _ = members(lines, clean, root + 1, 1)
    head = [f"// Generated stub of shell/{module}/{name}.qml, basecamp/omarchy@{REV}.",
            "// Member declarations only, for qmllint; nothing here runs."]
    if "pragma Singleton" in src:
        head.append("pragma Singleton")
    head.append("import QtQuick")
    if base.startswith("T."):
        head.append("import QtQuick.Templates as T")
    body = [f"{base} {{"] + emit(items, 2) + ["}"]
    return "\n".join(head + body) + "\n"


def main():
    sets = {
        ("Ui", "qs/Ui"): ["BarWidget", "BorderSurface", "Button", "KeyboardPanel", "Panel",
                          "PanelActionButton", "PanelController", "PanelKeyCatcher", "PanelToolTip",
                          "TextField", "ToggleSwitch", "WidgetButton"],
        ("Commons", "qs/Commons"): ["Color", "Style"],
    }
    for (module, rel), names in sets.items():
        d = OUT / rel
        d.mkdir(parents=True, exist_ok=True)
        qmldir = [f"module {rel.replace('/', '.')}"]
        for name in names:
            (d / f"{name}.qml").write_text(stub(module, name))
            single = "singleton " if module == "Commons" else ""
            qmldir.append(f"{single}{name} 1.0 {name}.qml")
        (d / "qmldir").write_text("\n".join(qmldir) + "\n")


main()
