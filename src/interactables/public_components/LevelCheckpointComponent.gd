class_name LevelCheckpointComponent
extends Component

@export var sprite: Sprite2D
@export var animation_player: AnimationPlayer

@export_storage var has_been_enabled: bool = false


func _ready() -> void:
	sprite.set_instance_shader_parameter(&"enabled_factor", 0.0)
	sprite.set_instance_shader_parameter(&"hue", 2.0 / 3.0)
	parent.interacted.connect(place_checkpoint)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"has_been_enabled":
			return has_been_enabled if reason == Serialize.Reason.PRACTICE else null
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"has_been_enabled":
			has_been_enabled = field_data
			sprite.set_instance_shader_parameter(&"enabled_factor", 1.0 if has_been_enabled else 0.0)
		_:
			set(field_name, field_data)


func place_checkpoint(player: Player) -> void:
	sprite.set_instance_shader_parameter(&"enabled_factor", 1.0)
	if player.has_just_spawned():
		return
	var tween: Tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)
	tween.tween_method(
		_set_sprite_enabled_factor,
		1.0, # from
		0.0, # to
		0.75, # duration
	)
	animation_player.play(&"Activate")
	player.place_checkpoint().done()


func _set_sprite_enabled_factor(factor: float) -> void:
	sprite.set_instance_shader_parameter(&"flash_factor", factor)
