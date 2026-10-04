# 04 — In-game editor

The editor is a first-class part of the game (no external tooling): `scenes/EditorScene.tscn`
(7,598 lines) + `src/EditorScene.gd` + the `Editor` autoload, with systems under
`src/editor/**`, widgets under `src/gui/**`, and `src/editor/LevelOperationsHandler.gd` in the
scene for level file I/O.

## 1. Editor autoload — `src/autoloads/Editor.gd`

```gdscript
enum EditorMode { PLACE, EDIT, SELECTION_FILTERS }

var root: EditorScene
var in_editor: bool          # getter: root != null
var clipboard: Selection
var snapshot := PackedScene.new()
var level_data_snapshot: Dictionary
var level_history_version: int = 1
var shortcut_blocker: Node
var viewport: EditorViewport
var version_history: UndoRedo
var render_mode_manager: RenderMode
var is_picking_node: bool

# MOBILE CONTROLS
var swipe: bool
var delete: bool

func is_text_input_focused() -> bool
func clear_data() -> void
```

`Editor.in_editor` is read all over the game (LDM off, decoration keeps nodes, culling off,
`Editor.render_mode_manager` colour early-outs, `HiddenOutsideEditorAttribute`, etc.).

## 2. Editor scene structure (`scenes/EditorScene.tscn`)

- Root: `Control` named **`LevelEditor`**, script `src/EditorScene.gd`, wired to
  `edit_handler`, `level_operations_handler`, `editor_camera` (`MapCamera2D`),
  `view_menu`, `inspector_tree`, `inspector_manager`.
- `TriggerGroupBoundingBox` (Node2D) — group bounding-box overlay.
- `EditorUI` (`CanvasLayer`) → `Editor` (`HSplitContainer`) → `VBoxContainer` with:
  - `MenuBarContainer` → `MenuBar` with `Level`, `Edit`, `View`, `Actions`, `Help` popups
    (scripts in `src/editor/menu_bar/`), `KeychordDisplay`, and a `CenterContainer` holding the
    `TransformPivot` option button.
  - `VSplitContainer` → `Viewport` (`Control` with `Playtest` button and `RenderModes`) and
    `Modes` (`TabContainer` of `Place` / `Edit` / selection-filters tabs).
  - `Place` tab → `Blocks` (`Control`) → `SmoothScrollContainer` → `ButtonContainer`
    (`HFlowContainer`) holding the palette buttons (`RegularBlock01`, `OutlineBlock01`,
    `FillBlock02`, … each with a `BlockPaletteRef` and `GenerateBlockPaletteVariants`).
- Editor camera is `MapCamera2D` (`src/MapCamera2D.gd`): mouse/keyboard/gesture pan-zoom-drag,
  `zoom_factor 1.25`, `zoom_relative`, edge panning (`pan_speed 250`, `pan_margin 25`),
  middle-drag, mouse wrap like the Godot editor.

`EditorScene.gd` responsibilities: `_enter_tree`/`_ready` wiring, `_physics_process`,
`_unhandled_input` (editor actions), `reset()`, `start_playtest()` / `stop_playtest()`,
`_fade_enter()`, `level_was_modified()`, `any_dialog_is_open()`,
`texture_variation_overlapping(type,id)` (palette variant selection), and
`_load_default_player_data_component(component)`.

## 3. Placement — `src/editor/PlaceHandler.gd`, `BlockPaletteRef.gd`, `EditorGrid.gd`

