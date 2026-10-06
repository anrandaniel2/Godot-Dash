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
	TOUCH,
	FOLLOW_PLAYER_Y,
	EVENT,
	OPTIONS,
	ADV_FOLLOW,
	ADV_FOLLOW_EDIT,
	ADV_FOLLOW_RETARGET,
	SPAWN_PARTICLE,
	BG_SPEED,
	RESET_GROUP,
	END_WALL,
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
	1595: Kind.TOUCH,
	1814: Kind.FOLLOW_PLAYER_Y,
	3604: Kind.EVENT,
	2899: Kind.OPTIONS,
	3016: Kind.ADV_FOLLOW,
	3660: Kind.ADV_FOLLOW_EDIT,
	3661: Kind.ADV_FOLLOW_RETARGET,
	3608: Kind.SPAWN_PARTICLE,
	3606: Kind.BG_SPEED,
	3618: Kind.RESET_GROUP,
	1931: Kind.END_WALL,
}

const ADV_TICK_HZ: float = 240.0
const PX_PER_UNIT: float = 128.0 / 30.0

## GD units to pixels on Y (+Y up in GD); matches native CELLS_TO_PX_Y.
const UNITS_TO_PX_Y: float = -128.0 / 30.0

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
static var _armed_touches: Array[GameplayTriggerComponent] = []
static var _armed_events: Array[GameplayTriggerComponent] = []
static var _touch_states: Dictionary[GameplayTriggerComponent, bool] = {}
## Target group -> {"trigger", "player", "remaining", "history": Array[Vector2] of (time, y)}.
static var _follow_player_y: Dictionary[String, Dictionary] = {}
## Each {"trigger", "order", "start", "player", "history": Array[Vector3] (time, x, y)},
## sorted by priority (key 365) descending, then spawn order.
static var _adv_follows: Array[Dictionary] = []
static var _adv_order: int = 0
static var _adv_velocities: Dictionary[Node2D, Vector2] = {}
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
	_armed_touches.clear()
	_armed_events.clear()
	_touch_states.clear()
	_follow_player_y.clear()
	_adv_follows.clear()
	_adv_velocities.clear()
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


static func notify_touch(player: Player, slot: int, pressed: bool) -> void:
	for trigger: GameplayTriggerComponent in _armed_touches.duplicate():
		if not is_instance_valid(trigger):
			continue
		var only: int = trigger._i("198")
		if only != 0 and only != slot:
			continue
		var result: int = GDItemMath.touch_toggle_result(trigger._b("81"), trigger._i("82"), pressed, _touch_states.get(trigger, true))
		if result < 0:
			continue
		_touch_states[trigger] = result == 1
		trigger._toggle_spawn_state(result == 1, player)


static func notify_event(player: Player, event_id: int, slot: int, material: int) -> void:
	for trigger: GameplayTriggerComponent in _armed_events.duplicate():
		if not is_instance_valid(trigger):
			continue
		var ids := PackedInt32Array()
		for part: String in trigger.properties.get("430", "").replace(",", ".").split(".", false):
			ids.append(int(part))
		if GDItemMath.event_matches(ids, material, trigger._i("525"), event_id, trigger._i("447"), slot):
			_spawn(trigger.properties.get("51", ""), player)


