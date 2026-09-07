class_name LevelStream
extends Node
## Builds gameplay placements the way Geometry Dash does: the level's object
## records stay resident as data, and actual scene nodes only exist for a
## window around the player.
##
## A GD level never instantiates every object - it keeps a compact list of
## every object's fields and creates display nodes only for the section the
## camera is in. Copying that here is what lets a very large level (hundreds of
## thousands of objects) open and play on a phone: the memory cost stops
## scaling with the whole level.
##
## What lives in this window: every non-decoration placement (blocks, slopes,
## spikes, saws, orbs, pads, portals, triggers...). Decoration was already
## reduced to lightweight batch records by DecorationBatch, so it stays
## resident like the data does.
##
## How GD avoids hitches - and how this mirrors it:
##  - GD never creates objects while the game is running; it pays the cost up
##    front, behind a loading screen. This windowed level cannot keep every
##    node on a phone, so all window work is *sliced* instead of burst:
##    every live frame takes only a small number of node instantiations,
##    physics-shape additions and node frees, and the AHEAD_CHUNKS margin
##    (several seconds of travel) means each slice is invisible. No frame
##    ever commits or tears down a whole chunk at once.
##  - GD respawns after a fixed pause and only *resets* its objects in place -
##    it never rebuilds the level. Our whole 1-second death animation is a
##    free loading window: as soon as the player dies, the stream tears the
##    old window down and builds the respawn window on generous per-frame
##    budgets, so when the attempt restarts there is almost nothing left to
##    do - the same spot GD hides its own per-attempt work.
##  - GD never recreates its physics world per chunk. Chunk shapes are
##    committed to and released from persistent shared bodies
##    (LevelPhysics.commit/release) at a per-frame slice, so the player's
##    physics world is never churned in a burst mid-run.
##
## Respawning after death rebuilds the window from the records, which also
## resets every one-shot object exactly as GD respawns do.

## Width of one streamed chunk, in cells. Kept to a few screens so the number
## of live nodes stays small.
const CHUNK_CELLS := 12
## Chunks kept spawned behind the player.
const BEHIND_CHUNKS := 3
## Chunks kept spawned ahead of the player (objects scroll in here, so this is
## generous - like GD, nothing should ever pop in).
const AHEAD_CHUNKS := 8
## Chunks behind the player beyond which live nodes are freed. Must exceed
## BEHIND_CHUNKS so chunks are not spawned and freed every frame.
const FREE_BEHIND_CHUNKS := 12
## How many chunks ahead of the start position are spawned synchronously while
## the level opens (the loading moment). Everything else in the window drains
## on the per-frame budget once the attempt runs. Kept tiny so opening a level
## never allocates its whole window at once.
const START_SPAN_CHUNKS := 2

## Per-frame node instantiation budget while the level is actually playing.
## Slicing is what keeps a dense section from landing in one frame; each frame
## this many nodes (split across however many chunks are pending) are created.
const PLAY_SPAWN_BUDGET := 48
## Per-frame budget of nodes whose shapes join the shared physics bodies.
const PLAY_COMMIT_BUDGET := 80
## Per-frame node teardown budget for chunks left behind.
const PLAY_FREE_BUDGET := 300
## Per-frame budgets during the death animation (a hidden loading window, the
## same way GD uses its respawn pause).
const PRELOAD_SPAWN_BUDGET := 600
const PRELOAD_COMMIT_BUDGET := 700
const PRELOAD_FREE_BUDGET := 1000
## A chunk this close to the player that is still missing is finished in one
## frame instead of being budgeted. With AHEAD_CHUNKS of margin the budget
## drains everything long before it gets this close, so this only fires when a
## drain fell behind (pathological density) - it guarantees the ground under
## the player always exists.
const FORCE_DISTANCE_CHUNKS := 0

## Set on the Level while its gameplay placements are streamed.
const STREAMING_META: StringName = &"_gd_level_streaming"

