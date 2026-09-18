extends Node
## CI runtime validation for the native colour-trigger chain.
##
## Born from the Amethyst white-beams investigation: a device run showed
## 348k "changed" emissions from colour-trigger fades while not a single
## channel ever left white - every fire behaved as if it had parsed as
## KEEP (no 7/8/9, no copy, no player colour, opacity 1). This test pins
## the classic encoding end to end so a regression in any link - property
## parse, channel lookup, crossing fire, fade capture, apply_color write -
## fails CI instead of shipping as white beams:
##
##   register_packed_trigger({7/8/9 RGB, 23 channel, 10 duration})
##     -> advance() crossing -> capture_color_target -> fade -> apply_color
##     -> ColorChannelData.color actually changes.
##
## Grep "NATIVE_COLOR_SELFTEST" in the log; the step gates on the summary
## line (engine exit may be a tolerated teardown hang, like the GDR
## self-test).

var checks := 0
var failures: PackedStringArray = []


func _ready() -> void:
	if not NativeCore.available() or not ClassDB.class_exists(&"NativeTriggerRuntime"):
		# The linux native library is built earlier in the same CI job, so
		# an unavailable extension here is a real failure, not a skip.
		_fail("NativeTriggerRuntime class unavailable (native core not loaded)")
		_finish()
		return
	var runtime: Object = ClassDB.instantiate(&"NativeTriggerRuntime")
	if runtime == null:
		_fail("ClassDB.instantiate(NativeTriggerRuntime) returned null")
		_finish()
		return

	# Four independent channels, one per parse path under test.
	var faded := ColorChannelData.new()
	faded.associated_group = "c_35"
	var keep := ColorChannelData.new()
	keep.associated_group = "c_36"
	var source := ColorChannelData.new()
	source.associated_group = "c_37"
	source.color = Color(0.2, 0.4, 0.9)
	var copied := ColorChannelData.new()
	copied.associated_group = "c_38"
	var copied_black := ColorChannelData.new()
	copied_black.associated_group = "c_39"
	var spawn_triggered_channel := ColorChannelData.new()
	spawn_triggered_channel.associated_group = "c_40"

	runtime.call(&"bind_context", self, null, null)
	runtime.call(&"register_channel", "c_35", faded)
	runtime.call(&"register_channel", "c_36", keep)
	runtime.call(&"register_channel", "c_37", source)
	runtime.call(&"register_channel", "c_38", copied)
	runtime.call(&"register_channel", "c_39", copied_black)
	runtime.call(&"register_channel", "c_40", spawn_triggered_channel)

	# Trigger at x = 0 (before player spawn x = 15): instant recolour of c_40
	runtime.call(&"register_packed_trigger", 0.0, 0.0, 0, 0, PackedStringArray(), 899,
		{"7": "50", "8": "150", "9": "250", "23": "40"})
	# Classic 899: RGB fade over 0.5 s on channel 35.
	runtime.call(&"register_packed_trigger", 100.0, 0.0, 0, 1, PackedStringArray(), 899,
		{"7": "30", "8": "200", "9": "120", "23": "35", "10": "0.5"})
	# KEEP variant: no 7/8/9 and no copy, so only the opacity fades; instant
	# (no duration key) so it applies at fire time. Channel 36.
	runtime.call(&"register_packed_trigger", 200.0, 0.0, 0, 2, PackedStringArray(), 899,
		{"35": "0.4", "23": "36"})
	# Copy variant: channel 38 fades towards channel 37's colour (0.3 s) and
	# then keeps following it through the persisted copy link.
	runtime.call(&"register_packed_trigger", 300.0, 0.0, 0, 3, PackedStringArray(), 899,
		{"50": "37", "23": "38", "10": "0.3"})
	# Copy reserved channel 1010 (Black)
	runtime.call(&"register_packed_trigger", 320.0, 0.0, 0, 4, PackedStringArray(), 899,
		{"50": "1010", "23": "39", "10": "0.0"})
	runtime.call(&"finalize")

	var player := Node2D.new()
	player.global_position = Vector2(15.0, 0.0)
	add_child(player)
	# Initial spawn: advance_player must activate setup triggers at x <= 15 (e.g. x=0)
	runtime.call(&"advance_player", player)

	# Crossings in x order; each interval ends inside the next record.
	runtime.call(&"advance", player, 50.0, 150.0)
	runtime.call(&"advance", player, 150.0, 250.0)
	runtime.call(&"advance", player, 250.0, 350.0)
	# Both fading triggers started at clock 0; 0.6 s completes them (weight 1).
	runtime.call(&"tick", 0.6)

	_expect_color("spawn-time trigger at x=0 fired for player at x=15", spawn_triggered_channel, Color(50.0 / 255.0, 150.0 / 255.0, 250.0 / 255.0))
	_expect_color("RGB fade recolours the channel", faded, Color(30.0 / 255.0, 200.0 / 255.0, 120.0 / 255.0))
	_expect_alpha("instant KEEP opacity", keep, 0.4)
	_expect("KEEP variant left colour untouched", keep.color == Color.WHITE)
	_expect("KEEP variant severed no copy link", keep.copied_channel_id == 0)
	_expect_color("copy fade lands on the source colour", copied, Color(0.2, 0.4, 0.9))
	_expect("copy link persisted at completion", copied.copied_channel_id == 37)
	_expect_color("copying reserved channel 1010 (Black) lands on black", copied_black, Color.BLACK)
	_expect_color("source channel untouched", source, Color(0.2, 0.4, 0.9))
	_finish()


func _expect(description: String, condition: bool) -> void:
	checks += 1
	if condition:
		print("NATIVE_COLOR_SELFTEST ok ", description)
	else:
		_fail(description)


func _expect_color(description: String, data: ColorChannelData, expected: Color) -> void:
	_expect("%s (got %s, want %s)" % [description, data.color, expected],
		data.color.is_equal_approx(expected))


func _expect_alpha(description: String, data: ColorChannelData, expected: float) -> void:
	_expect("%s (got %.3f, want %.3f)" % [description, data.alpha, expected],
		is_equal_approx(data.alpha, expected))


func _fail(description: String) -> void:
	failures.append(description)
	print("NATIVE_COLOR_SELFTEST_FAIL ", description)


func _finish() -> void:
	print("NATIVE_COLOR_SELFTEST_SUMMARY total=", checks, " failed=", failures.size())
	get_tree().quit(1 if not failures.is_empty() else 0)
