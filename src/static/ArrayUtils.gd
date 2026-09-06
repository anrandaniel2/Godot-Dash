@abstract
class_name ArrayUtils
extends Node

enum Transformation {
	MEAN,
	MEDIAN,
}


## Appends an array to another and removes the duplicates between the two.
static func union(a: Array, b: Array) -> Array:
	var result: Array = a.duplicate()
	for element in b:
		if not element in a:
			result.append(element)
	return result


## Get an array of the elements only in the first array.
static func difference(a: Array, b: Array) -> Array:
	var result: Array
	for element in a:
		if not element in b:
			result.append(element)
	return result


## Get an array of the elements only in both arrays.
static func intersect(a: Array, b: Array) -> Array:
	var result: Array
	for element in b:
		if element in a:
			result.append(element)
	return result


## Get an array with only unique elements from the source array (removes duplicates).
static func to_set(array: Array) -> Array:
	var result: Array
	for element in array:
		if not element in result:
			result.append(element)
	return result


static func are_equivalent(a: Array, b: Array) -> bool:
	return a.all(func(element): return element in b) and b.all(func(element): return element in a)


## Get an array of the median of a float array or a [Vector2] with the median of the x and y components.
static func transform(array: Array[Variant], transformation: Transformation, at_edges: bool = false) -> Variant:
	if array[0] is float or array[0] is int:
		var result: float
		if at_edges:
			array.sort()
			array = [array[0], array[-1]]
		else:
			array = to_set(array)
		match transformation:
			Transformation.MEAN:
				result = _mean_float(array)
			Transformation.MEDIAN:
				result = _median_float(array)
		return result
	elif array[0] is Vector2 or array[0] is Vector2i:
		var result: Vector2
		var array_x = array.map(func(element): return round(element.x))
		var array_y = array.map(func(element): return round(element.y))
		array_x = to_set(array_x)
		array_y = to_set(array_y)
		if at_edges:
			array_x.sort()
			array_y.sort()
			array_x = [array_x[0], array_x[-1]]
			array_y = [array_y[0], array_y[-1]]
		match transformation:
			Transformation.MEAN:
				result.x = _mean_float(array_x)
				result.y = _mean_float(array_y)
			Transformation.MEDIAN:
				result.x = _median_float(array_x)
				result.y = _median_float(array_y)
		if array is Array[Vector2i]:
			return Vector2i(result)
		else:
			return result
	else:
		printerr("Array must be of type float, int, Vector2 or Vector2i")
		return null


# Filter out `null` elements of an array in `Array.filter`
static func flatten(val: Variant) -> Variant:
	return val != null


static func _median_float(array: Array) -> float:
	array.sort()
	if len(array) % 2 == 1:
		return array[(len(array)) * 0.5]
	else:
		return (array[len(array) * 0.5 - 1] + array[len(array) * 0.5]) * 0.5


static func _mean_float(array: Array) -> float:
	return array.reduce(func(accum, number): return accum + number) / len(array)
