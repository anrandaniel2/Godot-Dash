class_name EasingComponent
extends Component

signal progressed(player: Player, weight_delta: float)
signal finished(player: Player)
signal restored(player: Player)

enum Action {
	CHANGE,
	PULSE,
}

@export_custom(PROPERTY_HINT_TOOL_BUTTON, "Preview,Play") var preview: Callable = start_preview
@export var action: Action:
	set(value):
		action = value
		notify_property_list_changed()

@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:s") var duration: float = 1.0
@export var easing_type: Tween.EaseType = Tween.EASE_IN_OUT
@export var easing_transition: Tween.TransitionType

@export_group("Fade In:open", "fade_in_")
@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:s") var fade_in_duration: float = 0.5
@export var fade_in_easing_type: Tween.EaseType = Tween.EASE_IN_OUT
@export var fade_in_easing_transition: Tween.TransitionType

@export_group("Hold:open", "hold_")
@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:s") var hold_duration: float = 1.0

@export_group("Fade Out:open", "fade_out_")
@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:s") var fade_out_duration: float = 0.5
@export var fade_out_easing_type: Tween.EaseType = Tween.EASE_IN_OUT
@export var fade_out_easing_transition: Tween.TransitionType

@export_group("Activation")
@export var keep_active: bool ## Keep the easing active after it completes.
@export var trigger_for_one_player: bool = true
@export var prevent_restart_during_animation: bool = true
@export var ignore_time_scale: bool = false
@export var _use_physics_process: bool = false
@export var _can_be_previewed: bool = true
@export var _can_change_action: bool = true

@export_storage var elapsed_time: Dictionary[NodePath, float]

var is_previewing: bool = false
var tweens: Dictionary[Player, Tween]
var weights: Dictionary[Player, float]
var _previous_weights: Dictionary[Player, float]
var _weight_derivatives: Dictionary[Player, float]


func _ready() -> void:
	parent.interacted.connect(start)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _use_physics_process:
		return
	# Avoid applying triggers with a weight delta again,
	# when the restored object already has this delta.
	for player in tweens.keys():
		if not is_inactive(player):
			var weight_delta: float = get_weight_delta(player)
			_weight_derivatives[player] = weight_delta / delta
			progressed.emit(player, weight_delta)
		elif player in _weight_derivatives:
			_weight_derivatives.erase(player)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not _use_physics_process:
		return
	# Avoid applying triggers with a weight delta again,
	# when the restored object already has this delta.
	for player in tweens.keys():
		if not is_inactive(player):
			var weight_delta: float = get_weight_delta(player)
			_weight_derivatives[player] = weight_delta / delta
			progressed.emit(player, weight_delta)
		elif player in _weight_derivatives:
			_weight_derivatives.erase(player)


func _validate_property(property: Dictionary) -> void:
	if property.name in ["trigger_for_one_player", "ignore_time_scale"] and parent.has(TimescaleChangerComponent):
		property.usage |= PROPERTY_USAGE_READ_ONLY
		trigger_for_one_player = true
		ignore_time_scale = true
	if property.name == "preview" and is_previewing:
		property.hint_string = "Preview,Stop"
	if property.name == "preview" and not _can_be_previewed:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name == "action" and not _can_change_action:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name in ["duration", "easing_type", "easing_transition"] and action != Action.CHANGE:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name in [
		"Fade In:open",
		"fade_in_duration",
		"fade_in_easing_type",
		"fade_in_easing_transition",
		"Hold:open",
		"hold_duration",
		"Fade Out:open",
		"fade_out_duration",
		"fade_out_easing_type",
		"fade_out_easing_transition",
	] and action != Action.PULSE:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"action": Action.CHANGE,
		# Change
		"duration": 1.0,
		"easing_type": Tween.EASE_IN_OUT,
		"easing_transition": Tween.TRANS_LINEAR,
		# Pulse
		"fade_in_duration": 0.5,
		"fade_in_easing_type": Tween.EASE_IN_OUT,
		"fade_in_easing_transition": Tween.TRANS_LINEAR,
		"hold_duration": 1.0,
		"fade_out_duration": 0.5,
		"fade_out_easing_type": Tween.EASE_IN_OUT,
		"fade_out_easing_transition": Tween.TRANS_LINEAR,
		# Activation
		"keep_active": false,
		"trigger_for_one_player": true,
		"prevent_restart_during_animation": true,
		"ignore_time_scale": false,
	}
	return DEFAULT_VALUES.get(property)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	if is_previewing:
		stop_preview(LevelManager.player)
	match field_name:
		"elapsed_time":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return get_elapsed_time()
		"action":
			# Prevent serialization so the field can't be changed by manipulating json level data
			if not _can_change_action:
				return null
			return action
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"elapsed_time":
			elapsed_time = field_data
			restore_from_elapsed_time.call_deferred()
		_:
			set(field_name, field_data)


