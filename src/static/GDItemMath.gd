class_name GDItemMath
## Twin of the native Item Edit / Item Compare / Sequence helpers
## (native/src/gdash_native.cpp item_arith .. sequence_advance). Enums from
## gmdkit src/gmdkit/utils/enums.py: ItemOperation 0 EQUAL, 1 ADD/GT,
## 2 SUBTRACT/GE, 3 MULTIPLY/LT, 4 DIVIDE/LE, 5 NOT_EQUAL; ItemRoundOp 0 none,
## 1 round, 2 floor, 3 ceiling; ItemSignOp 0 none, 1 absolute, 2 negative;
## SequenceMode 0 stop, 1 loop, 2 last; SequenceResetType 0 full, 1 step.


static func arith(a: float, op: int, b: float) -> float:
	match op:
		0:
			return b
		1:
			return a + b
		2:
			return a - b
		3:
			return a * b
		4:
			return a / b
	return a


static func round_op(v: float, op: int) -> float:
	match op:
		1:
			return roundf(v)
		2:
			return floorf(v)
		3:
			return ceilf(v)
	return v


static func sign_op(v: float, op: int) -> float:
	match op:
		1:
			return absf(v)
		2:
			return -absf(v)
	return v


## Items are int32: truncate toward zero and saturate; NaN becomes -2^31.
static func to_item_int(v: float) -> int:
	if is_nan(v):
		return -2147483648
	if v >= 2147483647.0:
		return 2147483647
	if v <= -2147483648.0:
		return -2147483648
	return int(v)


static func timer_clamp(v: float) -> float:
	if is_nan(v):
		return 0.0
	return clampf(v, -9999999.0, 9999999.0)


static func timer_event_due(mod: float, target: float, time: float) -> bool:
	return (mod > 0.0 and target > 0.0 and time >= target) or (mod < 0.0 and target < 0.0 and time <= target)


## Tolerance widens each comparison toward true (gd_docs item_compare.md).
static func compare(l: float, op: int, r: float, tolerance: float) -> bool:
	var d: float = l - r
	match op:
		1:
			return d > -tolerance
		2:
			return d >= -tolerance
		3:
			return d < tolerance
		4:
			return d <= tolerance
		5:
			return absf(d) > tolerance
	return absf(d) <= tolerance


## Unset item IDs read 0; op2 0 means +, op3 0 means multiply.
static func edit_rhs(a: float, b: float, op2: int, op3: int, mod: float, round_1: int, sign_1: int) -> float:
	var v: float = arith(a, 1 if op2 == 0 else op2, b)
	v = arith(v, 3 if op3 == 0 else op3, mod)
	return sign_op(round_op(v, round_1), sign_1)


## Op 0 makes the side equal to the mod.
static func compare_side(value: float, op: int, mod: float, round_mode: int, sign_mode: int) -> float:
	return sign_op(round_op(arith(value, op, mod), round_mode), sign_mode)


## Counts expand into sum(counts) steps. [param state] holds "step" and
## "last". Returns the group index to spawn or -1. A call blocked by MinInt
## leaves "last" unchanged.
static func sequence_advance(state: Dictionary, counts: PackedInt32Array, mode: int, min_interval: float, reset_time: float, reset_type: int, now: float) -> int:
	var total: int = 0
	for c: int in counts:
		total += maxi(0, c)
	if total <= 0:
		return -1
	var last: float = state.get("last", -1.0)
	if last >= 0.0 and min_interval > 0.0 and now - last < min_interval:
		return -1
	var step: int = state.get("step", 0)
	if last >= 0.0 and reset_time > 0.0 and now - last >= reset_time:
		if reset_type == 1:
			step = maxi(0, step - floori((now - last) / reset_time))
		else:
			step = 0
	state["last"] = now
	if step >= total:
		state["step"] = step
		return -1
	var cursor: int = step
	var group: int = 0
	for i: int in counts.size():
		var c: int = maxi(0, counts[i])
		if cursor < c:
			group = i
			break
		cursor -= c
	step += 1
	if step >= total:
		match mode:
			1:
				step = 0
			2:
				step = total - 1
			_:
				step = total
	state["step"] = step
	return group


## Collision pair key (1815/3609): P1 = -1, P2 = -2 replace block A; PP pairs
## the players. Unordered.
static func collision_pair_key(a: int, b: int, p1: bool, p2: bool, pp: bool) -> int:
	if pp:
		a = -1
		b = -2
	elif p1:
		a = -1
	elif p2:
		a = -2
	if a > b:
		var swap: int = a
		a = b
		b = swap
	return (a << 32) ^ (b & 0xffffffff)


## Inverse of [method collision_pair_key]: [side a, side b].
static func collision_pair_sides(key: int) -> PackedInt32Array:
	var low: int = key & 0xffffffff
	if low >= 0x80000000:
		low -= 0x100000000
	return PackedInt32Array([key >> 32, low])


## Touch (1595): 1 toggle on, 0 toggle off, -1 nothing. Twin of the native
## touch_toggle_result.
static func touch_toggle_result(hold: bool, mode: int, pressed: bool, current_on: bool) -> int:
	if hold:
		return 1 if (mode == 1) == pressed else 0
	if not pressed:
		return -1
	if mode == 1:
		return 1
	if mode == 2:
		return 0
	return 0 if current_on else 1


## Follow Player Y (1814): easing 4/speed, max px per 60 Hz frame (0 = none).
static func follow_player_y_step(current: float, target: float, speed: float, max_px: float, dt: float) -> float:
	var diff: float = target - current
	var frac: float = 1.0 if speed >= 4.0 else clampf(speed / 4.0 * dt * 60.0, 0.0, 1.0)
	var step: float = diff * frac
	if max_px > 0.0:
		var limit: float = max_px * dt * 60.0
		step = clampf(step, -limit, limit)
	return step


