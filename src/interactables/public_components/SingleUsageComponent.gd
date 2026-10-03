class_name SingleUsageComponent
extends Marker

@export var original_collision_mask: int


func _ready() -> void:
	parent.interacted.connect(disable)


func disable(_body: Node2D) -> void:
	original_collision_mask = parent.collision_mask
	parent.collision_mask = 0


func reset() -> void:
	parent.collision_mask = original_collision_mask
