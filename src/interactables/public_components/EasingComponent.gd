class_name EasingComponent
extends Component

signal progressed(player: Player, weight_delta: float)
signal finished(player: Player)
signal restored(player: Player)

enum Action {
	CHANGE,
	PULSE,
}

@export var action: Action:
	set(value):
		action = value
		notify_property_list_changed()

@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:s") var duration: float = 1.0
@export var easing_type: Tween.EaseType = Tween.EASE_IN_OUT
@export var easing_transition: Tween.TransitionType
## Imported Geometry Dash easing curve/rate. -1 keeps user-authored Godot Tween settings.
@export_storage var gd_easing_id: int = -1
@export_storage var gd_easing_rate: float = 2.0

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
@export var _can_change_action: bool = true

@export_storage var elapsed_time: Dictionary[NodePath, float]

var tweens: Dictionary[Player, Tween]
var weights: Dictionary[Player, float]
var _previous_weights: Dictionary[Player, float]
var _weight_derivatives: Dictionary[Player, float]


func _ready() -> void:
	parent.interacted.connect(start)
	# Every placed trigger with an easing used to iterate tweens.keys() (an
	# allocation) once per frame even while completely idle; thousands of
	# inactive triggers paid that forever. Processing is enabled on demand and
	# disabled again once no tween remains.
	_set_processing_active(false)


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


## Toggles the per-frame/per-physics-tick driver loop. Only the tween itself
## and this loop touch `weights`; with no tween there is nothing to emit.
## Disabling also drops weight derivatives, matching the always-processing
## behaviour where the entry was erased on the first inactive frame.
func _set_processing_active(active: bool) -> void:
	set_process(active and not _use_physics_process)
	set_physics_process(active and _use_physics_process)
	if not active:
		_weight_derivatives.clear()


func _validate_property(property: Dictionary) -> void:
	if property.name in ["trigger_for_one_player", "ignore_time_scale"] and parent.has(TimescaleChangerComponent):
		property.usage |= PROPERTY_USAGE_READ_ONLY
		trigger_for_one_player = true
		ignore_time_scale = true
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
		"gd_easing_id": -1,
		"gd_easing_rate": 2.0,
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
	if trigger_for_one_player and tweens.size() == 1 and tweens[tweens.keys()[0]] != player:
		return
	if prevent_restart_during_animation and not tweens.is_empty():
		return
	reset_player(player)
	tweens[player] = create_tween()
	_set_processing_active(true)
	var tween_weight := func(value: float): weights[player] = value
	var use_custom_gd_easing: bool = uses_custom_gd_easing(
		gd_easing_id, gd_easing_rate
	)
	var gd_tween_weight := func(value: float):
		weights[player] = gd_easing_weight(gd_easing_id, gd_easing_rate, value)
	tweens[player].set_process_mode(Tween.TWEEN_PROCESS_PHYSICS if _use_physics_process else Tween.TWEEN_PROCESS_IDLE)
	tweens[player].set_ignore_time_scale(ignore_time_scale)
	if action == Action.CHANGE:
		# Keep the common/default curve on Godot's native Tween easing path.
		# A script callback on every tween step is only needed for a non-default
		# Geometry Dash easing rate; id 0 and rate 2 map to the existing native
		# transition/ease pair produced by GMDConverter.
		var callback: Callable = gd_tween_weight if use_custom_gd_easing else tween_weight
		var transition: Tween.TransitionType = (
			Tween.TRANS_LINEAR if use_custom_gd_easing else easing_transition
		)
		var ease: Tween.EaseType = Tween.EASE_IN_OUT if use_custom_gd_easing else easing_type
		tweens[player] \
				.tween_method(callback, 0.0, 1.0, duration) \
				.set_trans(transition) \
				.set_ease(ease)
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
			if tweens.is_empty():
				_set_processing_active(false)
	)


## Use the GDScript curve only when Geometry Dash's non-default key-85 rate
## cannot be represented by the imported Tween transition. The default rate is
## already encoded in easing_type/easing_transition and uses Godot's native
## easing implementation, avoiding one script callback per active tween step.
static func uses_custom_gd_easing(easing_id: int, rate: float) -> bool:
	if easing_id <= 0 or easing_id > 18:
		return false
	var effective_rate: float = rate if rate > 0.0 else 2.0
	return not is_equal_approx(effective_rate, 2.0)


## Geometry Dash's easing curve evaluator, mirrored from the native runtime so
## editor/fallback triggers can honor both the easing id and key-85 rate.
static func gd_easing_weight(easing_id: int, rate: float, t: float) -> float:
	var x: float = clampf(t, 0.0, 1.0)
	if easing_id <= 0 or easing_id > 18:
		return x
	if x == 0.0 or x == 1.0:
		return x
	if not (rate > 0.0):
		rate = 2.0
	var family: int = floori(float(easing_id - 1) / 3.0)
	var mode: int = (easing_id - 1) % 3
	if mode == 1:
		return _gd_ease_in(family, rate, x)
	if mode == 2:
		if family == 0:
			return pow(x, 1.0 / rate)
		return 1.0 - _gd_ease_in(family, rate, 1.0 - x)
	if x < 0.5:
		return _gd_ease_in(family, rate, 2.0 * x) * 0.5
	return 1.0 - _gd_ease_in(family, rate, 2.0 - 2.0 * x) * 0.5


static func _gd_ease_in(family: int, rate: float, x: float) -> float:
	if x <= 0.0:
		return 0.0
	if x >= 1.0:
		return 1.0
	match family:
		0:
			# The GD easing curve stays linear through the first percent.
			return x * pow(0.01, rate - 1.0) if x <= 0.01 else pow(x, rate)
		1:
			return pow(2.0, 10.0 * (x - 1.0)) * sin(PI * (0.5 + (2.0 - 2.0 * x) / rate))
		2:
			return 1.0 - _gd_bounce_out(1.0 - x)
		3:
			return pow(2.0, 10.0 * (x - 1.0))
		4:
			return 1.0 - cos(0.5 * PI * x)
		_:
			return 3.5949095 * x * x * x - 2.5949095 * x * x


static func _gd_bounce_out(t: float) -> float:
	const C1: float = 7.5625
	const C2: float = 2.75
	if t < 1.0 / C2:
		return C1 * t * t
	if t < 2.0 / C2:
		var x1: float = t - 1.5 / C2
		return C1 * x1 * x1 + 0.75
	if t < 2.5 / C2:
		var x2: float = t - 2.25 / C2
		return C1 * x2 * x2 + 0.9375
	var x3: float = t - 2.625 / C2
	return C1 * x3 * x3 + 0.984375


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
	if tweens.is_empty():
		_set_processing_active(false)


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
