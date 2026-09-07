class_name LevelStream
extends Node
## Builds gameplay placements the way Geometry Dash does: the level's object
## records stay resident as *packed data* (not per-object Dictionaries and not
## nodes), and actual scene nodes only exist for a window around the player.
##
## A GD level never instantiates every object - it keeps a compact list of
## every object's fields and creates display nodes only for the section the
## camera is in. Copying that here is what lets a very large level (hundreds of
## thousands of objects) open and play on a phone: the memory cost stops
## scaling with the whole level.
##
## Resident records: at load the gameplay entries are snapshotted per chunk
## into var_to_bytes() blobs (an exact, engine-guaranteed round trip) and the
## source level-data Dictionary graph is released (see GameScene.load_level).
## A chunk decodes back into its entries only when it enters the window, so
## whole-level Dictionary allocations simply never happen during play.
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
## Chunks behind the player beyond which live nodes are freed. BEHIND_CHUNKS
## (3) are kept for gameplay; this adds a small hysteresis (2 chunks) so a
## chunk at the edge is not freed one frame and re-requested the next when the
## player nudges across a boundary or reverses briefly. It must stay small:
## every chunk between BEHIND_CHUNKS and FREE_BEHIND_CHUNKS behind the player
## is pure dead weight on a one-way level - keeping 9 of them (the old value)
## nearly doubled the live node count and with it the steady frame cost.
const FREE_BEHIND_CHUNKS := 5
## How many chunks ahead of the start position are spawned synchronously while
## the level opens (the loading moment). Everything else in the window drains
## on the per-frame budget once the attempt runs. Kept tiny so opening a level
## never allocates its whole window at once.
const START_SPAN_CHUNKS := 2

## How much real time (milliseconds) the stream may spend on its queues in one
## *live gameplay* frame. All window work - spawning, physics commits, node
## frees and decoration chunk building - runs against this clock, so a dense
## chunk or a heavy respawn can never land as a multi-millisecond burst: the
## drain loop stops as soon as the budget is spent and the margin of
## AHEAD_CHUNKS (several seconds of travel) absorbs the leftover. This is the
## one number that bounds the stream's frame cost on a given device; the
## *_SLICE constants below only bound how far one loop pass can overshoot.
const PLAY_DRAIN_MS := 4.0
## Same budget during the death animation, a hidden loading window (like GD's
## respawn pause): the whole frame can spend more on the stream there, but the
## death scene must still animate, so it is not unlimited.
const PRELOAD_DRAIN_MS := 8.0
## How many frames an attempt start (the first attempt of a session, and any
## restart that was not preloaded by a death) gets with a multiplied drain
## budget, so the window fills quickly behind the fresh respawn.
const ATTEMPT_BOOST_FRAMES := 120
const ATTEMPT_BOOST_MULTIPLIER := 2.0

## Per-drain-pass upper bounds on one queue step. Small enough that even a
## worst-case pass lands well under a frame; the drain loop repeats passes
## until its millisecond budget is spent, so these do not limit throughput -
## they only stop the loop overshooting its budget by a whole chunk.
## Spawns are the most expensive item (instantiate + per-object configure), so
## their pass is the smallest.
const SPAWN_SLICE := 12
## Physics-shape commits per pass (each a shape add to a shared body).
const COMMIT_SLICE := 32
## Node frees per pass.
const FREE_SLICE := 64
## Decoration entries fed through GDDecorationLoader.add_object per pass.
const DECO_ENTRY_SLICE := 150
## Decoration batches whose items are sorted (batch.build) per pass. Sorting is
## the per-batch finalise cost, so it is sliced too: a chunk with many batches
## appears progressively instead of in one sorted frame.
const DECO_BATCH_SLICE := 4
## Decoration chunks whose queued teardown runs per pass.
const DECO_FREE_SLICE := 2

## The ground under the player is guaranteed a different way: the spawn queue
## is ordered nearest chunk first and the drain loop spends its whole budget
## on the front of the queue, so whatever the player is standing on is always
## what gets built first (and restart already spawns it synchronously, see
## _spawn_chunk_now). There is no "force-finish this chunk now" path left:
## finishing a dense chunk in one frame is precisely the burst this streamer
## exists to avoid.

## Set on the Level while its gameplay placements are streamed.
const STREAMING_META: StringName = &"_gd_level_streaming"

