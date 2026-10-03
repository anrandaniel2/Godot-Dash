class_name SolidObject
extends RigidBody2D

@export var _slope: bool = false

@export_storage var physics_object: bool = false
@export_storage var friction: float = 1.0
@export_storage var rough: bool = false
@export_storage var bounce: float = 0.0
@export_storage var absorbent: bool = false
@export_storage var pushable_by_player: bool = true


func _ready() -> void:
	LevelManager.level_started.connect(_start)
	LevelManager.level_stopped.connect(_stop)


func _start() -> void:
	if not physics_object:
		return
	collision_layer = 1 if pushable_by_player else 2
	if _slope:
		collision_layer &= 7
	collision_mask = 2103
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = friction
	physics_material_override.rough = rough
	physics_material_override.bounce = bounce
	physics_material_override.absorbent = absorbent
	freeze = false


func _stop() -> void:
	physics_material_override = null
	freeze = true
	collision_layer = 2
	if _slope:
		collision_layer &= 7
	collision_mask = 1


func get_data() -> Dictionary:
	return {
		"physics_object": physics_object,
		"mass": mass,
		"friction": friction,
		"rough": rough,
		"bounce": bounce,
		"absorbent": absorbent,
		"gravity_scale": gravity_scale,
		"pushable_by_player": pushable_by_player,
		"linear_velocity": linear_velocity,
		"angular_velocity": angular_velocity,
	}


func use_data(data: Dictionary) -> void:
	physics_object = data.physics_object
	mass = data.mass
	friction = data.friction
	rough = data.rough
	bounce = data.bounce
	absorbent = data.absorbent
	gravity_scale = data.gravity_scale
	pushable_by_player = data.pushable_by_player
	linear_velocity = data.linear_velocity
	angular_velocity = data.angular_velocity
