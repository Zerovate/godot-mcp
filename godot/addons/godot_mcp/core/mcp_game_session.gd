@tool
extends RefCounted
class_name MCPGameSession

signal screenshot_received(success: bool, image_base64: String, width: int, height: int, error: String)
signal performance_metrics_received(metrics: Dictionary)
signal find_nodes_received(matches: Array, count: int, error: String)
signal input_map_received(actions: Array, error: String)
signal input_sequence_completed(result: Dictionary)
signal sequence_capture_received(requested_ms: int, actual_ms: int, ok: bool, image_base64: String, width: int, height: int, error: String)
signal type_text_completed(result: Dictionary)
signal bridge_ready()

var session_id: int
var debugger_session_id: int
var debugger_session: Object
var scene_path := ""
var process_id := 0
var metadata: Dictionary = {}
var _active := true
var _command_in_progress := false
var _call_sequence := 0


# True once the running game's bridge has announced it is ready to receive input
# (its main scene is up). The debug session connects before the scene loads, so
# has_active_session() alone is not enough to know input will land (#241).
var _bridge_ready: bool = false
var _pending_screenshot: bool = false
# Mesh-integrity warnings that rode along with the last screenshot result
# (element 6 of screenshot_result; empty for bridges that predate it). Held
# here instead of widening the screenshot_received signal signature.
var last_screenshot_warnings: Array = []
var _pending_performance_metrics: bool = false
var _pending_find_nodes: bool = false
var _pending_input_map: bool = false
var _pending_input_sequence: bool = false
var _pending_type_text: bool = false
var _pending_requests: Dictionary = {}
var _responses: Dictionary = {}

func _init(instance_id: int, slot_id: int, transport: Object) -> void:
	session_id = instance_id
	debugger_session_id = slot_id
	debugger_session = transport


func next_call_id() -> int:
	_call_sequence += 1
	return _call_sequence


func acquire() -> bool:
	if not has_active_session() or is_busy():
		return false
	_command_in_progress = true
	return true


func release() -> void:
	_command_in_progress = false
	_responses.clear()


func is_busy() -> bool:
	return _command_in_progress or not _pending_requests.is_empty() or _pending_screenshot or _pending_performance_metrics or _pending_find_nodes or _pending_input_map or _pending_input_sequence or _pending_type_text


func describe() -> Dictionary:
	var result := metadata.duplicate()
	result.merge({"session_id": session_id, "debugger_session_id": debugger_session_id,
		"ready": is_bridge_ready(), "busy": is_busy(), "scene_path": scene_path,
		"process_id": process_id}, true)
	return result


func capture(message: String, data: Array) -> bool:
	if not _active:
		return false
	match message:
		"godot_mcp:screenshot_result":
			_handle_screenshot_result(data)
			return true
		"godot_mcp:performance_metrics_result":
			_handle_performance_metrics_result(data)
			return true
		"godot_mcp:find_nodes_result":
			_handle_find_nodes_result(data)
			return true
		"godot_mcp:input_map_result":
			_handle_input_map_result(data)
			return true
		"godot_mcp:input_sequence_result":
			_handle_input_sequence_result(data)
			return true
		"godot_mcp:sequence_capture":
			_handle_sequence_capture(data)
			return true
		"godot_mcp:type_text_result":
			_handle_type_text_result(data)
			return true
		"godot_mcp:game_response":
			_handle_game_response(data)
			return true
		"godot_mcp:bridge_ready":
			_handle_bridge_ready(data)
			return true
	return false


func _handle_bridge_ready(data: Array) -> void:
	scene_path = str(data[0]) if not data.is_empty() else ""
	metadata = data[1].duplicate() if data.size() > 1 and data[1] is Dictionary else {}
	process_id = int(metadata.get("process_id", 0))
	_bridge_ready = true
	bridge_ready.emit()