var level: Level
## Per layer index: chunk id -> PackedByteArray. Each blob is var_to_bytes()
## of that chunk's object-data entries, snapshotted at load time so the level
## does not have to keep the whole Dictionary graph resident (the GD idea of a
## compact resident record list: memory stops scaling with the full level).
## A chunk is decoded back into entry Dictionaries only when it enters the
## player's window; the graph itself is released once indexed (see
## GameScene.load_level).
var _chunk_entries: Array = []
## Per layer index: chunk id -> PackedByteArray of that chunk's *decoration*
## entries, packed the same way as the gameplay chunks above. Decoration is
## kept as packed records too and its display objects (DecorationBatch nodes)
## are built only while the chunk is near the player and freed behind - so
## neither the open-time build nor the resident memory scales with the whole
## level's decoration (a whole-level batch build at open was what crashed
## decoration-heavy levels like Orbit).
var _deco_entries: Array = []
## Live decoration batches: chunk key -> Array[DecorationBatch].
var _deco_live: Dictionary = {}
## Decoration chunk entries decoded, awaiting their batch build: key -> Array.
var _deco_ready: Dictionary = {}
## Worker threads decoding decoration chunk entries: key -> Thread.
var _deco_threads: Dictionary = {}
## Decoration chunks whose entries are still being fed into their batches,
## nearest first. Each entry is a Dictionary {key, layer_idx, entries, index,
## batches} where batches is a GDDecorationLoader accumulator shared by every
## per-frame slice, so one chunk's decoration is built item by item across
## frames instead of in a whole-chunk burst. A chunk leaves this queue only
## once every entry is in, and moves to [_deco_finalize_queue].
var _deco_build_queue: Array = []
## Decoration chunks whose batches are fully filled, being finalised: each
## batch's items are sorted (a bounded number of batches per pass) and, once
## the last batch is built, the ordered batches join the layer together.
var _deco_finalize_queue: Array = []
## Chunks waiting to have their decoration batches freed.
var _deco_free_queue: Array = []
## Decoration chunks whose entries contain no drawable artwork (their whole
## decoration list exists but nothing maps to an atlas frame). They are marked
## so the window scan never re-decodes and re-builds them every frame.
var _deco_blank: Dictionary = {}
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
## Decoded-but-not-yet-spawned chunk entries: chunk key -> Array. A chunk's
## packed records are decoded on a worker thread (pure data, no scene-tree
## access), cached here, and only moved into the spawn queue when the chunk is
## inside the window - so the main thread never allocates a whole chunk's
## Dictionaries in one frame.
var _decoded: Dictionary = {}
## Chunk key -> Thread currently decoding that chunk's records.
var _decode_threads: Dictionary = {}
## Safety cap: if a fast run or several resets leave strays in [_decoded],
## drop them rather than let the cache grow (a straggler re-decodes on demand).
const DECODED_CACHE_CAP := 48
## Frames after an attempt start that was not preloaded by a death during
## which the drain budget is multiplied, so a freshly built window catches up
## quickly (the first attempt of a session and manual/practice restarts). Death
## restarts do not need it: the death animation already preloaded the new
## window.
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
	stream._initial_deco(data.start_position.x)
	# The first attempt of the session starts right after this load with only
	# the start region built; give it the attempt-start drain boost so the
	# rest of the window fills in behind the first seconds of play (death
	# preloading covers every later attempt).
	stream._boost_frames = ATTEMPT_BOOST_FRAMES
	return stream


## Splits each layer's object data into horizontal chunks by the placement's
## x, then snapshots every chunk as a var_to_bytes() blob. The Dictionary
## entries are only referenced here transiently: once indexed, the caller can
## release the whole level-data graph and this stream keeps working from the
## blobs (decoding a chunk is exact, so nothing about the entries changes).
func _index(data: Dictionary) -> void:
	var layers_data: Array = data.get("layers", [])
	_chunk_entries.resize(layers_data.size())
	_deco_entries.resize(layers_data.size())
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
		var cold: Dictionary = {}
		for chunk: int in by_chunk.keys():
			cold[chunk] = var_to_bytes(by_chunk[chunk])
		_chunk_entries[layer_idx] = cold
		# Decoration entries are chunked identically. In low detail mode the
		# whole decoration layer is dropped (as the old whole-level build did),
		# leaving every layer's decoration list empty.
		var deco_cold: Dictionary = {}
		if not Config.ldm:
			var deco_by_chunk: Dictionary = {}
			for entry: Dictionary in layers_data[layer_idx].get("objects", []):
				if not entry.get("decoration", false):
					continue
				var x: float = entry.get("transform", Transform2D.IDENTITY).origin.x
				var chunk := _chunk_of(x)
				if not deco_by_chunk.has(chunk):
					deco_by_chunk[chunk] = []
				deco_by_chunk[chunk].append(entry)
			for chunk: int in deco_by_chunk.keys():
				deco_cold[chunk] = var_to_bytes(deco_by_chunk[chunk])
		_deco_entries[layer_idx] = deco_cold


## Decodes a chunk's packed records back into object-data entries. Called only
## when the chunk enters the player's window, so the resident memory stays a
## few compact blobs rather than per-object Dictionaries for the whole level.
func _entries_of(layer_idx: int, chunk: int) -> Array:
	var by_chunk: Dictionary = _chunk_entries[layer_idx]
	var blob: PackedByteArray = by_chunk[chunk]
	var decoded: Variant = bytes_to_var(blob)
	return decoded as Array