var level: Level
## Per layer index: chunk id -> Array of object-data entries.
var _chunk_entries: Array = []
## Fully spawned live chunks: "layer/chunk" -> chunk record Dictionary
## {nodes: Array[Node2D], phys: int, key: String}. phys counts how many of the
## node's shapes have been committed to the shared bodies.
var _spawned: Dictionary = {}
## Chunks waiting to spawn. Each entry is a Dictionary with the spawning
## cursor so a chunk is sliced across many frames.
var _spawn_queue: Array = []
## Spawned chunks whose shapes have not all joined the shared bodies yet
## (FIFO). Each entry is the chunk record; phys advances on a per-frame budget.
var _phys_queue: Array = []
## Chunks waiting to be freed, each entry carries a free cursor. Shapes are
## released and nodes freed together, in slices.
var _free_queue: Array = []
var _last_player_chunk: int = -0x7fffffff
## True between the player's death and the attempt restart, while the respawn
## window is being preloaded on the death-animation budget.
var _preloading := false
## Respawn chunk the preload is building towards.
var _preload_chunk: int = -0x7fffffff
## Set when a chunk finished spawning: its nodes' HSV watchers were added
## after the level's ColorChannelWatchers already ran their one-shot colour
## pass, so the current channel colours must be pushed into them.
var _refresh_pending := false
## Scene paths handed to ResourceLoader's worker threads; drained once loaded.
var _prefetch_pending: Dictionary = {}
## Frames after a manual (non-death) restart during which the play budgets are
## multiplied, so a freshly built window catches up quickly after the
## synchronous teardown. Death restarts do not need it: the death animation
## already preloaded the new window.
var _boost_frames := 0
## Set true during device tuning to draw a small stats readout (FPS, live
## nodes, queue depths, stream time budget) in the top-left corner. Leave on
## until the remaining Android issues are measured, then set false.
const SHOW_STATS := true
var _stats_label: Label
var _stats_timer := 0.0
var _last_drain_ms := 0.0


static func is_streaming(level: Level) -> bool:
	return level != null and bool(level.get_meta(STREAMING_META, false))


## Where the player respawns after death: the last practice checkpoint when
## practising, otherwise the level start. Kept in sync with
## GameScene.restart_level so preloading builds the right window.
static func respawn_x_for(level: Level) -> float:
	var x: float = level.start_position.x
	if LevelManager.practice_mode and not LevelManager.practice_level_snapshots.is_empty():
		var snapshot: Dictionary = LevelManager.practice_level_snapshots[-1]
		if snapshot.has("practice_data") and snapshot.has("start_position"):
			x = (snapshot.start_position as Vector2).x
	return x


static func make(level: Level, data: Dictionary) -> LevelStream:
	var stream := LevelStream.new()
	stream.level = level
	stream.name = "LevelStream"
	stream._index(data)
	level.set_meta(STREAMING_META, true)
	level.add_child(stream, false, INTERNAL_MODE_BACK)
	if SHOW_STATS:
		stream._setup_stats()
	# Only the start region is built here at load time (masked by the level's
	# own loading); the rest of the window drains on the per-frame budget once
	# the attempt runs. The first start_level builds the shared physics from
	# whatever this spawns (see Level.start_level).
	stream._initial_spawn(data.start_position.x)
	return stream


## Splits each layer's object data into horizontal chunks by the placement's
## x. Entries are kept as references into the source level data.
func _index(data: Dictionary) -> void:
	var layers_data: Array = data.get("layers", [])
	_chunk_entries.resize(layers_data.size())
	for layer_idx: int in layers_data.size():
		var by_chunk: Dictionary = {}
		for entry: Dictionary in layers_data[layer_idx].get("objects", []):
			if entry.get("decoration", false):
				continue
			var x: float = entry.get("transform", Transform2D.IDENTITY).origin.x
			var chunk := _chunk_of(x)
			if not by_chunk.has(chunk):
				by_chunk[chunk] = []
			by_chunk[chunk].append(entry)
		_chunk_entries[layer_idx] = by_chunk


func _chunk_of(world_x: float) -> int:
	return floori(world_x / (CHUNK_CELLS * Constants.CELL_SIZE))


func _chunk_key(layer_idx: int, chunk: int) -> String:
	return "%d/%d" % [layer_idx, chunk]


func _setup_stats() -> void:
	var layer := CanvasLayer.new()
	layer.name = "StreamStatsLayer"
	layer.layer = 100
	_stats_label = Label.new()
	_stats_label.position = Vector2(8, 8)
	_stats_label.add_theme_font_size_override("font_size", 14)
	layer.add_child(_stats_label)
	level.add_child(layer)