func stop() -> void:
	_active = false
	_command_in_progress = false
	_bridge_ready = false
	if _pending_screenshot:
		_pending_screenshot = false
		screenshot_received.emit(false, "", 0, 0, "Game session ended")
	if _pending_performance_metrics:
		_pending_performance_metrics = false
		performance_metrics_received.emit({})
	if _pending_find_nodes:
		_pending_find_nodes = false
		find_nodes_received.emit([], 0, "Game session ended")
	if _pending_input_map:
		_pending_input_map = false
		input_map_received.emit([], "Game session ended")
	if _pending_input_sequence:
		_pending_input_sequence = false
		input_sequence_completed.emit({"error": "Game session ended"})
	if _pending_type_text:
		_pending_type_text = false
		type_text_completed.emit({"error": "Game session ended"})
	# Drop pending relays rather than answering them with an empty dictionary,
	# which callers would have read as a successful (empty) response. The relay
	# loops notice has_active_session() going false and report GAME_EXITED.
	for msg_type in _pending_requests:
		_responses.erase(msg_type)
	_pending_requests.clear()


func has_active_session() -> bool:
	return _active and debugger_session != null and debugger_session.is_active()


# True only once the running game's bridge has reported its main scene is up and
# can consume input. Input commands gate on this (not just has_active_session) so
# a sequence injected right after run is not dispatched into a half-booted game.
func is_bridge_ready() -> bool:
	return _bridge_ready and has_active_session()


func request_screenshot(max_width: int = 1024) -> void:
	if not has_active_session():
		screenshot_received.emit(false, "", 0, 0, "No active game session")
		return
	_pending_screenshot = true
	var session := debugger_session
	if session:
		session.send_message("godot_mcp:take_screenshot", [max_width])
	else:
		_pending_screenshot = false
		screenshot_received.emit(false, "", 0, 0, "Could not get debugger session")


func _handle_screenshot_result(data: Array) -> void:
	if not _pending_screenshot:
		return
	_pending_screenshot = false
	if not _command_in_progress:
		return
	if data.size() < 5:
		screenshot_received.emit(false, "", 0, 0, "Invalid response data")
		return
	var success: bool = data[0]
	var image_base64: String = data[1]
	var width: int = data[2]
	var height: int = data[3]
	var error: String = data[4]
	last_screenshot_warnings = data[5] if data.size() > 5 and data[5] is Array else []
	screenshot_received.emit(success, image_base64, width, height, error)


func request_performance_metrics() -> void:
	if not has_active_session():
		performance_metrics_received.emit({})
		return
	_pending_performance_metrics = true
	var session := debugger_session
	if session:
		session.send_message("godot_mcp:get_performance_metrics", [])
	else:
		_pending_performance_metrics = false
		performance_metrics_received.emit({})


func _handle_performance_metrics_result(data: Array) -> void:
	if not _pending_performance_metrics:
		return
	_pending_performance_metrics = false
	if not _command_in_progress:
		return
	var metrics: Dictionary = data[0] if data.size() > 0 else {}
	performance_metrics_received.emit(metrics)


func request_find_nodes(name_pattern: String, type_filter: String, root_path: String) -> void:
	if not has_active_session():
		find_nodes_received.emit([], 0, "No active game session")
		return
	_pending_find_nodes = true
	var session := debugger_session
	if session:
		session.send_message("godot_mcp:find_nodes", [name_pattern, type_filter, root_path])
	else:
		_pending_find_nodes = false
		find_nodes_received.emit([], 0, "Could not get debugger session")


func _handle_find_nodes_result(data: Array) -> void:
	if not _pending_find_nodes:
		return
	_pending_find_nodes = false
	if not _command_in_progress:
		return
	var matches: Array = data[0] if data.size() > 0 else []
	var count: int = data[1] if data.size() > 1 else 0
	var error: String = data[2] if data.size() > 2 else ""
	find_nodes_received.emit(matches, count, error)


func request_input_map() -> void:
	if not has_active_session():
		input_map_received.emit([], "No active game session")
		return
	_pending_input_map = true
	var session := debugger_session
	if session:
		session.send_message("godot_mcp:get_input_map", [])
	else:
		_pending_input_map = false
		input_map_received.emit([], "Could not get debugger session")


func _handle_input_map_result(data: Array) -> void:
	if not _pending_input_map:
		return
	_pending_input_map = false
	if not _command_in_progress:
		return
	var actions: Array = data[0] if data.size() > 0 else []
	var error: String = data[1] if data.size() > 1 else ""
	input_map_received.emit(actions, error)


func request_input_sequence(inputs: Array, report: Array = [], screenshots: Array = [], screenshot_max_width: int = 640) -> void:
	if not has_active_session():
		input_sequence_completed.emit({"error": "No active game session"})
		return
	_pending_input_sequence = true
	var session := debugger_session
	if session:
		session.send_message("godot_mcp:execute_input_sequence", [inputs, report, screenshots, screenshot_max_width])
	else:
		_pending_input_sequence = false
		input_sequence_completed.emit({"error": "Could not get debugger session"})


