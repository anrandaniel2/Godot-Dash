class_name MsgPack
extends RefCounted
## Minimal MessagePack codec for the GDR replay interchange format.
##
## GDR 1 files (".gdr", the replay format shared with Mega Hack, GDRMobile,
## xdBot and the rest of the GD replay ecosystem) are a MessagePack-
## serialized dictionary: every .gdr file in the wild starts with a fixmap
## header followed by the "author" key. This codec covers exactly the value
## types GDR documents use - nil, bools, integers, floats, strings, arrays
## and string-keyed maps - and rejects binary/extension types with an error
## instead of misreading them.
##
## decode() answers with a result dictionary ({"ok": true, "value": ...} or
## {"ok": false, "error": "..."}) because null is itself a valid decoded
## value and cannot double as the failure sentinel.


static func encode(value: Variant) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	if not _encode(buffer, value):
		return PackedByteArray()
	return buffer.data_array


static func decode(bytes: PackedByteArray) -> Dictionary:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.data_array = bytes
	var size := bytes.size()
	if size == 0:
		return _fail("empty data")
	var result := _decode_value(buffer, size)
	if not result.ok:
		return result
	# A valid document is exactly one value; trailing bytes mean the data
	# is not MessagePack (or is corrupted).
	if buffer.get_position() != size:
		return _fail("trailing data after value")
	return result