func _update_stats(delta: float) -> void:
	_stats_timer += delta
	if _stats_timer < 0.25:
		return
	_stats_timer = 0.0
	var live := 0
	for rec: Dictionary in _spawned.values():
		live += (rec.nodes as Array).size()
	var pending_spawn := 0
	for item: Dictionary in _spawn_queue:
		pending_spawn += (item.entries as Array).size() - int(item.index)
	var pending_free := 0
	for item: Dictionary in _free_queue:
		pending_free += ((item.rec as Dictionary).nodes as Array).size() - int(item.index)
	var pending_commit := 0
	for rec: Dictionary in _phys_queue:
		pending_commit += (rec.nodes as Array).size() - int(rec.phys)
	var mem_mb: float = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	_stats_label.text = (
		"FPS %d  live %d  stream %0.1fms  |  spawn %d  commit %d  free %d  |  mem %.0fMB"
		% [
			int(Engine.get_frames_per_second()),
			live,
			_last_drain_ms,
			pending_spawn,
			pending_commit,
			pending_free,
			mem_mb,
		]
	)


func _process(_delta: float) -> void:
	if SHOW_STATS and _stats_label != null:
		_update_stats(_delta)
	if not LevelManager.level_playing:
		return
	_settle_prefetches()
	var player: Player = LevelManager.player
	if player == null:
		return
	if player.dead:
		_preload_tick()
		return
	var player_chunk := _chunk_of(player.global_position.x)
	if player_chunk != _last_player_chunk:
		_last_player_chunk = player_chunk
		_reconcile_window(player_chunk)
	# Whatever is missing inside the window (left over from a restart or from a
	# chunk that just finished tearing down) gets enqueued every frame - the
	# scan is a handful of dict lookups.
	_enqueue_missing_window(player_chunk)
	var spawn_budget: int = PLAY_SPAWN_BUDGET
	var commit_budget: int = PLAY_COMMIT_BUDGET
	if _boost_frames > 0:
		_boost_frames -= 1
		spawn_budget *= 4
		commit_budget *= 4
	var started_usec: int = Time.get_ticks_usec()
	_drain(spawn_budget, commit_budget, PLAY_FREE_BUDGET, player_chunk, true)
	_last_drain_ms = (Time.get_ticks_usec() - started_usec) / 1000.0


## The per-frame worker: spawns, physics-shape commits and node frees all run
## here in small slices, never in a burst on a live gameplay frame. GD has no
## equivalent mid-run loop because it never creates objects while playing -
## the slices are how a windowed level gets the same effect.
func _drain(spawn_budget: int, commit_budget: int, free_budget: int, player_chunk: int, allow_force: bool) -> void:
	var changed := false
	changed = _tick_frees(free_budget) or changed
	changed = _tick_spawns(spawn_budget, player_chunk, allow_force) or changed
	changed = _tick_physics(commit_budget) or changed
	# Chunk spawns/frees churn the layer's children, which the level tracks as
	# a physics invalidation; the shared bodies were updated incrementally, so
	# clear that so the next prepare() does not needlessly full-rebuild.
	if changed:
		LevelPhysics.clear_dirty(level)
	if _refresh_pending:
		_refresh_pending = false
		_refresh_new_node_colors()


func _tick_frees(budget: int) -> bool:
	var changed := false
	while budget > 0 and not _free_queue.is_empty():
		var item: Dictionary = _free_queue[0]
		var rec: Dictionary = item.rec
		var nodes: Array = rec.nodes
		var index: int = item.index
		var to_free: int = mini(budget, nodes.size() - index)
		var batch: Array = []
		for i: int in range(index, index + to_free):
			var node: Node2D = nodes[i]
			if is_instance_valid(node):
				batch.append(node)
		if not batch.is_empty() and level.is_inside_tree():
			# The shared-body shapes leave first, then the nodes die: a node
			# never lingers with its shape still registered in a shared body.
			LevelPhysics.release(level, batch)
		for i: int in range(index, index + to_free):
			var node: Node2D = nodes[i]
			if is_instance_valid(node):
				node.free()
		item.index = index + to_free
		changed = true
		budget -= to_free
		if int(item.index) >= nodes.size():
			_free_queue.pop_front()
			_spawned.erase(item.key)
	return changed


