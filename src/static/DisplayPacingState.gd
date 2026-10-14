class_name DisplayPacingState
extends RefCounted
## Debounce display transitions without deriving an FPS cap from any monitor.
## Two matching samples avoid repeated swapchain changes while docking or
## changing Duplicate/Extend topology. Empty snapshots are transient failures.

var _active: PackedInt64Array = PackedInt64Array()
var _candidate: PackedInt64Array = PackedInt64Array()


func observe(snapshot: PackedInt64Array) -> bool:
	if snapshot.is_empty():
		_candidate.clear()
		return false
	if _active.is_empty():
		_active = snapshot.duplicate()
		return false
	if snapshot == _active:
		_candidate.clear()
		return false
	if snapshot != _candidate:
		_candidate = snapshot.duplicate()
		return false
	_active = snapshot.duplicate()
	_candidate.clear()
	return true
