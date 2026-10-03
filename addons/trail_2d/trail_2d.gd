extends Line2D

class_name Trail2D

enum Mode {
	LENGTH,
	TIME,
}

@export var mode: Mode = Mode.LENGTH
@export var length: int = 10
@export var time: float = 1.0
@export var use_physics_process: bool = false

var add_points: bool = true

@onready var parent: Node = get_parent()


func _ready() -> void:
	top_level = true


func _process(delta: float) -> void:
	if not use_physics_process:
		update(delta)


func _physics_process(delta: float) -> void:
	if use_physics_process:
		update(delta)


func update(delta: float) -> void:
	match mode:
		Mode.LENGTH:
			var point: Vector2 = parent.global_position
			if points.is_empty() or point != points[0] and get_point_count() <= length and add_points:
				add_point(point, 0)
			if get_point_count() > length / abs(Engine.time_scale) or not add_points:
				remove_point(get_point_count() - 1)
		Mode.TIME:
			var point: Vector2 = parent.global_position
			length = lerp(length, int(round(time / delta)), 0.9)
			if get_point_count() <= length and add_points:
				add_point(point, 0)
			if get_point_count() > 0 and (get_point_count() > length or not add_points):
				remove_point(get_point_count() - 1)
	if get_point_count() >= 3:
		cull_previous_point()


func cull_previous_point() -> void:
	var first_to_second: Vector2 = get_point_position(1) - get_point_position(0)
	var first_to_third: Vector2 = get_point_position(2) - get_point_position(0)
	var aligned: bool = absf(first_to_second.x * first_to_third.y - first_to_third.x * first_to_second.y) < 0.1
	if not aligned:
		return
	var second_to_third: Vector2 = get_point_position(2) - get_point_position(1)
	var same_direction: bool = first_to_second.sign() == second_to_third.sign()
	if aligned and same_direction:
		# remove middle point
		remove_point(1)
