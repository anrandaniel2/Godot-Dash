extends WorldEnvironment

func _ready() -> void:
	# Compatibility glow is several fullscreen passes and hitches the HTML
	# build. A second world SubViewport for "soft bloom" was worse (a full
	# extra canvas pass on WebGPU). WebSoftEffects is frost-only; bloom is
	# desktop/Android.
	environment.glow_enabled = Config.bloom and not OS.has_feature("web")