## Decodes a chunk's packed *decoration* records. Same lossless round trip as
## gameplay; called on a worker thread when the chunk nears the window.
func _deco_entries_of(layer_idx: int, chunk: int) -> Array:
	var by_chunk: Dictionary = _deco_entries[layer_idx]
	var blob: PackedByteArray = by_chunk[chunk]
	return bytes_to_var(blob) as Array


## Entries for a chunk the player needs *right now* (the ground under a
## respawn): prefers an already-finished decode, otherwise decodes inline.
func _chunk_entries_now(layer_idx: int, chunk: int, key: String) -> Array:
	if _decoded.has(key):
		var ready: Array = _decoded[key] as Array
		_decoded.erase(key)
		return ready
	if _decode_threads.has(key):
		var thread: Thread = _decode_threads[key]
		if not thread.is_alive():
			_decode_threads.erase(key)
			return thread.wait_to_finish() as Array
	return _entries_of(layer_idx, chunk)


func _chunk_of(world_x: float) -> int:
	return floori(world_x / (CHUNK_CELLS * Constants.CELL_SIZE))


func _chunk_key(layer_idx: int, chunk: int) -> String:
	return "%d/%d" % [layer_idx, chunk]


## Worker-thread body: turns one chunk's packed records back into its object
## entries. This is pure data (builtin types only - transforms, strings,
## arrays, dictionaries - no Nodes, no scene tree), so it is one of the few
## operations in the whole pipeline Godot permits off the main thread, and it
## is where the per-chunk Dictionary allocation happens.
func _decode_blob(blob: PackedByteArray) -> Array:
	var decoded: Variant = bytes_to_var(blob)
	return decoded as Array


## Starts a background decode for a chunk, or reuses one already decoded.
## Returns the decoded entries if they are ready right now, otherwise an empty
## Array (the chunk is decoding on a worker thread and the spawn is enqueued
## when that finishes; see _settle_decodes). An empty result is therefore the
## "not ready yet" signal - every real chunk has at least one entry.
func _ensure_decoded(layer_idx: int, chunk: int, key: String) -> Array:
	if _decoded.has(key):
		return _decoded[key] as Array
	if _decode_threads.has(key):
		return []
	var by_chunk: Dictionary = _chunk_entries[layer_idx]
	if not by_chunk.has(chunk):
		return []
	var thread := Thread.new()
	var err := thread.start(_decode_blob.bind(by_chunk[chunk]))
	if err != OK:
		# Thread pool exhausted or failed: fall back to decoding inline so the
		# chunk still works (a rare one-frame cost beats missing geometry).
		return _entries_of(layer_idx, chunk)
	_decode_threads[key] = thread
	return []


## Drains finished background decodes into [_decoded] / [_deco_ready] and
## moves them into the spawn/build queues when their chunk is still inside the
## current window.
func _settle_decodes() -> void:
	_settle_gameplay_decodes()
	_settle_deco_decodes()


func _settle_gameplay_decodes() -> void:
	if _decode_threads.is_empty():
		return
	for key: String in _decode_threads.keys():
		var thread: Thread = _decode_threads[key]
		if thread.is_alive():
			continue
		var entries: Array = thread.wait_to_finish()
		_decode_threads.erase(key)
		_decoded[key] = entries
		if _decoded.size() > DECODED_CACHE_CAP:
			# Strays only (a chunk decoded then the window moved away); they
			# re-decode on demand. Cleared wholesale to stay O(1).
			_decoded.clear()
			_decoded[key] = entries
		var target_chunk := _current_target_chunk()
		if target_chunk != -0x7fffffff:
			var parts := key.split("/")
			var chunk := int(parts[1])
			var distance := absi(chunk - target_chunk)
			if distance <= AHEAD_CHUNKS and chunk >= target_chunk - BEHIND_CHUNKS:
				_enqueue_spawn_item(int(parts[0]), chunk, entries, key, target_chunk)


## Drains finished decoration decodes into [_deco_ready]; _enqueue_missing_window
## picks them up into the build queue (running later the same frame). If the
## window has already moved far past the chunk the entries are dropped - they
## re-decode on demand, and holding them would defeat the packing.
func _settle_deco_decodes() -> void:
	if _deco_threads.is_empty():
		return
	for key: String in _deco_threads.keys():
		var thread: Thread = _deco_threads[key]
		if thread.is_alive():
			continue
		var entries: Array = thread.wait_to_finish() as Array
		_deco_threads.erase(key)
		_deco_ready[key] = entries
		if _deco_ready.size() > DECODED_CACHE_CAP:
			# Strays only (a chunk decoded then the window moved away); they
			# re-decode on demand if the window ever returns.
			_deco_ready.clear()
			_deco_ready[key] = entries


## The chunk the window is currently centred on: the respawn target during the
## death preload, the player's chunk while playing, or a sentinel otherwise.
func _current_target_chunk() -> int:
	if _preloading:
		return _preload_chunk
	var player: Player = LevelManager.player
	if player != null and not player.dead and is_instance_valid(player):
		return _chunk_of(player.global_position.x)
	return -0x7fffffff


