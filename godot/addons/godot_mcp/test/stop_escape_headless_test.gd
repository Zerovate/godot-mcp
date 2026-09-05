extends SceneTree

class IgnoredQuitTransport extends RefCounted:
	func send_message(_message: String, _data: Array) -> void:
		pass

class ProcessSession extends RefCounted:
	var session_id: int
	var process_id: int
	var debugger_session := IgnoredQuitTransport.new()

	func has_active_session() -> bool:
		return OS.is_process_running(process_id)

	func is_bridge_ready() -> bool:
		return true


func _initialize() -> void:
	if OS.get_cmdline_user_args().has("child"):
		return
	_run.call_deferred()


func _run() -> void:
	var arguments := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://addons/godot_mcp/test/stop_escape_headless_test.gd", "--", "child"])
	var target := ProcessSession.new()
	target.session_id = 41
	target.process_id = OS.create_instance(arguments)
	var survivor := OS.create_instance(arguments)
	if target.process_id <= 0 or survivor <= 0:
		if target.process_id > 0:
			OS.kill(target.process_id)
		if survivor > 0:
			OS.kill(survivor)
		printerr("Could not create test processes")
		quit(1)
		return
	var started := Time.get_ticks_msec()
	var result: Dictionary = await MCPDebugCommands.new()._stop_sessions([target])
	var elapsed := Time.get_ticks_msec() - started
	var passed: bool = result.get("status") == "success" and result.result.forced == [41] \
		and not OS.is_process_running(target.process_id) and OS.is_process_running(survivor) \
		and elapsed >= 2000 and elapsed < 5000
	OS.kill(survivor)
	if OS.is_process_running(target.process_id):
		OS.kill(target.process_id)
	print("stop escape targeted force fallback: %s (%d ms)" % ["PASS" if passed else "FAIL", elapsed])
	quit(0 if passed else 1)
