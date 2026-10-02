extends WorldEnvironment

func _ready() -> void:
	# Web uses WebSoftEffects for bloom. Compatibility glow is several
	# fullscreen passes and is what made the HTML build hitch.
	environment.glow_enabled = Config.bloom and not OS.has_feature("web")
