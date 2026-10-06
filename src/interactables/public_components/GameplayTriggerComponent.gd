class_name GameplayTriggerComponent
extends Component
## Twin of the native gameplay arms (native/src/gdash_native.cpp): Item Edit
## (3619), Item Compare (3620), Persistent Item (3641), Time (3614), Time
## Event (3615), Time Control (3617), Sequence (3607) and Reverse (1917). Keys
## from gmdkit data/csv/prop_table.csv; [member properties] holds the raw GD
## keys. Items share [member ToggleComponent.item_counts] so Count triggers
## fire on edits.

enum Kind {
	ITEM_EDIT,
	ITEM_COMPARE,
	ITEM_PERSIST,
	TIMER_START,
	TIMER_EVENT,
	TIMER_CONTROL,
	SEQUENCE,
	REVERSE,
	COLLISION,
	INSTANT_COLLISION,
	ON_DEATH,
}

const KIND_BY_ID: Dictionary[int, Kind] = {
	3619: Kind.ITEM_EDIT,
	3620: Kind.ITEM_COMPARE,
	3641: Kind.ITEM_PERSIST,
	3614: Kind.TIMER_START,
	3615: Kind.TIMER_EVENT,
	3617: Kind.TIMER_CONTROL,
	3607: Kind.SEQUENCE,
	1917: Kind.REVERSE,
	1815: Kind.COLLISION,
	3609: Kind.INSTANT_COLLISION,
	1812: Kind.ON_DEATH,
}

## Godot group holding imported collision blocks (1816); twin of the native
## refresh_collision_blocks().
const COLLISION_BLOCK_GROUP: StringName = &"gd_collision_block"

## Timer id -> {"value", "mod", "running", "has_stop", "stop", "target", "player"}.
static var timers: Dictionary[int, Dictionary] = {}
## Each {"timer", "time", "group", "multi", "player"}.
static var timer_events: Array[Dictionary] = []
static var points: int = 0
static var _last_timer_frame: int = -1
static var _level_time: float = 0.0
static var _armed_collisions: Array[GameplayTriggerComponent] = []
static var _armed_deaths: Array[GameplayTriggerComponent] = []
## Pair key -> last recorded overlap state.
static var _collision_states: Dictionary[int, bool] = {}
## Pair key -> [block a, block b] for every collision trigger in the level.
static var _collision_pairs: Dictionary[int, PackedInt32Array] = {}

@export var kind: Kind = Kind.ITEM_EDIT
@export var properties: Dictionary[String, String] = {}

var _sequence_state: Dictionary = {}


static func reset_state() -> void:
	timers.clear()
	timer_events.clear()
	points = 0
	_level_time = 0.0
	_armed_collisions.clear()
	_armed_deaths.clear()
	_collision_states.clear()


func _ready() -> void:
	parent.interacted.connect(_on_interacted)
	if kind == Kind.COLLISION or kind == Kind.INSTANT_COLLISION:
		var key: int = _collision_key()
		_collision_pairs[key] = GDItemMath.collision_pair_sides(key)


func _collision_key() -> int:
	return GDItemMath.collision_pair_key(_i("80"), _i("95"), _b("138"), _b("200"), _b("201"))


static func notify_player_death(player: Player) -> void:
	for trigger: GameplayTriggerComponent in _armed_deaths.duplicate():
		if is_instance_valid(trigger):
			trigger._toggle_spawn(player)


## Key 56 unchecked toggles the group off; checked toggles it on and spawns it.
func _toggle_spawn(player: Player) -> void:
	var on: bool = _b("56")
	for node: Node in get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + properties.get("51", ""))):
		if node is CanvasItem:
			(node as CanvasItem).visible = on
		node.set_deferred(&"process_mode", PROCESS_MODE_INHERIT if on else PROCESS_MODE_DISABLED)
	if on:
		_spawn(properties.get("51", ""), player)


static func _node_box(node: Node2D) -> Rect2:
	if node == null or not node.is_visible_in_tree():
		return Rect2()
	var half: Vector2 = node.global_scale.abs() * 64.0
	return Rect2(node.global_position - half, half * 2.0)


static func _overlaps(a: Rect2, b: Rect2) -> bool:
	return a.has_area() and b.has_area() and a.intersects(b)


