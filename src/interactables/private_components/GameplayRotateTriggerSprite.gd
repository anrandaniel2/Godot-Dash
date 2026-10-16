class_name GameplayRotateTriggerSprite
extends TriggerSprite

@export var gameplay_rotation_changer_component: GameplayRotationChangerComponent
@export var direction_changer_component: DirectionChangerComponent

const Direction = DirectionChangerComponent.Direction


func _ready() -> void:
	visibility_changed.connect(_on_visibility_changed)
	set_process(is_visible_in_tree())


func _on_visibility_changed() -> void:
	var should_process: bool = is_visible_in_tree()
	set_process(should_process)
	if should_process:
		_update_sprite()


func _process(_delta: float) -> void:
	_update_sprite()


func _update_sprite() -> void:
	global_rotation_degrees = gameplay_rotation_changer_component.gameplay_rotation
	var player_is_reverse: bool = LevelManager.player.horizontal_direction < 0
	if Editor.in_editor and not LevelManager.level_playing:
		player_is_reverse = Editor.root.level.start_reverse
	flip_h = (
		direction_changer_component.direction == Direction.BACKWARDS
		or (direction_changer_component.direction == Direction.KEEP and player_is_reverse)
		or (direction_changer_component.direction == Direction.FLIP and not player_is_reverse)
	)