func _exit_tree() -> void:
	# Join any in-flight decode threads so they never outlive this node and
	# touch a freed object. Decodes are short (a chunk of plain data), so this
	# only ever waits a few milliseconds.
	for key: String in _decode_threads.keys():
		var thread: Thread = _decode_threads[key]
		if thread.is_alive():
			thread.wait_to_finish()
	_decode_threads.clear()
	_decoded.clear()
	for key: String in _deco_threads.keys():
		var thread: Thread = _deco_threads[key]
		if thread.is_alive():
			thread.wait_to_finish()
	_deco_threads.clear()
	_deco_ready.clear()
	# Half-built decoration chunks hold detached DecorationBatch nodes that are
	# not children of anything; free them so nothing leaks when the stream dies.
	_cancel_all_deco_builders()


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
	var decoding: int = _decode_threads.size() + _decoded.size()
	var deco_chunks: int = _deco_live.size()
	var deco_build: int = (
		_deco_build_queue.size()
		+ _deco_finalize_queue.size()
		+ _deco_threads.size()
		+ _deco_ready.size()
	)
	var mem_mb: float = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	_stats_label.text = (
		"FPS %d  live %d  stream %0.1fms  |  spawn %d  commit %d  free %d  dec %d  |  deco %d(+%d)  mem %.0fMB"
		% [
			int(Engine.get_frames_per_second()),
			live,
			_last_drain_ms,
			pending_spawn,
			pending_commit,
			pending_free,
			decoding,
			deco_chunks,
			deco_build,
			mem_mb,
		]
	)


func _process(_delta: float) -> void:
	if SHOW_STATS and _stats_label != null:
		_update_stats(_delta)
	if not LevelManager.level_playing:
		return
	_settle_prefetches()
	_settle_decodes()
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
	var drain_ms: float = PLAY_DRAIN_MS
	if _boost_frames > 0:
		_boost_frames -= 1
		drain_ms *= ATTEMPT_BOOST_MULTIPLIER
	var started_usec: int = Time.get_ticks_usec()
	_drain(drain_ms)
	_last_drain_ms = (Time.get_ticks_usec() - started_usec) / 1000.0


## The per-frame worker: spawns, physics-shape commits, node frees and
## decoration chunk building all run here against a real-time budget, never as
## a burst on a live gameplay frame. GD has no equivalent mid-run loop because
## it never creates objects while playing - small time-bounded passes are how
## a windowed level gets the same effect.
##
## Each pass of the loop takes at most one *_SLICE from every queue, then the
## loop repeats while its millisecond budget remains, so a heavy moment (a
## dense chunk arriving, a respawn rebuild) spreads across frames instead of
## landing whole - and the frame cost of the stream is bounded by [param
## time_ms] no matter how dense the level is or how slow the device is. A
## fixed node-count budget cannot do that: 48 instantiations is nothing on a
## desktop and a dropped frame on a phone.
func _drain(time_ms: float) -> void:
	var deadline := Time.get_ticks_usec() + int(time_ms * 1000.0)
	var changed := false
	while Time.get_ticks_usec() < deadline:
		var worked := false
		if _tick_frees(FREE_SLICE):
			changed = true
			worked = true
		# The clock is checked between tickers too, so one overshooting pass can
		# cost at most its own slice rather than every queue's slice summed.
		if Time.get_ticks_usec() >= deadline:
			break
		if _tick_spawns(SPAWN_SLICE):
			changed = true
			worked = true
		if Time.get_ticks_usec() >= deadline:
			break
		if _tick_physics(COMMIT_SLICE):
			changed = true
			worked = true
		if _tick_deco_entries(DECO_ENTRY_SLICE):
			worked = true
		if _tick_deco_finalize(DECO_BATCH_SLICE):
			changed = true
			worked = true
		if _tick_deco_frees(DECO_FREE_SLICE):
			changed = true
			worked = true
		if not worked:
			break
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


## Spawns nodes within one drain pass, shared fairly across every pending
## chunk so one dense chunk cannot starve the rest of the window. The queue is
## ordered nearest-first (see _enqueue_spawn_item), so the chunk under the
## player is always served first and never waits behind far chunks.
func _tick_spawns(budget: int) -> bool:
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
## queued for freeing, and any decoration chunk still mid-build whose window
## position is already gone is dropped so its work is not wasted.
func _reconcile_window(player_chunk: int) -> void:
	for key: String in _spawned.keys():
		var parts := key.split("/")
		var chunk := int(parts[1])
		if chunk < player_chunk - FREE_BEHIND_CHUNKS:
			_enqueue_free(key)
	for key: String in _deco_live.keys():
		var parts := key.split("/")
		var chunk := int(parts[1])
		if chunk < player_chunk - FREE_BEHIND_CHUNKS:
			_enqueue_deco_free(key)
	_drop_stale_deco_builders(player_chunk)