## Spawns nodes on the budget, shared fairly across every pending chunk so one
## dense chunk cannot starve the rest of the window.
func _tick_spawns(budget: int, player_chunk: int, allow_force: bool) -> bool:
	var active := 0
	for item: Dictionary in _spawn_queue:
		if int(item.index) < (item.entries as Array).size():
			active += 1
	if active == 0:
		return false
	var share := maxi(1, budget / active)
	var changed := false
	var qi := 0
	while qi < _spawn_queue.size() and budget > 0:
		var item: Dictionary = _spawn_queue[qi]
		var entries: Array = item.entries
		if int(item.index) >= entries.size():
			_spawn_queue.remove_at(qi)
			_register_spawned(item)
			changed = true
			continue
		var remaining: int = entries.size() - int(item.index)
		var to_spawn: int = mini(share, remaining)
		if allow_force and int(item.chunk) <= player_chunk + FORCE_DISTANCE_CHUNKS:
			# The chunk under the player cannot wait on the budget.
			to_spawn = remaining
		if to_spawn > 0:
			_spawn_slice(item, to_spawn)
			item.index = int(item.index) + to_spawn
			changed = true
			budget -= to_spawn
		if int(item.index) >= entries.size():
			_spawn_queue.remove_at(qi)
			_register_spawned(item)
			continue
		qi += 1
	return changed


## Commits finished chunks' shapes to the shared bodies at a per-frame slice,
## so physics additions never arrive in a whole-chunk burst.
func _tick_physics(budget: int) -> bool:
	var changed := false
	while budget > 0 and not _phys_queue.is_empty():
		var rec: Dictionary = _phys_queue[0]
		if not _spawned.has(rec.key):
			# The chunk was freed before its shapes were committed; nothing to
			# add (its nodes are gone with it).
			_phys_queue.pop_front()
			continue
		var nodes: Array = rec.nodes
		var remaining: int = nodes.size() - int(rec.phys)
		if remaining <= 0:
			_phys_queue.pop_front()
			continue
		var count: int = mini(budget, remaining)
		var batch: Array = []
		for i: int in range(int(rec.phys), int(rec.phys) + count):
			var node: Node2D = nodes[i]
			if is_instance_valid(node) and node.is_inside_tree():
				batch.append(node)
		rec.phys = int(rec.phys) + count
		if not batch.is_empty():
			LevelPhysics.commit(level, batch)
			changed = true
		budget -= count
		if int(rec.phys) >= nodes.size():
			_phys_queue.pop_front()
	return changed


## Spawns [param count] objects of a queued chunk and slots them under the
## layer, ahead of its DecorationBatch children so decoration keeps drawing
## above gameplay as in a full build.
func _spawn_slice(item: Dictionary, count: int) -> void:
	var rec: Dictionary = item.rec
	var entries: Array = item.entries
	var layer: Layer = level.layers[item.layer_idx]
	var insert_at: int = item.insert_at
	for i: int in range(int(item.index), int(item.index) + count):
		var entry: Dictionary = entries[i]
		var object: Node2D = Level.instantiate_object_from_data(entry, level)
		if object == null:
			continue
		object.set_meta(Constants.LAYER_META, layer)
		layer.add_child(object)
		layer.move_child(object, insert_at)
		insert_at += 1
		# Configures groups, colour channels, attributes, components - the same
		# per-object pass the editor's full build runs.
		Level.deserialize_data_to_object(entry, object, level, true)
		(item.rec as Dictionary).nodes.append(object)


func _register_spawned(item: Dictionary) -> void:
	var rec: Dictionary = item.rec
	_spawned[item.key] = rec
	if not (rec.nodes as Array).is_empty() and not _key_in_queue(_phys_queue, item.key):
		_phys_queue.append(rec)
	_refresh_pending = true


func _make_spawn_item(layer_idx: int, chunk: int, entries: Array, key: String, rec: Dictionary) -> Dictionary:
	var layer: Layer = level.layers[layer_idx]
	# Gameplay nodes draw under the decoration batches of the same z layer (the
	# order a full build uses): batches were added first, so new gameplay nodes
	# slot in right before the first batch, after any already spawned gameplay.
	var insert_at := 0
	var found_batch := false
	for child in layer.get_children():
		if child is DecorationBatch:
			found_batch = true
			break
		insert_at += 1
	if not found_batch:
		# Pure gameplay layer: gameplay fills the layer, append at its end.
		insert_at = layer.get_child_count()
	return {
		"key": key,
		"layer_idx": layer_idx,
		"chunk": chunk,
		"entries": entries,
		"index": 0,
		"insert_at": insert_at,
		"rec": rec,
	}


