class_name Replay
extends Resource

@export var data: Array[PackedByteArray] = [] # [jump_pressed as int, direction]
@export var level_name: String = "Level"


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
	DirAccess.remove_absolute(Constants.REPLAYS_DIR + name + ".res")
	ResourceSaver.save(self, Constants.REPLAYS_DIR + name + ".res", ResourceSaver.SaverFlags.FLAG_COMPRESS)
