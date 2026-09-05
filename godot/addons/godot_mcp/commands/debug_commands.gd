@tool
extends MCPBaseCommand
class_name MCPDebugCommands

# Keep in sync with LAUNCH_FROZEN_ENV in mcp_game_bridge.gd.
const LAUNCH_FROZEN_ENV := "GODOT_MCP_LAUNCH_FROZEN"
const READY_TIMEOUT_MS := 20000
const STOP_GRACE_MS := 2000
const STOP_TIMEOUT_MS := 5000


func get_commands() -> Dictionary:
	return {
		"run_project": run_project,
		"launch_instance": launch_instance,
		"list_instances": list_instances,
		"stop_project": stop_project,
		"stop_all_instances": stop_all_instances,
		"get_log_messages": get_log_messages,
		"get_stack_trace": get_stack_trace,
	}


func run_project(params: Dictionary) -> Dictionary:
	return await _lifecycle(_run_project, params)


func launch_instance(params: Dictionary) -> Dictionary:
	return await _lifecycle(_launch_instance, params)


func stop_project(params: Dictionary) -> Dictionary:
	return await _lifecycle(_stop_project, params)


func stop_all_instances(params: Dictionary) -> Dictionary:
	return await _lifecycle(_stop_all_instances, params)


func list_instances(_params: Dictionary) -> Dictionary:
	return _success({"instances": _plugin.get_debugger_plugin().list_instances()})


func _lifecycle(operation: Callable, params: Dictionary) -> Dictionary:
	var manager = _plugin.get_debugger_plugin()
	if manager.lifecycle_busy:
		return _error("LIFECYCLE_BUSY", "Another game launch or stop is in progress")
	manager.lifecycle_busy = true
	var result: Dictionary = await operation.call(params)
	manager.lifecycle_busy = false
	return result


func _validate_launch(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
		if main_scene.is_empty():
			return _error("NO_MAIN_SCENE", "Set application/run/main_scene or pass scene_path")
	elif not ResourceLoader.exists(scene_path, "PackedScene"):
		return _error("INVALID_SCENE", "Scene does not exist: %s" % scene_path)
	return {}


func _run_project(params: Dictionary) -> Dictionary:
	var manager = _plugin.get_debugger_plugin()
	if not manager.list_instances().is_empty() or EditorInterface.is_playing_scene():
		return _error("ALREADY_RUNNING", "Stop existing instances before run, or use launch_instance")
	var count := int(params.get("instances", 1))
	if count < 1 or count > 4:
		return _error("INVALID_INSTANCE_COUNT", "instances must be between 1 and 4")
	var validation := _validate_launch(params)
	if not validation.is_empty():
		return validation
	var scene_path: String = params.get("scene_path", "")
	var frozen: bool = params.get("frozen", false)
	var previous_env := OS.get_environment(LAUNCH_FROZEN_ENV)
	var previous_uri := OS.get_environment("GODOT_MCP_REMOTE_DEBUG_URI")
	OS.set_environment("GODOT_MCP_REMOTE_DEBUG_URI", "")
	OS.set_environment(LAUNCH_FROZEN_ENV, "1" if frozen else "")
	if scene_path.is_empty():
		EditorInterface.play_main_scene()
	else:
		EditorInterface.play_custom_scene(scene_path)
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	OS.set_environment(LAUNCH_FROZEN_ENV, previous_env)
	OS.set_environment("GODOT_MCP_REMOTE_DEBUG_URI", previous_uri)
	var first := await _wait_ready([])
	var initial_ids: Array = []
	for instance in manager.list_instances():
		initial_ids.append(instance["session_id"])
	if first.is_empty():
		return await _failed_launch("BRIDGE_NOT_READY", "Game bridge did not become ready within 20 seconds", [], initial_ids)
	if manager.list_instances().size() != 1:
		return await _failed_launch("RUN_COUNT_MISMATCH", "The editor launched multiple instances. Set its Run Multiple Instances count to 1", [], initial_ids)
	if count > 1 and str(first.get("remote_debug_uri", "")).is_empty():
		return await _failed_launch("DEBUG_ENDPOINT_UNAVAILABLE", "Could not read the first game's original --remote-debug argument. This platform must allow querying its own process command line", [], initial_ids)
	var launched: Array = []
	for index in range(1, count):
		var pid := _spawn_instance(params, str(first.get("remote_debug_uri", "")))
		if pid <= 0:
			return await _failed_launch("LAUNCH_FAILED", "Could not spawn an additional instance; check remote_debug_uri", launched, initial_ids)
		launched.append(pid)
	if not launched.is_empty() and (await _wait_ready(launched)).is_empty():
		return await _failed_launch("BRIDGE_NOT_READY", "Additional game bridges did not become ready within 20 seconds", launched, initial_ids)
	var instances: Array = manager.list_instances()
	if instances.size() != count:
		return await _failed_launch("RUN_COUNT_MISMATCH", "The number of connected instances differs from the requested count", launched, initial_ids)
	return _success({"instances": instances, "frozen": frozen})


func _launch_instance(params: Dictionary) -> Dictionary:
	var validation := _validate_launch(params)
	if not validation.is_empty():
		return validation
	var manager = _plugin.get_debugger_plugin()
	var uri := ""
	for instance in manager.list_instances():
		if instance.get("ready", false):
			uri = str(instance.get("remote_debug_uri", ""))
			if not uri.is_empty():
				break
	if uri.is_empty():
		return _error("DEBUG_ENDPOINT_UNAVAILABLE", "No ready game reports its original --remote-debug endpoint. Run a game and allow querying its own process command line")
	var pid := _spawn_instance(params, uri)
	if pid <= 0:
		return _error("LAUNCH_FAILED", "Could not create game process")
	var instance := await _wait_ready([pid])
	if instance.is_empty():
		if OS.is_process_running(pid):
			OS.kill(pid)
		return _error("BRIDGE_NOT_READY", "New game bridge did not become ready within 20 seconds")
	return _success({"instance": instance, "frozen": params.get("frozen", false)})


func _spawn_instance(params: Dictionary, uri: String) -> int:
	if uri.is_empty():
		return -1
	var arguments := PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), "--remote-debug", uri])
	var scene_path: String = params.get("scene_path", "")
	if not scene_path.is_empty():
		arguments.append(scene_path)
	var user_args: Array = params.get("args", [])
	if not user_args.is_empty():
		arguments.append("--")
		arguments.append_array(PackedStringArray(user_args))
	var previous_env := OS.get_environment(LAUNCH_FROZEN_ENV)
	var previous_uri := OS.get_environment("GODOT_MCP_REMOTE_DEBUG_URI")
	OS.set_environment("GODOT_MCP_REMOTE_DEBUG_URI", uri)
	OS.set_environment(LAUNCH_FROZEN_ENV, "1" if params.get("frozen", false) else "")
	var pid := OS.create_instance(arguments)
	OS.set_environment(LAUNCH_FROZEN_ENV, previous_env)
	OS.set_environment("GODOT_MCP_REMOTE_DEBUG_URI", previous_uri)
	return pid


