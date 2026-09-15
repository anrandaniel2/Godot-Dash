extends Node
## CI runtime validation for the GDR replay codec (src/static/GDRFormat.gd
## and src/static/MsgPack.gd).
##
## The GOLDEN_HEX document was produced by an independent Python
## implementation of the GDR 1 format (itself validated against .gdr files
## written by ecosystem tools), so the byte-for-byte comparison below
## proves wire compatibility with other tools rather than self-consistency.
## It embeds the current application version string, so a version bump
## means regenerating the golden bytes.


const GOLDEN_HEX := "8ea6617574686f72a6546573746572a3626f7482a46e616d65aa476f646f742d44617368a776657273696f6ead312e302e302d616c7068612e35a5636f696e7300a76461736845787481a877617665446f776e94920cc3921ec2922dc3923cc2ab6465736372697074696f6ea0a86475726174696f6ecb3fd0444444444444a96672616d6572617465cb406e000000000000ab67616d6556657273696f6ecb400199999999999aa6696e707574739684a23270c2a362746e01a4646f776ec3a56672616d650584a23270c2a362746e01a4646f776ec2a56672616d650c84a23270c2a362746e03a4646f776ec3a56672616d652884a23270c2a362746e03a4646f776ec2a56672616d653284a23270c2a362746e02a4646f776ec3a56672616d653284a23270c2a362746e02a4646f776ec2a56672616d6537a36c646dc2a56c6576656c82a2696400a46e616d65aa54657374204c6576656caa706c6174666f726d6572c3a47365656400a776657273696f6ecb3ff0000000000000"

var failures: PackedStringArray = []
var checks := 0


func _ready() -> void:
	_test_msgpack_primitives()
	_test_msgpack_foreign_bytes()
	_test_golden_document()
	_test_replay_roundtrip_classic()
	_test_json_variant()
	_test_framerate_resample()
	_test_rejects_garbage()
	print("GDR_SELFTEST_SUMMARY total=", checks, " failed=", failures.size())
	for failure in failures:
		print("GDR_SELFTEST_FAIL ", failure)
	get_tree().quit(1 if not failures.is_empty() else 0)


func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(label)
		print("GDR_SELFTEST_CHECK_FAILED ", label)


func _test_msgpack_primitives() -> void:
	var values: Array = [
		null, true, false,
		0, 1, 127, 128, 255, 256, 65535, 65536, 4294967296,
		-1, -32, -33, -128, -32768, -32769,
		1.5, -0.25,
		"", "a", "hello world",
		"x".repeat(31), "x".repeat(32), "x".repeat(255), "x".repeat(256), "x".repeat(300),
		[], [1, 2, 3],
		{}, {"a": 1, "b": [true, null]},
		[["deep"], {"k": 3.5}],
	]
	for value: Variant in values:
		var result: Dictionary = MsgPack.decode(MsgPack.encode(value))
		check("msgpack round trip of %s" % [value], result.ok and result.value == value)
	# The encoder must pick the smallest representation for each value.
	var sizes := {
		0: 1, 127: 1, 128: 2, 256: 3, 65536: 5, 4294967296: 9,
		-1: 1, -33: 2, -32769: 5,
		1.5: 9,
	}
	for value: Variant in sizes:
		check("msgpack size of %s" % [value], MsgPack.encode(value).size() == sizes[value])
	check("msgpack size of empty string", MsgPack.encode("").size() == 1)
	check("msgpack size of 31-char string", MsgPack.encode("x".repeat(31)).size() == 32)
	check("msgpack size of 32-char string", MsgPack.encode("x".repeat(32)).size() == 34)
	check("msgpack size of empty array", MsgPack.encode(Array()).size() == 1)
	check("msgpack size of empty map", MsgPack.encode({}).size() == 1)
	var zeros_15: Array = []
	zeros_15.resize(15)
	check("msgpack size of 15-element array", MsgPack.encode(zeros_15).size() == 16)
	var zeros_16: Array = []
	zeros_16.resize(16)
	check("msgpack size of 16-element array", MsgPack.encode(zeros_16).size() == 19)
	# Single-character keys keep the arithmetic below simple.
	var alphabet := "abcdefghijklmnop"
	var map_15 := {}
	var map_16 := {}
	for i in 15:
		map_15[alphabet[i]] = 0
	for i in 16:
		map_16[alphabet[i]] = 0
	check("msgpack size of 15-key map", MsgPack.encode(map_15).size() == 1 + 3 * 15)
	check("msgpack size of 16-key map", MsgPack.encode(map_16).size() == 3 + 3 * 16)


