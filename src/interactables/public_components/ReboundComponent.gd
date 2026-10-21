class_name ReboundComponent
extends Component

const VELOCITY_REDIRECTORS_LAYER: int = 1 << 10
## Horizontal distance (world px) beyond which tracking stops: no player can
## interact with an orb or pad from farther than this, the tracked velocity is
## an exact read (not smoothed) so resuming is seamless, and the pad hitbox
## only reacts to the factor within a 700 px approach anyway. Culling managers
## never hide interactables, so without this gate every orb and pad in the
## level read the player's velocity and transform at high frequency.
const TRACK_RANGE: float = 900.0

## Every live rebound in the scene, driven by ONE signal callback instead of
## a per-instance engine callback per tick. A level with N rebound orbs and
## pads used to schedule N _physics_process calls at 240 Hz plus N _process
## calls at the frame rate; the per-instance bodies are a handful of float
## ops, so the callback dispatch dominated completely as N grew. The driver
## connection lives on SceneTree.physics_frame / process_frame, which fire
## regardless of any parent's process_mode (group toggles can disable a
## rebound's Area processing — the original code only kept working because
## some *other* instance still received callbacks), and is checked against
## tree pause to match the old pausable processing.
static var _registry: Array[ReboundComponent] = []
static var _driver: ReboundComponent = null


## Whether any rebound orb/pad exists in the scene. Player._ensure_velocity_redirect's
## per-tick velocity cast can only ever return true through a ReboundComponent
## or a REDIRECT TeleportComponent, so the player skips the cast when both
## counts are zero (see TeleportComponent.redirect_count).
static func any_registered() -> bool:
	return not _registry.is_empty()

@export var _pulse_circle: PulseCircle
@export var _sprite: ReboundSprite

var player_velocity: Vector2
var hitbox_id: int


func _ready() -> void:
	if parent is PadInteractable:
		parent.collision_layer |= VELOCITY_REDIRECTORS_LAYER
		parent.interacted.connect(_pulse)
	hitbox_id = parent.get_shape_owners()[0]
	_registry.append(self)
	if _driver == null or not is_instance_valid(_driver):
		_become_driver()


func _exit_tree() -> void:
	_registry.erase(self)
	if _driver == self:
		_cease_driver()
		_driver = null
		for candidate: ReboundComponent in _registry:
			if is_instance_valid(candidate):
				candidate._become_driver()
				break


func _become_driver() -> void:
	# Engine.get_main_loop() rather than get_tree(): re-election can run
	# while the previous driver is mid-removal, where is_inside_tree() is
	# not dependable.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_driver = self
	if not tree.physics_frame.is_connected(_on_driver_physics_frame):
		tree.physics_frame.connect(_on_driver_physics_frame)
	if not tree.process_frame.is_connected(_on_driver_process_frame):
		tree.process_frame.connect(_on_driver_process_frame)


func _cease_driver() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	if tree.physics_frame.is_connected(_on_driver_physics_frame):
		tree.physics_frame.disconnect(_on_driver_physics_frame)
	if tree.process_frame.is_connected(_on_driver_process_frame):
		tree.process_frame.disconnect(_on_driver_process_frame)


func _pulse(_player: Player) -> void:
	_pulse_circle.visible = player_velocity.y != 0


func _on_driver_physics_frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.paused:
		return
	for component: ReboundComponent in _registry:
		if is_instance_valid(component):
			component._track_player_velocity()


func _on_driver_process_frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.paused:
		return
	for component: ReboundComponent in _registry:
		if is_instance_valid(component):
			component._update_sprite_factor()


func _track_player_velocity() -> void:
	var player: Player = LevelManager.player
	if player == null or absf(parent.global_position.x - player.global_position.x) > TRACK_RANGE:
		return
	# Direct write: the old set_deferred for the zero case only postponed a
	# plain script-variable assignment by a frame.
	player_velocity = (
		player.velocity.rotated(-player.gameplay_rotation)
		* player.gravity_flip
	)


func _update_sprite_factor() -> void:
	if player_velocity.y > 0:
		return
	var player: Player = LevelManager.player
	if player == null or absf(parent.global_position.x - player.global_position.x) > TRACK_RANGE:
		return
	var position_delta: Vector2 = parent.to_global(parent.shape_owner_get_transform(hitbox_id).origin) - player.global_position
	var player_distance: float = position_delta.rotated(-player.gameplay_rotation).y * player.gravity_flip
	_sprite.factor = clampf(player_distance / 700, 0, 1)


func get_velocity(player: Player) -> float:
	return -player_velocity.y * player.gravity_flip
