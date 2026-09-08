class_name LevelBatching
extends Object
## Batches the *drawing* of static object placements during play, without
## taking the placements away.
##
## Real Geometry Dash levels place the same block, spike or decoration
## thousands of times. A node per placement is still needed for editing,
## colour channels, serialization and (for gameplay objects) the shared
## collision harvest, but drawing each placement as its own CanvasItem costs a
## render-server item and draw entry per sprite. RobTop-style batching instead
## renders repeated copies from shared batches: each gd_object placement stays
## exactly where it is, but its art is hidden while it is drawn by a
## [DecorationBatch] shared with every other placement that shares its z layer
## and group fate.
##
## When this runs:
##   - prepare() at every level start (play attempt). The first time it builds
##     the batches from the placements' own data ([method GDObject.to_data])
##     and hides the placements' art; afterwards it only re-hides placements
##     that an attempt reset showed again. Batches persist across attempts.
##   - teardown() when the level stops being played (editor playtest stop,
##     leaving the level): batches are freed and every placement's art comes
##     back, so editing is unaffected.
##
## What is batched: [GDObject] placements nothing can move or toggle
## individually - no Geometry Dash group (a trigger could address it), no
## built-in spin (the node animates its own transform), no physics, no
## texture override. Everything else keeps drawing per-node, exactly as a
## trigger or the physics system expects. Decoration nodes that exist in a
## live edited level (editor playtest) and static gameplay gd scenes both go
## through the same path.

## Set on the Level while its batching is active (once per play session).
const LEVEL_META: StringName = &"_gd_level_batching_active"
## Set on placements whose art is currently hidden and drawn by a batch.
const OBJECT_META: StringName = &"_gd_level_batched_object"
## Set on the DecorationBatch nodes this manager created, so teardown frees
## exactly those and leaves level-decoration batches alone.
const BATCH_META: StringName = &"_gd_level_batched_batch"


## Called from Level.start_level before the player moves. Builds the batches
## once per play session; later attempts just re-hide placements that the
## attempt reset showed again.
static func prepare(level: Level) -> void:
	# TEMPORARY DIAGNOSTIC: plain play draws every placement's own scene art
	# (see Config.DIAGNOSTIC_NO_OPTIMIZATIONS).
	if Config.diagnostic_plain_play():
		return
	var active: bool = bool(level.get_meta(LEVEL_META, false))
	if not active:
		_build(level)
		level.set_meta(LEVEL_META, true)
		return
	# A practice/attempt reset calls use_data(), which shows every placement
	# again; re-hide the batched ones so they do not double-draw.
	for layer in level.layers:
		for child in layer.get_children():
			if child.has_meta(OBJECT_META) and child.visible:
				child.visible = false


## Builds one shared batch set per layer for every batchable placement in it,
## then hides those placements' art.
static func _build(level: Level) -> void:
	if level.layers.is_empty():
		return
	for layer in level.layers:
		var placements: Array = []
		var objects: Array[GDObject] = []
		for child in layer.get_children():
			var object := child as GDObject
			if object == null or not _is_batchable(object):
				continue
			# The placement's own data - transform, colour channels, tint,
			# glow, z - exactly as it currently stands. The batch builder
			# registers the item on its channel groups, so a colour trigger
			# repaints it together with the per-node watchers.
			var entry := object.to_data()
			if entry.is_empty():
				continue
			# Whether to show an object in low detail mode was decided when the
			# node was created (gameplay objects are never dropped, and in the
			# editor nothing is); do not let the batch builder drop it again.
			entry.erase("high_detail")
			placements.append(entry)
			objects.append(object)
		if placements.is_empty():
			continue
		for batch: DecorationBatch in GDDecorationLoader.build_batches(
				placements, GDDecorationLoader.art_scale()
		):
			batch.set_meta(BATCH_META, true)
			batch.set_meta(Constants.LAYER_META, layer)
			layer.add_child(batch)
		for object: GDObject in objects:
			object.visible = false
			object.set_meta(OBJECT_META, true)


## A placement is batchable when nothing can drive it individually, so hiding
## its art and drawing it from a shared batch is invisible to gameplay.
static func _is_batchable(object: GDObject) -> bool:
	if object.has_meta(Constants.TEXTURE_OVERRIDE_META):
		return false
	# Hidden placements stay hidden; only what would otherwise draw is batched.
	if not object.is_visible_in_tree():
		return false
	# A spinning object rotates its own transform each frame.
	if not is_zero_approx(object.spin):
		return false
	# Any Geometry Dash group can be driven by a Move/Rotate/Scale/Alpha/Toggle
	# trigger, so its placement must keep drawing itself.
	for group: StringName in object.get_groups():
		if str(group).begins_with(Constants.GROUP_PREFIX):
			return false
	return true


## Restores every placement's art and frees the batches this manager created.
## Called when the level stops being played, so the editor is unaffected.
static func teardown(level: Level) -> void:
	if level == null:
		return
	if not bool(level.get_meta(LEVEL_META, false)):
		return
	for layer in level.layers:
		var batches: Array = []
		for child in layer.get_children():
			if child.has_meta(BATCH_META):
				batches.append(child)
			if child.has_meta(OBJECT_META):
				child.visible = true
				child.remove_meta(OBJECT_META)
		for batch: Node in batches:
			batch.free()
	level.remove_meta(LEVEL_META)
