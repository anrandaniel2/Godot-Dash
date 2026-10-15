extends Node
## Synthetic CPU timing; same delta sequence and placement code, not FPS/GPU proof.
const LEGACY = preload("res://tools/reference/LegacyMonsterBatch.gd")
var checks: int = 0
var failed: int = 0


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failed += 1
		print("MONSTER_TIMELINE_FAIL %s" % message)


func _ready() -> void:
	_check(ClassDB.class_exists(&"NativeMonsterTimeline"), "native timeline exists")
	if failed > 0:
		get_tree().quit(1)
		return
	var saved_native: bool = Config.use_native_core
	Config.use_native_core = true
	var legacy: DecorationBatch = _make_batch(true, 100)
	var current: DecorationBatch = _make_batch(false, 100)
	var deltas: Array[float] = [0.0, 1.0 / 240.0, 0.025, 0.06, 0.5, -0.001, 0.001, 1.25]
	for tick: int in 320:
		if tick > 0 and tick % 43 == 0:
			legacy.play_monster_animation(tick % 10)
			current.play_monster_animation(tick % 10)
		if tick > 0 and tick % 79 == 0:
			legacy.reset_monster_animations()
			current.reset_monster_animations()
		# Switch between fallback/native while clocks are live.
		Config.use_native_core = tick % 17 != 0
		legacy._advance_monsters(deltas[tick % deltas.size()])
		current._advance_monsters(deltas[tick % deltas.size()])
		for index: int in current.monsters.size():
			var a: DecorationBatch.Monster = legacy.monsters[index]
			var b: DecorationBatch.Monster = current.monsters[index]
			_check(a.frame == b.frame and a.animation == b.animation, "frame/clip parity")
			_check(a.elapsed == b.elapsed, "bit-exact residual clock")
			_check(a.bound_items[0].transform == b.bound_items[0].transform, "sprite placement parity")
	_check(current._monster_timeline != null, "production dispatcher used native")
	# Same-sized replacement needs a fresh configure, not stale native mirrors.
	current._monster_timeline = null
	current.monsters[0] = _monster("GJBeast04", "sleep")
	legacy.monsters[0] = _monster("GJBeast04", "sleep")
	current._advance_monsters(0.75)
	legacy._advance_monsters(0.75)
	_check(current.monsters[0].frame == legacy.monsters[0].frame, "reconfigure new tracks")
	_check(current.monsters[0].elapsed == legacy.monsters[0].elapsed, "reconfigure residual time")
	_test_missing_clips()
	legacy.free()
	current.free()

	Config.use_native_core = true
	legacy = _make_batch(true, 2000)
	current = _make_batch(false, 2000)
	_measure(legacy)
	_measure(current)
	var old_times: Array[float] = []
	var new_times: Array[float] = []
	for trial: int in 3:
		if trial % 2 == 0:
			old_times.append(_measure(legacy))
			new_times.append(_measure(current))
		else:
			new_times.append(_measure(current))
			old_times.append(_measure(legacy))
	old_times.sort()
	new_times.sort()
	print("MONSTER_TIMELINE_BENCH tracks=2000 ticks=240 legacy_ms=%.3f native_ms=%.3f" % [old_times[1], new_times[1]])
	legacy.free()
	current.free()
	Config.use_native_core = saved_native
	print("MONSTER_TIMELINE_SELFTEST checks=%d failed=%d" % [checks, failed])
	get_tree().quit(0 if failed == 0 else 1)


func _monster(monster_name: String, animation: String) -> DecorationBatch.Monster:
	var monster: DecorationBatch.Monster = DecorationBatch.Monster.new()
	monster.name = monster_name
	monster.animation = animation
	monster.object_transform = Transform2D(0.2, Vector2(-1.2, 0.9), 0.15, Vector2(28, -8))
	monster.art_scale_factor = 2.1
	monster.sprite_indices.append(0)
	monster.trim_offsets.append(Vector2(1.5, -2.5))
	monster.bound_items.append(DecorationBatch.Item.new())
	return monster


func _make_batch(old: bool, count: int) -> DecorationBatch:
	var batch: DecorationBatch = LEGACY.new() if old else DecorationBatch.new()
	var names: Array[String] = ["GJBeast01", "GJBeast02", "GJBeast03", "GJBeast04", "GJBeast05"]
	for index: int in count:
		var monster_name: String = names[index % names.size()]
		var clips: Array = MonsterAnimations.monster(monster_name).get("animations", {}).keys()
		batch.monsters.append(_monster(monster_name, str(clips[(index / names.size()) % clips.size()])))
	return batch


func _measure(batch: DecorationBatch) -> float:
	batch.reset_monster_animations()
	batch._advance_monsters(0.0) # configure excluded; advancement + placement included
	var start: int = Time.get_ticks_usec()
	for tick: int in 240:
		batch._advance_monsters(1.0 / 240.0)
	return (Time.get_ticks_usec() - start) / 1000.0


func _test_missing_clips() -> void:
	# Exercise zero-length and missing following clips against the unchanged
	# fallback, including the old one-frame rule within a transition tick.
	var old_table: Dictionary = MonsterAnimations._table
	var old_loaded: bool = MonsterAnimations._loaded
	MonsterAnimations._loaded = true
	MonsterAnimations._table = {"monsters": {"fixture": {"default": "empty", "animations": {
		"start": {"frames": [[]], "delay": 0.0, "next": "missing"},
		"empty": {"frames": [], "delay": 0.02},
	}}}}
	var a: DecorationBatch = LEGACY.new()
	var b: DecorationBatch = DecorationBatch.new()
	for animation: String in ["start", "empty", "unknown"]:
		a.monsters.append(_monster("fixture", animation))
		b.monsters.append(_monster("fixture", animation))
	for delta: float in [0.001, 0.003, 0.08, -0.001, 0.0]:
		a._advance_monsters(delta)
		b._advance_monsters(delta)
		for index: int in a.monsters.size():
			_check(a.monsters[index].frame == b.monsters[index].frame, "empty frame parity")
			_check(a.monsters[index].animation == b.monsters[index].animation, "missing clip parity")
			_check(a.monsters[index].elapsed == b.monsters[index].elapsed, "empty clock parity")
	a.free()
	b.free()
	MonsterAnimations._table = old_table
	MonsterAnimations._loaded = old_loaded
