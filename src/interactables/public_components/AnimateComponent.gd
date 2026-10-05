class_name AnimateComponent
extends Component
## Animate trigger (1585): plays monster animation [member animation_id]
## (key 76) on every monster batch in [member target_group] (key 51). Twin
## of the native ANIMATE arm; the monster batches own the animation clocks.
## parity: GD 2.11 EffectGameObject::customObjectSetup case 1585.

@export var target_group: String = ""
@export var animation_id: int = 0


func _ready() -> void:
	parent.interacted.connect(_on_interacted)


func _on_interacted(_player: Player = null) -> void:
	if target_group.is_empty():
		return
	get_tree().call_group(StringName(Constants.GROUP_PREFIX + target_group), &"play_monster_animation", animation_id)
