extends Node

signal menu_loop_changed(menu_loop: String)

enum WindowMode {
	WINDOWED,
	FULLSCREEN,
	EXCLUSIVE_FULLSCREEN,
}

enum TextureFilteringMode {
	NEAREST_NEIGHBOR,
	LINEAR,
	LINEAR_WITH_MIPMAPS,
}

enum TouchScreenMode {
	FOLLOW_DEVICE,
	FORCE_ENABLED,
	FORCE_DISABLED,
}

enum ParticleVisibility {
	PLAYER = 1 << 0,
	ORB = 1 << 1,
	PAD = 1 << 2,
	PORTAL = 1 << 3,
	SPEED_PORTAL = 1 << 4,
	MAX = (1 << 5) - 1,
}

enum ParticlePreprocessing {
	ORB = 1 << 0,
	PAD = 1 << 1,
	PORTAL = 1 << 2,
	SPEED_PORTAL = 1 << 3,
	MAX = (1 << 4) - 1,
}

# Graphics
@export_group("Graphics")

@export_subgroup("Framerate")
@export_range(0, 60, 1, "or_greater") var max_fps: int = 60
@export var vsync: int

@export_subgroup("Window")
@export var window_mode: WindowMode = WindowMode.FULLSCREEN
@export var render_scale: float = 1.0

@export_subgroup("Post-processing")
@export var anti_aliasing: Viewport.MSAA = Viewport.MSAA.MSAA_4X
@export var texture_filtering: TextureFilteringMode = TextureFilteringMode.LINEAR_WITH_MIPMAPS
@export var bloom: bool = true
@export var menu_blur: bool = true
@export var blur_strength: float = 3
@export var ui_color: Color = Color("#808080")
@export var transition_duration: float = 0.5

# Performance
@export_group("Performance")
@export var enable_title_screen_icons: bool = true
@export var ldm: bool = false

## Hide level objects far outside the camera while playing (see
## FrustumCuller). Cheap to leave on; turn it off only to rule it out when
## debugging a level.
@export var culling_enabled: bool = true
## How far beyond the screen edges, in cells, objects stay visible. A speed
## change or camera trigger can move the view a long way in one frame, and the
## buffer keeps objects on screen from popping in late. Half a screen is 7-8
## cells; the default is deliberately generous.
@export_range(4, 200, 1, "suffix:cells") var culling_buffer_cells: int = 40

@export_subgroup("Geometry Dash import")
## Draw decoration objects from the bundled Geometry Dash atlases when importing
## a `.gmd`. Turning this off restores a gameplay-only import, which loads
## faster and produces far smaller levels.
@export var import_gd_decorations: bool = true
## Use Geometry Dash's own artwork for gameplay objects that have it, instead of
## Godot Dash's original textures. Only the texture changes - collision,
## components and editor behaviour are untouched.
@export var use_gd_artwork: bool = true

@export_subgroup("Particles")
@export var show_particles_in_editor: bool = true
@export var particles_visibility: int = ParticleVisibility.MAX
@export var preprocess_particles_in_editor: bool = true
@export var particles_preprocessing: int = ParticlePreprocessing.MAX

# Gameplay
@export_group("Gameplay")
@export var show_percentage: bool = true
@export var click_on_steps: bool = true

# Practice
@export_subgroup("Practice")
@export var automatic_checkpoints: bool = true
@export var automatic_checkpoint_distance: float = 10.0

# Audio
@export_group("Audio")

@export_subgroup("Volume")
@export_range(0, 100, 5) var master_audio_level: int = 100
@export_range(0, 100, 5) var music_audio_level: int = 100
@export_range(0, 100, 5) var game_sfx_audio_level: int = 100
@export_range(0, 100, 5) var in_level_sfx_audio_level: int = 100
@export var mute_game_on_unfocus: bool = true

@export_subgroup("Music")
@export_global_file(
	"*.mp3",
	"*.ogg",
	"*.wav",
)
var menu_loop: String:
	set(value):
		menu_loop = value
		menu_loop_changed.emit(value)

# Keybinds
@export_group("Keybinds")
@export_storage var input_map: Dictionary[StringName, Array] = { } # Dictionary[StringName, Array[InputEvent]]

