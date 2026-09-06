@abstract
class_name PropertyGenerator

static func from_property_list_field(field: Dictionary, default_value: Variant) -> Property:
	var type: Variant.Type = field.type
	var property: Property
	match type:
		TYPE_INT:
			match field.hint:
				PROPERTY_HINT_ENUM:
					var fields: PackedStringArray = field.hint_string.split(",")
					if fields.size() > 3:
						property = EnumProperty.new()
					else:
						property = OneLineEnumProperty.new()
					var prefix: String = "%s " % field.class_name.capitalize()
					property.fields = fields
					for i in property.fields.size():
						var enum_variant_name: String = property.fields[i].get_slice(":", 0).trim_prefix(prefix)
						property.fields.set(i, enum_variant_name)
					if default_value != null:
						property.default = default_value as int
				PROPERTY_HINT_FLAGS:
					property = FlagsProperty.new()
					property.flags = field.hint_string.split(",")
					for i in property.flags.size():
						property.flags.set(i, property.flags[i].get_slice(":", 0))
					if default_value != null:
						property.default = default_value as int
				_:
					property = FloatProperty.new()
					property.allow_lesser = true
					property.allow_greater = true
					property.rounded = true
					property.step = 1.0
					if default_value != null:
						property.default = default_value as float
		TYPE_FLOAT:
			property = FloatProperty.new()
			property.draw_slider = "slider" in field.hint_string
			property.is_percentage = "percentage" in field.hint_string
			if field.hint == PROPERTY_HINT_NONE:
				property.allow_lesser = true
				property.allow_greater = true
			elif field.hint == PROPERTY_HINT_RANGE:
				property = handle_range_hint(field, property)
			if default_value != null:
				property.default = default_value as float
		TYPE_STRING, TYPE_STRING_NAME:
			if field.hint == PROPERTY_HINT_GLOBAL_FILE:
				property = FileProperty.new()
				var split_hint_string := Array(field.hint_string.split(","))
				if "load_root" in field.hint_string:
					var hint_string_idx: int = split_hint_string.find("load_root")
					property.load_root = split_hint_string[hint_string_idx].trim_prefix("load_root:")
					split_hint_string.remove_at(hint_string_idx)
				if "import_to" in field.hint_string:
					var hint_string_idx: int = split_hint_string.find("import_to")
					property.load_root = split_hint_string[hint_string_idx].trim_prefix("import_to:")
					split_hint_string.remove_at(hint_string_idx)
				property.filetype_filters = PackedStringArray(split_hint_string)
			elif field.hint == PROPERTY_HINT_MULTILINE_TEXT:
				property = MultilineStringProperty.new()
			else:
				if "suggestion_provider" in field and field.suggestion_provider is SuggestionProvider:
					property = SearchableStringProperty.new()
					property.suggestion_provider = field.suggestion_provider as SuggestionProvider
				else:
					property = StringProperty.new()
				if field.hint == PROPERTY_HINT_PLACEHOLDER_TEXT:
					property.placeholder = field.hint_string
			if default_value != null:
				property.default = default_value as String
		TYPE_NODE_PATH:
			property = NodeProperty.new()
			if default_value != null:
				property.default = Serialize.Node(default_value) if not default_value.is_empty() else NodePath()
		TYPE_COLOR:
			property = ColorProperty.new()
			if default_value != null:
				property.default = default_value as Color
		TYPE_VECTOR2:
			property = Vector2Property.new()
			if field.hint == PROPERTY_HINT_NONE:
				property.allow_lesser = true
				property.allow_greater = true
				if "suffix" in field.hint_string:
					property.suffix = field.hint_string.trim_prefix("suffix:")
			elif field.hint == PROPERTY_HINT_RANGE:
				property = handle_range_hint(field, property)
			property.default = default_value as Vector2
		TYPE_BOOL:
			property = BoolProperty.new()
			if default_value != null:
				property.default = default_value as bool
		TYPE_OBJECT:
			match field.hint:
				PROPERTY_HINT_RESOURCE_TYPE:
					property = load("res://scenes/components/game_components/resource_properties/" + field.hint_string + "Property.tscn").instantiate()
		TYPE_ARRAY:
			property = ArrayProperty.new()
			var hint_string: String = field.hint_string
			var array_type := int(hint_string.get_slice("/", 0))
			var array_hint := int(hint_string.get_slice("/", 1))
			var array_hint_string: String = hint_string.get_slice(":", 1)
			var packed := PackedScene.new()
			# TODO: handle other typed arrays
			if array_type == TYPE_OBJECT and array_hint == PROPERTY_HINT_RESOURCE_TYPE:
				packed = load("res://scenes/components/game_components/resource_properties/" + array_hint_string + "Property.tscn")
			property.item_template = packed
	assert(property != null)
	return property


static func handle_range_hint(field: Dictionary, property: Property) -> Property:
	var hint_string: String = field.hint_string
	var split_hint_string: PackedStringArray = hint_string.split(",")
	var min_value: float = float(split_hint_string[0])
	var max_value: float = float(split_hint_string[1])
	var step: float = float(split_hint_string[2])
	property.min_value = min_value
	property.max_value = max_value
	property.step = step
	if "or_greater" in hint_string:
		property.allow_greater = true
	if "or_less" in hint_string:
		property.allow_lesser = true
	if "degrees" in hint_string:
		property.suffix = "°"
	if "suffix" in hint_string:
		property.suffix = split_hint_string[split_hint_string.find("suffix")].trim_prefix("suffix:")
	return property
