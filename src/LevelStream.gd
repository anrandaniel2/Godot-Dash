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
##    front, behind a loading screen. Here, chunk work never happens in a
##    burst on a live frame: it drains on a per-frame budget of node
##    instantiations, far enough ahead of the player that each slice is
##    invisible. If the drain ever falls behind, a chunk close to the player
##    is force-finished in one go rather than letting geometry pop in.
##  - GD respawns after a fixed pause and only *resets* its objects in place -
##    it never rebuilds the level. Our level is windowed so it cannot keep
##    everything, but the whole 1-second death animation is a free loading
##    window: as soon as the player dies, the stream tears the old window down
##    and builds the respawn window on a large budget, so when the attempt
##    restarts there is almost nothing left to do - the same spot GD hides its
##    own per-attempt work.
##  - GD never recreates its physics world per chunk. Chunk spawn/free here
##    commit and release *shapes* on persistent shared bodies
##    (LevelPhysics.commit/release) instead of rebuilding them, so the
##    player's physics world is never churned mid-run.
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

## Per-frame node budget while the level is actually playing. Instantiation is
## spread over the frames of travel time the AHEAD_CHUNKS margin buys, so a
## dense chunk never lands in one frame.
const PLAY_SPAWN_BUDGET := 150
## Per-frame node budget for tearing the old window down while playing.
const PLAY_FREE_BUDGET := 500
## Per-frame budgets during the death animation (a hidden loading window, the
## same way GD uses its respawn pause).
const PRELOAD_SPAWN_BUDGET := 800
const PRELOAD_FREE_BUDGET := 900
## A chunk this close to the player that is still missing is finished in one
## frame instead of being budgeted. With AHEAD_CHUNKS of margin the budget
## drains everything long before it gets this close, so this only fires when a
## drain fell behind (pathological density) - finishing the *next* chunk a
## screen ahead keeps any pop at the far edge of the view instead of under the
## player.
const FORCE_DISTANCE_CHUNKS := 1

## Set on the Level while its gameplay placements are streamed.
const STREAMING_META: StringName = &"_gd_level_streaming"

var level: Level
## Original level data the entries reference; kept so the records live.
var source_data: Dictionary
## Per layer index: chunk id -> Array of object-data entries.
var _chunk_entries: Array = []
## Fully spawned, live chunk nodes: "layer/chunk" -> Array[Node2D].
var _spawned: Dictionary = {}
## Chunks waiting to spawn, nearest first. Each entry carries a spawn cursor so
## a chunk can be sliced across many frames.
var _spawn_queue: Array = []
## Chunks waiting to be freed, each entry carries a free cursor.
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
	stream.source_data = data
	stream.name = "LevelStream"
	stream._index(data)
	level.set_meta(STREAMING_META, true)
	level.add_child(stream, false, INTERNAL_MODE_BACK)
	# The initial window is built here at load time (masked by the level's own
	# loading, exactly where GD does its heavy object creation). Physics is
	# built on the first start_level by the normal dirty->rebuild path.
	stream._initial_spawn(data.start_position.x)
	return stream


## Splits each layer's object data into horizontal chunks by the placement's
## x. Entries are kept as references into [member source_data].
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


func _process(_delta: float) -> void:
	if not LevelManager.level_playing:
		return
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
	_drain(PLAY_SPAWN_BUDGET, PLAY_FREE_BUDGET, player_chunk, true)


## Instantiation happens here, on a per-frame budget, never in a burst on a
## live gameplay frame. GD has no equivalent mid-run loop because it simply
## never creates objects while playing - the budget is how a windowed level
## gets the same effect.
func _drain(spawn_budget: int, free_budget: int, player_chunk: int, allow_force: bool) -> void:
	var changed := false
	changed = _tick_frees(free_budget) or changed
	changed = _tick_spawns(spawn_budget, player_chunk, allow_force) or changed
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
	while not _free_queue.is_empty() and budget > 0:
		var item: Dictionary = _free_queue[0]
		var nodes: Array = item.nodes
		var index: int = item.index
		var to_free: int = mini(budget, nodes.size() - index)
		for i: int in range(index, index + to_free):
			nodes[i].free()
		item.index = index + to_free
		changed = true
		budget -= to_free
		if item.index >= nodes.size():
			_free_queue.pop_front()
			_spawned.erase(item.key)
	return changed