func _key_in_queue(queue: Array, key: String) -> bool:
	for item: Dictionary in queue:
		if item.key == key:
			return true
	return false


## Enqueues a live chunk's nodes for freeing, in slices. A key is never in
## more than one of {live, free queue, spawn queue}.
func _enqueue_free(key: String) -> void:
	if not _spawned.has(key) or _key_in_queue(_free_queue, key):
		return
	var rec: Dictionary = _spawned[key]
	_free_queue.append({"key": key, "rec": rec, "index": 0})


## Reconciles the live window with the player's chunk: far-behind chunks are
## queued for freeing.
func _reconcile_window(player_chunk: int) -> void:
	for key: String in _spawned.keys():
		var parts := key.split("/")
		var chunk := int(parts[1])
		if chunk < player_chunk - FREE_BEHIND_CHUNKS:
			_enqueue_free(key)


## Enqueues every window chunk that is neither live nor queued. Cheap enough
## to run every frame.
func _enqueue_missing_window(player_chunk: int) -> void:
	for layer_idx: int in level.layers.size():
		var by_chunk: Dictionary = _chunk_entries[layer_idx]
		for chunk: int in range(player_chunk - BEHIND_CHUNKS, player_chunk + AHEAD_CHUNKS + 1):
			if not by_chunk.has(chunk):
				continue
			var key := _chunk_key(layer_idx, chunk)
			if _spawned.has(key) or _key_in_queue(_spawn_queue, key) or _key_in_queue(_free_queue, key):
				continue
			_enqueue_spawn_near(layer_idx, chunk, by_chunk[chunk] as Array, key, player_chunk)


func _enqueue_spawn_near(layer_idx: int, chunk: int, entries: Array, key: String, near_chunk: int) -> void:
	var rec := {"nodes": [], "phys": 0, "key": key}
	var item := _make_spawn_item(layer_idx, chunk, entries, key, rec)
	# Nearest chunks first (what the run needs soonest); the per-frame share
	# below still stops any single chunk from hogging the budget.
	var distance := absi(chunk - near_chunk)
	var index := 0
	while index < _spawn_queue.size():
		var other: Dictionary = _spawn_queue[index]
		if distance < absi(int(other.chunk) - near_chunk):
			break
		index += 1
	_spawn_queue.insert(index, item)
	# Ask the resource loader's worker threads to fetch this chunk's scenes so
	# instantiation never blocks on disk or scene parsing.
	_request_scene_preloads(entries)


## Adds the (single) chunk holding [param world_x] right now, whatever the
## budget. Called from reset_to so the ground under the respawned player
## exists (and its collision is committed) before the attempt starts.
func _spawn_chunk_now(world_x: float) -> void:
	var chunk := _chunk_of(world_x)
	for layer_idx: int in level.layers.size():
		var by_chunk: Dictionary = _chunk_entries[layer_idx]
		if not by_chunk.has(chunk):
			continue
		var key := _chunk_key(layer_idx, chunk)
		if _spawned.has(key):
			# Already live; make sure its physics is fully committed.
			_commit_chunk_now(key)
			continue
		# If this very chunk is mid-teardown, the player needs it now: finish
		# the teardown immediately so it can be built fresh.
		if _key_in_queue(_free_queue, key):
			_finish_free_now(key)
		# Cancel a queued (possibly partial) spawn and land the whole chunk in
		# this frame.
		var qi := 0
		while qi < _spawn_queue.size():
			if (_spawn_queue[qi] as Dictionary).key == key:
				var partial: Dictionary = _spawn_queue[qi]
				_spawn_queue.remove_at(qi)
				_free_node_array((partial.rec as Dictionary).nodes)
				break
			qi += 1
		var rec := {"nodes": [], "phys": 0, "key": key}
		var item := _make_spawn_item(layer_idx, chunk, by_chunk[chunk] as Array, key, rec)
		_spawn_slice(item, (item.entries as Array).size())
		_spawned[key] = rec
		_refresh_pending = true
		_commit_chunk_now(key)


