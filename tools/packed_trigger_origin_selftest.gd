extends Node
## CI runtime validation for packed trigger placement.
##
## Packed trigger rows are level-local (converter transform origin, GROUND_Y =
## 0). The Level node sits at (640, 925) in GameScene.tscn, and the player and
## node-based triggers use global space. Before the fix, packed triggers were
## registered with their local origin, so a trigger at placed x fired when the
## player reached x - 150 GD units (640 px), and touch checks were 925 px off in Y.
##
## This test pins the rule end to end at the runtime boundary:
##   set_packed_transform(Level.global_transform)
##     -> register_packed_trigger(local) / register_packed_table(local origin)
##     -> record_position == the node path's global_position for the same place.
## It also pins the identity default, which the smoke tests rely on.
##
## Grep "PACKED_TRIGGER_SELFTEST" in the log.

var checks := 0
var failures: PackedStringArray = []


func _ready() -> void:
	var level_runtime := ClassDB.instantiate(&"NativeLevelRuntime") as Node
	if level_runtime == null:
		_fail("NativeLevelRuntime could not be instantiated")
		_finish()
		return
	add_child(level_runtime)

	for method: String in ["set_packed_transform", "record_position", "register_packed_trigger",
			"register_packed_table", "register_trigger", "trigger_count"]:
		_expect("NativeLevelRuntime has %s" % method, level_runtime.has_method(StringName(method)))
	if not failures.is_empty():
		_finish()
		return

	# Identity default: a direct caller (no bridge) keeps raw coordinates.
	var index_identity: int = level_runtime.call(&"register_packed_trigger", 100.0, 0.0, 0, 0,
			PackedStringArray(), 1612, {"1": "1612"})
	_expect_vector("identity default keeps local x", level_runtime.call(&"record_position", index_identity),
			Vector2(100.0, 0.0))

	# The Level's own global transform, as NativeTriggerBridge passes it.
	var level_transform := Transform2D(0.0, Vector2(640.0, 925.0))
	level_runtime.call(&"set_packed_transform", level_transform)

	var index_packed: int = level_runtime.call(&"register_packed_trigger", 100.0, 0.0, 0, 1,
			PackedStringArray(), 1612, {"1": "1612"})
	var packed_place: Vector2 = level_runtime.call(&"record_position", index_packed)
	_expect_vector("packed row lands at Level-global x (640 + 100)", packed_place, Vector2(740.0, 925.0))

	# Node path parity: a node-based trigger at the same global place must store
	# the same coordinates the packed row now stores.
	var node := Node2D.new()
	node.position = Vector2(740.0, 925.0)
	# Not in the tree, so read position (no parent: position is the global place)
	# rather than global_position, which is undefined outside the scene tree.
	var index_node: int = level_runtime.call(&"register_trigger", node, node.position.x,
			node.position.y, 0, 2, PackedStringArray(), 1612, {"1": "1612"})
	_expect_vector("packed row matches node-path global position",
			packed_place, level_runtime.call(&"record_position", index_node))
	node.free()

	# Table path (the one the bridge uses for real levels): one row, origin (100, 0).
	var before_table: int = level_runtime.call(&"trigger_count")
	var table := {
		"gd_id": PackedInt32Array([1612]),
		"source_order": PackedInt32Array([3]),
		"flags": PackedByteArray([0]),
		"xform": PackedFloat32Array([1.0, 0.0, 0.0, 1.0, 100.0, 0.0]),
		"group_offsets": PackedInt32Array([0, 0]),
		"group_ids": PackedInt32Array(),
		"prop_offsets": PackedInt32Array([0, 0]),
		"prop_keys": PackedInt32Array(),
		"value_offsets": PackedInt32Array([0]),
		"value_bytes": PackedByteArray(),
	}
	var registered: int = level_runtime.call(&"register_packed_table", table)
	_expect("packed table registers one row", registered == 1)
	var index_table: int = before_table
	var table_place: Vector2 = level_runtime.call(&"record_position", index_table)
	_expect_vector("packed table row lands at Level-global x (640 + 100)", table_place, Vector2(740.0, 925.0))

	# Y matters for touch checks: a row at local y 0 must sit at the Level's y.
	_expect("packed table row carries the Level's Y offset", is_equal_approx(table_place.y, 925.0))

	(level_runtime as Node).queue_free()
	_finish()


func _expect(description: String, condition: bool) -> void:
	checks += 1
	if condition:
		print("PACKED_TRIGGER_SELFTEST ok ", description)
	else:
		_fail(description)


func _expect_vector(description: String, actual: Variant, expected: Vector2) -> void:
	var actual_vector: Vector2 = actual if actual is Vector2 else Vector2(NAN, NAN)
	_expect("%s (got %s, want %s)" % [description, actual_vector, expected],
			actual_vector.is_equal_approx(expected))


func _fail(description: String) -> void:
	failures.append(description)
	print("PACKED_TRIGGER_SELFTEST_FAIL ", description)


func _finish() -> void:
	print("PACKED_TRIGGER_SELFTEST_SUMMARY total=", checks, " failed=", failures.size())
	get_tree().quit(1 if not failures.is_empty() else 0)
