class_name TriggerHitboxComponent
extends Component

enum HitboxShape {
	LINE,
	SQUARE,
	DISABLED,
}

@export var _hitbox: CollisionShape2D
@export var hitbox_shape: HitboxShape:
	set(value):
		hitbox_shape = value
		if _hitbox != null:
			match value:
				HitboxShape.LINE:
					_hitbox.shape = SegmentShape2D.new()
					_hitbox.shape.a = Vector2(0, -line_height * Constants.CELL_SIZE)
					_hitbox.shape.b = Vector2(0, line_height * Constants.CELL_SIZE)
				HitboxShape.SQUARE:
					_hitbox.shape = RectangleShape2D.new()
					_hitbox.shape.size = Vector2.ONE * Constants.CELL_SIZE
				HitboxShape.DISABLED:
					_hitbox.shape = null
		notify_property_list_changed()

@export_range(0.01, 128.0, 0.01, "or_greater", "slider", "suffix:cells") var line_height: float = 64.0:
	set(value):
		line_height = value
		if hitbox_shape != HitboxShape.LINE or _hitbox == null:
			return
		_hitbox.shape = SegmentShape2D.new()
		_hitbox.shape.a = Vector2(0, -value * Constants.CELL_SIZE)
		_hitbox.shape.b = Vector2(0, value * Constants.CELL_SIZE)


func _validate_property(property: Dictionary) -> void:
	if hitbox_shape != HitboxShape.LINE and property.name == "line_height":
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"hitbox_shape": HitboxShape.LINE,
		"line_height": 64.0,
	}
	return DEFAULT_VALUES.get(property)
