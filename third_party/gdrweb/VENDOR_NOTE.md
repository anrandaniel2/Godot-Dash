# Vendored GDRweb reference

This directory contains an unmodified snapshot of [GDRweb](https://github.com/iliasHDZ/GDRweb)
(MIT license, Copyright (c) 2021 IliasHDZ) — a TypeScript Geometry Dash level
player whose colour, copy-channel and trigger-track semantics are ported into
this project's GDScript converter and native engine.

It is kept in-tree as the authoritative reference for Geometry Dash's colour
rules so future parsing gaps can be diffed against a known-good implementation
instead of being rediscovered one key at a time. Nothing here is compiled or
shipped; the game's own implementations live in:

- `src/static/GMDConverter.gd` — kS38 channel table import (copies keep their
  link metadata instead of being flattened to literal colours).
- `src/resources/ColorChannelData.gd` — per-channel copy link, copy HSV and
  copy-opacity fields (GDRweb's `CopyColor`).
- `src/ColorChannelWatcher.gd` — live copy resolution with a cycle budget
  (GDRweb's `CopyColor.evaluate` iteration guard) and dependency fan-out.
- `native/src/gdash_native.cpp` — trigger-side copy links (key 50) and the
  legacy colour-trigger default channels (GDRweb's `COLOR_TRIGGER_IDS`).

Snapshot taken 2026-09-13 from the repository's default branch.
