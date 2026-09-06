@abstract
class_name Constants

enum Axis {
	BOTH,
	X,
	Y,
}

enum AxisBitflag {
	NONE = 0,
	X = 1 << 0,
	Y = 1 << 1,
}

enum SpecialColorChannel {
	BACKGROUND,
	GROUND,
	LINE,
	# TODO implement players colors
	P1,
	P2,
	GLOW,
}

const GROUP_PREFIX: String = "g_"
const COLOR_CHANNEL_GROUP_PREFIX := "c_"

const DEFAULT_PLAYER_POSITION: Vector2 = Vector2(640.0, 861.0)
const DEFAULT_BACKGROUND_COLOR: Color = Color("#3670ff")
const DEFAULT_GROUND_COLOR: Color = Color("#1b4bc4")
const DEFAULT_LINE_COLOR: Color = Color.WHITE

const CELL_SIZE: int = 128
const CELLS_TO_PX := Vector2(CELL_SIZE, -CELL_SIZE)

const LEVEL_DIR: String = "user://created_levels/levels/"
const SONG_DIR: String = "user://created_levels/songs/"
const FONT_DIR: String = "user://created_levels/fonts/"
const ICON_DIR: String = "res://assets/textures/player/"
const CUSTOM_ICON_DIR: String = "user://textures/player/"
const COLORED_ICON_DIR: String = "user://.cache/player/"
const REPLAYS_DIR: String = "user://replays/"

const LAYER_META: StringName = &"layer"
const TEXTURE_OVERRIDE_META: StringName = &"texture_override"
const ATTRIBUTE_META: StringName = &"attributes"
const HSV_WATCHER_META: StringName = &"hsv_watcher"
const BASE_TEXTURE_META: StringName = &"base"
const DETAIL_TEXTURE_META: StringName = &"detail"

const FREED: String = "__freed"

const DEFAULT_LEVEL_NAME: String = "New level"

const ATTRIBUTE_PATH_ROOT: String = "res://src/attributes/"

const LEVEL_COMPRESSION_MODE: FileAccess.CompressionMode = FileAccess.COMPRESSION_GZIP
const LEVEL_FILE_EXTENSION: String = "bin"

## Extension of the shareable level format, as used by the GDShare mod.
## Levels are saved locally as [constant LEVEL_FILE_EXTENSION], but importing
## and exporting both go through `.gmd`.
const GMD_FILE_EXTENSION: String = "gmd"
## GDShare's zipped variant, which can also carry the level's song.
const GMD2_FILE_EXTENSION: String = "gmd2"
const GMD_FILE_FILTER: String = "*.gmd, *.gmd2, *.lvl ; Geometry Dash level"
