class_name FireDashComponent
extends Component

# TODO figure out how to make cyan dash orbs work
## Dash orbs _completely_ override the player's velocity.

@export_flags("X", "Y") var snap: int = Constants.AxisBitflag.NONE
@export var _path: FireDashSpeed

var initial_gameplay_rotation: float
var initial_speed: float
var initial_direction: int
var offset: Vector2

var _tween: Tween


func _ready() -> void:
	await require([EasingComponent])
	parent.interacted.connect(start)


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"snap": Constants.AxisBitflag.NONE,
	}
	return DEFAULT_VALUES.get(property)


func start(player: Player) -> void:
	var easing: EasingComponent = parent.query(EasingComponent)
	if easing.get_duration() > 0.0:
		if snap & Constants.AxisBitflag.X:
			offset.x = player.global_position.x - parent.global_position.x
		if snap & Constants.AxisBitflag.Y:
			offset.y = player.global_position.y - parent.global_position.y
	else:
		if snap & Constants.AxisBitflag.X:
			player.global_position.x = parent.global_position.x
		if snap & Constants.AxisBitflag.Y:
			player.global_position.y = tan(parent.rotation) \
					* (player.global_position.x - parent.global_position.x) \
					+ parent.global_position.y
	player.dash_control = self
	initial_gameplay_rotation = player.gameplay_rotation
	initial_speed = player.speed_multiplier
	initial_direction = player.horizontal_direction
	if LevelManager.platformer:
		player.horizontal_direction = sign(cos(parent.global_rotation - initial_gameplay_rotation) * parent.scale.y)
	player.get_node(^"DashParticles").emitting = true
	var dash_flame: AnimatedSprite2D = player.get_node(^"DashFlame")
	dash_flame.play()
	dash_flame.show()
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)
	_tween.tween_property(dash_flame, ^"scale", Vector2.ONE * 1.3, 0.5).from(Vector2.ZERO)
	_tween.tween_property(dash_flame, ^"modulate:a", 1.0, 0.5).from(0.0)
	if not parent.has(NoEffectsComponent):
		var dash_boom: OneShotAnimatedSprite = player.DASH_BOOM.instantiate()
		dash_boom.top_level = true
		player.add_child(dash_boom)
		dash_boom.global_position = parent.global_position


func get_velocity(player: Player) -> Vector2:
	var easing: EasingComponent = parent.query(EasingComponent)
	return _path.get_velocity(player, self) - offset * easing.get_weight_derivative(player)


func stop(player: Player) -> void:
	var dash_flame: AnimatedSprite2D = player.get_node(^"DashFlame")
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)
	_tween.tween_property(dash_flame, ^"scale", Vector2.ZERO, 0.5)
	_tween.tween_property(dash_flame, ^"modulate:a", 0.5, 0.5)