## Enqueues every window chunk that is neither live nor queued nor being
## decoded. Cheap enough to run every frame. A chunk's packed records are
## decoded on a worker thread (see _ensure_decoded / _settle_decodes) and only
## moved into the spawn queue once that finishes, so this never allocates a
## whole chunk's Dictionaries on the main thread.
func _enqueue_missing_window(player_chunk: int) -> void:
	for layer_idx: int in level.layers.size():
		var by_chunk: Dictionary = _chunk_entries[layer_idx]
		for chunk: int in range(player_chunk - BEHIND_CHUNKS, player_chunk + AHEAD_CHUNKS + 1):
			if not by_chunk.has(chunk):
				continue
			var key := _chunk_key(layer_idx, chunk)
			if _spawned.has(key) or _key_in_queue(_spawn_queue, key) or _key_in_queue(_free_queue, key):
				continue
			# Kick off (or reuse) the chunk's decode. When it is already ready
			# the entries come back immediately and the chunk joins the spawn
			# queue now; while it decodes on a worker the call returns empty
			# and _settle_decodes enqueues it later.
			var entries := _ensure_decoded(layer_idx, chunk, key)
			if not entries.is_empty():
				_enqueue_spawn_item(layer_idx, chunk, entries, key, player_chunk)
		# Decoration for the same window: its display batches are built (and
		# later freed) chunk by chunk, never for the whole level. Building is
		# incremental (see _tick_deco_entries) so no frame ever takes a whole
		# decorated chunk at once.
		var deco_by_chunk: Dictionary = _deco_entries[layer_idx]
		if deco_by_chunk.is_empty():
			continue
		for chunk: int in range(player_chunk - BEHIND_CHUNKS, player_chunk + AHEAD_CHUNKS + 1):
			if not deco_by_chunk.has(chunk):
				continue
			var key := _chunk_key(layer_idx, chunk)
			if _deco_busy(key) or _deco_blank.has(key):
				continue
			if _deco_threads.has(key):
				continue
			if _deco_ready.has(key):
				_begin_deco_build(key, layer_idx, _deco_ready[key])
				_deco_ready.erase(key)
			else:
				_start_deco_decode(layer_idx, chunk, key)


## Inserts a decoded chunk into the spawn queue, nearest first. Only called
## once the chunk's records finished decoding, so instantiation never blocks
## on that allocation.
func _enqueue_spawn_item(layer_idx: int, chunk: int, entries: Array, key: String, near_chunk: int) -> void:
	if _spawned.has(key) or _key_in_queue(_spawn_queue, key) or _key_in_queue(_free_queue, key):
		return
	var rec := {"nodes": [], "phys": 0, "key": key}
	var item := _make_spawn_item(layer_idx, chunk, entries, key, rec)
	# The entries now belong to the spawn item; do not keep a second reference
	# in the decoded cache.
	_decoded.erase(key)
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
		# The ground under the respawn point cannot wait on the decode worker:
		# use the cache if the decode already finished, otherwise decode here
		# (a rare one-shot cost at the moment of a restart).
		var entries := _chunk_entries_now(layer_idx, chunk, key)
		var rec := {"nodes": [], "phys": 0, "key": key}
		var item := _make_spawn_item(layer_idx, chunk, entries, key, rec)
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


# --- Decoration streaming -------------------------------------------------
#
# Decoration lives as packed records (see _deco_entries) and its display
# objects - DecorationBatch nodes - are built only while their chunk is in the
# player's window, then freed behind it. This is what stops a decorated
# level's memory and its open-time build from scaling with the whole level:
# the old path built every decoration in the level into batches at open, which
# was the crash point for decoration-heavy levels like Orbit.


## Starts a worker-thread decode of a chunk's decoration records.
func _start_deco_decode(layer_idx: int, chunk: int, key: String) -> void:
	var thread := Thread.new()
	var err := thread.start(_decode_blob.bind(_deco_entries[layer_idx][chunk]))
	if err != OK:
		# Thread pool exhausted: decode inline so the chunk still appears (a
		# rare one-frame cost beats missing decoration). The build itself is
		# still incremental.
		_begin_deco_build(key, layer_idx, _deco_entries_of(layer_idx, chunk))
		return
	_deco_threads[key] = thread


## Whether a decoration chunk is live, being built, being finalised or being
## freed (i.e. it must not be re-enqueued).
func _deco_busy(key: String) -> bool:
	return (
		_deco_live.has(key)
		or _key_in_queue(_deco_build_queue, key)
		or _key_in_queue(_deco_finalize_queue, key)
		or _key_in_queue(_deco_free_queue, key)
	)


