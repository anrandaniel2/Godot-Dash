extends Node

@onready var _spectrum: AudioEffectSpectrumAnalyzerInstance = AudioServer.get_bus_effect_instance(AudioServer.get_bus_index(&"Music"), 0)


func get_volume() -> float:
	if Editor.in_editor and not LevelManager.level_playing:
		return 0.15
	var magnitude_channels: Vector2 = _spectrum.get_magnitude_for_frequency_range(40, 10000)
	return lerpf(magnitude_channels.x, magnitude_channels.y, 0.5) * 0.6
