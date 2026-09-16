class_name NativeTriggerBridge
extends Node
## One bridge per loaded level. Geometry Dash trigger records remain packed in
## NativeTriggerRuntime; this node only supplies player coordinates and invokes
## the existing component signal when C++ reports a deterministic crossing.

var _runtime: Object
var _target_cache: Dictionary[String, Node2D] = {}
var _level: Level


func setup(level: Level, level_data: Dictionary = {}) -> bool:
	_level = level
	if not NativeCore.available() or not ClassDB.class_exists(&"NativeLevelRuntime"):
		return false
	_runtime = ClassDB.instantiate(&"NativeLevelRuntime")
	if _runtime == null or _runtime is not Node:
		return false
	add_child(_runtime as Node)
	# Colour/camera/player effects execute in C++: they need the level's own
	# colours, the channel table and the live camera and Config objects.
	_runtime.call(&"bind_context", level, LevelManager.player_camera, Config)
	for channel: ColorChannelData in level.color_channels:
		if not channel.associated_group.is_empty():
			_runtime.call(&"register_channel", channel.associated_group, channel)
	var records: Array[TriggerInteractable] = []
	for node: Node in get_tree().get_nodes_in_group(&"_gd_native_trigger"):
		if node is TriggerInteractable and level.is_ancestor_of(node):
			records.append(node as TriggerInteractable)
	records.sort_custom(func(a: TriggerInteractable, b: TriggerInteractable) -> bool:
		return int(a.get_meta(&"gd_source_order", 0)) < int(b.get_meta(&"gd_source_order", 0))
	)
	for trigger: TriggerInteractable in records:
		_configure_runtime_targets(trigger)
		var flags := int(trigger.get_meta(&"gd_trigger_flags", 0))
		var gd_id := int(trigger.get_meta(&"gd_object_id", 0))
		var trigger_groups := PackedStringArray()
		for group: StringName in trigger.get_groups():
			if String(group).begins_with(Constants.GROUP_PREFIX):
				trigger_groups.append(String(group))
		_runtime.call(
			&"register_trigger", trigger, trigger.global_position.x, trigger.global_position.y,
			flags, int(trigger.get_meta(&"gd_source_order", 0)), trigger_groups,
			gd_id, trigger.get_meta(&"gd_properties", {}),
		)
		# Physical line crossings are now indexed in C++. Square/touch triggers
		# keep overlap semantics, but only when their family has no native
		# effect: native families (including touch-flagged ones) are checked
		# against the player hitbox in C++, so their Area2D would double-fire.
		if (flags & 2) == 0 or gd_id in GMDObjects.NATIVE_EFFECT_TRIGGER_IDS:
			# Remove the entire Area from broad-phase participation, not only its
			# shape. This is the material win on trigger-dense levels.
			trigger.set_deferred(&"monitoring", false)
			trigger.set_deferred(&"monitorable", false)
			var hitbox := trigger.get_node_or_null(^"TriggerHitboxComponent") as TriggerHitboxComponent
			if hitbox != null and hitbox._hitbox != null:
				hitbox._hitbox.set_deferred(&"disabled", true)
	_register_packed_triggers(level_data)
	# Build and compact the X/group indexes during level loading rather than on
	# the first gameplay physics frame, eliminating a visible first-jump hitch.
	_runtime.call(&"finalize")
	print("[gdash] native trigger runtime packed %d records" % int(_runtime.call(&"trigger_count")))
	return true


func _register_packed_triggers(level_data: Dictionary) -> void:
	var packed_records: Array = level_data.get("native_trigger_records", [])
	# Compatibility for levels imported before the side index existed.
	if packed_records.is_empty():
		for layer_data: Dictionary in level_data.get("layers", []):
			for object_data: Dictionary in layer_data.get("objects", []):
				if object_data.get("native_only_trigger", false):
					packed_records.append(object_data)
	for value: Variant in packed_records:
		var object_data: Dictionary = value
		var transform: Transform2D = object_data.get("transform", Transform2D.IDENTITY)
		var groups := PackedStringArray()
		for group: Variant in object_data.get("groups", []):
			groups.append(str(group))
		_runtime.call(
			&"register_packed_trigger", transform.origin.x, transform.origin.y,
			int(object_data.get("gd_trigger_flags", 0)),
			int(object_data.get("gd_source_order", 0)), groups,
			int(object_data.get("gd_object_id", 0)),
			object_data.get("gd_properties", {}),
		)
	_print_trigger_key_diagnostics(packed_records)


