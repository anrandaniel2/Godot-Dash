@icon("res://addons/at-icons/node2d/area.svg")
class_name HitboxDisplay
extends Node2D

@export var hitbox: CollisionShape2D
@export var color_config_key: String
@export var fill_alpha_config_key: String


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var color: Color = Config.get(color_config_key)
	var fill_color = color
	fill_color.a = Config.get(fill_alpha_config_key)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE / global_scale)
	match hitbox.shape:
		var rectangle when hitbox.shape is RectangleShape2D:
			var size: Vector2 = rectangle.size * global_scale
			draw_rect(Rect2(-size / 2, size), color, false, 4.0)
			draw_rect(Rect2(-size / 2, size), fill_color)
		var line when hitbox.shape is SegmentShape2D:
			draw_line(line.a, line.b, color, 4.0)
