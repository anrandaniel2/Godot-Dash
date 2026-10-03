@abstract
class_name StringUtils
extends Node
## String utilities.
##
## Pure GDScript port of the class that used to live in the `godot-rust-utils` GDExtension.
## The fuzzy matching previously used the Rust `skim` crate; this implementation reproduces its
## behaviour (smart case subsequence matching with a relevance score, best matches first) with a
## simplified scoring heuristic, which is all the suggestion dropdowns need.


## Returns the plural form of [param word] for [param count].
##
## Handles regular English pluralization rules and the most common irregular words. Words that
## are already plural are returned unchanged.
static func pluralize(word: String, count: int) -> String:
	const IRREGULARS := {
		"child": "children", "children": "children",
		"man": "men", "men": "men",
		"woman": "women", "women": "women",
		"person": "people", "people": "people",
		"mouse": "mice", "mice": "mice",
		"goose": "geese", "geese": "geese",
		"tooth": "teeth", "teeth": "teeth",
		"foot": "feet", "feet": "feet",
		"ox": "oxen", "oxen": "oxen",
		"die": "dice", "dice": "dice",
	}
	const VOWELS := ["a", "e", "i", "o", "u"]

	if count == 1:
		return word

	var lowered := word.to_lower()
	if IRREGULARS.has(lowered):
		return IRREGULARS[lowered]
	if lowered.ends_with("s") or lowered.ends_with("x") or lowered.ends_with("z") \
			or lowered.ends_with("ch") or lowered.ends_with("sh"):
		return word + "es"
	if lowered.ends_with("y") and lowered.length() > 1 \
			and not lowered[lowered.length() - 2] in VOWELS:
		return word.substr(0, word.length() - 1) + "ies"
	if lowered.ends_with("fe"):
		return word.substr(0, word.length() - 2) + "ves"
	if lowered.ends_with("f"):
		return word.substr(0, word.length() - 1) + "ves"
	return word + "s"


## Filters [param strings], keeping the ones fuzzy-matched by [param pattern], sorted by relevance
## (best matches first, ties keep their original order). Strings that don't match are removed.
## An empty [param pattern] matches every string.
static func fuzzy_filter(strings: Array[String], pattern: String) -> Array[String]:
	if pattern.is_empty():
		return strings.duplicate()

	var scored: Array = []
	for index: int in strings.size():
		var score: Variant = _fuzzy_score(strings[index], pattern)
		if score != null:
			# Keep the original index around for stable sorting.
			scored.append([score, index, strings[index]])

	scored.sort_custom(
		func(a: Array, b: Array) -> bool:
			return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1])
	)

	var result: Array[String] = []
	for entry: Array in scored:
		result.append(entry[2])
	return result


# Scores a fuzzy match of pattern against candidate, or returns null if there is no match.
# Uses skim-style smart case: lowercase pattern characters match case-insensitively, uppercase
# pattern characters must match the exact uppercase character. If that fails, the match is
# retried fully case-insensitively.
static func _fuzzy_score(candidate: String, pattern: String) -> Variant:
	var score: Variant = _score(candidate, pattern, false)
	if score == null:
		score = _score(candidate, pattern, true)
	return score


static func _score(candidate: String, pattern: String, ignore_case: bool) -> Variant:
	var score := 0
	var previous_match_index := -2
	for pattern_index: int in pattern.length():
		var pattern_char := pattern[pattern_index]
		var pattern_char_is_uppercase := pattern_char != pattern_char.to_lower()
		var found := false
		var search_from := maxi(previous_match_index + 1, 0)
		for candidate_index: int in range(search_from, candidate.length()):
			var candidate_char := candidate[candidate_index]
			var chars_match: bool = (
				candidate_char.to_lower() == pattern_char.to_lower()
				if ignore_case or not pattern_char_is_uppercase
				else candidate_char == pattern_char
			)
			if not chars_match:
				continue

			found = true
			score += 4
			if candidate_char == pattern_char:
				score += 2
			if candidate_index == previous_match_index + 1:
				score += 8 # consecutive match
			elif candidate_index == 0 or candidate[candidate_index - 1] in " _-.()[]/\\":
				score += 6 # word boundary match
			if previous_match_index == -2:
				score -= 3 # gap before the first match
				score -= candidate_index
			else:
				score -= candidate_index - previous_match_index - 1 # gap between matches
			previous_match_index = candidate_index
			break
		if not found:
			return null
	return score
