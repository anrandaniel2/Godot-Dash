class_name GroupSuggestionProvider
extends SuggestionProvider

func get_suggestions(group_to_search: String) -> Array[String]:
	var all_groups: Array[StringName] = []
	for layer: Layer in LevelManager.current_level.layers:
		for object: Node in layer.get_children():
			all_groups.append_array(object.get_groups())

	var groups_available: Array[String] = []
	for group in ArrayUtils.to_set(all_groups):
		if group.begins_with(Constants.GROUP_PREFIX):
			groups_available.append(str(group).trim_prefix(("g_")))

	group_to_search = group_to_search.strip_edges()
	if not group_to_search.is_empty():
		groups_available = StringUtils.fuzzy_filter(groups_available, group_to_search)
	return groups_available
