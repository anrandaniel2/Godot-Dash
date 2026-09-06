class_name PropertySaveLoad
extends Node

@export var config_property: StringName
@export var property_owner: Node

var _property_owner: Variant

@onready var parent := get_parent() as Property


func _ready() -> void:
	parent.value_changed.connect(save)
	load_value()


func load_value() -> void:
	if property_owner != null:
		_property_owner = property_owner
	else:
		_property_owner = Config
	if config_property in _property_owner:
		parent.set_value_no_signal.call_deferred(_property_owner.get(config_property))


func save(value: Variant) -> void:
	if property_owner != null:
		_property_owner = property_owner
	else:
		_property_owner = Config
	_property_owner.set(config_property, value)
	if _property_owner == Config:
		Config.save()
