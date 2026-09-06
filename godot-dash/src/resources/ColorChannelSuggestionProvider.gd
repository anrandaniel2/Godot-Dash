class_name ColorChannelSuggestionProvider
extends SuggestionProvider

func get_suggestions(color_channel_to_search: String) -> Array[String]:
	var color_channels: Array[String] = []
	for color_channel in LevelManager.current_level.color_channels:
		color_channels.append(color_channel.associated_group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX))
	color_channel_to_search = color_channel_to_search.strip_edges()
	if not color_channel_to_search.is_empty():
		color_channels = StringUtils.fuzzy_filter(color_channels, color_channel_to_search)
	return color_channels