- `PlaceHandler` instantiates the palette's selected object at the cursor, snapped to the editor
  grid cell (`editor_grid.cell_size`, offset back from the grid's origin), assigns it to the
  active `Layer`, and records history.
- `BlockPaletteRef` marks a palette button as referring to a block type + variant id;
  `GenerateBlockPaletteVariants` expands variations; `EditorScene.texture_variation_overlapping`
  decides which variant to place (e.g. blocks lining up with neighbours).
- `EditorGrid` draws the grid (hidden during playtest when `Config.hide_grid_on_playtest`).
- Selection colliders (`EditorSelectionCollider`, layer 9) are what the mouse actually picks;
  every placeable scene carries one with `type` (`BLOCK, SPIKE, SPIKE_FLAT, SPIKE_MEDIUM,
  SPIKE_SMALL, GROUND_SPIKE, SLOPE, SLOPE_LARGE, INTERACTABLE, DECORATION`) and `id`.

## 4. Selection and transforms — `src/editor/EditHandler.gd` (856 lines)

- Selection model: `Selection` (`src/refcounted/Selection.gd`) — an ordered set with set
  algebra (`union`, `intersection`, `difference`), predicates (`all/any/filter`), and
  `map`/`flat_map`/`fold_generic` helpers; `Selection.EMPTY()`.
- Input: `_handle_input`, `_update_selection`, `_swipe_selection_zone` (mobile drag-select),
  `_reset_selection_zone`, `_update_interactive_picking`.
- Transforms: `move_selection(distance_cells)`, `rotate_selection(angle)` (90°/45°/free via
  gizmos), `scale_selection(...)`, `scale_transform`/`scale_transform_local`, `_flip_selection(axis)`.
- Pivot: `EditHandler.TransformPivot { MEDIAN_POINT, INDIVIDUAL_ORIGINS }` selected by the
  `transform_pivot_button` option button, with `selection_pivot` / `selection_pivot_with_player`
  cached per selection and rotated with it (`_update_pivot`).
- Clipboard/history: `copy_selection`, `paste_selection`, `duplicate_selection` (supports
  "duplicate paste" flows), `delete_selection`, `clear_selection`, `select_all`, all routed
  through `Editor.version_history` (`UndoRedo`) with signal feedback
  (`selection_changed`, `moved_selection_cells`, `rotated_selection_degrees`,
  `resized_selection`, `deleted_selection`).
- Throttling: `THROTTLE_MOVE_COOLDOWN` / `THROTTLE_ROTATE_COOLDOWN` = 0.2 s for held keys.
- Gizmos (`src/editor/gizmos/`): `Gizmo` base + `MoveGizmo`, `RotateGizmo`, `ScaleGizmo`,
  `QuickGizmoValueInput` (type an exact value), driven from `EditorMoveControls`
  (`src/editor/EditorMoveControls.gd`, mobile-friendly arrow pad).
- `SelectionZoneDisplay` draws the marquee; `TriggerGroupBoundingBox` outlines a group's extent.

## 5. Inspector — `src/editor/InspectorTree.gd`, `InspectorManager.gd`, `src/gui/properties/**`

- `InspectorTree` (`src/editor/InspectorTree.gd`, 501 lines) is a `Tree` of layers and objects:
  lock/visibility buttons (icons from `addons/at-icons`), drag-and-drop reparenting between
  layers (`_get_drag_data`, `_can_drop_data`, `_drop_data`), rename handling,
  `MAX_ITEMS_PER_LAYER = 1000` (performance guard), filtering (`filter_items`), and item
  selection syncing with `EditHandler` (`signal selection_changed`).
- `InspectorManager` shows the property panels for the selection; the panels live in
  `src/editor/editor_panels/`: `TransformEditor`, `PhysicsEditor`, `AttributeEditor`,
  `GroupEditor`, `InteractableEditor` (+ `color_channel/ColorChannelEditor` and
  `ColorChannelItem`).
- The generic property system:
  - `src/static/PropertyGenerator.gd` turns a script's `get_property_list()` fields into
    `Property` widgets, honouring `PROPERTY_HINT_RANGE`, tool buttons, and defaults.
  - `src/gui/properties/Property.gd` + `types/*`: `ArrayProperty`, `ArrayPropertyItem`,
    `BoolProperty`, `ColorProperty`, `EnumProperty`, `FileProperty`, `FlagsProperty`,
    `FloatProperty`, `MultilineStringProperty`, `NodeProperty`, `OneLineEnumProperty`,
    `ResourceProperty`, `SearchableStringProperty`, `StringProperty`, `Vector2Property`.
  - Components (`components/`): `PropertyReset` (uses `get_property_default_value`),
    `PropertySaveLoad` (per-property preset save/load), `PropertyWatcher` (live refresh),
    `PropertyValueThemeDefaultFont`.
  - Reusable inputs: `DragBox`, `Vector2DragBox`, `EnumButton`, `EnumButtonTabContainer`,
    `IDOptionButton`, `ViewportSizeValue`, `NoFocusTabContainer`.
- `InteractableEditor` is the object-specific panel: it lists the interactable's components
  (`Interactable.components`), excludes `COMPONENT_BLACKLIST`/`MARKER_COMPONENTS`, and manages
  markers ("flags" such as trigger behaviours). `TriggerPropertyInternalName`
  (`src/editor/TriggerPropertyInternalName.gd`) maps display names to internal property names.
- `AttributeEditor` exposes the node-attribute flags: `BOOL_ATTRIBUTES` (`NoTouchAttribute`,
  `DisabledInLowDetailModeAttribute`) rendered as `BoolProperty`, and `FLAG_ATTRIBUTES` groups
  ("Hide" → sprite/base/detail/particles, "Music Scale" → sprite/base/detail/particles/hitbox)
  rendered as `FlagsProperty`.
- `BaseDetailHandler` edits an object's `base`/`detail` colour channels through
  `SearchableStringProperty` inputs and keeps the channel groups in sync
  (`clear_color_channels`, `_load_base`, `_load_detail`) — it is also what makes playtest-time
  object edits work.

## 6. Level operations — `src/editor/LevelOperationsHandler.gd` (522 lines)

- `signal level_loaded(level: Level)`, `signal level_saved`.
- New/open/import/save/save-as/export via `Files` dialogs; `_open_level`, `_load_level` (builds
  through the same `LevelBuildJob`), `save_level()`, `_on_save_level_as_dialog_file_selected`,
  `_on_export_level_dialog_file_selected` (writes `.gmd` via `GMDConverter`).
- Autosave: `autosave_toast`, `_process` timer using `Config.autosave_delay`, with
  `pause_autosave()` / `unpause_autosave()` around operations that must not snapshot halfway.
- Metadata sidecars: `LEVEL_META_EXTENSION = ".meta"`, `write_level_meta` / readers used by
  `LevelPanelLoader` so the level list never decodes a level.
- Import path: `_import_and_open_level` handles `.gmd`/`.gmd2`/`.lvl`, shows
  `Files.show_corrupted_level_warning` on invalid files, and reports skipped object ids.
- `LevelSettings` (`src/editor/LevelSettings.gd`) edits level-wide fields (name, creator,
  description, song, colours, start state, platformer, transition widths…).

## 7. Editor menus and shortcuts

- `MenuBarEdit.gd`, `MenuBarView.gd`, `MenuBarHelp.gd`, `Actions.gd` (`src/editor/menu_bar/`).
  `Actions` is the central editor command table (playtest, palette actions, mobile actions).
- Input actions (from `project.godot [input]`): `editor_add`, `editor_add_swipe`,
  `editor_remove`, `editor_remove_swipe`, `editor_rotate_90`, `editor_rotate_45`,
  `editor_place_mode`, `editor_edit_mode`, `editor_selection_filters_mode`, `editor_delete`,
  `editor_select_all`, `editor_deselect`, `editor_selection_remove`, `editor_duplicate`,
  `editor_selection_area_move`, `editor_flip_h`, `editor_flip_v`, `editor_new_level`,
  `editor_save`, `editor_save_as`, `editor_open_level`, `editor_import_level`,
  `editor_export_level`, `editor_hide_panels`, `editor_rotate_free`, `editor_quick_rotate_free`,
  `editor_scale`, `editor_quick_scale`, `editor_focus_input`, `editor_move`,
  `editor_quick_move`, `editor_toggle_playtest`, `editor_move_left/right/up/down`,
  `gui_input_reset_default`, `ui_accept_keep_focus`.
- Keys are remappable: `KeybindLoader` (`src/autoloads/KeymapLoader.gd`) applies
  `Config.input_map`; `src/settings/AddKeybindButton.gd`, `RemoveKeybindButton.gd`, and
  `KeybindLoader.gd` are the UI for rebinding.

## 8. Render modes and visual aids

- `RenderModes` (`src/RenderModes.gd`, `class_name RenderMode`) with
  `Mode { OBJECT_MODE, MATERIAL_MODE, RENDERED_MODE, TEMP }`: OBJECT shows per-object colours
  (`object_color_selector`), MATERIAL shows channel colours, RENDERED is the game look; colour
  setters in `Level` early-out in `OBJECT_MODE`.
- `HSVHandler` (`src/editor/HSVHandler.gd`) edits an object's HSV shift.
- `GroupDisplay`, `ColorChannelDisplay`, `HitboxDisplay` (private components) are editor
  overlays driven by `Config.trigger_hitbox_color`/`trigger_hitbox_fill_alpha`,
  `Config.selection_zone_color`/`_fill_alpha`, `Config.hidden_layers_alpha`.
- `EditorViewport` (`src/editor/EditorViewport.gd`) is the camera host and picking surface.
- Playtest: `start_playtest()` snapshots the level (`Editor.level_data_snapshot`), swaps in
  `GameScene`, and `stop_playtest()` restores — `EditorScene.just_stopped_playtest` and
  `Editor.clear_data()` manage state; `BaseDetailHandler` supports playtest-time edits.

## 9. Adding to the editor

| Task | Where |
| --- | --- |
| New palette object | Add the scene under `scenes/components/level_components/**` with an `EditorSelectionCollider`, then add a palette button (`BlockPaletteRef` + `GenerateBlockPaletteVariants`) in the relevant `Place` tab; update `GMDObjects.MAP` if it must import from GD |
| New editor command | `src/editor/menu_bar/Actions.gd` (+ the menu that owns it), implement in `EditHandler` with `Editor.version_history` for undo, and expose it on mobile (`Editor.swipe`/`delete`, `EditorMoveControls`) |
| New object property | `@export` with the right hint on the component/script; `PropertyGenerator` renders it automatically; use `PropertyWatcher` if it can change from elsewhere |
| New object category / selection type | `EditorSelectionCollider.Type` + `GMDObjects.MAP` `type` field, and `EditorScene.texture_variation_overlapping` if variants interact |
| New settings | `Config` + `SettingsMenu` (`src/SettingsMenu.gd`, `scenes/components/game_components/SettingsMenu.tscn`), same order, save+load wired |
