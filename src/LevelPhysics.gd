class_name LevelPhysics
extends Object
## Builds and owns the level's shared static collision geometry.
##
## Instead of letting every placed static object carry its own physics body
## (one RigidBody2D/Area2D per block, spike or saw), the level collects their
## shapes into a small fixed set of bodies that live for the whole level:
##
##   LevelPhysics (Node2D, child of the Level)
##   └── lightweight RID owners (Node2D, object-ID mapping only)
##       ├── static PhysicsServer2D bodies for solids and slopes
##       └── PhysicsServer2D areas for rectangular and circular hazards
##
## Bodies are chunked by horizontal region (CHUNK_CELLS wide), so a level is a
## grid of (layer, chunk) RIDs; collision shapes are attached directly to the
## server rather than represented by CollisionShape2D nodes. Chunking keeps each
## RID's shape list local to its region, limiting shape tests on player queries.
##
## Objects that gameplay manipulates as bodies are NOT merged and keep their own
## physics, exactly as before:
##   - interactables (orbs, pads, portals, triggers, checkpoints) - their
##     per-object Area2D carries the components and signals;
##   - pushable / physics-edited solids (they carry "physics" data);
##   - any object whose group is the target of a move/rotate/scale trigger,
##     because those triggers animate the node transform and with it the body.
##
## Merged objects hand their collision over to the shared body: a gd-scene
## object's own [code]Collision[/code] child is freed once harvested (a
## registered physics body costs a physics-server object and tree nodes even
## fully disabled), while hand-made scene roots - which are their own body and
## cannot be freed - are neutralised (layers/mask 0, shapes disabled; monitoring
## off for areas). Both are fully reversible: a snapshot plus the cached
## geometry rebuild an identical body when an object becomes dynamic again or
## the level stops being played.
##
## Rebuild policy: the shared state is rebuilt on the next level start whenever
## a layer's children changed since the last build (the level tracks that with
## child_entered/exiting_tree signals). Between attempts nothing changes, so
## start only re-enables shapes that gameplay disabled (lethal wall pass-through
## for the spider dash).

const CONTAINER_NAME := "LevelPhysics"
const BODY_RID_OWNER_SCRIPT = preload("res://src/LevelPhysicsBodyRidOwner.gd")
const AREA_RID_OWNER_SCRIPT = preload("res://src/LevelPhysicsAreaRidOwner.gd")
## Metadata key set on each lightweight server-RID owner node.
const BODY_META: StringName = &"_gd_level_physics_body"
## Metadata keys stored on merged source objects.
const MERGED_META: StringName = &"_gd_level_physics_merged"
## Trigger IDs whose target group is animated by the C++ runtime (Move, Follow,
## Rotate, Scale), mirroring the interactable movers in _dynamic_transform_groups.
const NATIVE_MOVER_IDS: Array[int] = [901, 1347, 1346, 2067]
const SNAPSHOT_META: StringName = &"_gd_level_physics_snapshot"
const DESCRIPTORS_META: StringName = &"_gd_level_physics_descriptors"
## Metadata key on the Level: whether a rebuild is needed before next play.
const DIRTY_META: StringName = &"_gd_level_physics_dirty"
## Metadata key on merged objects: indices of shapes contributed to the
## shared server body. The full per-index descriptors live on its RID owner.
const SHAPES_META: StringName = &"_gd_level_physics_shapes"
## Metadata on each lightweight RID owner node. The node exists only to map
## server collision object IDs back to a scene object; collision bodies and
## shapes themselves are allocated directly through PhysicsServer2D.
const SERVER_RID_META: StringName = &"_gd_level_physics_rid"
const SERVER_SHAPES_META: StringName = &"_gd_level_physics_shape_data"
const SERVER_AREA_META: StringName = &"_gd_level_physics_area"
const SERVER_LAYER_META: StringName = &"_gd_level_physics_layer"
## Metadata key on the Level: the trigger-group set the last merge decision was
## made against. Kept so a rebuild restores merged members whose group turned
## dynamic before it re-merges.
const DYNAMIC_META: StringName = &"_gd_level_physics_dynamic_groups"

