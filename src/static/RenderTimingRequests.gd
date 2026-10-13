class_name RenderTimingRequests
extends RefCounted
## Viewport GPU timestamps are diagnostics, not a requirement for rendering.
## Share ownership so hiding F3 cannot disable an active performance capture.
## Callers release their request before leaving the tree. Main thread only.

static var _owners: Dictionary[RID, Dictionary] = {}


static func set_requested(viewport: RID, requester: Object, enabled: bool) -> void:
	var owners: Dictionary = _owners.get(viewport, {})
	var was_enabled: bool = not owners.is_empty()
	if enabled:
		owners[requester.get_instance_id()] = true
		_owners[viewport] = owners
	else:
		owners.erase(requester.get_instance_id())
		if owners.is_empty():
			_owners.erase(viewport)
	var is_enabled: bool = not owners.is_empty()
	if was_enabled != is_enabled:
		RenderingServer.viewport_set_measure_render_time(viewport, is_enabled)


static func is_requested(viewport: RID) -> bool:
	return _owners.has(viewport)
