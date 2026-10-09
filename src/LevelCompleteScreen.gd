class_name LevelCompleteScreen
extends CanvasLayer

## Geometry Dash's end screen (EndLevelLayer): shown once the End trigger's
## shake finishes, with the attempt count and Replay / Menu actions. Replay
## and Menu reuse the pause menu's restart and leave paths.

const TITLE_FONT: FontFile = preload("res://assets/fonts/Pusab.otf")
const TITLE_SIZE: int = 96
const BODY_SIZE: int = 48
const BUTTON_SIZE: int = 44
const PANEL_SIZE: Vector2 = Vector2(900.0, 560.0)

var _panel: PanelContainer
var _tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 110
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = PANEL_SIZE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.36, 0.2, 0.08, 0.95)
	style.border_color = Color(0.2, 0.1, 0.03, 1.0)
	style.set_border_width_all(10)
	style.set_corner_radius_all(32)
	_panel.add_theme_stylebox_override(&"panel", style)
	center.add_child(_panel)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override(&"separation", 36)
	_panel.add_child(column)
	column.add_child(_make_label("LEVEL COMPLETE!", TITLE_SIZE, Color(1.0, 0.85, 0.2)))
	column.add_child(_make_label("Attempts: %d" % LevelManager.attempt, BODY_SIZE, Color.WHITE))

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override(&"separation", 60)
	column.add_child(buttons)
	var replay: Button = _make_button("Replay")
	replay.pressed.connect(_on_replay_pressed)
	buttons.add_child(replay)
	var menu: Button = _make_button("Menu")
	menu.pressed.connect(_on_menu_pressed)
	buttons.add_child(menu)

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_panel.pivot_offset = PANEL_SIZE / 2.0
	_panel.scale = Vector2(0.1, 0.1)
	_tween = create_tween().set_ignore_time_scale(true)
	_tween.tween_property(_panel, ^"scale", Vector2.ONE, 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	replay.grab_focus.call_deferred()


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override(&"font", TITLE_FONT)
	label.add_theme_font_size_override(&"font_size", size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	label.add_theme_constant_override(&"outline_size", size / 4)
	return label


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(260.0, 100.0)
	button.add_theme_font_override(&"font", TITLE_FONT)
	button.add_theme_font_size_override(&"font_size", BUTTON_SIZE)
	return button


func _on_replay_pressed() -> void:
	queue_free()
	LevelManager.game_scene.pause_menu._on_restart_pressed()


func _on_menu_pressed() -> void:
	queue_free()
	LevelManager.game_scene.pause_menu._on_leave_pressed()
