class_name EditorSelectionCollider
extends Area2D

enum Type {
	BLOCK,
	SPIKE,
	SPIKE_FLAT,
	SPIKE_MEDIUM,
	SPIKE_SMALL,
	GROUND_SPIKE,
	SLOPE,
	SLOPE_LARGE,
	INTERACTABLE,
	## A placed Geometry Dash object (see GDObject); id is the object id.
	DECORATION,
}

@export var type: Type
@export var id: int
