extends Node
## Compares the existing pattern against a rejected candidate. No game
## autoloads, graphics, native DLL or user settings affect this microbenchmark.

const Builder = preload("res://MutableIndexCandidate.gd")
const COUNT: int = 50000


func _ready() -> void:
	var algorithm: String = "parity"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--algorithm="):
			algorithm = arg.trim_prefix("--algorithm=")
	if algorithm == "parity":
		for count: int in [0, 1, 1000]:
			for channels: int in [1, 8, 1000]:
				var reference: Array = _build(count, channels, false)
				var packed: Array = _build(count, channels, true)
				if reference != packed:
					print(
						"CHANNEL_INDEX_PARITY result=FAIL count=%d channels=%d" % [count, channels]
					)
					get_tree().quit(1)
					return
		print(
			"CHANNEL_INDEX_PARITY result=PASS cases=9 (empty channels and glow exclusion included)"
		)
	elif algorithm in ["old", "new"]:
		_build(1000, 8, algorithm == "new")
		for channels: int in [1, 8]:
			var durations: Array[float] = []
			var retained: int = 0
			for trial: int in 3:
				var before: int = OS.get_static_memory_usage()
				var started: int = Time.get_ticks_usec()
				var result: Array = _build(COUNT, channels, algorithm == "new")
				durations.append((Time.get_ticks_usec() - started) / 1000.0)
				retained = OS.get_static_memory_usage() - before
				if result[0].is_empty():
					get_tree().quit(1)
					return
				result.clear()
			durations.sort()
			print(
				(
					"CHANNEL_INDEX_BENCH algorithm=%s count=%d channels=%d median_ms=%.3f retained_bytes=%d process_static_peak_bytes=%d"
					% [
						algorithm,
						COUNT,
						channels,
						durations[1],
						retained,
						OS.get_static_memory_peak_usage(),
					]
				)
			)
	else:
		get_tree().quit(1)
		return
	get_tree().quit(0)


func _build(count: int, channels: int, optimized: bool) -> Array:
	var colors: Dictionary = {}
	var blends: Dictionary = {}
	for index: int in count:
		# Include empty channels and glow records, exactly as DecorationBatch's
		# loop filters them. Sparse channel keys must retain insertion order.
		var channel: StringName = (
			&"" if index % 17 == 0 else StringName("c_%d" % (index % channels))
		)
		if channel.is_empty():
			continue
		if optimized:
			Builder.append(colors, channel, index)
			if index % 5 != 0:
				Builder.append(blends, channel, index)
		else:
			var indices: PackedInt32Array = colors.get(channel, PackedInt32Array())
			indices.append(index)
			colors[channel] = indices
			if index % 5 != 0:
				var blend_indices: PackedInt32Array = blends.get(channel, PackedInt32Array())
				blend_indices.append(index)
				blends[channel] = blend_indices
	if optimized:
		return [Builder.finish(colors), Builder.finish(blends)]
	return [colors, blends]