## Old-scene collision layers that represent static world geometry. Everything
## else (interactables 8/16, custom physics, editor layers...) stays per-object.
const MERGEABLE_LAYERS: Array[int] = [2, 66, 4, 2048]

const SOLID_LAYER := 2
const SLOPE_LAYER := 66
const RECT_HAZARD_LAYER := 4
const CIRCLE_HAZARD_LAYER := 2048
## Horizontal width of one shared-body chunk, in cells. Each (layer, chunk)
## pair is one physics body, so a player query only touches the few chunks it
## is in rather than every shape in the level.
const CHUNK_CELLS: int = 24


static func mark_dirty(level: Level) -> void:
	level.set_meta(DIRTY_META, true)


static func is_dirty(level: Level) -> bool:
	return bool(level.get_meta(DIRTY_META, true))


## Called every time a level starts playing (each attempt). Rebuilds the shared
## state when the level changed since last time; otherwise just re-enables
## shapes that gameplay disabled during the previous attempt. Returns whether
## a full rebuild ran (callers use it to know the tree was freshly committed).
static func prepare(level: Level) -> bool:
	if is_dirty(level):
		rebuild(level)
		level.set_meta(DIRTY_META, false)
		return true
	_reenable_shapes(level)
	return false


static func _reenable_shapes(level: Level) -> void:
	var container := level.get_node_or_null(CONTAINER_NAME)
	if container == null:
		return
	for owner: Node in container.get_children():
		var rid: RID = owner.get_meta(SERVER_RID_META, RID())
		if not rid.is_valid():
			continue
		var shape_data: Array = owner.get_meta(SERVER_SHAPES_META, [])
		var is_area := bool(owner.get_meta(SERVER_AREA_META, false))
		for index in shape_data.size():
			if is_area:
				PhysicsServer2D.area_set_shape_disabled(rid, index, false)
			else:
				PhysicsServer2D.body_set_shape_disabled(rid, index, false)


## Frees every direct PhysicsServer2D object and its lightweight ID-mapping node.
## RIDs are not owned by the scene tree and must be released explicitly.
static func _free_server_bodies(container: Node) -> void:
	if container == null:
		return
	for owner: Node in container.get_children():
		var rid: RID = owner.get_meta(SERVER_RID_META, RID())
		if owner.has_method("unbind_physics_rid"):
			owner.call("unbind_physics_rid")
		if rid.is_valid():
			PhysicsServer2D.free_rid(rid)
		owner.free()


## Undoes merging and frees the shared bodies. Called when a level stops being
## played and its objects go back to being editable: editor playtest stop and
## leaving a level. Between attempts the shared bodies stay and prepare() only
## refreshes them, so this runs once per session, not per attempt.
static func teardown(level: Level) -> void:
	if level == null:
		return
	var container := level.get_node_or_null(CONTAINER_NAME)
	_free_server_bodies(container)
	for layer in level.layers:
		for object: Node2D in layer.get_children():
			if object.has_meta(MERGED_META):
				_restore_object(object)
	if container != null:
		container.free()
	level.remove_meta(DYNAMIC_META)
	level.set_meta(DIRTY_META, true)


## Frees and rebuilds the shared bodies from the current object tree. Runs
## whenever the tree changed since the last attempt (the level is fully built
## at open, so this is a whole-level rebuild over every placement).
static func rebuild(level: Level) -> void:
	var container := _container(level)
	_free_server_bodies(container)

	var dynamic_groups := _dynamic_transform_groups(level)
	# Shared bodies are chunked by horizontal region, so the physics broadphase
	# only ever sees the chunks near the player instead of one body whose shape
	# list spans the whole level (a huge single body would be tested in full on
	# every player query and grind large levels to a halt).
	var bodies: Dictionary[String, Node2D] = {}

	# First pass: restore objects that were merged but are no longer mergeable
	# (e.g. a move trigger now targets their group), so they never end up with
	# no collision at all.
	for layer in level.layers:
		for object: Node2D in layer.get_children():
			if object is DecorationBatch or object is Interactable:
				continue
			if not object.has_meta(MERGED_META):
				continue
			if not _is_mergeable(object, dynamic_groups):
				_restore_object(object)

	for layer in level.layers:
		for object: Node2D in layer.get_children():
			if object is DecorationBatch:
				continue
			if not _is_mergeable(object, dynamic_groups):
				continue
			_commit_object(container, bodies, object)
	level.set_meta(DYNAMIC_META, dynamic_groups)


