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
			return a / b if b != 0.0 else a
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


static func compare(l: float, op: int, r: float, tolerance: float) -> bool:
	match op:
		1:
			return l > r
		2:
			return l >= r
		3:
			return l < r
		4:
			return l <= r
		5:
			return absf(l - r) > tolerance
	return absf(l - r) <= tolerance


static func edit_rhs(has_a: bool, a: float, has_b: bool, b: float, op2: int, op3: int, mod: float, round_1: int, sign_1: int) -> float:
	var v: float
	if not has_a and not has_b:
		v = mod
	else:
		v = a if has_a else 0.0
		if has_b:
			v = arith(v, 1 if op2 == 0 else op2, b)
		v = arith(v, 3 if op3 == 0 else op3, mod)
	return sign_op(round_op(v, round_1), sign_1)


static func compare_side(has_item: bool, value: float, op: int, mod: float, round_mode: int, sign_mode: int) -> float:
	var v: float = arith(value, 3 if op == 0 else op, mod) if has_item else mod
	return sign_op(round_op(v, round_mode), sign_mode)


## [param state] holds "step", "count", "last", "finished". Returns the step to
## spawn or -1.
static func sequence_advance(state: Dictionary, counts: PackedInt32Array, mode: int, min_interval: float, reset_time: float, reset_type: int, now: float) -> int:
	if counts.is_empty():
		return -1
	var last: float = state.get("last", -1.0)
	if last >= 0.0 and min_interval > 0.0 and now - last < min_interval:
		return -1
	if last >= 0.0 and reset_time > 0.0 and now - last >= reset_time:
		state["count"] = 0
		if reset_type != 1:
			state["step"] = 0
			state["finished"] = false
	state["last"] = now
	if state.get("finished", false):
		return -1
	var step: int = state.get("step", 0)
	var count: int = int(state.get("count", 0)) + 1
	if count >= maxi(1, counts[step]):
		count = 0
		if step + 1 < counts.size():
			state["step"] = step + 1
		elif mode == 1:
			state["step"] = 0
		elif mode == 0:
			state["finished"] = true
	state["count"] = count
	return step
