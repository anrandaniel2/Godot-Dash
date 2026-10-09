class_name EndLevelComponent
extends Component

const TRANSITION_DURATION := 1.0

# No registration since we don't want these fields to appear in the editor
@export var static_trigger: TriggerInteractable
@export var shake_trigger: TriggerInteractable

## GD End trigger (3600, gd_docs docs/triggers/misc/end.md): 51 spawn group,
## 71 target position group, 487 instant. Imported levels set these.
@export var spawn_group: String = ""
@export var target_group: String = ""
@export var instant: bool = false
## Set by GMDConverter: the trigger itself is the fallback end position.
@export var gd_import: bool = false

## Only the first End activation per attempt counts.
static var _ended: bool = false

var initial_player_positions: Dictionary[Player, Vector2]
var _target: Node2D


func _ready() -> void:
	await require([TargetObjectComponent])
	var static_easing: EasingComponent = static_trigger.query(EasingComponent)
	var shake_camera_shake: CameraShakeComponent = shake_trigger.query(CameraShakeComponent)
	var shake_easing: EasingComponent = shake_trigger.query(EasingComponent)
	static_easing.easing_type = Tween.EASE_IN
	static_easing.easing_transition = Tween.TRANS_EXPO
	static_easing.progressed.connect(_on_static_easing_progressed)
	static_easing.finished.connect(_on_static_easing_finished)
	shake_camera_shake.strength = 25.0
	shake_easing.duration = 2.0
	shake_easing.easing_type = Tween.EASE_IN
	shake_easing.easing_transition = Tween.TRANS_QUAD
	shake_easing.finished.connect(_on_shake_easing_finished)
	parent.interacted.connect(start)


func start(player: Player) -> void:
	var gd_target: Node2D = _gd_target()
	if gd_target != null:
		if _ended:
			return
		_ended = true
		if not spawn_group.is_empty() and spawn_group != "0":
			for node: Node in get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + spawn_group)):
				if node.has_signal(&"interacted"):
					node.interacted.emit(player)
	elif parent.query(TargetObjectComponent).target.is_empty():
		Toasts.error("In %s: target object is unset" % parent.name)
		return
	# Imported levels: GD only shakes the camera at the end, it never pans
	# up to the end position, so the static pin keeps the current height.
	static_trigger.query(CameraStaticComponent).axis = Constants.Axis.X if gd_target != null else Constants.Axis.BOTH
	var static_target: TargetObjectComponent = static_trigger.query(TargetObjectComponent)
	static_target.target = LevelManager.current_level.get_path_to(gd_target) if gd_target != null else parent.query(TargetObjectComponent).target
	if instant and gd_target != null:
		player.set_collisions_enabled(false)
		player.in_end_level_animation = true
		_on_static_easing_finished(player)
		return
	static_trigger.interacted.emit(player)
	# Disable player collision
	player.set_collisions_enabled(false)
	player.in_end_level_animation = true
	initial_player_positions[player] = player.global_position
	_target = gd_target if gd_target != null else parent.query(TargetObjectComponent).target_to_node()
	if Editor.in_editor:
		LevelManager.current_level.record_duration()
		var duration: float = LevelManager.current_level.duration
		for level_data: Dictionary in LevelManager.practice_level_snapshots:
			level_data.duration = duration
		Editor.level_data_snapshot.duration = duration


## Imported GD End: the unique Target Pos member, else the trigger itself.
func _gd_target() -> Node2D:
	if not gd_import:
		return null
	if not target_group.is_empty() and target_group != "0":
		var members: Array[Node] = get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + target_group))
		if members.size() == 1 and members[0] is Node2D:
			return members[0] as Node2D
	return parent as Node2D


func reset() -> void:
	_ended = false
	static_trigger.query(EasingComponent).reset()
	shake_trigger.query(EasingComponent).reset()


# We use the static trigger's easing instead of requiring one,
# so it doesn't appear in the UI and it avoids duplication.
func _on_static_easing_progressed(player: Player, weight_delta: float) -> void:
	var initial_player_position: Vector2 = initial_player_positions[player]
	var weight: float = static_trigger.query(EasingComponent).weights[player]
	var rotation_direction = 1 if player.global_position < _target.global_position else -1
	player.global_position = initial_player_position.lerp(_target.global_position, weight)
	player.rotation += weight_delta * 5 * rotation_direction


func _on_static_easing_finished(player: Player) -> void:
	shake_trigger.interacted.emit(player)
	player.hide()


func _on_shake_easing_finished(_player: Player) -> void:
	LevelManager.current_level.stop_level()
	if Editor.in_editor:
		LevelManager.game_scene.pause_menu.toggle_pause_menu()
		return
	# GD's EndLevelLayer: the level-complete screen, not the pause menu.
	get_tree().paused = true
	LevelManager.game_scene.add_child(LevelCompleteScreen.new())