## Synchronously commits every uncommitted shape of a live chunk. Used for the
## ground under a respawn point and for chunks that are live when a restart
## needs them immediately.
func _commit_chunk_now(key: String) -> void:
	if not _spawned.has(key):
		return
	var rec: Dictionary = _spawned[key]
	var nodes: Array = rec.nodes
	if int(rec.phys) >= nodes.size():
		return
	var qi := 0
	while qi < _phys_queue.size():
		if (_phys_queue[qi] as Dictionary).key == key:
			_phys_queue.remove_at(qi)
		else:
			qi += 1
	var i: int = int(rec.phys)
	while i < nodes.size():
		var batch: Array = []
		while batch.size() < 64 and i < nodes.size():
			var node: Node2D = nodes[i]
			if is_instance_valid(node) and node.is_inside_tree():
				batch.append(node)
			i += 1
		if not batch.is_empty():
			LevelPhysics.commit(level, batch)
	rec.phys = nodes.size()


func _finish_free_now(key: String) -> void:
	for i: int in _free_queue.size():
		var item: Dictionary = _free_queue[i]
		if item.key != key:
			continue
		var nodes: Array = (item.rec as Dictionary).nodes
		var batch: Array = []
		for j: int in range(int(item.index), nodes.size()):
			var node: Node2D = nodes[j]
			if is_instance_valid(node):
				batch.append(node)
		if not batch.is_empty() and level.is_inside_tree():
			LevelPhysics.release(level, batch)
		for node: Node2D in batch:
			node.free()
		_free_queue.remove_at(i)
		_spawned.erase(key)
		return


func _free_node_array(nodes: Array) -> void:
	for node: Node2D in nodes:
		if is_instance_valid(node):
			node.free()


## Synchronously releases and frees a whole live chunk, cancelling any queued
## teardown of it. Used when a restart needs a clean slate immediately.
func _teardown_live_chunk(key: String) -> void:
	var qi := 0
	while qi < _free_queue.size():
		if (_free_queue[qi] as Dictionary).key == key:
			_free_queue.remove_at(qi)
		else:
			qi += 1
	if not _spawned.has(key):
		return
	var rec: Dictionary = _spawned[key]
	var nodes: Array = rec.nodes
	var batch: Array = []
	for node: Node2D in nodes:
		if is_instance_valid(node):
			batch.append(node)
	if not batch.is_empty() and level.is_inside_tree():
		LevelPhysics.release(level, batch)
	for node: Node2D in batch:
		node.free()
	_spawned.erase(key)


# --- Death preloading -------------------------------------------------------
#
# GD's fixed respawn pause is where it resets its level between attempts. This
# game's 1-second death animation is the same window: gameplay is over but the
# tree still runs, so the stream tears the old window down and builds the
# respawn window on generous budgets. When restart_level finally runs, the
# window it wants is already there and the attempt starts without a hitch.


func _preload_tick() -> void:
	if not _preloading:
		_preloading = true
		_preload_chunk = _chunk_of(respawn_x_for(level))
		_last_player_chunk = -0x7fffffff
		# Everything the finished attempt left live is stale for the next one:
		# queue it all for tearing down, farthest from the death first so the
		# death scene keeps its geometry until the restart moment.
		# Half-built chunks of the finished attempt are stale too: drop them
		# before anything below re-enqueues the respawn window.
		for item: Dictionary in _spawn_queue:
			_free_node_array((item.rec as Dictionary).nodes)
		_spawn_queue.clear()
		var death_chunk := _chunk_of(LevelManager.player.global_position.x)
		var keys: Array = _spawned.keys()
		keys.sort_custom(func(a: String, b: String) -> bool:
			return absi(int(a.split("/")[1]) - death_chunk) > absi(int(b.split("/")[1]) - death_chunk))
		for key: String in keys:
			_enqueue_free(key)
	_drain(PRELOAD_SPAWN_BUDGET, PRELOAD_COMMIT_BUDGET, PRELOAD_FREE_BUDGET, _preload_chunk, false)
	# Chunks that finished tearing down this frame are now free to be spawned
	# fresh.
	_enqueue_missing_window(_preload_chunk)


