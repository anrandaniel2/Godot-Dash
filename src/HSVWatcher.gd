@icon("res://addons/at-icons/node2d/swatches.svg")
class_name HSVWatcher
extends Node2D

enum SelectionHighlight {
	NONE,
	NORMAL,
	DUPLICATE,
}

@export_storage var hsv_shift: Array[float]
@export_storage var intensity: float = 1.0
@export_storage var alpha: float = 1.0
# Set by ColorChannelWatchers
@export_storage var base_intensity: float = 1.0
@export_storage var base_alpha: float = 1.0
## Whether the saturation / value entries of [member hsv_shift] multiply the
## colour instead of being added to it. Geometry Dash objects can use either;
## set per object when an imported level is built, never saved.
var saturation_multiplies: bool = false
var value_multiplies: bool = false

var selection_highlight: SelectionHighlight

@onready var parent: Node2D:
	get = _parent_getter


func _ready() -> void:
	# Avoid using the parent's modulate if the modulate is already set.
	# This happens when a scene with HSVWatchers with set up modulates is loaded.
	if not parent.has_meta(&"_has_hsvwatcher"):
		modulate = parent.modulate
	parent.set_meta(&"_has_hsvwatcher", true)
	hsv_shift.resize(3)
	LevelManager.update_hsv_watchers.connect(update_color)
	update_color()


func to_data() -> Dictionary:
	return {
		"hsv_shift": hsv_shift,
		"intensity": intensity,
		"alpha": alpha,
	}


func use_data(data: Dictionary) -> void:
	hsv_shift.assign(data.hsv_shift)
	intensity = data.intensity
	alpha = data.alpha


func update_color() -> void:
	var shifted_modulate: Color = modulate
	if saturation_multiplies:
		shifted_modulate.s *= hsv_shift[1]
	else:
		shifted_modulate.s += hsv_shift[1]
	if value_multiplies:
		shifted_modulate.v *= hsv_shift[2]
	else:
		shifted_modulate.v += hsv_shift[2]
	shifted_modulate.h += hsv_shift[0]
	match selection_highlight:
		SelectionHighlight.NONE:
			if Editor.render_mode_manager and Editor.render_mode_manager.mode == RenderMode.Mode.OBJECT_MODE:
				parent.modulate = Editor.render_mode_manager.object_modulate
			else:
				parent.modulate = shifted_modulate * intensity * base_intensity
				parent.modulate.a = modulate.a * alpha * base_alpha
		SelectionHighlight.NORMAL:
			parent.modulate = Color.GREEN
		SelectionHighlight.DUPLICATE:
			parent.modulate = Color.CYAN


func reset_color() -> void:
	hsv_shift.clear()
	hsv_shift.resize(3)
	intensity = 1.0
	alpha = 1.0
	update_color()


func _parent_getter() -> Node2D:
	return get_parent()