## The Level's shared-body container, created on first use.
static func _container(level: Level) -> Node2D:
	var container := level.get_node_or_null(CONTAINER_NAME) as Node2D
	if container == null:
		container = Node2D.new()
		container.name = CONTAINER_NAME
		level.add_child(container)
	return container


## Harvests one mergeable object into the shared server bodies: its geometry
## is read (and cached), shapes are added to the region RID, and the object's
## own body is merged away. One loop iteration of a full rebuild.
## Safe for already-merged objects (a rebuild over the whole tree): their
## stale shape registration is dropped and recreated from the cached geometry.
static func _commit_object(container: Node2D, bodies: Dictionary, object: Node2D) -> void:
	_drop_shared_shapes(object)
	var geometry := _object_geometry(object)
	if geometry.descriptors.is_empty():
		return
	if not MERGEABLE_LAYERS.has(int(geometry.collision_layer)):
		return
	var body_owner := _body_for(
		bodies,
		container,
		int(geometry.collision_layer),
		_chunk_of(object.global_position.x),
	)
	var added := _commit_server_shapes(body_owner, object, geometry.descriptors)
	object.set_meta(SHAPES_META, added)
	_merge_object(object)
	# Native online/static artwork lives in RenderingServer RIDs and this
	# object's authored collision now lives in the shared chunk body. If its
	# groups were dynamic _is_mergeable() would have rejected it above, so the
	# empty GDObject root has no remaining runtime responsibility. Keeping tens
	# of thousands of these roots was pure SceneTree traversal/memory overhead.
	if object.has_meta(&"_gd_native_packed_art"):
		object.free()


## Drops the object's bookkeeping for the previous shared server body. A full
## rebuild/teardown frees those bodies before restoring or re-committing objects.
static func _drop_shared_shapes(object: Node2D) -> void:
	object.remove_meta(SHAPES_META)


## Adds the object's shapes directly to a shared PhysicsServer2D body/area. The
## owner node is only an object-ID bridge so collision reports can be mapped
## back to this RID and its shape indices; there are no physics nodes per shape.
static func _commit_server_shapes(owner: Node2D, source: Node2D, descriptors: Array) -> Array:
	var rid: RID = owner.get_meta(SERVER_RID_META, RID())
	var is_area := bool(owner.get_meta(SERVER_AREA_META, false))
	var shape_data: Array = owner.get_meta(SERVER_SHAPES_META, [])
	var added: Array = []
	if not rid.is_valid():
		return added
	var owner_inverse := owner.global_transform.affine_inverse()
	for descriptor in descriptors:
		var shape: Shape2D = descriptor.get("resource")
		if shape == null or not shape.get_rid().is_valid():
			continue
		var local_transform: Transform2D = (
			owner_inverse
			* source.global_transform
			* descriptor.get("local_xform", Transform2D.IDENTITY)
		)
		if is_area:
			PhysicsServer2D.area_add_shape(rid, shape.get_rid(), local_transform)
		else:
			PhysicsServer2D.body_add_shape(rid, shape.get_rid(), local_transform)
		var index := shape_data.size()
		var entry := {
			"resource": shape,
			"transform": local_transform,
			"debug_color": descriptor.get("debug_color", Color.WHITE),
		}
		shape_data.append(entry)
		added.append(index)
	owner.set_meta(SERVER_SHAPES_META, shape_data)
	return added


static func _is_mergeable(object: Node2D, dynamic_groups: Dictionary) -> bool:
	if object is Interactable or object is DecorationBatch:
		return false
	# Pushable / physics-edited solids animate as bodies; keep them per-object.
	if object is SolidObject and object.physics_object:
		return false
	# Objects moved, rotated or scaled by triggers must keep a body that moves
	# with the node.
	for group in object.get_groups():
		if dynamic_groups.has(group):
			return false
	# A no-touch object never collides; it has nothing to contribute to the
	# shared world (and its own shapes were already disabled by the attribute).
	if _has_attribute(object, "NoTouchAttribute"):
		return false
	return true