## Respawns the level around [param world_x]: stale chunks are torn down and
## the window is rebuilt from the resident records (fresh nodes mean one-shot
## orbs, toggled objects and triggers start clean, exactly like GD respawns).
## The heavy lifting normally already happened during the death animation (see
## _preload_tick); this guarantees the ground under the player and queues
## whatever is still missing.
func reset_to(world_x: float) -> void:
	var was_preloading := _preloading
	_preloading = false
	if not was_preloading:
		# A restart with no death behind it (pause-menu restart, practice
		# toggled off): the whole live window belongs to the finished attempt,
		# so it is stale for the next one. It is torn down synchronously here -
		# this is a rare, user-triggered restart, so a single hitch is fine and
		# it guarantees the new window is not blocked behind a slow free queue.
		# (After a death the preload already owns the teardown, spread across
		# the death animation instead.)
		for item: Dictionary in _spawn_queue:
			_free_node_array((item.rec as Dictionary).nodes)
		_spawn_queue.clear()
		var keys: Array = _spawned.keys()
		for key: String in keys:
			_teardown_live_chunk(key)
		_boost_frames = 75
	var target_chunk := _chunk_of(world_x)
	_enqueue_missing_window(target_chunk)
	_last_player_chunk = -0x7fffffff
	# Ground under the respawn point must exist and collide right now.
	_spawn_chunk_now(world_x)
	LevelPhysics.clear_dirty(level)


## Called by Level.start_level right after a full physics rebuild: every live
## chunk's shapes are now in the shared bodies (the rebuild did it), so the
## incremental commit queue must not re-add them later.
func _mark_all_physics_committed() -> void:
	_phys_queue.clear()
	for rec: Dictionary in _spawned.values():
		rec.phys = (rec.nodes as Array).size()


## Synchronous start-region build at load time (see make). No physics work: the
## level starts with a dirty shared world and the first start_level rebuilds it
## from whatever this spawned.
func _initial_spawn(world_x: float) -> void:
	var player_chunk := _chunk_of(world_x)
	for layer_idx: int in level.layers.size():
		var by_chunk: Dictionary = _chunk_entries[layer_idx]
		for chunk: int in range(player_chunk, player_chunk + START_SPAN_CHUNKS + 1):
			if not by_chunk.has(chunk):
				continue
			var key := _chunk_key(layer_idx, chunk)
			var rec := {"nodes": [], "phys": 0, "key": key}
			var item := _make_spawn_item(layer_idx, chunk, by_chunk[chunk] as Array, key, rec)
			_spawn_slice(item, (item.entries as Array).size())
			_spawned[key] = rec
			_request_scene_preloads(item.entries as Array)
	_last_player_chunk = player_chunk


# --- Threaded scene loading -------------------------------------------------
#
# Godot cannot create or free scene-tree nodes on worker threads - that work
# is inherently main-thread. What the engine *does* load on worker threads is
# resources: every gd scene this level instantiates is handed to
# ResourceLoader.load_threaded_request as soon as its chunk is queued, so the
# file read and scene parse happen in the background and the main thread only
# ever instantiates an already-loaded PackedScene.


## Collects the scene paths a chunk's entries will instantiate and asks the
## resource loader's worker threads for them.
func _request_scene_preloads(entries: Array) -> void:
	for entry: Dictionary in entries:
		var path: String = str(entry.get("scene_file_path", ""))
		if path.is_empty():
			continue
		if not path.begins_with("res://"):
			path = "res://" + path
		if _prefetch_pending.has(path):
			continue
		if not ResourceLoader.exists(path):
			continue
		_prefetch_pending[path] = true
		ResourceLoader.load_threaded_request(path)


## Drains finished background loads into Godot's resource cache (a few per
## frame), so a later instantiate finds its scene already loaded.
func _settle_prefetches() -> void:
	var processed := 0
	for path: String in _prefetch_pending.keys():
		if processed >= 8:
			break
		processed += 1
		var status: int = ResourceLoader.load_threaded_get_status(path)
		if status == 3:  # THREAD_LOAD_LOADED
			ResourceLoader.load_threaded_get(path)
			_prefetch_pending.erase(path)
		elif status == 0 or status == 2:  # INVALID_RESOURCE / FAILED
			_prefetch_pending.erase(path)


## Re-colours nodes spawned after the level's [ColorChannelWatcher]s already
## ran their one-shot _ready pass (any chunk finished mid-play, on a streamed
## respawn, or during the death preload). Each watcher re-queries its channel
## group, so only the channels the new nodes use are visited.
func _refresh_new_node_colors() -> void:
	for child: Node in level.get_children():
		if child is ColorChannelWatcher:
			child.refresh_objects_color()
