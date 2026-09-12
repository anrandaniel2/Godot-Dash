class_name NativeTriggerBridge
extends Node
## One bridge per loaded level. Geometry Dash trigger records remain packed in
## NativeTriggerRuntime; this node only supplies player coordinates and invokes
## the existing component signal when C++ reports a deterministic crossing.

var _runtime: Object
var _previous_x: Dictionary[int, float] = {}
var _level: Level


func setup(level: Level) -> bool:
	_level = level
	if not NativeCore.available() or not ClassDB.class_exists(&"NativeTriggerRuntime"):
		return false
	_runtime = ClassDB.instantiate(&"NativeTriggerRuntime")
	if _runtime == null:
		return false
	var records: Array[TriggerInteractable] = []
	_collect_triggers(level, records)
	records.sort_custom(func(a: TriggerInteractable, b: TriggerInteractable) -> bool:
		return int(a.get_meta(&"gd_source_order", 0)) < int(b.get_meta(&"gd_source_order", 0))
	)
	for trigger: TriggerInteractable in records:
		var flags := int(trigger.get_meta(&"gd_trigger_flags", 0))
		var trigger_groups := PackedStringArray()
		for group: StringName in trigger.get_groups():
			if String(group).begins_with(Constants.GROUP_PREFIX):
				trigger_groups.append(String(group))
		_runtime.call(
				&"register_trigger", trigger, trigger.global_position.x, flags,
				int(trigger.get_meta(&"gd_source_order", 0)), trigger_groups,
				int(trigger.get_meta(&"gd_object_id", 0)),
				trigger.get_meta(&"gd_properties", {}),
		)
		# Physical line crossings are now indexed in C++. Square/touch triggers
		# retain their Area2D because overlap semantics depend on both axes.
		if (flags & 2) == 0:
			var hitbox := trigger.get_node_or_null(^"TriggerHitboxComponent") as TriggerHitboxComponent
			if hitbox != null and hitbox._hitbox != null:
				hitbox._hitbox.set_deferred(&"disabled", true)
	set_physics_process(true)
	print("[gdash] native trigger runtime packed %d records" % int(_runtime.call(&"trigger_count")))
	return true


func _collect_triggers(node: Node, output: Array[TriggerInteractable]) -> void:
	for child: Node in node.get_children():
		if child is TriggerInteractable and child.has_meta(&"gd_trigger_flags"):
			output.append(child as TriggerInteractable)
		_collect_triggers(child, output)


func _physics_process(delta: float) -> void:
	if _runtime == null or not LevelManager.level_playing:
		return
	_runtime.call(&"tick", delta)
	var players: Array[Player] = [LevelManager.player]
	players.append_array(LevelManager.player_duals)
	for player: Player in players:
		if player == null or not is_instance_valid(player):
			continue
		var id := int(player.get_instance_id())
		var current_x := player.global_position.x
		if _previous_x.has(id):
			_runtime.call(&"advance", player, _previous_x[id], current_x)
		_previous_x[id] = current_x


func reset_runtime() -> void:
	_previous_x.clear()
	if _runtime != null:
		_runtime.call(&"reset")


func snapshot() -> Dictionary:
	return _runtime.call(&"snapshot") if _runtime != null else {}


func restore(state: Dictionary) -> void:
	_previous_x.clear()
	if _runtime != null:
		_runtime.call(&"restore", state)