static func _has_attribute(object: Node, attribute_name: String) -> bool:
	var attributes: Array = object.get_meta(Constants.ATTRIBUTE_META, [])
	return attribute_name in attributes


## Every Interactable whose trigger group is animated by a move/rotate/scale
## changer contributes its group name; those groups' members keep their bodies.
## TODO(M4): once interactables live in gd scenes as Behaviour children of a
## GDObject root, this must walk those children instead of layer children.
static func _dynamic_transform_groups(level: Level) -> Dictionary:
	var groups := {}
	var remember := func(group_name: String) -> void:
		if group_name.is_empty():
			return
		groups[StringName(group_name)] = true
		# TargetGroupComponent stores either the full "g_<id>" name or just the
		# id depending on where it was filled in; accept both spellings.
		if not group_name.begins_with(Constants.GROUP_PREFIX):
			groups[StringName(Constants.GROUP_PREFIX + group_name)] = true
	for layer in level.layers:
		for object in layer.get_children():
			if not object is Interactable:
				continue
			var interactable := object as Interactable
			var mover := (
				interactable.has(PositionChangerComponent)
				or interactable.has(RotationChangerComponent)
				or interactable.has(ScaleChangerComponent)
			)
			if not mover:
				continue
			var target := interactable.query(TargetGroupComponent)
			if target != null:
				remember.call(target.target_group)
	# Native-only movers (Move 901, Follow 1347, Rotate 1346, Scale 2067) are
	# packed C++ records with no layer node, so the loop above never sees them.
	# Their target group (key 51) still animates members, which must keep their
	# own bodies: a merged body would stay put while the trigger moves the
	# visible decoration - the block the cube stands on would not travel.
	var packed: Dictionary = level.packed_trigger_records
	if not packed.is_empty():
		var ids: PackedInt32Array = packed.get("gd_id", PackedInt32Array())
		for i in ids.size():
			if not ids[i] in NATIVE_MOVER_IDS:
				continue
			var properties: Dictionary = PackedTriggers.row(packed, i).gd_properties
			var target_id := str(properties.get("51", "")).to_int()
			if target_id > 0:
				remember.call(Constants.GROUP_PREFIX + str(target_id))
	# Native-only movers that were not packed (GMDConverter keeps them as plain
	# records) animate their members exactly like packed ones, so they count too.
	# Without this a moved group stays merged into a static body and its
	# collider is left behind while the visible block travels away.
	for record: Dictionary in level.native_trigger_records:
		if not (int(record.get("gd_object_id", 0)) in NATIVE_MOVER_IDS):
			continue
		var record_properties: Dictionary = record.get("gd_properties", { })
		var record_target := str(record_properties.get("51", "")).to_int()
		if record_target > 0:
			remember.call(Constants.GROUP_PREFIX + str(record_target))
	return groups


## Geometry of one placed object, relative to the object root so it survives the
## object being moved, scaled or rotated between rebuilds: {collision_layer,
## descriptors: [{resource, local_xform, debug_color}]}. Cached on the object
## once harvested - the layer must be cached too, because merging zeroes the
## object's own body layers afterwards.
static func _object_geometry(object: Node2D) -> Dictionary:
	if object.has_meta(DESCRIPTORS_META):
		return object.get_meta(DESCRIPTORS_META)
	return NativeCore.backend().call(&"extract_object_geometry", object)


static func _own_body(object: Node2D) -> CollisionObject2D:
	if object is CollisionObject2D:
		return object
	var collision: Node = object.get_node_or_null(NodePath(GDObject.COLLISION_NODE))
	return collision as CollisionObject2D


## Direct CollisionShape2D / CollisionPolygon2D children of a body.
static func _shape_nodes_of(body: Node) -> Array:
	var shapes: Array = []
	for child in body.get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			shapes.append(child)
	return shapes


