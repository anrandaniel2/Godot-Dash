class_name TargetGroupComponent
extends Component

signal changed(target_group: String)

@export_placeholder("Group name") var target_group: String:
	set(value):
		target_group = value
		changed.emit.call_deferred(value)

## Additional groups targeted alongside [member target_group].
##
## Geometry Dash 2.2 lets one trigger target several groups at once (key 51
## becomes a dot separated list), so an imported trigger may own more than one
## target group. The first imported group lands in [member target_group] - the
## field the editor edits - and the remainder here; [method all_members]
## resolves the union, which is what a changer should act on.
@export var extra_target_groups: PackedStringArray


func _validate_property(property: Dictionary) -> void:
	if property.name == "target_group":
		property.suggestion_provider = preload("res://resources/GroupSuggestionProvider.tres")


## Every group this component targets, primary first.
func all_groups() -> Array[String]:
	var groups: Array[String] = []
	if not target_group.is_empty():
		groups.append(target_group)
	for group: String in extra_target_groups:
		if not group.is_empty() and not groups.has(group):
			groups.append(group)
	return groups


## Every [Node2D] member of every targeted group, without duplicates.
##
## An object in several of the groups is returned once, so a changer moving
## all groups doesn't apply its offset to it twice.
func all_members() -> Array[Node2D]:
	var members: Array[Node2D] = []
	for group: String in all_groups():
		for node: Node in get_tree().get_nodes_in_group(group):
			if node is Node2D and not members.has(node):
				members.append(node)
	return members
