class_name DeathFreezeMarker
extends Control

## Debug overlay for the frozen death state: a red cross and label drawn on a
## top CanvasLayer at the cube's screen position, so it can be seen even when
## the cube itself is not. Removes itself once the game is unpaused again.

var marker_position: Vector2 = Vector2.ZERO
var label_text: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	queue_redraw()


func _process(_delta: float) -> void:
	if not get_tree().paused:
		get_parent().queue_free()


func _draw() -> void:
	var red := Color.RED
	draw_arc(marker_position, 28.0, 0.0, TAU, 48, red, 4.0)
	draw_line(marker_position - Vector2(44.0, 0.0), marker_position + Vector2(44.0, 0.0), red, 3.0)
	draw_line(marker_position - Vector2(0.0, 44.0), marker_position + Vector2(0.0, 44.0), red, 3.0)
	draw_string(ThemeDB.fallback_font, marker_position + Vector2(36.0, -36.0), label_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 24, red)
