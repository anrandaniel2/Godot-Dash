@abstract
class_name DictUtils

static func map_keys(dict: Dictionary, method: Callable) -> Dictionary:
	var new_dict: Dictionary = { }
	for key in dict:
		new_dict[method.call(key)] = dict[key]
	return new_dict


static func map_values(dict: Dictionary, method: Callable) -> Dictionary:
	var new_dict: Dictionary = { }
	for key in dict:
		new_dict[key] = method.call(dict[key])
	return new_dict
