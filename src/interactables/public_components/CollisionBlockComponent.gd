class_name CollisionBlockComponent
extends Component
## Marks a Geometry Dash collision block (1816) for the Collision (1815) and
## Instant Collision (3609) triggers. GD collision blocks never touch the
## player; the native runtime and GameplayTriggerComponent find them through
## [constant GameplayTriggerComponent.COLLISION_BLOCK_GROUP]. Keys from gmdkit
## prop_table.csv: 80 block id, 94 dynamic.

@export var block_id: int = 0:
	set(value):
		block_id = value
		_sync()
@export var dynamic: bool = false:
	set(value):
		dynamic = value
		_sync()


func _ready() -> void:
	parent.add_to_group(GameplayTriggerComponent.COLLISION_BLOCK_GROUP)
	_sync()


## Component data may arrive before or after _ready; keep the meta current.
func _sync() -> void:
	var block: Node = parent if parent != null else get_parent()
	if block == null:
		return
	block.set_meta(&"gd_block_id", block_id)
	block.set_meta(&"gd_block_dynamic", dynamic)
