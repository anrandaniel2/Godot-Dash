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
