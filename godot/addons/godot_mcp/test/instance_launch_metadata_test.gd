extends SceneTree


func _initialize() -> void:
	var cases := [
		[PackedStringArray(["--remote-debug", "tcp://127.0.0.1:6007"]), "tcp://127.0.0.1:6007"],
		[PackedStringArray(["--path", "C:/Project With Spaces", "--remote-debug=tcp://localhost:6101"]), "tcp://localhost:6101"],
		[PackedStringArray(["--remote-debug", "tcp://[::1]:6008", "--editor-pid", "1234"]), "tcp://[::1]:6008"],
		[PackedStringArray(["--remote-debug"]), ""],
		[PackedStringArray(["--path", "res://"]), ""],
	]
	var failures := 0
	for index in cases.size():
		var actual := MCPGameBridge._remote_debug_uri(cases[index][0])
		if actual != cases[index][1]:
			printerr("FAIL remote debug URI case %d: %s" % [index, actual])
			failures += 1
	var command_lines := [
		["godot.exe --remote-debug tcp://127.0.0.1:6010 --scene res://main.tscn", "tcp://127.0.0.1:6010"],
		["\"C:/Path With Spaces/godot.exe\" --remote-debug \"tcp://[::1]:6009\"", "tcp://[::1]:6009"],
		["godot --remote-debug=tcp://127.0.0.1:6011", "tcp://127.0.0.1:6011"],
		["godot --scene res://main.tscn", ""],
	]
	for index in command_lines.size():
		var actual := MCPGameBridge._remote_debug_uri_from_command_line(command_lines[index][0])
		if actual != command_lines[index][1]:
			printerr("FAIL raw command line URI case %d: %s" % [index, actual])
			failures += 1
	var total := cases.size() + command_lines.size()
	print("instance launch metadata: %d/%d passed" % [total - failures, total])
	quit(1 if failures else 0)