## Queues a decoded chunk's decoration for building, nearest chunk first. The
## chunk is not built here - it joins [_deco_build_queue] with a shared
## GDDecorationLoader batch accumulator and _tick_deco_entries feeds it into
## that accumulator a few entries at a time across frames.
func _begin_deco_build(key: String, layer_idx: int, entries: Array) -> void:
	if _deco_busy(key) or _deco_blank.has(key):
		return
	if entries.is_empty():
		_deco_blank[key] = true
		return
	var parts := key.split("/")
	var chunk := int(parts[1])
	var target := _current_target_chunk()
	var distance := absi(chunk - target) if target != -0x7fffffff else 0
	var index := 0
	while index < _deco_build_queue.size():
		var other: Dictionary = _deco_build_queue[index]
		var parts_other := (other.key as String).split("/")
		var other_distance := absi(int(parts_other[1]) - target) if target != -0x7fffffff else 0
		if distance < other_distance:
			break
		index += 1
	_deco_build_queue.insert(index, {
		"key": key,
		"layer_idx": layer_idx,
		"entries": entries,
		"index": 0,
		"batches": GDDecorationLoader.new_batches(),
	})


## One drain pass of decoration entry feeding: adds up to [param budget]
## entries across the pending chunks (fairly, nearest first) into each chunk's
## batch accumulator. When a chunk's last entry is in, the chunk moves to
## [_deco_finalize_queue]. This is what stops a decorated chunk from landing
## as one multi-millisecond build: building a chunk is a per-entry cost spread
## over many passes, exactly like gameplay instantiation.
func _tick_deco_entries(budget: int) -> bool:
	var active := 0
	for item: Dictionary in _deco_build_queue:
		if int(item.index) < (item.entries as Array).size():
			active += 1
	if active == 0:
		return false
	var share := maxi(1, budget / active)
	var worked := false
	var qi := 0
	var art_scale := GDDecorationLoader.art_scale()
	while qi < _deco_build_queue.size() and budget > 0:
		var item: Dictionary = _deco_build_queue[qi]
		var entries: Array = item.entries
		if int(item.index) >= entries.size():
			_move_to_finalize(item)
			_deco_build_queue.remove_at(qi)
			worked = true
			continue
		var count: int = mini(share, entries.size() - int(item.index))
		var batches: Dictionary = item.batches
		for i: int in range(int(item.index), int(item.index) + count):
			GDDecorationLoader.add_object(batches, entries[i], art_scale)
		item.index = int(item.index) + count
		budget -= count
		worked = true
		if int(item.index) >= entries.size():
			_move_to_finalize(item)
			_deco_build_queue.remove_at(qi)
			continue
		qi += 1
	return worked


## Moves a fully fed chunk from the build queue to the finalize queue,
## snapshotting its batch nodes in insertion order for the per-batch sort.
func _move_to_finalize(item: Dictionary) -> void:
	var nodes: Array = []
	for batch: DecorationBatch in (item.batches as Dictionary).values():
		nodes.append(batch)
	_deco_finalize_queue.append({
		"key": item.key,
		"layer_idx": int(item.layer_idx),
		"batches_list": nodes,
		"built": [],
		"next_build": 0,
	})


## One drain pass of decoration finalising: sorts (batch.build) up to [param
## budget] batches of the front chunk per pass. When the chunk's last batch is
## built, its ordered batches join the layer together and the chunk is
## registered live. Sorting a whole chunk's items in one frame is itself a
## burst on a decorated level, so even this step is sliced per batch.
func _tick_deco_finalize(budget: int) -> bool:
	var worked := false
	while budget > 0 and not _deco_finalize_queue.is_empty():
		var item: Dictionary = _deco_finalize_queue[0]
		var nodes: Array = item.batches_list
		var i: int = int(item.next_build)
		while i < nodes.size() and budget > 0:
			var batch: DecorationBatch = nodes[i]
			if batch.items.is_empty():
				# A batch created for a glow layer whose frames are missing, or
				# similar; nothing to draw.
				batch.free()
			else:
				batch.build()
				(item.built as Array).append(batch)
			i += 1
			budget -= 1
		item.next_build = i
		worked = true
		if i >= nodes.size():
			# All batches sorted: order them against each other and join the
			# layer. Ordering and adding a chunk's handful of batch nodes is
			# small, so it is done atomically once the expensive per-batch
			# sorts have all run in their own passes.
			_deco_finalize_queue.remove_at(0)
			var ordered: Array = item.built
			if not ordered.is_empty():
				GDDecorationLoader.finalise_batch_order(ordered)
				_register_deco_live(str(item.key), int(item.layer_idx), ordered)
			else:
				# Everything in this chunk was undrawable; remember that so the
				# window scan stops re-requesting it.
				_deco_blank[str(item.key)] = true
		if budget <= 0:
			break
	return worked


## Adds a chunk's finished batches to its layer (above the gameplay nodes, the
## draw order a full build uses) and records the chunk as live decoration.
func _register_deco_live(key: String, layer_idx: int, batches: Array) -> void:
	if batches.is_empty() or _deco_live.has(key):
		return
	var layer: Layer = level.layers[layer_idx]
	for batch: DecorationBatch in batches:
		batch.set_meta(Constants.LAYER_META, layer)
		layer.add_child(batch)
	_deco_live[key] = batches
	_refresh_pending = true
	LevelPhysics.clear_dirty(level)


