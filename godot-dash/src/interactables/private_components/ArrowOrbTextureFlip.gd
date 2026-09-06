extends Node

const Direction = DirectionChangerComponent.Direction


func _on_direction_changed(new_direction: Direction) -> void:
	var indicator: Sprite2D = get_parent()
	match new_direction:
		Direction.KEEP, Direction.FORWARDS:
			indicator.scale.x = absf(indicator.scale.x)
		Direction.FLIP, Direction.BACKWARDS:
			indicator.scale.x = -absf(indicator.scale.x)
