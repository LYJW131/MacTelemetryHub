#!/usr/bin/env python3
"""Add a Swift file to the Xcode project.

The project uses explicit file references rather than a synchronized folder, so
a new source file is invisible to the build until three places know about it: a
PBXFileReference, the group's children, and the Sources build phase. Doing that
by hand is exactly the kind of edit that silently half-applies.

    Tools/add-source-file.py Sources/ChargerTelemetryKit/PowerBank.swift
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "MacTelemetryHub.xcodeproj" / "project.pbxproj"

GROUP_FOR_PREFIX = {
    "Sources/ChargerTelemetryKit": "A10000000000000000000011",
    "App/MacTelemetryHub": "A10000000000000000000010",
}


def next_id(text: str, prefix: str) -> str:
    used = {int(m, 16) for m in re.findall(rf"{prefix}([0-9A-F]{{2}})\b", text)}
    for candidate in range(0x20, 0xFF):
        if candidate not in used:
            return f"{prefix}{candidate:02X}"
    raise SystemExit("ran out of identifiers")


def add(relative: str) -> None:
    path = ROOT / relative
    if not path.exists():
        raise SystemExit(f"{relative} does not exist")
    name = path.name

    text = PBXPROJ.read_text()
    if f"/* {name} */" in text:
        print(f"{name} already referenced")
        return

    group_dir = str(pathlib.Path(relative).parent)
    group_id = GROUP_FOR_PREFIX.get(group_dir)
    if group_id is None:
        raise SystemExit(f"no group configured for {group_dir}")

    file_id = next_id(text, "F100000000000000000000")
    build_id = next_id(text, "B100000000000000000000")

    text = text.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_id} /* {name} */; }};\n/* End PBXBuildFile section */",
    )
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {name}; "
        f"sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */",
    )
    # Group children: insert before the closing paren of that group's list.
    # Match the group *definition*, not the reference to it inside the root
    # group's own children — that reference comes first in the file and would
    # land the new file in whichever group happens to be defined next.
    marker = f"{group_id} /* {pathlib.Path(group_dir).name} */ = {{"
    start = text.index(marker)
    children = text.index("children = (", start)
    close = text.index("\t\t\t);", children)
    text = text[:close] + f"\t\t\t\t{file_id} /* {name} */,\n" + text[close:]

    text = text.replace(
        "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
        "/* End PBXSourcesBuildPhase section */",
        f"\t\t\t\t{build_id} /* {name} in Sources */,\n"
        "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
        "/* End PBXSourcesBuildPhase section */",
    )

    PBXPROJ.write_text(text)
    print(f"added {relative}  (file {file_id}, build {build_id})")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for argument in sys.argv[1:]:
        add(argument)
