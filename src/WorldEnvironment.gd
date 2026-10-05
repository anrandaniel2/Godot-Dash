extends WorldEnvironment

func _enter_tree() -> void:
	_apply_glow()


func _ready() -> void:
	_apply_glow()


func _apply_glow() -> void:
	if environment == null:
		return
	# Compatibility glow is several fullscreen passes and hitches the HTML
	# build. A second world SubViewport for "soft bloom" was worse (a full
	# extra canvas pass on WebGPU). WebSoftEffects is frost-only; bloom is
	# desktop/Android.
	environment.glow_enabled = Config.bloom and not OS.has_feature("web")
