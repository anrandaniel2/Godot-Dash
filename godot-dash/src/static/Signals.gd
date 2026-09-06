@abstract
class_name Signals

## Adapted from https://github.com/ava-cassiopeia/gdscript-signals

static func first(...signal_list: Array) -> Signal:
	var listener := _AnySignalListener.new()
	for single_signal: Signal in signal_list:
		listener.add_signal(single_signal)
	var first_signal: Signal = await listener.any_signal_received
	return first_signal


class _AnySignalListener:
	signal any_signal_received(first_signal: Signal)
	var signal_list: Array[Signal] = []
	var completed: bool = false


	func add_signal(single_signal: Signal) -> void:
		assert(
			not completed,
			"Cannot add signal: this signal listener has already completed.",
		)
		signal_list.append(single_signal)
		# We use dummy arguments so the signal can connect successfully.
		single_signal.connect(func(_arg1 = null, _arg2 = null, _arg3 = null): _on_signal(single_signal))


	func _on_signal(sig: Signal) -> void:
		if completed:
			return
		any_signal_received.emit(sig)
		_disconnect_all_signals()
		completed = true


	func _disconnect_all_signals() -> void:
		if completed:
			return
		for single_signal in signal_list:
			if not single_signal.get_object():
				continue
			if single_signal.is_connected(_on_signal):
				single_signal.disconnect(_on_signal)
