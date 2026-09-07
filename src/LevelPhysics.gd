class_name LevelPhysics
extends Object
## Builds and owns the level's shared static collision geometry.
##
## Instead of letting every placed static object carry its own physics body
## (one RigidBody2D/Area2D per block, spike or saw), the level collects their
## shapes into a small fixed set of bodies that live for the whole level:
##
##   LevelPhysics (Node2D, child of the Level)
##   ├── Solids            StaticBody2D, layer 2 (blocks)
##   ├── Slopes            StaticBody2D, layers 2+7 (slopes keep the
##   │                     slope_enabler bit the player queries)
##   ├── RectHazards       Area2D, layer 3 (spikes, ground spikes)
##   └── CircleHazards     Area2D, layer 12 (saws)
##
## A body's collision layer is a per-body property, and bodies are chunked by
## horizontal region (CHUNK_CELLS wide), so a level is a grid of (layer, chunk)
## bodies; the four layers above are the only ones the old level-component
## scenes used. Chunking keeps each body's shape list local to its region -
## otherwise a big level's one body per layer would be tested shape-by-shape on
## every player query.
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
## Metadata key set on every shared body node.
const BODY_META: StringName = &"_gd_level_physics_body"
## Metadata keys stored on merged source objects.
const MERGED_META: StringName = &"_gd_level_physics_merged"
const SNAPSHOT_META: StringName = &"_gd_level_physics_snapshot"
const DESCRIPTORS_META: StringName = &"_gd_level_physics_descriptors"
## Metadata key on the Level: whether a rebuild is needed before next play.
const DIRTY_META: StringName = &"_gd_level_physics_dirty"
## Metadata key on merged objects: the CollisionShape2D children this object
## contributed to the shared bodies. Lets a streamed chunk be removed (or an
## object restored) by freeing exactly its shapes, without touching the rest.
const SHAPES_META: StringName = &"_gd_level_physics_shapes"
## Metadata key on the Level: the trigger-group set the last merge decision was
## made against. When a new move/rotate/scale trigger enters the live window,
## its group's merged members must get their own bodies back before it fires.
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


## Clears the dirty flag. LevelStream keeps the shared bodies exactly in sync
## with the live window (commit adds a chunk's shapes, release removes them),
## so the tree churn of spawning/freeing chunks must not force a full rebuild
## on the next attempt.
static func clear_dirty(level: Level) -> void:
	level.set_meta(DIRTY_META, false)


## Called every time a level starts playing (each attempt). Rebuilds the shared
## state when the level changed since last time; otherwise just re-enables
## shapes that gameplay disabled during the previous attempt.
static func prepare(level: Level) -> void:
	if is_dirty(level):
		rebuild(level)
		level.set_meta(DIRTY_META, false)
		return
	_reenable_shapes(level)


static func _reenable_shapes(level: Level) -> void:
	var container := level.get_node_or_null(CONTAINER_NAME)
	if container == null:
		return
	for body in container.get_children():
		for shape in _shape_nodes_of(body):
			if shape.disabled:
				shape.disabled = false


## Undoes merging and frees the shared bodies. Called when a level stops being
## played and its objects go back to being editable: editor playtest stop and
## leaving a level. Between attempts the shared bodies stay and prepare() only
## refreshes them, so this runs once per session, not per attempt.
static func teardown(level: Level) -> void:
	if level == null:
		return
	for layer in level.layers:
		for object: Node2D in layer.get_children():
			if object.has_meta(MERGED_META):
				_restore_object(object)
	var container := level.get_node_or_null(CONTAINER_NAME)
	if container != null:
		container.free()
	level.remove_meta(DYNAMIC_META)
	level.set_meta(DIRTY_META, true)


## Frees and rebuilds the shared bodies from the current object tree. Used by
## non-streamed levels (full rebuild each time the tree changed) and by a
## streamed level's first start; afterwards LevelStream only commits and
## releases chunk deltas onto the persistent bodies.
static func rebuild(level: Level) -> void:
	var container := _container(level)
	for child in container.get_children():
		child.free()

	var dynamic_groups := _dynamic_transform_groups(level)
	# Shared bodies are chunked by horizontal region, so the physics broadphase
	# only ever sees the chunks near the player instead of one body whose shape
	# list spans the whole level (a huge single body would be tested in full on
	# every player query and grind large levels to a halt).
	var bodies: Dictionary[String, CollisionObject2D] = {}

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


## Adds the collision of every node in [param nodes] to the shared bodies.
##
## This is the streaming equivalent of a full rebuild for one chunk: the
## existing shared bodies stay untouched, only the chunk's shapes are appended
## to them (and the objects' own bodies are merged away as usual). Because the
## bodies persist, nothing else in the world is recreated and the player's
## contacts are undisturbed.
static func commit(level: Level, nodes: Array) -> void:
	if nodes.is_empty():
		return
	var dynamic_groups := _dynamic_transform_groups(level)
	var known: Dictionary = level.get_meta(DYNAMIC_META, {})
	if not _dynamic_groups_equal(known, dynamic_groups):
		# A trigger entered the live window and made a group dynamic; merged
		# members of the newly dynamic groups get their own bodies back before
		# anything new is committed, so a trigger never animates a body that
		# belongs to the shared world.
		level.set_meta(DYNAMIC_META, dynamic_groups)
		_restore_dynamic_members(level, known, dynamic_groups)
	var container := _container(level)
	var bodies := _bodies_of(container)
	for object: Node2D in nodes:
		if object is DecorationBatch or object is Interactable:
			continue
		if not _is_mergeable(object, dynamic_groups):
			continue
		_commit_object(container, bodies, object)
	clear_dirty(level)


