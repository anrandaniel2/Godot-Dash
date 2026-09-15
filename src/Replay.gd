class_name Replay
extends Resource

@export var data: Array[PackedByteArray] = [] # [jump_pressed as int, direction]
@export var level_name: String = "Level"
# GDR interchange metadata (see GDRFormat); the author and platformer flag
# are captured at record time so a saved .gdr file is shareable as-is.
var author: String = ""
var description: String = ""
var level_id: int = 0
var platformer: bool = false


func pressing_jump(tick: int) -> bool:
	return data[tick][0] == 1


func pressing_down(tick: int) -> bool:
	return data[tick][0] == -1


func get_direction(tick: int) -> int:
	return data[tick][1]


func just_pressed_jump(tick: int) -> bool:
	return (tick == 0 and pressing_jump(tick)) or (not pressing_jump(tick - 1) and pressing_jump(tick))


func just_released_jump(tick: int) -> bool:
	return tick != 0 and pressing_jump(tick - 1) and not pressing_jump(tick)


func reset() -> void:
	data.clear()


func save(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(Constants.REPLAYS_DIR)
	var error := GDRFormat.save(self, Constants.REPLAYS_DIR.path_join(name + GDRFormat.FILE_EXTENSION))
	if error != OK:
		push_error("Could not save replay: Error %s." % error)