func _test_msgpack_foreign_bytes() -> void:
	# Hand-written spec bytes covering decoder branches the golden document
	# does not (float32, str8, array16, map16, negative ints, uint64).
	var cases := {
		"ca3f800000": 1.0,
		"d903616263": "abc",
		"dc0003010203": [1, 2, 3],
		"de0001a1612a": {"a": 42},
		"d0df": -33,
		"d18000": -32768,
		"c0": null,
		"c2": false,
		"c3": true,
		"cf0000000100000000": 4294967296,
	}
	for hex: String in cases:
		var result: Dictionary = MsgPack.decode(_hex_to_raw(hex))
		check("msgpack decodes %s" % hex, result.ok and result.value == cases[hex])
	check("msgpack rejects trailing data", not MsgPack.decode(_hex_to_raw("0102")).ok)
	check("msgpack rejects empty data", not MsgPack.decode(PackedByteArray()).ok)
	check("msgpack rejects binary types", not MsgPack.decode(_hex_to_raw("c403010203")).ok)
	check("msgpack rejects extension types", not MsgPack.decode(_hex_to_raw("d40000")).ok)
	check("msgpack rejects truncated string", not MsgPack.decode(_hex_to_raw("a541")).ok)


func _test_golden_document() -> void:
	var golden := _hex_to_raw(GOLDEN_HEX)
	var decoded: Dictionary = MsgPack.decode(golden)
	check("golden document decodes", decoded.ok)
	if not decoded.ok:
		print("GDR_SELFTEST_DETAIL ", decoded.error)
		return
	check("golden document matches", decoded.value == _golden_document())
	# The same document must come out of encoding the equivalent replay.
	var replay := Replay.new()
	replay.author = "Tester"
	replay.description = ""
	replay.level_name = "Test Level"
	replay.level_id = 0
	replay.platformer = true
	replay.data = _golden_data()
	var produced := GDRFormat.to_bytes(replay)
	if produced != golden:
		# Keep the diff compact: the annotation budget is small.
		var diff_index := 0
		var max_check: int = mini(produced.size(), golden.size())
		while diff_index < max_check and produced[diff_index] == golden[diff_index]:
			diff_index += 1
		var lo: int = maxi(diff_index - 12, 0)
		print("GDR_SELFTEST_DETAIL encode mismatch: produced=", produced.size(), "B golden=", golden.size(), "B first diff at byte ", diff_index)
		print("GDR_SELFTEST_DETAIL produced[", lo, "..] = ", produced.slice(lo, diff_index + 20).hex_encode())
		print("GDR_SELFTEST_DETAIL golden  [", lo, "..] = ", golden.slice(lo, diff_index + 20).hex_encode())
	check("replay encodes to golden bytes", produced == golden)
	var loaded: Dictionary = GDRFormat.from_bytes(golden)
	check("golden document loads as a replay", loaded.ok)
	if not loaded.ok:
		print("GDR_SELFTEST_DETAIL ", loaded.error)
		return
	check("golden replay round-trips its data", _data_equals(loaded.replay.data, _golden_data()))
	check("golden replay keeps author", loaded.replay.author == "Tester")
	check("golden replay keeps level name", loaded.replay.level_name == "Test Level")
	check("golden replay keeps platformer flag", loaded.replay.platformer)


func _test_replay_roundtrip_classic() -> void:
	var replay := Replay.new()
	replay.author = "Classic"
	replay.level_name = "Classic Level"
	replay.platformer = false
	replay.data = []
	for tick in 100:
		# Classic recordings carry a constant direction column that the GDR
		# format cannot express (and must not: emitting it would mark the
		# replay as platformer for the ecosystem tools); the round trip
		# normalizes it away.
		replay.data.append(PackedByteArray([1 if tick % 7 < 3 else 0, 1]))
	var loaded: Dictionary = GDRFormat.from_bytes(GDRFormat.to_bytes(replay))
	check("classic replay round-trips", loaded.ok)
	if not loaded.ok:
		print("GDR_SELFTEST_DETAIL ", loaded.error)
		return
	var expected: Array[PackedByteArray] = []
	for tick in 100:
		expected.append(PackedByteArray([1 if tick % 7 < 3 else 0, 0]))
	check("classic replay data matches", _data_equals(loaded.replay.data, expected))
	check("classic replay stays classic", not loaded.replay.platformer)
	check("classic replay keeps author", loaded.replay.author == "Classic")