func _handle_input_sequence_result(data: Array) -> void:
	if not _pending_input_sequence:
		return
	_pending_input_sequence = false
	if not _command_in_progress:
		return
	var result: Dictionary = data[0] if data.size() > 0 else {}
	input_sequence_completed.emit(result)


# A mid-sequence frame capture (#239) arriving on its own message. Re-emitted for
# the editor command to collect; the final input_sequence_result follows once the
# bridge has sent every requested frame.
func _handle_sequence_capture(data: Array) -> void:
	if not _pending_input_sequence or not _command_in_progress:
		return
	var requested_ms: int = int(data[0]) if data.size() > 0 else 0
	var actual_ms: int = int(data[1]) if data.size() > 1 else 0
	var ok: bool = bool(data[2]) if data.size() > 2 else false
	var base64: String = String(data[3]) if data.size() > 3 else ""
	var width: int = int(data[4]) if data.size() > 4 else 0
	var height: int = int(data[5]) if data.size() > 5 else 0
	var error: String = String(data[6]) if data.size() > 6 else ""
	sequence_capture_received.emit(requested_ms, actual_ms, ok, base64, width, height, error)


func request_type_text(text: String, delay_ms: int, submit: bool) -> void:
	if not has_active_session():
		type_text_completed.emit({"error": "No active game session"})
		return
	_pending_type_text = true
	var session := debugger_session
	if session:
		session.send_message("godot_mcp:type_text", [text, delay_ms, submit])
	else:
		_pending_type_text = false
		type_text_completed.emit({"error": "Could not get debugger session"})


func _handle_type_text_result(data: Array) -> void:
	if not _pending_type_text:
		return
	_pending_type_text = false
	if not _command_in_progress:
		return
	var result: Dictionary = data[0] if data.size() > 0 else {}
	type_text_completed.emit(result)


func send_game_message(msg_type: String, args: Array = []) -> bool:
	if not has_active_session():
		return false
	var session := debugger_session
	if not session:
		return false
	var call_id := -1
	if not args.is_empty() and args[0] is Dictionary:
		call_id = int(args[0].get("call_id", -1))
	_pending_requests[msg_type] = call_id
	_responses.erase(msg_type)
	session.send_message("godot_mcp:" + msg_type, args)
	return true


func has_response(msg_type: String) -> bool:
	return _responses.has(msg_type)


func get_response(msg_type: String) -> Variant:
	return _responses.get(msg_type)


func clear_response(msg_type: String) -> void:
	# A relay timeout abandons the result, not the message already in flight.
	# Keep admission closed until that message replies or the process stops.
	_responses.erase(msg_type)


func _handle_game_response(data: Array) -> void:
	if data.size() < 2:
		return
	var msg_type: String = data[0]
	var response_data: Variant = data[1]
	if not _pending_requests.has(msg_type):
		return
	var expected_id: int = _pending_requests[msg_type]
	if expected_id >= 0 and response_data is Dictionary and response_data.has("call_id") and int(response_data["call_id"]) != expected_id:
		return
	_pending_requests.erase(msg_type)
	if _command_in_progress:
		_responses[msg_type] = response_data


func toggle_frame_profiler(enable: bool) -> void:
	if not has_active_session():
		return
	var session := debugger_session
	if session:
		session.toggle_profiler("mcp_frame_profiler", enable)


# True when the debugger has paused the running game (script error, failed
# assert, or breakpoint). A break suspends whatever bridge handler was running
# mid-call, so relays that would otherwise time out can detect and recover.
func is_session_breaked() -> bool:
	if not has_active_session():
		return false
	var session := debugger_session
	return session != null and session.is_breaked()


# Resume a debugger-paused game. EditorDebuggerSession exposes no continue API,
# but the raw "continue" command is the same wire message the editor's Continue
# button sends (ScriptEditorDebugger::_put_msg), and the game's RemoteDebugger
# handles it in its break loop. Returns false when there is nothing to resume.
func continue_session() -> bool:
	if not has_active_session():
		return false
	var session := debugger_session
	if session == null or not session.is_breaked():
		return false
	session.send_message("continue", [])
	return true