## Synchronously builds and registers one chunk's decoration - the open-time
## start region (see make) and the visual ground under a respawn. Only used
## where the work is masked by a loading moment; during play decoration builds
## go through the incremental queues above.
func _sync_build_deco(key: String, layer_idx: int, entries: Array) -> void:
	if entries.is_empty():
		_deco_blank[key] = true
		return
	var batches := GDDecorationLoader.build_batches(entries, GDDecorationLoader.art_scale())
	if batches.is_empty():
		_deco_blank[key] = true
		return
	_register_deco_live(key, layer_idx, batches)


## Queues a live decoration chunk for freeing.
func _enqueue_deco_free(key: String) -> void:
	if not _deco_live.has(key) or _key_in_queue(_deco_free_queue, key):
		return
	_deco_free_queue.append({"key": key, "batches": _deco_live[key]})


## Frees one decoration chunk's batches immediately (cancelling any queued
## teardown of it). When [param captured] is given (a queued free with the
## chunk's batches snapshotted at enqueue time) exactly those are freed and the
## live entry is only dropped if it still refers to the same batch objects - a
## chunk rebuilt between enqueue and free (respawn preload racing a teardown)
## must survive the stale free of its predecessor.
func _free_deco_chunk_now(key: String, captured: Array = []) -> void:
	# Cancel any queued teardown of this chunk, freeing its snapshotted
	# batches.
	var qi := 0
	while qi < _deco_free_queue.size():
		var item: Dictionary = _deco_free_queue[qi]
		if item.key == key:
			_free_deco_batches(item.batches)
			_deco_free_queue.remove_at(qi)
		else:
			qi += 1
	if captured.is_empty():
		if not _deco_live.has(key):
			return
		captured = _deco_live[key]
	_free_deco_batches(captured)
	# Removing layer children invalidates the shared-physics rebuild flag (the
	# level tracks any child change); decoration is not part of that physics,
	# so the flag must not force a needless rebuild on the next attempt.
	LevelPhysics.clear_dirty(level)
	# Only forget the live entry if what was freed is what is live: a rebuilt
	# chunk (new batch nodes) must not be erased by a stale teardown of its
	# predecessor. Batches are never empty for a stored chunk.
	if not _deco_live.has(key):
		return
	var current_arr: Array = _deco_live[key]
	if current_arr.is_empty():
		_deco_live.erase(key)
		return
	if captured.is_empty() or current_arr[0] == captured[0]:
		_deco_live.erase(key)


## Frees a set of DecorationBatch nodes (idempotent per node).
func _free_deco_batches(batches: Array) -> void:
	for batch: DecorationBatch in batches:
		if is_instance_valid(batch):
			batch.free()


## Cancels any partially built decoration chunk (queued or mid-finalise),
## freeing its detached batch nodes. A chunk in these queues has not joined
## the layer yet, so freeing is all a cancel needs.
func _cancel_deco_builder(key: String) -> void:
	var qi := 0
	while qi < _deco_build_queue.size():
		var item: Dictionary = _deco_build_queue[qi]
		if item.key == key:
			_free_builder_batches(item.batches)
			_deco_build_queue.remove_at(qi)
		else:
			qi += 1
	qi = 0
	while qi < _deco_finalize_queue.size():
		var item: Dictionary = _deco_finalize_queue[qi]
		if item.key == key:
			_free_deco_batches(item.batches_list)
			_deco_finalize_queue.remove_at(qi)
		else:
			qi += 1


## Cancels every partially built decoration chunk (used by teardown paths).
func _cancel_all_deco_builders() -> void:
	for item: Dictionary in _deco_build_queue:
		_free_builder_batches(item.batches)
	_deco_build_queue.clear()
	for item: Dictionary in _deco_finalize_queue:
		_free_deco_batches(item.batches_list)
	_deco_finalize_queue.clear()


## Frees the batch nodes of one in-progress chunk (the accumulator Dictionary
## holds every batch created for it so far).
func _free_builder_batches(batches: Dictionary) -> void:
	for batch: DecorationBatch in batches.values():
		if is_instance_valid(batch):
			batch.free()


## Drops decoration chunks that are mid-build but whose window position is
## already outside the kept range (a backward teleport, a very fast recede).
## Their entries re-decode and rebuild on demand if the window returns.
func _drop_stale_deco_builders(player_chunk: int) -> void:
	var stale: Array = []
	for item: Dictionary in _deco_build_queue:
		var chunk := int((item.key as String).split("/")[1])
		if chunk < player_chunk - FREE_BEHIND_CHUNKS or chunk > player_chunk + AHEAD_CHUNKS + 2:
			stale.append(item.key)
	for item: Dictionary in _deco_finalize_queue:
		var chunk := int((item.key as String).split("/")[1])
		if chunk < player_chunk - FREE_BEHIND_CHUNKS or chunk > player_chunk + AHEAD_CHUNKS + 2:
			stale.append(item.key)
	for key: String in stale:
		_cancel_deco_builder(key)