## Removes the shared shapes of every node in [param nodes]. Call before the
## nodes themselves are freed (a streamed chunk dropping out of the window).
## The owning shared bodies persist; only the chunk's own shapes are freed.
static func release(level: Level, nodes: Array) -> void:
	for object: Node2D in nodes:
		_drop_shared_shapes(object)
	clear_dirty(level)


## Existing shared bodies, keyed by node name.
static func _bodies_of(container: Node2D) -> Dictionary:
	var bodies: Dictionary = {}
	for child in container.get_children():
		if child is CollisionObject2D and child.has_meta(BODY_META):
			bodies[child.name] = child
	return bodies


## Harvests one mergeable object into the shared bodies: its geometry is read
## (and cached), shape nodes are added under the region's body, and the
## object's own body is merged away. Exactly what one loop iteration of a full
## rebuild does, minus the rebuild. Safe for already-merged objects (a full
## rebuild over previously committed chunks): their stale shape registration
## is dropped and recreated from the cached geometry.
static func _commit_object(container: Node2D, bodies: Dictionary, object: Node2D) -> void:
	_drop_shared_shapes(object)
	var geometry := _object_geometry(object)
	if geometry.descriptors.is_empty():
		return
	if not MERGEABLE_LAYERS.has(int(geometry.collision_layer)):
		return
	var body := _body_for(
			bodies, container, int(geometry.collision_layer),
			_chunk_of(object.global_position.x),
	)
	var added: Array = []
	for descriptor in geometry.descriptors:
		var shape_node: CollisionShape2D = CollisionShape2D.new()
		shape_node.shape = descriptor.resource
		shape_node.debug_color = descriptor.debug_color
		body.add_child(shape_node)
		# Position the shape where the source shape is in the world: body is at
		# the container's origin (identity), so applying the object's own global
		# transform reproduces the shape exactly, including the object's scale,
		# rotation and flip.
		shape_node.global_transform = object.global_transform * descriptor.local_xform
		added.append(shape_node)
	object.set_meta(SHAPES_META, added)
	_merge_object(object)


## Frees the shape nodes an object contributed to the shared bodies.
static func _drop_shared_shapes(object: Node2D) -> void:
	var shapes: Array = object.get_meta(SHAPES_META, [])
	if not shapes.is_empty():
		for shape_node in shapes:
			if is_instance_valid(shape_node):
				shape_node.free()
	object.remove_meta(SHAPES_META)


static func _dynamic_groups_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for group: StringName in a:
		if not b.has(group):
			return false
	return true


## Restores merged live objects whose group turned dynamic since the last
## merge decision. Only the objects in the newly dynamic groups are touched.
static func _restore_dynamic_members(level: Level, known: Dictionary, current: Dictionary) -> void:
	var newly_dynamic: Array = []
	for group: StringName in current:
		if not known.has(group):
			newly_dynamic.append(group)
	if newly_dynamic.is_empty():
		return
	for layer in level.layers:
		for object: Node2D in layer.get_children():
			if not object.has_meta(MERGED_META):
				continue
			for group: StringName in object.get_groups():
				if group in newly_dynamic:
					_restore_object(object)
					break


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
	return groups


## Geometry of one placed object, relative to the object root so it survives the
## object being moved, scaled or rotated between rebuilds: {collision_layer,
## descriptors: [{resource, local_xform, debug_color}]}. Cached on the object
## once harvested - the layer must be cached too, because merging zeroes the
## object's own body layers afterwards.
static func _object_geometry(object: Node2D) -> Dictionary:
	if object.has_meta(DESCRIPTORS_META):
		return object.get_meta(DESCRIPTORS_META)
	var geometry := {
		"collision_layer": 0,
		"descriptors": [],
	}
	var body := _own_body(object)
	if body == null:
		return geometry
	geometry.collision_layer = int(body.collision_layer)
	var descriptors: Array = []
	var inverse := object.global_transform.affine_inverse()
	for shape_node in _shape_nodes_of(body):
		if shape_node.shape == null:
			continue
		descriptors.append({
			"resource": shape_node.shape,
			"local_xform": inverse * shape_node.global_transform,
			"debug_color": shape_node.debug_color,
		})
	geometry.descriptors = descriptors
	if not descriptors.is_empty():
		object.set_meta(DESCRIPTORS_META, geometry)
	return geometry


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
) -> CollisionObject2D:
	var body: CollisionObject2D = StaticBody2D.new()
	var base_name: String
	match collision_layer:
		RECT_HAZARD_LAYER:
			body = Area2D.new()
			body.collision_layer = RECT_HAZARD_LAYER
			base_name = "RectHazards"
		CIRCLE_HAZARD_LAYER:
			body = Area2D.new()
			body.collision_layer = CIRCLE_HAZARD_LAYER
			base_name = "CircleHazards"
		SLOPE_LAYER:
			body = Area2D.new()
			body.collision_layer = SLOPE_LAYER
			base_name = "Slopes"
		_:
			body.collision_layer = SOLID_LAYER
			base_name = "Solids"
	# Keys and names are the body name: a persistent body set must be findable
	# by name when chunks are added incrementally (see commit).
	var key := "%s@%d" % [base_name, chunk_x]
	if bodies.has(key):
		return bodies[key]
	body.name = key
	body.collision_mask = 0
	body.set_meta(BODY_META, true)
	container.add_child(body)
	bodies[key] = body
	return body

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


## Whether [param collider] is one of the level's shared bodies.
static func is_shared_body(collider: Node) -> bool:
	return collider is CollisionObject2D and collider.has_meta(BODY_META)