# Editor
@export_group("Editor")
@export var hide_grid_on_playtest: bool = true
@export var editor_trail: bool = true
@export var autosave_delay: float = 2.0
@export var username: String = "Player"
@export var default_render_mode: RenderMode.Mode = RenderMode.Mode.RENDERED_MODE
@export_range(0, 1, .05) var hidden_layers_alpha := 0.1
@export var selection_zone_color := Color.GREEN
@export_range(0, 1, .05) var selection_zone_fill_alpha := 0.2
@export var trigger_hitbox_color := Color.CYAN
@export_range(0, 1, .05) var trigger_hitbox_fill_alpha := 0.2
@export var has_seen_navigation_help: bool = false

# Debug
@export_group("Debug")
@export var draw_debug_overlays: bool
@export var touch_screen_mode: TouchScreenMode = TouchScreenMode.FOLLOW_DEVICE
@export_storage var is_touch_screen: bool = false

# Easter Eggs
@export_group("Easter Eggs")
@export var enable_easter_eggs: bool

# Internet
@export_group("Internet")
@export var check_for_updates: bool = true
@export var discord_rich_presence: bool = true

# Icons
@export_group("Icon")
@export var primary_color: Color = Color(0.5, 0, 1, 1)
@export var secondary_color: Color = Color(0, 1, 1, 1)
@export var glow_color: Color = Color(0, 1, 0.5, 1)
@export var outline_color: Color = Color(0.16, 0.03, 0.2, 1)
@export var icon_paths: Dictionary[PreviewIcon.Icon, String] = {
	PreviewIcon.Icon.CUBE: "res://assets/textures/player/cube/Cube1.svg",
	PreviewIcon.Icon.SHIP: "res://assets/textures/player/ship/Ship1.svg",
	PreviewIcon.Icon.JETPACK: "res://assets/textures/player/jetpack/Jetpack1.svg",
	PreviewIcon.Icon.UFO: "res://assets/textures/player/ufo/Ufo1.svg",
	PreviewIcon.Icon.BALL: "res://assets/textures/player/ball/Ball1.svg",
	PreviewIcon.Icon.WAVE: "res://assets/textures/player/wave/Wave1.svg",
	PreviewIcon.Icon.ROBOT: "res://assets/textures/player/robot/Robot1",
	PreviewIcon.Icon.SPIDER: "res://assets/textures/player/spider/Spider1",
	PreviewIcon.Icon.SWING: "res://assets/textures/player/swing/Swing1",
	PreviewIcon.Icon.TRAIL: "res://assets/textures/player/trail/Trail1.png",
	PreviewIcon.Icon.DEATH_EFFECT: "res://assets/textures/player/death_effect/DeathEffect1",
}
@export var icon_hue_shift_speed: float = 0

# Replays
@export_group("Replay")

var saved_window_size: Vector2
var config_file: ConfigFile = ConfigFile.new()