static func _step_follow_player_y(delta: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for group: String in _follow_player_y.keys():
		var follow: Dictionary = _follow_player_y[group]
		var trigger: GameplayTriggerComponent = follow["trigger"]
		var player: Player = follow["player"]
		if not is_instance_valid(trigger) or not is_instance_valid(player) or float(follow["remaining"]) <= 0.0:
			_follow_player_y.erase(group)
			continue
		var history: Array[Vector2] = follow["history"]
		history.append(Vector2(_level_time, player.global_position.y))
		var delay: float = maxf(0.0, trigger._f("91"))
		while history.size() > 1 and history[1].x <= _level_time - delay:
			history.pop_front()
		var target: float = history[0].y + trigger._f("92") * UNITS_TO_PX_Y
		var max_px: float = absf(trigger._f("105") / 4.0 * UNITS_TO_PX_Y)
		for node: Node in tree.get_nodes_in_group(StringName(Constants.GROUP_PREFIX + group)):
			if node is Node2D:
				var node_2d := node as Node2D
				node_2d.global_position.y += GDItemMath.follow_player_y_step(node_2d.global_position.y, target, trigger._f("90", 1.0), max_px, delta)
		follow["remaining"] = float(follow["remaining"]) - delta


static func _adv_center(follow: Dictionary) -> Variant:
	var trigger: GameplayTriggerComponent = follow.get("retarget", follow["trigger"])
	if trigger._b("138"):
		return LevelManager.player.global_position if is_instance_valid(LevelManager.player) else null
	if trigger._b("200"):
		for dual: Player in LevelManager.player_duals:
			if is_instance_valid(dual):
				return dual.global_position
		return null
	var tree := Engine.get_main_loop() as SceneTree
	for node: Node in tree.get_nodes_in_group(StringName(Constants.GROUP_PREFIX + trigger.properties.get("71", ""))):
		if node is Node2D:
			return (node as Node2D).global_position
	return null


## Twin of the native step_adv_follow (gd_docs advanced_follow.md).
static func _step_adv_follow(delta: float) -> void:
	if _adv_follows.is_empty():
		return
	var tree := Engine.get_main_loop() as SceneTree
	var ticks: float = delta * ADV_TICK_HZ
	var exclusive: Dictionary[Node2D, bool] = {}
	var touched: Dictionary[Node2D, bool] = {}
	for follow: Dictionary in _adv_follows:
		var trigger: GameplayTriggerComponent = follow["trigger"]
		if not is_instance_valid(trigger):
			continue
		if follow.has("retarget") and not is_instance_valid(follow["retarget"]):
			follow.erase("retarget")
		var now: Variant = _adv_center(follow)
		if now == null:
			continue
		var history: Array[Vector3] = follow["history"]
		history.append(Vector3(_level_time, now.x, now.y))
		var delay: float = maxf(0.0, trigger._f("292"))
		while history.size() > 1 and history[1].x <= _level_time - delay:
			history.pop_front()
		if _level_time - float(follow["start"]) < delay:
			continue
		var center := Vector2(history[0].y, history[0].z)
		for node: Node in tree.get_nodes_in_group(StringName(Constants.GROUP_PREFIX + trigger.properties.get("51", ""))):
			var target := node as Node2D
			if target == null or target == follow["player"] or exclusive.has(target):
				continue
			var offset: Vector2 = (center - target.global_position) / PX_PER_UNIT
			var result: Array = GDItemMath.adv_follow_tick(trigger.properties, offset, _adv_velocities.get(target, Vector2.ZERO), not _adv_velocities.has(target))
			_adv_velocities[target] = result[1]
			var step: Vector2 = result[0] * ticks
			if trigger._i("367") == 0 and step.length_squared() > offset.length_squared():
				step = offset
			touched[target] = true
			if trigger._b("571") and step != Vector2.ZERO:
				exclusive[target] = true
			target.global_position += step * PX_PER_UNIT
	for target: Node2D in _adv_velocities.keys():
		if not touched.has(target):
			_adv_velocities.erase(target)


## Key 56 unchecked toggles the group off; checked toggles it on and spawns it.
func _toggle_spawn(player: Player) -> void:
	_toggle_spawn_state(_b("56"), player)


func _toggle_spawn_state(on: bool, player: Player) -> void:
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
	_step_follow_player_y(delta)
	_step_adv_follow(delta)
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
		Kind.TOUCH:
			if not _armed_touches.has(self):
				_armed_touches.append(self)
		Kind.EVENT:
			if not _armed_events.has(self):
				_armed_events.append(self)
		Kind.ADV_FOLLOW:
			_adv_order += 1
			var adv_history: Array[Vector3] = []
			_adv_follows.append({ "trigger": self, "order": _adv_order, "start": _level_time, "player": player, "history": adv_history })
			_adv_follows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var pa: int = (a["trigger"] as GameplayTriggerComponent)._i("365") if is_instance_valid(a["trigger"]) else 0
				var pb: int = (b["trigger"] as GameplayTriggerComponent)._i("365") if is_instance_valid(b["trigger"]) else 0
				return pa > pb if pa != pb else int(a["order"]) < int(b["order"]))
		Kind.ADV_FOLLOW_EDIT:
			var dir_ref: Node2D = null
			for node: Node in get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + properties.get("565", ""))):
				if node is Node2D:
					dir_ref = node as Node2D
					break
			for node: Node in get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + properties.get("51", ""))):
				var target := node as Node2D
				if target == null or not _adv_velocities.has(target):
					continue
				var base: float = -PI / 2.0
				if dir_ref != null and dir_ref.global_position != target.global_position:
					base = (dir_ref.global_position - target.global_position).angle()
				_adv_velocities[target] = GDItemMath.adv_follow_edit(_adv_velocities[target],
						_f("566", 1.0) + randf() * _f("567"), _f("568", 1.0) + randf() * _f("569"),
						_f("300") + randf() * _f("301"), base + deg_to_rad(_f("563") + randf() * _f("564")), _b("306"), _b("307"))
		Kind.ADV_FOLLOW_RETARGET:
			if _i("71") > 0 or _b("138") or _b("200"):
				var follow_triggers: Array[Node] = get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + properties.get("51", "")))
				for follow: Dictionary in _adv_follows:
					var trigger: GameplayTriggerComponent = follow["trigger"]
					if is_instance_valid(trigger) and follow_triggers.has(trigger.parent):
						follow["retarget"] = self
						(follow["history"] as Array).clear()
		Kind.SPAWN_PARTICLE:
			var level: Level = LevelManager.current_level
			var targets: Array[Node] = get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + properties.get("71", "")))
			if level != null and not targets.is_empty():
				var target := targets.pick_random() as Node2D
				var datas: Variant = level.gd_particle_groups.get(Constants.GROUP_PREFIX + properties.get("51", ""))
				if target != null and datas != null:
					for raw: String in datas:
						var offset := Vector2(_f("547") + randf_range(-1.0, 1.0) * _f("549"), -(_f("548") + randf_range(-1.0, 1.0) * _f("550"))) * PX_PER_UNIT
						var rotation: float = _f("552") + randf_range(-1.0, 1.0) * _f("553")
						if _b("551"):
							rotation += rad_to_deg(target.global_rotation)
						GDParticleSpawner.spawn(GDParticleSpawner.parse(raw), target.global_position + offset, rotation,
								_f("554", 1.0) + randf_range(-1.0, 1.0) * _f("555"), level)
		Kind.BG_SPEED:
			if LevelManager.current_level != null:
				LevelManager.current_level.apply_gd_bg_speed(Vector2(_f("143", 0.1), _f("144", 0.1)))
		Kind.RESET_GROUP:
			for node: Node in get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + properties.get("51", ""))):
				if node.has_method(&"gd_reset"):
					node.call(&"gd_reset")
		Kind.END_WALL:
			for node: Node in get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + properties.get("51", ""))):
				if node is Node2D and LevelManager.current_level != null:
					LevelManager.current_level.apply_gd_end_wall((node as Node2D).global_position, _b("59"))
					break
		Kind.OPTIONS:
			if LevelManager.current_level != null:
				LevelManager.current_level.apply_gd_options(properties)
		Kind.FOLLOW_PLAYER_Y:
			var group: String = properties.get("51", "")
			if player != null and not group.is_empty() and group != "0":
				var history: Array[Vector2] = []
				_follow_player_y[group] = { "trigger": self, "player": player, "remaining": maxf(0.0, _f("10")), "history": history }
		Kind.REVERSE:
			if player != null and not LevelManager.platformer:
				player.horizontal_direction = -player.horizontal_direction
