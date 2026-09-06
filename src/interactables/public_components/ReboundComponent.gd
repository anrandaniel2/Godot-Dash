class_name ReboundComponent
extends Component

const VELOCITY_REDIRECTORS_LAYER: int = 1 << 10

@export var _pulse_circle: PulseCircle
@export var _sprite: ReboundSprite

var player_velocity: Vector2
var hitbox_id: int


func _ready() -> void:
	if parent is PadInteractable:
		parent.collision_layer |= VELOCITY_REDIRECTORS_LAYER
		parent.interacted.connect(_pulse)
	hitbox_id = parent.get_shape_owners()[0]


func _pulse(_player: Player) -> void:
	_pulse_circle.visible = player_velocity.y != 0


func _physics_process(_delta: float) -> void:
	var new_player_velocity: Vector2 = (
			LevelManager.player.velocity.rotated(-LevelManager.player.gameplay_rotation)
			* LevelManager.player.gravity_flip
	)
	if new_player_velocity.y == 0:
		set_deferred(&"player_velocity", new_player_velocity)
	else:
		player_velocity = new_player_velocity


func _process(_delta: float) -> void:
	if player_velocity.y <= 0:
		var position_delta: Vector2 = parent.to_global(parent.shape_owner_get_transform(hitbox_id).origin) - LevelManager.player.global_position
		var player_distance: float = position_delta.rotated(-LevelManager.player.gameplay_rotation).y * LevelManager.player.gravity_flip
		_sprite.factor = clampf(player_distance / 700, 0, 1)


func get_velocity(player: Player) -> float:
	return -player_velocity.y * player.gravity_flip
