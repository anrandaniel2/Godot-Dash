class_name ResourceCache
extends RefCounted

var cache: Dictionary[String, Resource]


func get_or_load(path: String) -> Resource:
	if path in cache.keys():
		return cache[path]
	var resource: Resource = load(path)
	cache[path] = resource
	return resource
