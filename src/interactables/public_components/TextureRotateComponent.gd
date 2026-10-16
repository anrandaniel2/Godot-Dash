class_name TextureRotateComponent
extends Component

@export var _sprite: Node2D
@export_range(-360.0, 360.0, 0.01, "or_greater", "or_less", "suffix:°/s") var rotation_rate: float:
	set(value):
		rotation_rate = value
		if is_inside_tree():
			set_process(rotation_rate != 0.0)


func _ready() -> void:
	set_process(rotation_rate != 0.0)


func _process(delta: float) -> void:
	_sprite.rotation_degrees += rotation_rate * delta