static func _encode(buffer: StreamPeerBuffer, value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL:
			buffer.put_u8(0xc0)
		TYPE_BOOL:
			buffer.put_u8(0xc3 if value else 0xc2)
		TYPE_INT:
			_encode_int(buffer, value)
		TYPE_FLOAT:
			buffer.put_u8(0xcb)
			buffer.put_double(value)
		TYPE_STRING:
			_encode_string(buffer, value)
		TYPE_ARRAY:
			var elements: Array = value
			var size: int = elements.size()
			if size <= 0x0f:
				buffer.put_u8(0x90 | size)
			elif size <= 0xffff:
				buffer.put_u8(0xdc)
				buffer.put_u16(size)
			else:
				buffer.put_u8(0xdd)
				buffer.put_u32(size)
			for element: Variant in elements:
				if not _encode(buffer, element):
					return false
		TYPE_DICTIONARY:
			var fields: Dictionary = value
			var size: int = fields.size()
			if size <= 0x0f:
				buffer.put_u8(0x80 | size)
			elif size <= 0xffff:
				buffer.put_u8(0xde)
				buffer.put_u16(size)
			else:
				buffer.put_u8(0xdf)
				buffer.put_u32(size)
			for key: Variant in fields:
				if typeof(key) == TYPE_STRING_NAME:
					_encode_string(buffer, String(key))
				elif typeof(key) == TYPE_STRING:
					_encode_string(buffer, key)
				else:
					return false
				if not _encode(buffer, fields[key]):
					return false
		_:
			return false
	return true


static func _encode_int(buffer: StreamPeerBuffer, value: int) -> void:
	if value >= 0:
		if value <= 0x7f:
			buffer.put_u8(value)
		elif value <= 0xff:
			buffer.put_u8(0xcc)
			buffer.put_u8(value)
		elif value <= 0xffff:
			buffer.put_u8(0xcd)
			buffer.put_u16(value)
		elif value <= 0xffffffff:
			buffer.put_u8(0xce)
			buffer.put_u32(value)
		else:
			buffer.put_u8(0xcf)
			buffer.put_u64(value)
	elif value >= -0x20:
		buffer.put_u8(value & 0xff)
	elif value >= -0x80:
		buffer.put_u8(0xd0)
		buffer.put_8(value)
	elif value >= -0x8000:
		buffer.put_u8(0xd1)
		buffer.put_16(value)
	elif value >= -0x80000000:
		buffer.put_u8(0xd2)
		buffer.put_32(value)
	else:
		buffer.put_u8(0xd3)
		buffer.put_64(value)


static func _encode_string(buffer: StreamPeerBuffer, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	var size := bytes.size()
	if size <= 0x1f:
		buffer.put_u8(0xa0 | size)
	elif size <= 0xff:
		buffer.put_u8(0xd9)
		buffer.put_u8(size)
	elif size <= 0xffff:
		buffer.put_u8(0xda)
		buffer.put_u16(size)
	else:
		buffer.put_u8(0xdb)
		buffer.put_u32(size)
	buffer.put_data(bytes)


static func _decode_value(buffer: StreamPeerBuffer, size: int) -> Dictionary:
	if buffer.get_position() >= size:
		return _fail("unexpected end of data")
	var marker := buffer.get_u8()
	# Positive and negative fixints.
	if marker <= 0x7f:
		return _ok(marker)
	if marker >= 0xe0:
		return _ok(marker - 0x100)
	# Fixstr / fixarray / fixmap.
	if marker >= 0xa0:
		var length := marker & 0x1f
		if buffer.get_position() + length > size:
			return _fail("string exceeds data")
		return _ok(buffer.get_string(length))
	if marker >= 0x90:
		return _read_array(buffer, marker & 0x0f, size)
	if marker >= 0x80:
		return _read_map(buffer, marker & 0x0f, size)
	match marker:
		0xc0:
			return _ok(null)
		0xc2:
			return _ok(false)
		0xc3:
			return _ok(true)
		0xca:
			if not _has(buffer, size, 4):
				return _fail("truncated float32")
			return _ok(buffer.get_float())
		0xcb:
			if not _has(buffer, size, 8):
				return _fail("truncated float64")
			return _ok(buffer.get_double())
		0xcc:
			return _ok(buffer.get_u8())
		0xcd:
			if not _has(buffer, size, 2):
				return _fail("truncated uint16")
			return _ok(buffer.get_u16())
		0xce:
			if not _has(buffer, size, 4):
				return _fail("truncated uint32")
			return _ok(buffer.get_u32())
		0xcf:
			if not _has(buffer, size, 8):
				return _fail("truncated uint64")
			return _ok(buffer.get_u64())
		0xd0:
			if not _has(buffer, size, 1):
				return _fail("truncated int8")
			return _ok(buffer.get_8())
		0xd1:
			if not _has(buffer, size, 2):
				return _fail("truncated int16")
			return _ok(buffer.get_16())
		0xd2:
			if not _has(buffer, size, 4):
				return _fail("truncated int32")
			return _ok(buffer.get_32())
		0xd3:
			if not _has(buffer, size, 8):
				return _fail("truncated int64")
			return _ok(buffer.get_64())
		0xd9:
			return _read_string_result(buffer, size, 1)
		0xda:
			return _read_string_result(buffer, size, 2)
		0xdb:
			return _read_string_result(buffer, size, 4)
		0xdc:
			return _read_array(buffer, _read_len(buffer, size, 2), size)
		0xdd:
			return _read_array(buffer, _read_len(buffer, size, 4), size)
		0xde:
			return _read_map(buffer, _read_len(buffer, size, 2), size)
		0xdf:
			return _read_map(buffer, _read_len(buffer, size, 4), size)
		_:
			return _fail("unsupported message type 0x%02x" % marker)


static func _read_len(buffer: StreamPeerBuffer, size: int, byte_count: int) -> int:
	# Reads a big-endian length prefix, bounds-checked so a corrupt length
	# cannot make the following allocation runaway.
	var length := 0
	if not _has(buffer, size, byte_count):
		return -1
	for _i in byte_count:
		length = (length << 8) | buffer.get_u8()
	return length


static func _read_string_result(buffer: StreamPeerBuffer, size: int, length_bytes: int) -> Dictionary:
	var length := _read_len(buffer, size, length_bytes)
	if length < 0:
		return _fail("truncated string length")
	if buffer.get_position() + length > size:
		return _fail("string exceeds data")
	return _ok(buffer.get_string(length))


static func _read_array(buffer: StreamPeerBuffer, length: int, size: int) -> Dictionary:
	if length < 0:
		return _fail("invalid array length")
	var values: Array = []
	for _i in length:
		var result := _decode_value(buffer, size)
		if not result.ok:
			return result
		values.append(result.value)
	return _ok(values)


static func _read_map(buffer: StreamPeerBuffer, length: int, size: int) -> Dictionary:
	if length < 0:
		return _fail("invalid map length")
	var values := {}
	for _i in length:
		var key_result := _decode_value(buffer, size)
		if not key_result.ok:
			return key_result
		if typeof(key_result.value) != TYPE_STRING:
			return _fail("map keys must be strings")
		var value_result := _decode_value(buffer, size)
		if not value_result.ok:
			return value_result
		values[key_result.value] = value_result.value
	return _ok(values)


static func _has(buffer: StreamPeerBuffer, size: int, byte_count: int) -> bool:
	return buffer.get_position() + byte_count <= size


static func _ok(value: Variant) -> Dictionary:
	return {"ok": true, "value": value}


static func _fail(error: String) -> Dictionary:
	return {"ok": false, "error": error}