## One-shot diagnostic for the white-beams investigation: which property keys
## the level's packed colour triggers actually carry. The native effect parser
## reads the classic encoding (7/8/9 RGB, 23 channel, 35 opacity, 50 copy,
## 15/16 player colour, 17 blending, 10 duration); an Amethyst device run
## showed 348k recolour events while no channel ever left white - as if every
## fire parsed as KEEP - so the real key vocabulary of a modern effect level's
## triggers has to be visible in a logcat. Prints, per colour-family object
## id, the record count, the flags histogram and a key-presence histogram,
## plus the three key-richest raw property dictionaries as samples.
## Grep "TRIGDIAG".
func _print_trigger_key_diagnostics(packed_records: Array) -> void:
	if packed_records.is_empty():
		return
	const COLOR_FAMILY := {
		29: true, 30: true, 104: true, 105: true, 221: true, 717: true, 718: true,
		743: true, 744: true, 899: true, 900: true, 915: true, 1006: true,
	}
	var family_counts: Dictionary = {}
	var key_counts: Dictionary = {}
	var flag_counts: Dictionary = {}
	var samples: Dictionary = {}
	for value: Variant in packed_records:
		var object_data: Dictionary = value
		var gd_id := int(object_data.get("gd_object_id", 0))
		if not COLOR_FAMILY.has(gd_id):
			continue
		family_counts[gd_id] = int(family_counts.get(gd_id, 0)) + 1
		var flags := int(object_data.get("gd_trigger_flags", 0))
		var flag_key := str(gd_id) + "/" + str(flags)
		flag_counts[flag_key] = int(flag_counts.get(flag_key, 0)) + 1
		var properties: Dictionary = object_data.get("gd_properties", {})
		var counts: Dictionary = key_counts.get(gd_id, {})
		for key: Variant in properties:
			var key_text := str(key)
			counts[key_text] = int(counts.get(key_text, 0)) + 1
		key_counts[gd_id] = counts
		# Keep the three key-richest records as full samples: richer records
		# show more of the vocabulary than the first three.
		var best: Array = samples.get(gd_id, [])
		best.append(properties)
		best.sort_custom(func(a, b) -> bool: return a.size() > b.size())
		if best.size() > 3:
			best.resize(3)
		samples[gd_id] = best
	if family_counts.is_empty():
		return
	var flag_parts: PackedStringArray = []
	for flag_key: Variant in flag_counts:
		flag_parts.append("%s=%d" % [flag_key, flag_counts[flag_key]])
	print("TRIGDIAG flags(spawn=1,touch=2,multi=4) ", " ".join(flag_parts))
	for gd_id: Variant in family_counts:
		var counts: Dictionary = key_counts[gd_id]
		var keys := counts.keys()
		keys.sort_custom(func(a, b) -> bool: return str(a).to_int() < str(b).to_int())
		var key_parts: PackedStringArray = []
		for key: Variant in keys:
			key_parts.append("%s:%d" % [key, counts[key]])
		print("TRIGDIAG gd_id=%s n=%d keys=%s" % [gd_id, family_counts[gd_id], ",".join(key_parts)])
		var best: Array = samples.get(gd_id, [])
		for i: int in best.size():
			print("TRIGDIAG gd_id=%s sample%d=%s" % [gd_id, i, str(best[i])])


func _configure_runtime_targets(trigger: TriggerInteractable) -> void:
	var properties: Dictionary = trigger.get_meta(&"gd_properties", {})
	var gd_id := int(trigger.get_meta(&"gd_object_id", 0))
	# TargetObject/center references are encoded as group IDs in GD, while the
	# established components use NodePaths. Resolve them only after every layer
	# has been constructed, so source order cannot leave a forward target null.
	var target_key := "71"
	var target_id := str(properties.get(target_key, "")).strip_edges()
	if target_id.is_valid_int() and int(target_id) > 0:
		var target_group := Constants.GROUP_PREFIX + target_id
		var target: Node2D = _target_cache.get(target_group)
		if not _target_cache.has(target_group):
			for candidate: Node in get_tree().get_nodes_in_group(target_group):
				if candidate is Node2D and _level.is_ancestor_of(candidate):
					target = candidate as Node2D
					break
			_target_cache[target_group] = target
		if target != null:
			var target_component := trigger.get_node_or_null(^"TargetObjectComponent") as TargetObjectComponent
			if target_component != null:
				target_component.target = _level.get_path_to(target)
			var scale_component := trigger.get_node_or_null(^"ScaleChangerComponent") as ScaleChangerComponent
			if scale_component != null:
				scale_component.pivot = _level.get_path_to(target)
			var rotation_component := trigger.get_node_or_null(^"RotationChangerComponent") as RotationChangerComponent
			if rotation_component != null:
				rotation_component.pivot = _level.get_path_to(target)
	if gd_id == 1914:
		var static_component := trigger.get_node_or_null(^"CameraStaticComponent") as CameraStaticComponent
		if static_component != null:
			static_component.mode = CameraStaticComponent.Mode.EXIT if properties.get("110", "0") == "1" else CameraStaticComponent.Mode.ENTER
			static_component.axis = clampi(int(properties.get("101", "0")), Constants.Axis.BOTH, Constants.Axis.Y)


func reset_runtime() -> void:
	if _runtime != null:
		_runtime.call(&"reset")


func snapshot() -> Dictionary:
	return _runtime.call(&"snapshot") if _runtime != null else {}


func restore(state: Dictionary) -> void:
	if _runtime != null:
		_runtime.call(&"restore", state)
