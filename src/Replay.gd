class_name Replay
extends Resource
## Two bytes per physics tick in one flat [PackedByteArray]:
## index 2*tick   = jump state as int (0 none, 1 jump, 2 wave descend)
## index 2*tick+1 = direction + 1 (0 left, 1 none, 2 right)
## The previous layout (one 2-byte [PackedByteArray] element per tick inside an
## [Array]) allocated an array element and a packed-array header every one of
## the 240 physics ticks a player runs — pure allocator churn that shows up in
## mobile profiles. The flat buffer appends two bytes into one geometrically
## growing allocation instead.
@export var data: PackedByteArray = PackedByteArray()
@export var level_name: String = "Level"
# GDR interchange metadata (see GDRFormat); the author and platformer flag
# are captured at record time so a saved .gdr file is shareable as-is.
var author: String = ""
var description: String = ""
var level_id: int = 0
var platformer: bool = false


func tick_count() -> int:
	return data.size() >> 1


## Appends one tick. Kept as a method so the direction + 1 encoding and the
## two-byte layout live in one place instead of at every recording site.
func record_tick(jump_state: int, direction: int) -> void:
	data.append(jump_state)
	data.append(direction + 1)


func pressing_jump(tick: int) -> bool:
	return data[tick << 1] == 1


func pressing_down(tick: int) -> bool:
	# 2, not -1: a stored byte is unsigned, so the -1 this used to compare
	# against could never be stored in the first place.
	return data[tick << 1] == 2


func get_direction(tick: int) -> int:
	return data[(tick << 1) + 1] - 1


func just_pressed_jump(tick: int) -> bool:
	if tick == 0:
		return pressing_jump(tick)
	return not pressing_jump(tick - 1) and pressing_jump(tick)


func just_released_jump(tick: int) -> bool:
	return tick != 0 and pressing_jump(tick - 1) and not pressing_jump(tick)


func reset() -> void:
	data.clear()


func save(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(Constants.REPLAYS_DIR)
	var error := GDRFormat.save(self, Constants.REPLAYS_DIR.path_join(name + GDRFormat.FILE_EXTENSION))
	if error != OK:
		push_error("Could not save replay: Error %s." % error)