func _wait_ready(process_ids: Array) -> Dictionary:
	var manager = _plugin.get_debugger_plugin()
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < READY_TIMEOUT_MS:
		var remaining := process_ids.duplicate()
		var last: Dictionary = {}
		for instance in manager.list_instances():
			if not instance.get("ready", false):
				continue
			if process_ids.is_empty():
				return instance
			var pid := int(instance.get("process_id", 0))
			if remaining.has(pid):
				remaining.erase(pid)
				last = instance
		if remaining.is_empty() and not last.is_empty():
			return last
		await Engine.get_main_loop().process_frame
	return {}


func _failed_launch(code: String, message: String, process_ids: Array, initial_ids: Array) -> Dictionary:
	var manager = _plugin.get_debugger_plugin()
	var sessions: Array = []
	for instance in manager.list_instances():
		if initial_ids.has(instance["session_id"]) or process_ids.has(instance.get("process_id", 0)):
			var resolved: Dictionary = manager.resolve_session({"session_id": instance["session_id"]})
			if resolved.has("session") and resolved.session != null:
				sessions.append(resolved.session)
	await _stop_sessions(sessions)
	for pid in process_ids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	var unrelated := false
	for instance in manager.list_instances():
		if not initial_ids.has(instance["session_id"]) and not process_ids.has(instance.get("process_id", 0)):
			unrelated = true
	if not unrelated and EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	return _error(code, message)


func _stop_project(params: Dictionary) -> Dictionary:
	var resolved: Dictionary = _plugin.get_debugger_plugin().resolve_session(params)
	if resolved.get("status") == "error":
		return resolved
	var session = resolved.get("session")
	if session == null:
		return _success({"stopped": [], "forced": []})
	return await _stop_sessions([session])


func _stop_all_instances(_params: Dictionary) -> Dictionary:
	var manager = _plugin.get_debugger_plugin()
	var sessions: Array = []
	for instance in manager.list_instances():
		var resolved: Dictionary = manager.resolve_session({"session_id": instance["session_id"]})
		if resolved.has("session") and resolved.session != null:
			sessions.append(resolved.session)
	return await _stop_sessions(sessions)


func _stop_sessions(sessions: Array) -> Dictionary:
	var stopped: Array = []
	var forced: Array = []
	var force_attempted := false
	for session in sessions:
		session.debugger_session.send_message("godot_mcp:quit", [])
		stopped.append(session.session_id)
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < STOP_TIMEOUT_MS:
		if not force_attempted and Time.get_ticks_msec() - start >= STOP_GRACE_MS:
			force_attempted = true
			for session in sessions:
				var pid: int = session.process_id
				if session.has_active_session() and session.is_bridge_ready() and pid > 0 and pid != OS.get_process_id():
					if OS.is_process_running(pid) and OS.kill(pid) == OK:
						forced.append(session.session_id)
		var active := false
		for session in sessions:
			active = active or session.has_active_session()
		if not active:
			return _success({"stopped": stopped, "forced": forced})
		await Engine.get_main_loop().process_frame
	return _error("STOP_TIMEOUT", "Some instances did not exit within 5 seconds; force-stop requires a ready bridge with a known process_id")


func get_log_messages(params: Dictionary) -> Dictionary:
	var clear: bool = params.get("clear", false)
	var limit: int = int(params.get("limit", 50))
	var severity: String = params.get("severity", "all")
	var since: int = int(params.get("since", 0))

	var result := MCPLogger.query(since, severity, limit)

	if clear:
		MCPLogger.clear_errors()

	# The phantom "Identifier not found: <autoload>" errors that mislead agents
	# come from the editor running stale after project.godot was edited on disk
	# (#245). When that divergence is present, attach it here so the caller reads
	# the log and the "your editor is stale, restart it" advisory in one shot,
	# instead of chasing compile errors that do not exist at runtime.
	var staleness := MCPUtils.detect_project_staleness()
	if staleness.get("stale", false):
		result["staleness"] = staleness

	return _success(result)


func get_stack_trace(_params: Dictionary) -> Dictionary:
	var frames := MCPLogger.get_last_stack_trace()
	var errors := MCPLogger.get_errors()
	var last_error: Dictionary = errors[-1] if not errors.is_empty() else {}
	return _success({
		"error": last_error.get("message", ""),
		"error_type": last_error.get("type", ""),
		"file": last_error.get("file", ""),
		"line": last_error.get("line", 0),
		"frames": frames,
	})
