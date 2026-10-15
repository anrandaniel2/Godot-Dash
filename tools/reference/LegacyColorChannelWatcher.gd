extends ColorChannelWatcher
## Frozen Build 15 refresh loop for exact parity and A/B timing only.
## Never referenced by exported game code.


func refresh_objects_color(hsv_watchers: Array[HSVWatcher] = [], _data: ColorChannelData = data) -> void:
	var self_id := get_instance_id()
	var owns_fanout := _data == data
	if owns_fanout:
		_rewire_copy_dependency()
		if _refresh_stack.has(self_id):
			# A copy chain circled back here: this refresh was already started
			# further up the stack, so the cycle is broken by doing nothing.
			return
		_refresh_stack.append(self_id)
		if _had_first_refresh:
			live_recolor_count += 1
			live_last_channel = String(_data.associated_group).trim_prefix(
				Constants.COLOR_CHANNEL_GROUP_PREFIX
			)
			_note_live_refresh(live_last_channel, _data.color)
		else:
			_had_first_refresh = true
	_apply_blending_if_changed(_data)
	if hsv_watchers.is_empty():
		if _refresh_native(_data):
			_refresh_decoration_batches(_data)
			_finish_fanout(owns_fanout, self_id)
			return
		hsv_watchers.assign(get_tree().get_nodes_in_group(_data.associated_group))
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.modulate = _channel_color(_data)
		hsv_watcher.modulate.s += _data.hsv_shift[1]
		hsv_watcher.modulate.v += _data.hsv_shift[2]
		hsv_watcher.modulate.h += _data.hsv_shift[0]
		hsv_watcher.base_intensity = _data.intensity
		hsv_watcher.base_alpha = _effective_alpha(_data)
		hsv_watcher.update_color()
	_refresh_decoration_batches(_data)
	_finish_fanout(owns_fanout, self_id)