static func _evaluate_pair(a: int, b: int, blocks: Array[Node]) -> bool:
	var player_box: Rect2 = _node_box(LevelManager.player) if is_instance_valid(LevelManager.player) else Rect2()
	if a < 0 and b < 0:
		return false
	if a < 0:
		if a != -1:
			return false
		for block: Node in blocks:
			if int(block.get_meta(&"gd_block_id", 0)) == b and _overlaps(player_box, _node_box(block as Node2D)):
				return true
		return false
	for first: Node in blocks:
		if int(first.get_meta(&"gd_block_id", 0)) != a:
			continue
		var first_box: Rect2 = _node_box(first as Node2D)
		for second: Node in blocks:
			if second == first or int(second.get_meta(&"gd_block_id", 0)) != b:
				continue
			if not first.get_meta(&"gd_block_dynamic", false) and not second.get_meta(&"gd_block_dynamic", false):
				continue
			if _overlaps(first_box, _node_box(second as Node2D)):
				return true
	return false


## Every tick after movement; armed Collision triggers fire on the change
## they watch (gd_docs collision_trigger.md).
static func _check_collisions() -> void:
	if _collision_pairs.is_empty():
		return
	var tree := Engine.get_main_loop() as SceneTree
	var blocks: Array[Node] = tree.get_nodes_in_group(COLLISION_BLOCK_GROUP)
	for key: int in _collision_pairs:
		var pair: PackedInt32Array = _collision_pairs[key]
		var now: bool = _evaluate_pair(pair[0], pair[1], blocks)
		var before: bool = _collision_states.get(key, false)
		_collision_states[key] = now
		if now == before:
			continue
		for trigger: GameplayTriggerComponent in _armed_collisions.duplicate():
			if is_instance_valid(trigger) and trigger._collision_key() == key and now != trigger._b("93"):
				trigger._toggle_spawn(LevelManager.player)


func _physics_process(delta: float) -> void:
	var frame: int = Engine.get_physics_frames()
	if frame == _last_timer_frame:
		return
	_last_timer_frame = frame
	_level_time += delta
	_advance_timers(delta)
	_check_collisions()


static func _advance_timers(delta: float) -> void:
	for timer_id: int in timers.keys():
		var timer: Dictionary = timers[timer_id]
		if not timer.get("running", false):
			continue
		var before: float = timer["value"]
		var mod: float = timer["mod"]
		var after: float = before + delta * mod
		var stopped := false
		var stop: float = timer["stop"]
		if timer["has_stop"] and ((mod >= 0.0 and before < stop and after >= stop) or (mod < 0.0 and before > stop and after <= stop)):
			after = stop
			stopped = true
		timer["value"] = after
		for ev: Dictionary in timer_events.duplicate():
			var time: float = ev["time"]
			if ev["timer"] == timer_id and ((before < time and after >= time) or (before > time and after <= time)):
				_spawn(ev["group"], ev["player"])
				if not ev["multi"]:
					timer_events.erase(ev)
		if stopped:
			timer["running"] = false
			_spawn(timer["target"], timer["player"])


static func _spawn(group: String, player: Player) -> void:
	if group.is_empty() or group == "0":
		return
	var tree := Engine.get_main_loop() as SceneTree
	for node: Node in tree.get_nodes_in_group(StringName(Constants.GROUP_PREFIX + group)):
		if node.has_signal(&"interacted"):
			node.interacted.emit(player)


func _i(key: String, fallback: int = 0) -> int:
	return int(properties.get(key, str(fallback)))


func _f(key: String, fallback: float = 0.0) -> float:
	return float(properties.get(key, str(fallback)))


func _b(key: String) -> bool:
	return properties.get(key, "0") == "1"


## ItemType (gmdkit enums): 0/1 item, 2 timer, 3 points, 4 main time, 5 attempts.
static func item_read(type: int, id: int) -> float:
	match type:
		2:
			return float(timers.get(id, {}).get("value", 0.0))
		3:
			return float(points)
		4:
			return _level_time
	return float(ToggleComponent.item_counts.get(id, 0))


