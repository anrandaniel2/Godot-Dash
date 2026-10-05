class_name GroupPulse
extends Object
## GDScript twin of the native group pulse (1006 with key 52 = 1).
##
## Geometry Dash tints each member object from its own colour towards the
## pulse colour by the envelope weight. Batches lerp their records through
## DecorationBatch.apply_group_pulse; node-drawn objects keep the
## watcher-owned modulate on each layer sprite and get the factor
## self_modulate = lerp(1, pulse / tint, weight), so the product equals
## lerp(tint, pulse, weight) wherever the tint component is non-zero.


static func apply_to_group(tree: SceneTree, group: StringName, pulse: Color, weight: float) -> void:
	for node: Node in tree.get_nodes_in_group(group):
		apply_to_node(node, pulse, weight)


static func apply_to_node(node: Node, pulse: Color, weight: float) -> void:
	if node.has_method(&"apply_group_pulse"):
		node.call(&"apply_group_pulse", pulse, weight)
		return
	for child: Node in node.get_children():
		if child is CanvasItem:
			var layer := child as CanvasItem
			layer.self_modulate = self_modulate_for(layer.modulate, pulse, weight)


static func self_modulate_for(tint: Color, pulse: Color, weight: float) -> Color:
	return Color(
			_factor(tint.r, pulse.r, weight),
			_factor(tint.g, pulse.g, weight),
			_factor(tint.b, pulse.b, weight),
			1.0,
	)


static func _factor(from: float, to: float, weight: float) -> float:
	var target: float = to / from if from > 1.0 / 255.0 else (255.0 if to > 0.0 else 1.0)
	return 1.0 + (target - 1.0) * weight
