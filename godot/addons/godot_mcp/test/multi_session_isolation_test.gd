extends SceneTree

# Run with --headless --editor --path <fixture> --script <this script>.
# EditorDebuggerPlugin cannot be instantiated in a non-editor process.

class FakeTransport extends RefCounted:
	var active := true
	var sent: Array = []
	func is_active() -> bool:
		return active
	func send_message(message: String, data: Array) -> void:
		sent.append([message, data])
	func is_breaked() -> bool:
		return false

class FakePlugin extends EditorPlugin:
	var manager: MCPDebuggerPlugin
	func get_debugger_plugin() -> MCPDebuggerPlugin:
		return manager

class ConcurrentHandler extends MCPBaseCommand:
	var local_marker := -1
	func get_commands() -> Dictionary:
		return {"find_nodes": probe}
	func probe(_params: Dictionary) -> Dictionary:
		local_marker = _get_debugger_plugin().session_id
		_get_debugger_plugin().send_game_message("probe")
		while not _get_debugger_plugin().has_response("probe"):
			await Engine.get_main_loop().process_frame
		return _success({"local_marker": local_marker,
			"response": _get_debugger_plugin().get_response("probe")})

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var registry := MCPDebuggerPlugin.new()
	var wire_a := FakeTransport.new()
	var wire_b := FakeTransport.new()
	var a := registry._register_session(0, wire_a)
	var b := registry._register_session(1, wire_b)
	_check(a.session_id != b.session_id, "instances have distinct public IDs")
	registry._capture("godot_mcp:bridge_ready", ["res://a.tscn", {"process_id": 101}], 0)
	_check(a.is_bridge_ready() and not b.is_bridge_ready(), "ready belongs only to its source session")
	_check(a.describe().process_id == 101, "ready metadata retains source PID")
	_check(registry.resolve_session({}).error.code == "AMBIGUOUS_SESSION", "multiple instances require explicit target")
	_check(registry.resolve_session({"session_id": b.session_id}).session == b, "explicit target resolves to its object")
	_check(registry.resolve_session({"session_id": 0.5}).error.code == "INVALID_PARAMS", "fractional ID rejected")
	_check(registry.resolve_session({"session_id": -1}).error.code == "INVALID_PARAMS", "negative ID rejected")
	_check(registry.resolve_session({"session_id": true}).error.code == "INVALID_PARAMS", "boolean ID rejected")
	_check(a.acquire() and b.acquire(), "different sessions admit concurrent commands")
	_check(not a.acquire(), "same session rejects overlapping command")
	a.send_game_message("exec_run", [{"call_id": 1}])
	b.send_game_message("exec_run", [{"call_id": 2}])
	_check(wire_a.sent[0][1][0].call_id == 1 and wire_b.sent[0][1][0].call_id == 2, "commands use their own debugger transport")
	registry._capture("godot_mcp:game_response", ["exec_run", {"call_id": 2, "value": "B"}], 1)
	_check(not a.has_response("exec_run") and b.get_response("exec_run").value == "B", "same-named responses never cross instances")
	registry._capture("godot_mcp:game_response", ["exec_run", {"call_id": 99}], 0)
	_check(not a.has_response("exec_run") and a.is_busy(), "wrong call ID cannot complete current request")
	a.clear_response("exec_run")
	a.release()
	_check(a.is_busy() and not a.acquire(), "generic timeout keeps pending request admitted until wire completion")
	registry._capture("godot_mcp:game_response", ["exec_run", {"call_id": 1, "value": "old"}], 0)
	_check(not a.is_busy() and not a.has_response("exec_run"), "late generic reply drains pending state and is discarded")
	_check(a.acquire(), "next command admitted after late response drains")
	a.send_game_message("exec_run", [{"call_id": 3}])
	registry._capture("godot_mcp:game_response", ["exec_run", {"call_id": 1, "value": "stale"}], 0)
	_check(not a.has_response("exec_run"), "late duplicate cannot satisfy a newer exec")
	registry._capture("godot_mcp:game_response", ["exec_run", {"call_id": 3, "value": "new"}], 0)
	_check(a.get_response("exec_run").value == "new", "new exec receives its own result")
	a.clear_response("exec_run")
	a.release()
	b.clear_response("exec_run")
	b.release()
	_check(a.next_call_id() != a.next_call_id(), "exec correlation IDs survive fresh handler lifetimes")
	for kind in ["screenshot", "performance_metrics", "find_nodes", "input_map", "input_sequence", "type_text"]:
		_check(a.acquire(), "dedicated %s request acquires session" % kind)
		match kind:
			"screenshot": a.request_screenshot()
			"performance_metrics": a.request_performance_metrics()
			"find_nodes": a.request_find_nodes("*", "", "")
			"input_map": a.request_input_map()
			"input_sequence": a.request_input_sequence([])
			"type_text": a.request_type_text("hello", 0, false)
		a.release()
		_check(a.is_busy() and not a.acquire(), "timed-out %s remains busy" % kind)
		registry._capture("godot_mcp:%s_result" % kind, [], 1)
		_check(a.is_busy(), "other instance's %s reply cannot unlock this instance" % kind)
		registry._capture("godot_mcp:%s_result" % kind, [], 0)
		_check(not a.is_busy(), "late %s reply drains its own pending flag" % kind)
	a.acquire()
	a.send_game_message("watch_collect")
	a.release()
	b.acquire()
	b.send_game_message("watch_collect")
	registry._session_stopped(0)
	_check(not a.has_active_session() and not a.is_busy(), "stopping a session cancels only its pending requests")
	_check(b.has_active_session() and b.is_busy(), "other session stays active with its pending request intact")
	_check(registry.resolve_session({}).session == b, "sole remaining session becomes unambiguous")
	var replacement := registry._register_session(0, FakeTransport.new())
	_check(replacement.session_id > b.session_id, "reused debugger slot gets fresh monotonically increasing public ID")
	_check(registry.resolve_session({"session_id": a.session_id}).error.code == "NO_SESSION", "stale public ID cannot select replacement process")
	_check(not replacement.is_bridge_ready() and not replacement.is_busy(), "replacement starts with clean ready and pending state")
	_check(not a.capture("godot_mcp:bridge_ready", []), "stopped object ignores late capture")
	registry._capture("godot_mcp:game_response", ["watch_collect", {"value": "B-live"}], 1)
	_check(b.get_response("watch_collect").value == "B-live", "other instance completes after peer restart")
	b.release()
	var fake_plugin := FakePlugin.new()
	fake_plugin.manager = registry
	var router := MCPCommandRouter.new()
	router.setup(fake_plugin)
	router._register_handler(ConcurrentHandler.new(), fake_plugin)
	var completions := {}
	_complete_route(router, b.session_id, completions)
	_complete_route(router, replacement.session_id, completions)
	await process_frame
	_check(completions.is_empty(), "two router requests remain independently in flight")
	var rejected: Dictionary = await router.handle_command("find_nodes", {"session_id": b.session_id})
	_check(rejected.error.code == "SESSION_BUSY", "router rejects overlapping request on same target")
	registry._capture("godot_mcp:game_response", ["probe", "replacement"], 0)
	await process_frame
	_check(completions.has(replacement.session_id) and not completions.has(b.session_id), "one response completes only its own router call")
	registry._capture("godot_mcp:game_response", ["probe", "B"], 1)
	await process_frame
	_check(completions[b.session_id].result.local_marker == b.session_id, "fresh handlers keep invocation-local state across awaits")
	_check(completions[replacement.session_id].result.local_marker == replacement.session_id, "second fresh handler retains its own bound session")
	_check(not b.is_busy() and not replacement.is_busy(), "router releases successful commands independently")
	fake_plugin.free()
	registry._session_stopped(0)
	registry._session_stopped(1)
	_check(registry.resolve_session({}).session == null, "no running instance permits explicit editor fallback")
	print("MULTI SESSION: %d checks, %d failures" % [_checks, _failures])
	while EditorInterface.get_resource_filesystem().is_scanning():
		await process_frame
	quit(1 if _failures else 0)


func _complete_route(router: MCPCommandRouter, id: int, completions: Dictionary) -> void:
	completions[id] = await router.handle_command("find_nodes", {"session_id": id})


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("ok %d - %s" % [_checks, label])
	else:
		_failures += 1
		printerr("FAIL %d - %s" % [_checks, label])