func _test_json_variant() -> void:
	var document := {
		"author": "JsonBot",
		"bot": {"name": "SomeBot", "version": "2.0"},
		"coins": 0,
		"description": "",
		"duration": 0.5,
		"framerate": 240.0,
		"gameVersion": 2.2,
		"inputs": [
			{"2p": false, "btn": 1, "down": true, "frame": 10},
			{"2p": false, "btn": 1, "down": false, "frame": 20},
		],
		"ldm": false,
		"level": {"id": 0, "name": "Json Level"},
		"platformer": false,
		"seed": 0,
		"version": 1.0,
	}
	var loaded: Dictionary = GDRFormat.from_bytes(JSON.stringify(document).to_utf8_buffer())
	check("JSON GDR document loads", loaded.ok)
	if not loaded.ok:
		print("GDR_SELFTEST_DETAIL ", loaded.error)
		return
	var expected: Array[PackedByteArray] = []
	for tick in 120:
		expected.append(PackedByteArray([1 if tick >= 10 and tick < 20 else 0, 0]))
	check("JSON GDR replay data matches", _data_equals(loaded.replay.data, expected))
	check("JSON GDR replay author matches", loaded.replay.author == "JsonBot")


func _test_framerate_resample() -> void:
	# A 60 fps bot replay must be resampled onto this engine's 240 ticks/s.
	var document := {
		"framerate": 60.0,
		"duration": 1.0,
		"inputs": [
			{"2p": false, "btn": 1, "down": true, "frame": 30},
			{"2p": false, "btn": 1, "down": false, "frame": 45},
		],
	}
	var loaded: Dictionary = GDRFormat.from_bytes(MsgPack.encode(document))
	check("resampled replay loads", loaded.ok)
	if not loaded.ok:
		print("GDR_SELFTEST_DETAIL ", loaded.error)
		return
	check("resampled replay length", loaded.replay.data.size() == 240)
	var data: Array[PackedByteArray] = loaded.replay.data
	var jump_ticks := 0
	for tick: PackedByteArray in data:
		if tick[0] == 1:
			jump_ticks += 1
	# Frames 30..44 become ticks 120..179.
	check("resampled jump window", jump_ticks == 60)


func _test_rejects_garbage() -> void:
	check("random bytes rejected", not GDRFormat.from_bytes(PackedByteArray([1, 2, 3, 4, 5])).ok)
	check("empty file rejected", not GDRFormat.from_bytes(PackedByteArray()).ok)
	check("missing inputs rejected", not GDRFormat.from_bytes(MsgPack.encode({"author": "x"})).ok)
	check("absurd duration rejected", not GDRFormat.from_bytes(MsgPack.encode({"duration": 100000.0, "framerate": 240.0, "inputs": []})).ok)


func _golden_document() -> Dictionary:
	return {
		"author": "Tester",
		"bot": {"name": "Godot-Dash", "version": "1.0.0-alpha.5"},
		"coins": 0,
		"dashExt": {"waveDown": [[12, true], [30, false], [45, true], [60, false]]},
		"description": "",
		"duration": 61.0 / 240.0,
		"framerate": 240.0,
		"gameVersion": 2.2,
		"inputs": [
			{"2p": false, "btn": 1, "down": true, "frame": 5},
			# The jump reads as released at frame 12: the wave descend takes
			# over the recorded jump state there, and the recording cannot
			# express "jump held underneath a wave descend".
			{"2p": false, "btn": 1, "down": false, "frame": 12},
			{"2p": false, "btn": 3, "down": true, "frame": 40},
			{"2p": false, "btn": 3, "down": false, "frame": 50},
			{"2p": false, "btn": 2, "down": true, "frame": 50},
			{"2p": false, "btn": 2, "down": false, "frame": 55},
		],
		"ldm": false,
		"level": {"id": 0, "name": "Test Level"},
		"platformer": true,
		"seed": 0,
		"version": 1.0,
	}


func _golden_data() -> Array[PackedByteArray]:
	var data: Array[PackedByteArray] = []
	for tick in 61:
		var jump_state := 0
		if tick >= 5 and tick <= 19:
			jump_state = 1
		if tick >= 12 and tick <= 29:
			jump_state = -1 # The wave descend wins over a held jump.
		if tick >= 45 and tick <= 59:
			jump_state = -1
		var direction := 0
		if tick >= 40 and tick <= 49:
			direction = 1
		elif tick >= 50 and tick <= 54:
			direction = -1
		data.append(PackedByteArray([jump_state, direction]))
	return data


func _data_equals(a: Array[PackedByteArray], b: Array[PackedByteArray]) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


## Marshalls has no hex decoder, so parse the spec fixtures by hand.
func _hex_to_raw(hex: String) -> PackedByteArray:
	var bytes := PackedByteArray()
	var high := 0
	for i in hex.length():
		var digit := hex.unicode_at(i)
		var nibble := 0
		if digit >= 48 and digit <= 57: # 0-9
			nibble = digit - 48
		elif digit >= 97 and digit <= 102: # a-f
			nibble = digit - 87
		if i % 2 == 0:
			high = nibble
		else:
			bytes.append((high << 4) | nibble)
	return bytes
