# Godot Dash — Agent Briefing Pack

A structured, verified briefing on the Godot Dash codebase for agent-mode work. Written from
the repository snapshot at commit `14288b1` (2026-10-03); every number, path and constant in
these files was read out of that checkout.

## The files

| File | Contents |
| --- | --- |
| [`00-ARENA-PASTE-PROMPT.md`](00-ARENA-PASTE-PROMPT.md) | **The prompt to paste into arena.ai.** Self-contained; points the agent at the rest of the pack. |
| [`01-repo-and-constraints.md`](01-repo-and-constraints.md) | Repo identity, scale, toolchain, build/export commands, hard rules, sandbox limits. |
| [`02-runtime-architecture.md`](02-runtime-architecture.md) | Boot, autoloads, config, scene flow, level lifecycle, streaming, batching, culling, audio/assets. |
| [`03-gameplay-and-physics.md`](03-gameplay-and-physics.md) | Physics layers, player contract, gamemodes, interactables/components/triggers, colour channels, replays, practice. |
| [`04-editor.md`](04-editor.md) | Editor autoload, scene tree, selection/transform, palette, inspector/property system, level operations, render modes. |
| [`05-gd-pipeline-and-tools.md`](05-gd-pipeline-and-tools.md) | `.gmd` import/export, level strings, object tables, atlas + scene generation pipeline, hitbox specs, unification plan. |
| [`06-native-extension.md`](06-native-extension.md) | GDExtension classes, bound methods, native/GDScript contract, build, tests, CI. |
| [`07-platforms-web-android.md`](07-platforms-web-android.md) | WebGPU web export, CORS relay, Android Gradle export, desktop packaging, CI workflows. |
| [`08-formats-and-schemas.md`](08-formats-and-schemas.md) | Every on-disk format and data shape: level dict, `.gmd` keys, `.gdr`, `.meta`, config, input actions. |
| [`09-conventions-invariants-verification.md`](09-conventions-invariants-verification.md) | Style rules, ~30 invariants/landmines, the verification playbook with exact CI gates. |
| [`10-task-playbooks-and-reference.md`](10-task-playbooks-and-reference.md) | Change recipes, glossary, cheat-sheet numbers, key-file index, open items. |
| [`11-accuracy-parity-campaign.md`](11-accuracy-parity-campaign.md) | **The current mission**, start here for correctness work: parser/trigger/camera parity, the OuterSpace acceptance level, decompiled-GD citations, native-vs-component paths, colour and camera failure maps. |

The root-level [`GODOT_DASH_MASTER_PROMPT.md`](../../GODOT_DASH_MASTER_PROMPT.md) is the same
material as one long single-file briefing; this folder is the expanded, per-subsystem version.

## How to use it with an agent

1. Attach/point the agent at the repository.
2. Paste the contents of `00-ARENA-PASTE-PROMPT.md` as the first message.
3. The agent will read the specific pack file for the subsystem it is about to change, then
   work. Ask it to cite the files it read.

## Verifying claims in this pack

Every claim here is checkable from the checkout:

- constants: `grep -rn "NAME" src/ native/`
- numbers/lists: the file named in the text
- CI behaviour: `.github/workflows/main.yml`, `.github/workflows/web.yml`
- design rationale: `GD_UNIFICATION_PLAN.md`

If a claim in this pack disagrees with the checkout, **the checkout wins** — fix the pack.