## Event (3604): any listed id, exact material, player 0 = any.
static func event_matches(ids: PackedInt32Array, material: int, player: int, event_id: int, event_material: int, slot: int) -> bool:
	return ids.has(event_id) and material == event_material and (player == 0 or player == slot)


## Advanced Follow (3016) tick, twin of the native adv_follow_tick. [param p]
## holds the raw GD keys (gmdkit prop_table adv_follow). Returns
## [step, velocity] in GD units per 240 Hz tick; out of range leaves the
## velocity unchanged and steps zero.
## Twin of native adv_start_heading: speed reference (560) -> its last movement,
## else direction reference (565) -> toward it, else up; plus `dir_deg` clockwise.
static func adv_start_heading(has_speed_ref: bool, ref_motion: Vector2, has_dir_ref: bool, to_ref: Vector2, dir_deg: float) -> float:
	var base: float = -PI / 2.0
	if has_speed_ref:
		if ref_motion != Vector2.ZERO:
			base = ref_motion.angle()
	elif has_dir_ref and to_ref != Vector2.ZERO:
		base = to_ref.angle()
	return base + deg_to_rad(dir_deg)


## Twin of native adv_rotate_step (Rotate Dir easing, capped per tick).
static func adv_rotate_step(current: float, target: float, easing: float, max_step: float) -> float:
	var diff: float = fposmod(target - current + PI, TAU) - PI
	var step: float = diff / easing if easing > 1.0 else diff
	return current + clampf(step, -max_step, max_step)


static func adv_follow_tick(p: Dictionary, offset: Vector2, velocity: Vector2, first: bool, start_override: Variant = null) -> Array:
	var x_only: bool = p.get("306", "0") == "1"
	var y_only: bool = p.get("307", "0") == "1"
	if x_only:
		offset.y = 0.0
	if y_only:
		offset.x = 0.0
	var dist: float = offset.length()
	var max_range: float = float(p.get("308", "0"))
	if max_range < 0.0 or (max_range > 0.0 and dist > max_range):
		return [Vector2.ZERO, velocity]
	if int(p.get("367", "0")) == 0:
		velocity = offset / maxf(1.0, float(p.get("361", "0")))
	else:
		var start_speed: float = float(p.get("300", "0"))
		var start: Vector2 = start_override if start_override is Vector2 else Vector2.UP.rotated(deg_to_rad(float(p.get("563", "0")))) * start_speed
		match int(p.get("572", "0")):
			0:
				if first:
					velocity = start
			1:
				if start_speed != 0.0:
					velocity = start
			2:
				velocity += start
		var accel: float = float(p.get("334", "0"))
		var friction: float = float(p.get("558", "0"))
		var near_dist: float = float(p.get("359", "0"))
		if near_dist > 0.0 and dist < near_dist:
			var t: float = dist / near_dist
			accel = lerpf(float(p.get("357", "0")), accel, t)
			friction = lerpf(float(p.get("561", "0")), friction, t)
		if int(p.get("367", "0")) == 2:
			velocity = adv_follow_steer(p, offset, velocity)
		else:
			velocity *= 1.0 - friction / 100.0
			if dist > 0.0:
				velocity += offset / dist * accel * 0.01
		if x_only:
			velocity.y = 0.0
		if y_only:
			velocity.x = 0.0
	var max_speed: float = float(p.get("298", "0"))
	if max_speed > 0.0 and velocity.length() > max_speed:
		velocity = velocity.normalized() * max_speed
	return [velocity, velocity]


## Mode 3 steering / braking, twin of the native adv_follow_steer.
static func adv_follow_steer(p: Dictionary, offset: Vector2, velocity: Vector2) -> Vector2:
	var dist: float = offset.length()
	var speed: float = velocity.length()
	var accel: float = float(p.get("334", "0"))
	if dist <= 0.0:
		return velocity
	var to_center: Vector2 = offset / dist
	if speed <= 0.0:
		return to_center * accel * 0.01
	var heading: float = velocity.angle()
	var diff: float = angle_difference(heading, to_center.angle())
	var break_angle: float = float(p.get("328", "180"))
	var braking: bool = break_angle < 0.0 or (break_angle < 180.0 and absf(diff) > deg_to_rad(break_angle))
	var steer: float = float(p.get("316", "0"))
	if braking:
		steer = float(p.get("330", "0")) if speed <= float(p.get("332", "0")) else 0.0
	elif p.get("337", "0") == "1" and speed < float(p.get("322", "0")):
		steer = float(p.get("318", "0"))
	elif p.get("338", "0") == "1" and speed > float(p.get("324", "0")):
		steer = float(p.get("320", "0"))
	var limit: float = maxf(0.0, steer) * 0.01
	var dir: Vector2 = Vector2.from_angle(heading + clampf(diff, -limit, limit))
	if braking:
		return dir * speed * (1.0 - clampf(float(p.get("326", "0")), 0.0, 100.0) / 100.0)
	return dir * speed + (to_center if p.get("305", "0") == "1" else dir) * accel * 0.01


## Edit Advanced Follow (3660), twin of the native adv_follow_edit.
static func adv_follow_edit(velocity: Vector2, mod_x: float, mod_y: float, speed: float, dir_rad: float, x_only: bool, y_only: bool) -> Vector2:
	var out := Vector2(velocity.x * mod_x, velocity.y * mod_y) + Vector2.from_angle(dir_rad) * speed
	if x_only:
		out.y = velocity.y
	if y_only:
		out.x = velocity.x
	return out