static func _body_for(
	bodies: Dictionary,
	container: Node2D,
	collision_layer: int,
	chunk_x: int,
) -> Node2D:
	var base_name: String
	var is_area := false
	match collision_layer:
		RECT_HAZARD_LAYER:
			is_area = true
			base_name = "RectHazards"
		CIRCLE_HAZARD_LAYER:
			is_area = true
			base_name = "CircleHazards"
		SLOPE_LAYER:
			# Slopes stay static bodies: the player's kinematic solver collides
			# with them and the extra layer bit remains available to slope queries.
			base_name = "Slopes"
		_:
			base_name = "Solids"
	# The lightweight Node2D is only the server object-ID bridge. Physics bodies,
	# areas and all shapes are allocated through PhysicsServer2D RIDs.
	var key := "%s@%d" % [base_name, chunk_x]
	if bodies.has(key):
		return bodies[key]
	var owner: Node2D = AREA_RID_OWNER_SCRIPT.new() if is_area else BODY_RID_OWNER_SCRIPT.new()
	owner.name = key
	if owner is Area2D:
		# Keep an Area2D identity adapter for existing area_entered callbacks, but
		# disable its empty node-owned RID. The active hazard area is the direct
		# server RID created below.
		(owner as Area2D).monitoring = false
		(owner as Area2D).monitorable = false
		(owner as Area2D).collision_layer = 0
		(owner as Area2D).collision_mask = 0
	owner.set_meta(BODY_META, true)
	owner.set_meta(SERVER_AREA_META, is_area)
	owner.set_meta(SERVER_LAYER_META, collision_layer)
	owner.set_meta(SERVER_SHAPES_META, [])
	container.add_child(owner)
	var rid := PhysicsServer2D.area_create() if is_area else PhysicsServer2D.body_create()
	if is_area:
		PhysicsServer2D.area_set_collision_layer(rid, collision_layer)
		PhysicsServer2D.area_set_collision_mask(rid, 0)
		PhysicsServer2D.area_set_monitorable(rid, true)
		PhysicsServer2D.area_attach_object_instance_id(rid, owner.get_instance_id())
	else:
		PhysicsServer2D.body_set_mode(rid, PhysicsServer2D.BODY_MODE_STATIC)
		PhysicsServer2D.body_set_collision_layer(rid, collision_layer)
		PhysicsServer2D.body_set_collision_mask(rid, 0)
		PhysicsServer2D.body_attach_object_instance_id(rid, owner.get_instance_id())
	owner.set_meta(SERVER_RID_META, rid)
	owner.call("bind_physics_rid", rid)
	bodies[key] = owner
	return owner


static func _chunk_of(world_x: float) -> int:
	return floori(world_x / (CHUNK_CELLS * Constants.CELL_SIZE))


## Neutralises the object's own body and marks the object merged.
##
## A gd-scene body is a [code]Collision[/code] child node: once its geometry is
## harvested into the shared bodies it is freed entirely, because a registered
## physics body still costs a physics-server object (and its tree nodes) even
## with every shape disabled. Hand-made scene roots are the object itself and
## cannot be freed, so those are neutralised in place instead.
static func _merge_object(object: Node2D) -> void:
	if object.has_meta(MERGED_META):
		return
	var body := _own_body(object)
	if body == null:
		# Nothing left to neutralise (a previous merge freed the body child),
		# but the object still belongs to the shared world.
		object.set_meta(MERGED_META, true)
		return
	if body != object:
		_free_child_body(object, body)
		return
	var snapshot := {
		"collision_layer": body.collision_layer,
		"collision_mask": body.collision_mask,
	}
	var shape_states: Array = []
	for shape_node in _shape_nodes_of(body):
		shape_states.append({
			"node": shape_node,
			"disabled": shape_node.disabled,
			"one_shot": false,
		})
		shape_node.disabled = true
	snapshot["shape_states"] = shape_states
	if body is Area2D:
		snapshot["monitoring"] = (body as Area2D).monitoring
		snapshot["monitorable"] = (body as Area2D).monitorable
		(body as Area2D).monitoring = false
		(body as Area2D).monitorable = false
	body.collision_layer = 0
	body.collision_mask = 0
	object.set_meta(SNAPSHOT_META, snapshot)
	object.set_meta(MERGED_META, true)