func _tick_spawns(budget: int, player_chunk: int, allow_force: bool) -> bool:
	var changed := false
	var qi := 0
	while qi < _spawn_queue.size() and budget > 0:
		var item: Dictionary = _spawn_queue[qi]
		var remaining: int = item.entries.size() - int(item.index)
		var forced := false
		if allow_force and int(item.chunk) <= player_chunk + FORCE_DISTANCE_CHUNKS:
			forced = true
		var to_spawn: int = remaining if forced else mini(budget, remaining)
		if to_spawn > 0:
			_spawn_slice(item, to_spawn)
			item.index = int(item.index) + to_spawn
			changed = true
		if int(item.index) >= item.entries.size():
			_spawn_queue.remove_at(qi)
			_finish_chunk(item)
			# A completed chunk costs nothing against the budget; keep draining.
			continue
		budget -= to_spawn
		qi += 1
	return changed


## Spawns [param count] objects of a queued chunk and slots them under the
## layer, ahead of its DecorationBatch children so decoration keeps drawing
## above gameplay as in a full build.
func _spawn_slice(item: Dictionary, count: int) -> void:
	var layer: Layer = level.layers[item.layer_idx]
	var insert_at: int = item.insert_at
	for i: int in range(int(item.index), int(item.index) + count):
		var entry: Dictionary = item.entries[i]
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
		item.nodes.append(object)


func _finish_chunk(item: Dictionary) -> void:
	_spawned[item.key] = item.nodes
	if not level.is_inside_tree() or item.nodes.is_empty():
		return
	# The chunk's shapes join the persistent shared bodies; nothing else in
	# the world is rebuilt (see LevelPhysics.commit).
	LevelPhysics.commit(level, item.nodes)
	_refresh_pending = true


## Re-colours nodes spawned after the level's [ColorChannelWatcher]s already
## ran their one-shot _ready pass (any chunk finished mid-play, on a streamed
## respawn, or during the death preload). Each watcher re-queries its channel
## group, so only the channels the new nodes use are visited.
func _refresh_new_node_colors() -> void:
	for child: Node in level.get_children():
		if child is ColorChannelWatcher:
			child.refresh_objects_color()


## Adds the (single) chunk holding [param world_x] right now, whatever the
## budget. Called from reset_to so the ground under the respawned player
## exists before the attempt starts.
func _spawn_chunk_now(world_x: float) -> void:
	var chunk := _chunk_of(world_x)
	for layer_idx: int in level.layers.size():
		var by_chunk: Dictionary = _chunk_entries[layer_idx]
		if not by_chunk.has(chunk):
			continue
		var key := _chunk_key(layer_idx, chunk)
		if _spawned.has(key):
			continue
		# If this very chunk is mid-teardown, the player needs it now: finish
		# the teardown immediately (its old nodes are stale for the new
		# attempt) so it can be built fresh.
		if _queue_has(_free_queue, key):
			_finish_free_now(key)
		# Cancel a queued (possibly partial) spawn and land the whole chunk in
		# this frame: the ground under the respawn point cannot wait on the
		# budget.
		var item: Dictionary = {}
		var found := false
		for qi: int in _spawn_queue.size():
			if _spawn_queue[qi].key == key:
				item = _spawn_queue[qi]
				_spawn_queue.remove_at(qi)
				found = true
				break
		if not found:
			item = _make_spawn_item(layer_idx, chunk, by_chunk[chunk], key)
		var remaining: int = item.entries.size() - int(item.index)
		if remaining > 0:
			_spawn_slice(item, remaining)
			_finish_chunk(item)