func start(player: Player) -> void:
	if LevelManager.level_playing and is_previewing:
		stop_preview(player)
	if trigger_for_one_player and tweens.size() == 1 and tweens[tweens.keys()[0]] != player:
		return
	if prevent_restart_during_animation and not tweens.is_empty():
		return
	reset_player(player)
	tweens[player] = create_tween()
	var tween_weight := func(value: float): weights[player] = value
	tweens[player].set_process_mode(Tween.TWEEN_PROCESS_PHYSICS if _use_physics_process else Tween.TWEEN_PROCESS_IDLE)
	tweens[player].set_ignore_time_scale(ignore_time_scale)
	if action == Action.CHANGE:
		tweens[player] \
				.tween_method(tween_weight, 0.0, 1.0, duration) \
				.set_trans(easing_transition) \
				.set_ease(easing_type)
	elif action == Action.PULSE:
		tweens[player] \
				.tween_method(tween_weight, 0.0, 1.0, fade_in_duration) \
				.set_trans(fade_in_easing_transition) \
				.set_ease(fade_in_easing_type)
		if hold_duration > 0.0:
			tweens[player].tween_interval(hold_duration)
		tweens[player] \
				.tween_method(tween_weight, 1.0, 0.0, fade_out_duration) \
				.set_trans(fade_out_easing_transition) \
				.set_ease(fade_out_easing_type)
	tweens[player].finished.connect(
		func():
			finished.emit(player)
			if get_tree() != null:
				await get_tree().process_frame
			if get_tree() != null:
				await get_tree().process_frame
			tweens.erase(player)
	)


func get_weight_delta(player: Player) -> float:
	var result = weights[player] - _previous_weights[player]
	_previous_weights[player] = weights[player]
	return result


func get_weight_derivative(player: Player) -> float:
	return _weight_derivatives[player] if player in _weight_derivatives else 0.0


func is_inactive(player: Player) -> bool:
	if action == Action.PULSE:
		# In action mode it's only inactive if it has fully returned to 0.0
		return weights[player] == 0.0 and _previous_weights[player] == 0.0
	return weights[player] == 0.0 or (_previous_weights[player] == 1.0 and not keep_active)


func is_inactive_any() -> bool:
	return weights.values().all(func(value): return value == 0.0) or (_previous_weights.values().all(func(value): return value == 1.0) and not keep_active)


func reset() -> void:
	var players: Array[Player]
	players.assign(tweens.keys())
	for player: Player in players:
		reset_player(player)


func reset_player(player: Player) -> void:
	if player in tweens:
		tweens[player].kill()
		tweens.erase(player)
	weights[player] = 0.0
	_previous_weights[player] = 0.0
	if player in _weight_derivatives:
		_weight_derivatives.erase(player)


func start_preview() -> void:
	var player: Player = LevelManager.player
	if is_previewing:
		stop_preview(player)
		return
	is_previewing = true
	notify_property_list_changed()
	finished.connect(_on_preview_end, CONNECT_ONE_SHOT)
	parent.interacted.emit(player)


func stop_preview(player: Player) -> void:
	is_previewing = false
	if player in tweens:
		_on_preview_end(player)
		tweens[player].kill()
		tweens.erase(player)


func get_elapsed_time() -> Dictionary[NodePath, float]:
	var _elapsed_time: Dictionary[NodePath, float] = { }
	for player in tweens:
		_elapsed_time[Serialize.Node(player)] = tweens[player].get_total_elapsed_time()
	return _elapsed_time


func get_duration() -> float:
	match action:
		Action.CHANGE:
			return duration
		Action.PULSE:
			return fade_in_duration + hold_duration + fade_out_duration
		_:
			return 0.0


func restore_from_elapsed_time() -> void:
	for player_path: NodePath in elapsed_time:
		var player: Player = Deserialize.Node(player_path)
		start(player)
		restored.emit(player)
		# Update _previous_weights so there isn't a
		# weight delta causing the trigger
		# to run like it just started from 0
		tweens[player].custom_step(elapsed_time[player_path])
		get_weight_delta(player)


func _on_preview_end(player: Player) -> void:
	var reverse_weight: float = -weights[player]
	reset_player(player)
	progressed.emit(player, reverse_weight)
	is_previewing = false
	notify_property_list_changed()