static func item_write(type: int, id: int, value: float, player: Player) -> void:
	match type:
		2:
			if not timers.has(id):
				timers[id] = _new_timer()
			timers[id]["value"] = GDItemMath.timer_clamp(value)
		3:
			points = GDItemMath.to_item_int(value)
		4, 5:
			pass
		_:
			ToggleComponent.change_item(id, GDItemMath.to_item_int(value) - int(ToggleComponent.item_counts.get(id, 0)), player)


static func _new_timer() -> Dictionary:
	return { "value": 0.0, "mod": 1.0, "running": false, "has_stop": false, "stop": 0.0, "target": "", "player": null }


func _on_interacted(player: Player = null) -> void:
	match kind:
		Kind.ITEM_EDIT:
			var type_a: int = _i("476")
			var type_b: int = _i("477")
			var rhs: float = GDItemMath.edit_rhs(
					item_read(type_a, _i("80")), item_read(type_b, _i("95")),
					_i("481", 1), _i("482", 3), _f("479", 1.0), _i("485"), _i("578"))
			var type_t: int = _i("478")
			var current: float = item_read(type_t, _i("51"))
			var result: float = GDItemMath.sign_op(GDItemMath.round_op(GDItemMath.arith(current, _i("480"), rhs), _i("486")), _i("579"))
			item_write(type_t, _i("51"), result, player)
		Kind.ITEM_COMPARE:
			var type_a: int = _i("476")
			var type_b: int = _i("477")
			var left: float = GDItemMath.compare_side(item_read(type_a, _i("80")), _i("480", 3), _f("479", 1.0), _i("485"), _i("578"))
			var right: float = GDItemMath.compare_side(item_read(type_b, _i("95")), _i("481", 3), _f("483", 1.0), _i("486"), _i("579"))
			if GDItemMath.compare(left, _i("482"), right, _f("484")):
				_spawn(properties.get("51", ""), player)
			else:
				_spawn(properties.get("71", ""), player)
		Kind.ITEM_PERSIST:
			ToggleComponent.set_persistent(_i("80"), _b("491"), _b("492"), _b("493"), _b("494"))
		Kind.TIMER_START:
			var timer_id: int = _i("80")
			var exists: bool = timers.has(timer_id)
			if not exists:
				timers[timer_id] = _new_timer()
			var timer: Dictionary = timers[timer_id]
			if not (_b("468") and exists):
				timer["value"] = _f("467")
			timer["mod"] = _f("470", 1.0)
			timer["has_stop"] = _b("474")
			timer["stop"] = _f("473")
			timer["target"] = properties.get("51", "")
			timer["player"] = player
			timer["running"] = not _b("471")
		Kind.TIMER_EVENT:
			var timer_id: int = _i("80")
			if timers.has(timer_id) and GDItemMath.timer_event_due(timers[timer_id]["mod"], _f("473"), timers[timer_id]["value"]):
				_spawn(properties.get("51", ""), player)
				if not _b("475"):
					return
			timer_events.append({ "timer": _i("80"), "time": _f("473"), "group": properties.get("51", ""), "multi": _b("475"), "player": player })
		Kind.TIMER_CONTROL:
			if timers.has(_i("80")):
				timers[_i("80")]["running"] = _i("472") == 0
		Kind.SEQUENCE:
			var groups := PackedStringArray()
			var counts := PackedInt32Array()
			var parts: PackedStringArray = properties.get("435", "").replace(",", ".").split(".")
			for index: int in range(0, parts.size() - 1, 2):
				if int(parts[index]) > 0 and float(parts[index + 1]) > 0.0:
					groups.append(parts[index])
					counts.append(int(float(parts[index + 1])))
			var step: int = GDItemMath.sequence_advance(_sequence_state, counts, _i("436"), _f("437"), _f("438"), _i("439"), _level_time)
			if step >= 0:
				_spawn(groups[step], player)
		Kind.COLLISION:
			if not _armed_collisions.has(self):
				_armed_collisions.append(self)
		Kind.INSTANT_COLLISION:
			if _collision_states.get(_collision_key(), false):
				_spawn(properties.get("51", ""), player)
			else:
				_spawn(properties.get("71", ""), player)
		Kind.ON_DEATH:
			if not _armed_deaths.has(self):
				_armed_deaths.append(self)
		Kind.REVERSE:
			if player != null and not LevelManager.platformer:
				player.horizontal_direction = -player.horizontal_direction