func _finish_free_now(key: String) -> void:
	for i: int in _free_queue.size():
		var item: Dictionary = _free_queue[i]
		if item.key != key:
			continue
		var nodes: Array = item.nodes
		for j: int in range(int(item.index), nodes.size()):
			nodes[j].free()
		_free_queue.remove_at(i)
		_spawned.erase(key)
		return


func _make_spawn_item(layer_idx: int, chunk: int, entries: Array, key: String) -> Dictionary:
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
		"nodes": [],
	}


func _queue_has(queue: Array, key: String) -> bool:
	for item: Dictionary in queue:
		if item.key == key:
			return true
	return false


## Enqueues a live chunk's nodes for freeing. Its shapes leave the shared
## bodies immediately; the node frees then trickle on the budget. A key is
## never in more than one of {live, free queue, spawn queue}.
func _enqueue_free(key: String) -> void:
	if not _spawned.has(key) or _queue_has(_free_queue, key) or _queue_has(_spawn_queue, key):
		return
	var nodes: Array = _spawned[key]
	if not nodes.is_empty() and level.is_inside_tree():
		LevelPhysics.release(level, nodes)
	_free_queue.append({"key": key, "nodes": nodes, "index": 0})


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
			if _spawned.has(key) or _queue_has(_spawn_queue, key) or _queue_has(_free_queue, key):
				continue
			_enqueue_spawn_near(layer_idx, chunk, by_chunk[chunk], key, player_chunk)


func _enqueue_spawn_near(layer_idx: int, chunk: int, entries: Array, key: String, near_chunk: int) -> void:
	var item := _make_spawn_item(layer_idx, chunk, entries, key)
	# Nearest chunks first (what the run needs soonest).
	var distance := absi(chunk - near_chunk)
	var index := 0
	while index < _spawn_queue.size():
		var other: Dictionary = _spawn_queue[index]
		if distance < absi(int(other.chunk) - near_chunk):
			break
		index += 1
	_spawn_queue.insert(index, item)


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
		var death_chunk := _chunk_of(LevelManager.player.global_position.x)
		var keys: Array = _spawned.keys()
		keys.sort_custom(func(a: String, b: String) -> bool:
			return absi(int(a.split("/")[1]) - death_chunk) > absi(int(b.split("/")[1]) - death_chunk))
		for key: String in keys:
			_enqueue_free(key)
	_drain(PRELOAD_SPAWN_BUDGET, PRELOAD_FREE_BUDGET, _preload_chunk, false)
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
		# so it is stale for the next one - tear it all down and rebuild. When
		# a death preload ran instead, its free queue already owns the old
		# chunks and whatever is live is already the fresh target window.
		for item: Dictionary in _spawn_queue:
			# Partially spawned chunks are not in _spawned yet: their nodes are
			# only referenced by the queue entry, so drop them before clearing.
			for node: Node2D in item.nodes:
				node.free()
		_spawn_queue.clear()
		var keys: Array = _spawned.keys()
		for key: String in keys:
			_enqueue_free(key)
	var target_chunk := _chunk_of(world_x)
	_enqueue_missing_window(target_chunk)
	_last_player_chunk = -0x7fffffff
	# Ground under the respawn point must exist right now.
	_spawn_chunk_now(world_x)
	LevelPhysics.clear_dirty(level)


## Synchronous initial window build at load time (see make). No physics work:
## the level starts with a dirty shared world and the first start_level
## rebuilds it from whatever this window contains.
func _initial_spawn(world_x: float) -> void:
	var player_chunk := _chunk_of(world_x)
	for layer_idx: int in level.layers.size():
		var by_chunk: Dictionary = _chunk_entries[layer_idx]
		for chunk: int in range(player_chunk - BEHIND_CHUNKS, player_chunk + AHEAD_CHUNKS + 1):
			if not by_chunk.has(chunk):
				continue
			var key := _chunk_key(layer_idx, chunk)
			var item := _make_spawn_item(layer_idx, chunk, by_chunk[chunk], key)
			_spawn_slice(item, item.entries.size())
			_spawned[key] = item.nodes
	_last_player_chunk = player_chunk