## Frees a merged object's own body child after its geometry was cached on the
## object (DESCRIPTORS_META). The snapshot carries everything needed to rebuild
## an identical body when the level stops being played.
static func _free_child_body(object: Node2D, body: CollisionObject2D) -> void:
	var is_area := body is Area2D
	var monitoring := true
	var monitorable := true
	if is_area:
		monitoring = (body as Area2D).monitoring
		monitorable = (body as Area2D).monitorable
	var snapshot := {
		"freed": true,
		"area": is_area,
		"body_name": body.name,
		"body_transform": body.transform,
		"collision_layer": body.collision_layer,
		"collision_mask": body.collision_mask,
		"monitoring": monitoring,
		"monitorable": monitorable,
	}
	object.set_meta(SNAPSHOT_META, snapshot)
	object.set_meta(MERGED_META, true)
	body.free()


## Restores an object that was merged earlier but must keep its own body again.
static func _restore_object(object: Node2D) -> void:
	if not object.has_meta(SNAPSHOT_META):
		return
	# Its shapes no longer belong in the shared bodies once it has its own
	# body back.
	_drop_shared_shapes(object)
	var snapshot: Dictionary = object.get_meta(SNAPSHOT_META)
	if snapshot.get("freed", false):
		_rebuild_child_body(object, snapshot)
	else:
		var body := _own_body(object)
		if body != null:
			body.collision_layer = int(snapshot.get("collision_layer", 0))
			body.collision_mask = int(snapshot.get("collision_mask", 0))
			if body is Area2D:
				(body as Area2D).monitoring = bool(snapshot.get("monitoring", true))
				(body as Area2D).monitorable = bool(snapshot.get("monitorable", true))
			for entry: Dictionary in snapshot.get("shape_states", []):
				var shape_node: CollisionShape2D = entry.get("node")
				if is_instance_valid(shape_node):
					shape_node.disabled = bool(entry.get("disabled", false))
	object.remove_meta(SNAPSHOT_META)
	object.remove_meta(MERGED_META)
	object.remove_meta(DESCRIPTORS_META)


## Recreates the Collision body a freed merged object lost, from the geometry
## cached at merge time (DESCRIPTORS_META). The body is identical in type,
## name, transform, layers and shapes, so the object is fully editable again.
static func _rebuild_child_body(object: Node2D, snapshot: Dictionary) -> void:
	var geometry := _object_geometry(object)
	var body: CollisionObject2D = Area2D.new() if snapshot.get("area", false) else StaticBody2D.new()
	body.name = str(snapshot.get("body_name", "Collision"))
	body.transform = snapshot.get("body_transform", Transform2D.IDENTITY)
	body.collision_layer = int(snapshot.get("collision_layer", 0))
	body.collision_mask = int(snapshot.get("collision_mask", 0))
	if body is Area2D:
		(body as Area2D).monitoring = bool(snapshot.get("monitoring", true))
		(body as Area2D).monitorable = bool(snapshot.get("monitorable", true))
	for descriptor in geometry.get("descriptors", []):
		var shape_node := CollisionShape2D.new()
		shape_node.shape = descriptor.resource
		shape_node.debug_color = descriptor.debug_color
		shape_node.transform = descriptor.local_xform
		body.add_child(shape_node)
	object.add_child(body)


## Whether [param collider] is one of the level's shared server objects.
static func is_shared_body(collider: Node) -> bool:
	return collider != null and collider.has_meta(BODY_META) and collider.has_meta(SERVER_RID_META)


## Per-shape metadata for a collision reported by a shared server RID.
static func shared_shape_data(collider: Node, shape_index: int) -> Dictionary:
	if not is_shared_body(collider):
		return {}
	var shape_data: Array = collider.get_meta(SERVER_SHAPES_META, [])
	if shape_index < 0 or shape_index >= shape_data.size():
		return {}
	return shape_data[shape_index]


## Disables the precise shape hit by the player, preserving the spider-dash
## pass-through behavior without requiring a CollisionShape2D node.
static func disable_shared_shape(collider: Node, shape_index: int) -> bool:
	if not is_shared_body(collider):
		return false
	var shape_data := shared_shape_data(collider, shape_index)
	if shape_data.is_empty():
		return false
	# Collision handling runs inside the physics callback. Defer the server
	# mutation just like the former CollisionShape2D.set_deferred call.
	if collider.has_method("set_server_shape_disabled"):
		collider.call_deferred("set_server_shape_disabled", shape_index, true)
		return true
	return false
