#!/usr/bin/env python3
"""Check that every component an object declares exists in its scene.

GMDObjects.gd lists, per object id, the components the converter may fill
("components": [...]) and the scene it instantiates ("scene": ...). The
converter writes data under a component's node name, and TriggerInteractable
then calls get_node(name).use_data(...). A name with no node in the scene
fails at import time ("Node not found" / "use_data on null instance") and the
object is left without that component.

Exits 1 and lists each mismatch; exits 0 when every declared component has a
node in its scene.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OBJECTS = os.path.join(ROOT, "src", "static", "GMDObjects.gd")


def const_strings(src: str) -> dict:
    return dict(re.findall(r'^const (\w+)\s*(?::=|:\s*\w+\s*=|=)\s*"([^"]*)"', src, re.M))


def entries(src: str):
    """Yield (id, body) for every `<id>: { ... }` entry, matching braces and skipping strings."""
    for match in re.finditer(r"(?m)^\s*(\d+):\s*\{", src):
        depth, i, in_str = 0, match.end() - 1, False
        start = match.end()
        while i < len(src):
            ch = src[i]
            if in_str:
                if ch == "\\":
                    i += 1
                elif ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    yield match.group(1), src[start:i]
                    break
            i += 1


def scene_path(body: str, consts: dict):
    m = re.search(r'"scene":\s*(?:(\w+)\s*\+\s*)?"([^"]+)"', body)
    if not m:
        return None
    prefix = consts.get(m.group(1), "") if m.group(1) else ""
    return os.path.join(ROOT, prefix + m.group(2))


def check(objects_path: str = OBJECTS) -> list:
    src = open(objects_path, encoding="utf-8").read()
    consts = const_strings(src)
    problems = []
    for gd_id, body in entries(src):
        comp = re.search(r'"components":\s*\[([^\]]*)\]', body)
        if not comp:
            continue
        declared = re.findall(r'"(\w+)"', comp.group(1))
        scene = scene_path(body, consts)
        if not scene or not os.path.isfile(scene):
            problems.append("%s: scene not found (%s)" % (gd_id, scene))
            continue
        nodes = set(re.findall(r'\[node name="([^"]+)"', open(scene, encoding="utf-8").read()))
        for name in declared:
            if name not in nodes:
                problems.append("%s %s: component %s has no node in %s"
                                % (gd_id, os.path.relpath(scene, ROOT), name, os.path.basename(scene)))
    return problems


if __name__ == "__main__":
    found = check()
    for line in found:
        print(line)
    print("checked; %d problem(s)" % len(found))
    sys.exit(1 if found else 0)
