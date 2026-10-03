class_name BoundingBox

var extents: Rect2
var transform: Transform2D


func _init(collision_objects: Array[CollisionObject2D], center: Vector2, rotation: float) -> void:
	var collision_shapes: Array[CollisionShape2D]
	for collision_object in collision_objects:
		for shape_owner: int in collision_object.get_shape_owners():
			collision_shapes.append(collision_object.shape_owner_get_owner(shape_owner))
	for collision_shape: CollisionShape2D in collision_shapes:
		var shape_rect: Rect2 = collision_shape.shape.get_rect()
		shape_rect = (
			shape_rect \
			.expand((shape_rect.position * collision_shape.global_scale * 0.5).rotated(collision_shape.global_rotation - rotation)) \
			.expand((shape_rect.size * collision_shape.global_scale * 0.5).rotated(collision_shape.global_rotation - rotation))
		)
		shape_rect.position += (collision_shape.global_position - center).rotated(-rotation)
		extents = extents.merge(shape_rect)
	transform = Transform2D.IDENTITY.scaled(extents.size / 2)


func as_rect():
	return extents


func as_transform():
	return transform
