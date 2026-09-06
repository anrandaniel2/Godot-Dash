class_name MusicScale
extends Node

@onready var parent: Node2D = get_parent()
@onready var initial_scale: Vector2 = parent.scale

var disabled: bool


func _ready() -> void:
	process_thread_group = Node.PROCESS_THREAD_GROUP_SUB_THREAD


func _process(delta: float):
	if disabled:
		return
	parent.set_deferred(
		&"scale",
		parent.scale.lerp(initial_scale * LevelManager.current_level.music_scale, 1 - exp(-delta * 12)),
	)
