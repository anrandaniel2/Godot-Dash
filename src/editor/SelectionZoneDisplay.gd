class_name SelectionZoneDisplay
extends Node2D

var zone: Rect2


func _draw() -> void:
	var zone_color := Config.selection_zone_color
	var zone_fill: Color = zone_color
	zone_fill.a = Config.selection_zone_fill_alpha
	draw_rect(zone, zone_fill, true, -1.0)
	draw_rect(zone, zone_color, false, 2.0)


func _on_edit_handler_selection_zone_changed(new_zone: Rect2) -> void:
	zone = new_zone
	if not zone.size.is_finite() or zone.size == Vector2.ZERO:
		hide()
	else:
		show()
		queue_redraw()
