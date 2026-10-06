class_name CollisionBlockComponent
extends Node
## Marks a Geometry Dash collision block (1816) for the Collision (1815) and
## Instant Collision (3609) triggers. GD collision blocks never touch the
## player; the native runtime and GameplayTriggerComponent find them through
## [constant GameplayTriggerComponent.COLLISION_BLOCK_GROUP]. Keys from gmdkit
## prop_table.csv: 80 block id, 94 dynamic.

@export var block_id: int = 0
@export var dynamic: bool = false


func _ready() -> void:
	var block: Node = get_parent()
	block.set_meta(&"gd_block_id", block_id)
	block.set_meta(&"gd_block_dynamic", dynamic)
	block.add_to_group(GameplayTriggerComponent.COLLISION_BLOCK_GROUP)