## Synchronously frees every live decoration chunk and cancels every partial
## build. Manual-restart and stream-teardown path.
func _teardown_all_deco() -> void:
	for key: String in _deco_live.keys():
		_free_deco_chunk_now(key)
	_cancel_all_deco_builders()
	_deco_free_queue.clear()
	_deco_ready.clear()


## One drain pass of decoration teardown: frees up to [param budget] live
## decoration chunks from the free queue.
func _tick_deco_frees(budget: int) -> bool:
	var worked := false
	while budget > 0 and not _deco_free_queue.is_empty():
		var item: Dictionary = _deco_free_queue[0]
		_deco_free_queue.remove_at(0)
		_free_deco_chunk_now(item.key, item.batches)
		budget -= 1
		worked = true
	return worked


## Builds the decoration of the single chunk holding [param world_x] right
## now, synchronously - the visual ground under a respawn. Used at restart,
## mirroring _spawn_chunk_now for gameplay.
func _deco_chunk_now(world_x: float) -> void:
	var chunk := _chunk_of(world_x)
	for layer_idx: int in level.layers.size():
		var deco_by_chunk: Dictionary = _deco_entries[layer_idx]
		if not deco_by_chunk.has(chunk):
			continue
		var key := _chunk_key(layer_idx, chunk)
		if _deco_live.has(key) or _deco_blank.has(key):
			continue
		_free_deco_chunk_now(key)
		_cancel_deco_builder(key)
		if _deco_live.has(key):
			continue
		var entries: Array
		if _deco_ready.has(key):
			entries = _deco_ready[key]
			_deco_ready.erase(key)
		elif _deco_threads.has(key):
			var thread: Thread = _deco_threads[key]
			if thread.is_alive():
				entries = _deco_entries_of(layer_idx, chunk)
			else:
				entries = thread.wait_to_finish() as Array
				_deco_threads.erase(key)
		else:
			entries = _deco_entries_of(layer_idx, chunk)
		_sync_build_deco(key, layer_idx, entries)


## Builds decoration for the start region at load time (see make): a small
## bounded slice - same span as the initial gameplay window - not the whole
## level's decoration.
func _initial_deco(world_x: float) -> void:
	var player_chunk := _chunk_of(world_x)
	for layer_idx: int in level.layers.size():
		var deco_by_chunk: Dictionary = _deco_entries[layer_idx]
		for chunk: int in range(player_chunk, player_chunk + START_SPAN_CHUNKS + 1):
			if not deco_by_chunk.has(chunk):
				continue
			var key := _chunk_key(layer_idx, chunk)
			if _deco_blank.has(key):
				continue
			var entries := _deco_entries_of(layer_idx, chunk)
			_sync_build_deco(key, layer_idx, entries)


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
		# Half-built decoration of the finished attempt is stale too (its
		# detached batch nodes are freed, never leaked).
		_cancel_all_deco_builders()
		_deco_ready.clear()
		var death_chunk := _chunk_of(LevelManager.player.global_position.x)
		var keys: Array = _spawned.keys()
		keys.sort_custom(func(a: String, b: String) -> bool:
			return absi(int(a.split("/")[1]) - death_chunk) > absi(int(b.split("/")[1]) - death_chunk))
		for key: String in keys:
			_enqueue_free(key)
		var deco_keys: Array = _deco_live.keys()
		deco_keys.sort_custom(func(a: String, b: String) -> bool:
			return absi(int(a.split("/")[1]) - death_chunk) > absi(int(b.split("/")[1]) - death_chunk))
		for key: String in deco_keys:
			_enqueue_deco_free(key)
	_drain(PRELOAD_DRAIN_MS)
	# Chunks that finished tearing down this frame are now free to be spawned
	# fresh.
	_enqueue_missing_window(_preload_chunk)
	if _refresh_pending:
		_refresh_pending = false
		_refresh_new_node_colors()


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
		_teardown_all_deco()
		_boost_frames = ATTEMPT_BOOST_FRAMES
	var target_chunk := _chunk_of(world_x)
	_enqueue_missing_window(target_chunk)
	_last_player_chunk = -0x7fffffff
	# Ground under the respawn point must exist and collide right now.
	_spawn_chunk_now(world_x)
	_deco_chunk_now(world_x)
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
			var entries := _entries_of(layer_idx, chunk)
			var rec := {"nodes": [], "phys": 0, "key": key}
			var item := _make_spawn_item(layer_idx, chunk, entries, key, rec)
			_spawn_slice(item, (item.entries as Array).size())
			_spawned[key] = rec
			_request_scene_preloads(entries)
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
