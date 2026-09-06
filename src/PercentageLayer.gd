extends CanvasLayer

@export var label: Label


func _process(_delta: float) -> void:
	if not LevelManager.current_level:
		return
	if is_zero_approx(LevelManager.current_level.duration):
		label.text = "Infinite"
	elif not LevelManager.player.dead:
		var time_since_level_start: float = LevelManager.current_level.stopwatch.get_elapsed_time_in_seconds()
		var percentage: float = (time_since_level_start / LevelManager.current_level.duration) * 100.0
		percentage = clampf(percentage, 0.0, 100.0)
		label.text = "%.2f%%" % percentage
