class_name SpawnTriggerComponent
extends Component

enum LoopState {
	DISABLED,
	COUNT,
	INFINITE,
}

@export var spawned_triggers: Array[SpawnedTrigger]:
	set(value):
		spawned_triggers = value
		notify_property_list_changed()
@export var loop: LoopState = LoopState.DISABLED:
	set(value):
		loop = value
		notify_property_list_changed()
@export var loop_count: int = 1
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:s") var loop_delay: float = 0.0
@export var _timer: Timer

@export_storage var _duration: float
@export_storage var _current_loop: int = 1
@export_storage var _interacted_with_player: Player


func _ready() -> void:
	parent.interacted.connect(start)


func _validate_property(property: Dictionary) -> void:
	if property.name in ["loop_count", "loop_delay"] and loop == LoopState.DISABLED:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name == "loop_count" and loop == LoopState.INFINITE:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _process(delta: float) -> void:
	if spawned_triggers.is_empty() or _timer.is_stopped():
		return
	var elapsed_time: float = _timer.wait_time - _timer.time_left
	for trigger in spawned_triggers:
		if elapsed_time >= trigger.time - delta and trigger.loop_idx < _current_loop:
			var trigger_node := LevelManager.current_level.get_node_or_null(trigger.path)
			if trigger_node == null:
				continue
			trigger_node.interacted.emit(_interacted_with_player)
			trigger.loop_idx = _current_loop
			print_debug(trigger)


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"spawned_triggers": [],
		"loop": LoopState.DISABLED,
		"loop_count": 1,
		"loop_delay": 0.0,
	}
	return DEFAULT_VALUES.get(property)


func start(player: Player) -> void:
	var is_spawned_trigger_valid := func(spawned_trigger: SpawnedTrigger):
		return not spawned_trigger.path.is_empty()
	spawned_triggers = spawned_triggers.filter(is_spawned_trigger_valid)
	if spawned_triggers.is_empty():
		Toasts.warning("In %s: spawned triggers is empty" % parent.name)
		return
	if not _timer.is_stopped():
		return
	for trigger in spawned_triggers:
		if LevelManager.current_level.get_node_or_null(trigger.path) == null:
			Toasts.error("In " + parent.name + ": Invalid Trigger at index " + str(spawned_triggers.find(trigger)) + " of Spawned Triggers", 3)
		if trigger.time > _duration:
			_duration = trigger.time
	_timer.start(_duration)
	_interacted_with_player = player
	if loop != LoopState.DISABLED:
		if _duration > 0.0:
			NodeUtils.connect_once(_timer.timeout, restart.bind(player))
		else:
			restart(player)


func restart(player: Player) -> void:
	prints("delay:", loop_delay)
	await get_tree().create_timer(loop_delay, false).timeout
	print("delay ended")
	if loop == LoopState.INFINITE or (loop == LoopState.COUNT and _current_loop < loop_count):
		_current_loop += 1
		parent.interacted.emit(player)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"spawned_triggers":
			return spawned_triggers.map(func(spawned_trigger: SpawnedTrigger): return spawned_trigger.to_data())
		"_duration":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return _duration
		"_current_loop":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return _current_loop
		"_interacted_with_player":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return Serialize.Node(_interacted_with_player)
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"spawned_triggers":
			spawned_triggers.assign(field_data.map(func(spawned_trigger_data: Dictionary): return SpawnedTrigger.from_data(spawned_trigger_data)))
		"_interacted_with_player":
			return Deserialize.Node(field_data)
		_:
			set(field_name, field_data)
