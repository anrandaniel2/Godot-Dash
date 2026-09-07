class_name LevelStream
extends Node
## Builds gameplay placements the way Geometry Dash does: the level's object
## records stay resident as data, and actual scene nodes only exist for a
## window around the player.
##
## A GD level never instantiates every object - it keeps a compact list of
## every object's fields and creates display nodes only for the section the
## camera is in, freeing the ones left behind. Copying that here is what lets a
## very large level (hundreds of thousands of objects) open and play on a
## phone: the memory cost stops scaling with the whole level.
##
## What lives in this window: every non-decoration placement (blocks, slopes,
## spikes, saws, orbs, pads, portals, triggers...). Decoration was already
## reduced to lightweight batch records by DecorationBatch, so it stays
## resident like the data does. When the player crosses into a new horizontal
## chunk the stream instantiates it (same per-object path the editor uses,
## including collision, colour channels and components) and freezes out chunks
## far behind; physics is rebuilt from whichever nodes now exist. Respawning
## after death simply rebuilds the window from the records, which also resets
## every one-shot object exactly as GD respawns do.

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

## Set on the Level while its gameplay placements are streamed.
const STREAMING_META: StringName = &"_gd_level_streaming"

var level: Level
## Original level data the entries reference; kept so the records live.
var source_data: Dictionary
## Per layer index: chunk id -> Array of object-data entries.
var _chunk_entries: Array = []
## Chunk id -> live nodes of that chunk ("layer/chunk").
var _spawned: Dictionary = {}
var _last_player_chunk: int = -0x7fffffff


static func is_streaming(level: Level) -> bool:
	return level != null and bool(level.get_meta(STREAMING_META, false))


static func make(level: Level, data: Dictionary) -> LevelStream:
	var stream := LevelStream.new()
	stream.level = level
	stream.source_data = data
	stream.name = "LevelStream"
	stream._index(data)
	level.set_meta(STREAMING_META, true)
	level.add_child(stream, false, INTERNAL_MODE_BACK)
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
			var chunk := floori(x / (CHUNK_CELLS * Constants.CELL_SIZE))
			if not by_chunk.has(chunk):
				by_chunk[chunk] = []
			by_chunk[chunk].append(entry)
		_chunk_entries[layer_idx] = by_chunk


func _process(_delta: float) -> void:
	if not LevelManager.level_playing:
		return
	if LevelManager.player == null:
		return
	sync_to(LevelManager.player.global_position.x)


## Spawns the window around world x and frees chunks far behind it.
func sync_to(world_x: float) -> void:
	var player_chunk := floori(world_x / (CHUNK_CELLS * Constants.CELL_SIZE))
	if player_chunk == _last_player_chunk:
		return
	_last_player_chunk = player_chunk
	var changed := false
	var spawned_any := false
	for layer_idx: int in level.layers.size():
		var by_chunk: Dictionary = _chunk_entries[layer_idx]
		for chunk: int in range(player_chunk - BEHIND_CHUNKS, player_chunk + AHEAD_CHUNKS + 1):
			var key: String = "%d/%d" % [layer_idx, chunk]
			if _spawned.has(key) or not by_chunk.has(chunk):
				continue
			_spawn_chunk(layer_idx, chunk, by_chunk[chunk], key)
			changed = true
			spawned_any = true
	# Free what is far enough behind that it will not be re-entered casually.
	for key: String in _spawned.keys():
		var parts := key.split("/")
		var chunk := int(parts[1])
		if chunk < player_chunk - FREE_BEHIND_CHUNKS:
			_free_chunk(key)
			changed = true
	if changed:
		if spawned_any:
			# The level's colour-channel watchers ran their one-shot _ready
			# before these nodes existed, so push the current channel colours
			# into the freshly spawned watchers.
			_refresh_new_node_colors()
		level.stream_physics_dirty()


func _spawn_chunk(layer_idx: int, chunk: int, entries: Array, key: String) -> void:
	var layer: Layer = level.layers[layer_idx]
	# Gameplay nodes draw under the decoration batches of the same z layer, the
	# order the full build uses; batches were added first here, so insert each
	# gameplay node right before them.
	var insert_at := layer.get_child_count()
	for child in layer.get_children():
		if child is DecorationBatch:
			insert_at = child.get_index()
			break
	var nodes: Array = []
	for entry: Dictionary in entries:
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
		nodes.append(object)
	_spawned[key] = nodes


func _free_chunk(key: String) -> void:
	# Nodes are freed immediately, not queue_free()d: the physics rebuild for
	# this window change runs in the same frame, so a node still pending
	# deletion would have its geometry re-harvested into the shared bodies and
	# then linger there as a ghost until the next chunk boundary. Immediate
	# frees also release the memory right away, which is the whole point of
	# streaming a huge level on a phone.
	for node: Node2D in _spawned[key]:
		node.free()
	_spawned.erase(key)


## Re-colours nodes spawned after the level's [ColorChannelWatcher]s already
## ran their one-shot _ready pass (any gameplay chunk created mid-play or on a
## streamed respawn). Each watcher re-queries its channel group, so only the
## channels the new nodes use are visited.
func _refresh_new_node_colors() -> void:
	if not level.is_inside_tree():
		return
	for child: Node in level.get_children():
		if child is ColorChannelWatcher:
			child.refresh_objects_color()


## Every live gameplay node is freed and the window is respawned around
## [param world_x] from the resident records. Used on restart: fresh nodes mean
## one-shot orbs, toggled objects and triggers start clean, exactly like GD
## respawns. The physics rebuild happens on the next level start (the shared
## bodies are rebuilt from whichever nodes exist then).
func reset_to(world_x: float) -> void:
	for key: String in _spawned.keys():
		_free_chunk(key)
	_last_player_chunk = -0x7fffffff
	sync_to(world_x)
	level.stream_physics_dirty()