func _init():
	config_file.load("user://config.cfg")

	# Graphics
	max_fps = config_file.get_value("Graphics", "max_fps", max_fps)
	vsync = config_file.get_value("Graphics", "vsync", vsync)
	window_mode = config_file.get_value("Graphics", "window_mode", window_mode)
	render_scale = config_file.get_value("Graphics", "render_scale", render_scale)
	anti_aliasing = config_file.get_value("Graphics", "anti_aliasing", anti_aliasing)
	texture_filtering = config_file.get_value("Graphics", "texture_filtering", texture_filtering)
	bloom = config_file.get_value("Graphics", "bloom", bloom)
	menu_blur = config_file.get_value("Graphics", "menu_blur", menu_blur)
	blur_strength = config_file.get_value("Graphics", "blur_strength", blur_strength)
	ui_color = config_file.get_value("Graphics", "ui_color", ui_color)
	transition_duration = config_file.get_value("Graphics", "transition_duration", transition_duration)

	# Performance
	enable_title_screen_icons = config_file.get_value("Performance", "enable_title_screen_icons", enable_title_screen_icons)
	ldm = config_file.get_value("Performance", "ldm", ldm)
	culling_enabled = config_file.get_value("Performance", "culling_enabled", culling_enabled)
	culling_buffer_cells = config_file.get_value("Performance", "culling_buffer_cells", culling_buffer_cells)
	show_particles_in_editor = config_file.get_value("Performance", "show_particles_in_editor", show_particles_in_editor)
	particles_visibility = config_file.get_value("Performance", "particles_visibility", particles_visibility)
	preprocess_particles_in_editor = config_file.get_value("Performance", "preprocess_particles_in_editor", preprocess_particles_in_editor)
	particles_preprocessing = config_file.get_value("Performance", "particles_preprocessing", particles_preprocessing)

	# Gameplay
	click_on_steps = config_file.get_value("Gameplay", "click_on_steps", click_on_steps)

	# Practice
	automatic_checkpoints = config_file.get_value("Practice", "automatic_checkpoints", automatic_checkpoints)
	automatic_checkpoint_distance = config_file.get_value("Practice", "automatic_checkpoint_distance", automatic_checkpoint_distance)

	# Audio
	master_audio_level = config_file.get_value("Audio", "master_audio_level", master_audio_level)
	music_audio_level = config_file.get_value("Audio", "music_audio_level", music_audio_level)
	game_sfx_audio_level = config_file.get_value("Audio", "game_sfx_audio_level", game_sfx_audio_level)
	in_level_sfx_audio_level = config_file.get_value("Audio", "in_level_sfx_audio_level", in_level_sfx_audio_level)
	mute_game_on_unfocus = config_file.get_value("Audio", "mute_game_on_unfocus", mute_game_on_unfocus)
	menu_loop = config_file.get_value("Audio", "menu_loop", menu_loop)

	# Keybinds
	input_map = config_file.get_value("Keybinds", "input_map", input_map)

	# Editor
	hide_grid_on_playtest = config_file.get_value("Editor", "hide_grid_on_playtest", hide_grid_on_playtest)
	editor_trail = config_file.get_value("Editor", "editor_trail", editor_trail)
	autosave_delay = config_file.get_value("Editor", "autosave_delay", autosave_delay)
	username = config_file.get_value("Editor", "username", username)
	default_render_mode = config_file.get_value("Editor", "default_render_mode", default_render_mode)
	hidden_layers_alpha = config_file.get_value("Editor", "hidden_layers_alpha", hidden_layers_alpha)
	selection_zone_color = config_file.get_value("Editor", "selection_zone_color", selection_zone_color)
	selection_zone_fill_alpha = config_file.get_value("Editor", "selection_zone_fill_alpha", selection_zone_fill_alpha)
	trigger_hitbox_color = config_file.get_value("Editor", "trigger_hitbox_color", trigger_hitbox_color)
	trigger_hitbox_fill_alpha = config_file.get_value("Editor", "trigger_hitbox_fill_alpha", trigger_hitbox_fill_alpha)
	has_seen_navigation_help = config_file.get_value("Editor", "has_seen_navigation_help", has_seen_navigation_help)

	# Debug
	draw_debug_overlays = config_file.get_value("Debug", "draw_debug_overlays", draw_debug_overlays)
	touch_screen_mode = config_file.get_value("Debug", "touch_screen_mode", touch_screen_mode)
	is_touch_screen = config_file.get_value("Debug", "is_touch_screen", is_touch_screen)

	# Easter Eggs
	enable_easter_eggs = config_file.get_value("Easter Eggs", "enable_easter_eggs", enable_easter_eggs)

	# Internet
	check_for_updates = config_file.get_value("Internet", "check_for_updates", check_for_updates)
	discord_rich_presence = config_file.get_value("Internet", "discord_rich_presence", discord_rich_presence)

	saved_window_size = config_file.get_value("Misc", "saved_window_size", saved_window_size)

	# Icons
	primary_color = config_file.get_value("Icons", "primary_color", primary_color)
	secondary_color = config_file.get_value("Icons", "secondary_color", secondary_color)
	glow_color = config_file.get_value("Icons", "glow_color", glow_color)
	outline_color = config_file.get_value("Icons", "outline_color", outline_color)
	icon_paths = config_file.get_value("Icons", "icon_paths", icon_paths)
	icon_hue_shift_speed = config_file.get_value("Icons", "icon_hue_shift_speed", icon_hue_shift_speed)


func _ready() -> void:
	if window_mode == WindowMode.WINDOWED:
		get_tree().root.set_size(saved_window_size)


func _notification(what):
	if mute_game_on_unfocus:
		if what == NOTIFICATION_APPLICATION_FOCUS_IN:
			AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), false)
		elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
			AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), true)


func is_click_on_steps_enabled() -> bool:
	return click_on_steps if not LevelManager.player else click_on_steps and not LevelManager.player.in_replay


