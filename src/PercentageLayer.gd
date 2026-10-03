extends CanvasLayer

@export var label: Label

var _last_text: String = ""


func _process(_delta: float) -> void:
	if not visible or not LevelManager.current_level:
		return
	var new_text: String
	if is_zero_approx(LevelManager.current_level.duration):
		new_text = "Infinite"
	elif not LevelManager.player.dead:
		var time_since_level_start: float = LevelManager.current_level.stopwatch.get_elapsed_time_in_seconds()
		var percentage: float = (time_since_level_start / LevelManager.current_level.duration) * 100.0
		percentage = clampf(percentage, 0.0, 100.0)
		new_text = "%.2f%%" % percentage
	else:
		return
	# Text assignment triggers a font shaping pass on the label; skip it when
	# the formatted string is identical to what is already shown.
	if new_text != _last_text:
		_last_text = new_text
		label.text = new_text