func save() -> void:
	# Graphics
	config_file.set_value("Graphics", "max_fps", max_fps)
	config_file.set_value("Graphics", "vsync", vsync)
	config_file.set_value("Graphics", "window_mode", window_mode)
	config_file.set_value("Graphics", "render_scale", render_scale)
	config_file.set_value("Graphics", "anti_aliasing", anti_aliasing)
	config_file.set_value("Graphics", "texture_filtering", texture_filtering)
	config_file.set_value("Graphics", "bloom", bloom)
	config_file.set_value("Graphics", "menu_blur", menu_blur)
	config_file.set_value("Graphics", "blur_strength", blur_strength)
	config_file.set_value("Graphics", "ui_color", ui_color)
	config_file.set_value("Graphics", "transition_duration", transition_duration)

	# Performance
	config_file.set_value("Performance", "enable_title_screen_icons", enable_title_screen_icons)
	config_file.set_value("Performance", "ldm", ldm)
	config_file.set_value("Performance", "culling_enabled", culling_enabled)
	config_file.set_value("Performance", "culling_buffer_cells", culling_buffer_cells)
	config_file.set_value("Performance", "show_particles_in_editor", show_particles_in_editor)
	config_file.set_value("Performance", "particles_visibility", particles_visibility)
	config_file.set_value("Performance", "preprocess_particles_in_editor", preprocess_particles_in_editor)
	config_file.set_value("Performance", "particles_preprocessing", particles_preprocessing)

	# Gameplay
	config_file.set_value("Gameplay", "click_on_steps", click_on_steps)

	# Practice
	config_file.set_value("Practice", "automatic_checkpoints", automatic_checkpoints)
	config_file.set_value("Practice", "automatic_checkpoint_distance", automatic_checkpoint_distance)

	# Audio
	config_file.set_value("Audio", "master_audio_level", master_audio_level)
	config_file.set_value("Audio", "music_audio_level", music_audio_level)
	config_file.set_value("Audio", "game_sfx_audio_level", game_sfx_audio_level)
	config_file.set_value("Audio", "in_level_sfx_audio_level", in_level_sfx_audio_level)
	config_file.set_value("Audio", "mute_game_on_unfocus", mute_game_on_unfocus)
	config_file.set_value("Audio", "menu_loop", menu_loop)

	# Keybinds
	config_file.set_value("Keybinds", "input_map", input_map)

	# Editor
	config_file.set_value("Editor", "hide_grid_on_playtest", hide_grid_on_playtest)
	config_file.set_value("Editor", "editor_trail", editor_trail)
	config_file.set_value("Editor", "autosave_delay", autosave_delay)
	config_file.set_value("Editor", "username", username)
	config_file.set_value("Editor", "default_render_mode", default_render_mode)
	config_file.set_value("Editor", "hidden_layers_alpha", hidden_layers_alpha)
	config_file.set_value("Editor", "selection_zone_color", selection_zone_color)
	config_file.set_value("Editor", "selection_zone_fill_alpha", selection_zone_fill_alpha)
	config_file.set_value("Editor", "trigger_hitbox_color", trigger_hitbox_color)
	config_file.set_value("Editor", "trigger_hitbox_fill_alpha", trigger_hitbox_fill_alpha)
	config_file.set_value("Editor", "has_seen_navigation_help", has_seen_navigation_help)

	# Debug
	config_file.set_value("Debug", "draw_debug_overlays", draw_debug_overlays)
	config_file.set_value("Debug", "touch_screen_mode", touch_screen_mode)
	config_file.set_value("Debug", "is_touch_screen", is_touch_screen)

	# Easter Eggs
	config_file.set_value("Easter Eggs", "enable_easter_eggs", enable_easter_eggs)

	# Internet
	config_file.set_value("Internet", "check_for_updates", check_for_updates)
	config_file.set_value("Internet", "discord_rich_presence", discord_rich_presence)

	# Icons
	config_file.set_value("Icons", "primary_color", primary_color)
	config_file.set_value("Icons", "secondary_color", secondary_color)
	config_file.set_value("Icons", "glow_color", glow_color)
	config_file.set_value("Icons", "outline_color", outline_color)
	config_file.set_value("Icons", "icon_paths", icon_paths)
	config_file.set_value("Icons", "icon_hue_shift_speed", icon_hue_shift_speed)

	config_file.set_value("Misc", "saved_window_size", saved_window_size)

	config_file.save("user://config.cfg")


func _exit_tree() -> void:
	saved_window_size = get_tree().root.size
	save()
