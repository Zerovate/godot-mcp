@tool
extends EditorDebuggerPlugin
class_name MCPDebuggerPlugin

var _sessions: Dictionary = {}
var _slots: Dictionary = {}
var _next_instance_id := 0
var lifecycle_busy := false


func _has_capture(prefix: String) -> bool:
	return prefix == "godot_mcp"


func _capture(message: String, data: Array, slot_id: int) -> bool:
	var session: MCPGameSession = _slots.get(slot_id)
	return session.capture(message, data) if session != null else false


func _setup_session(slot_id: int) -> void:
	var transport := get_session(slot_id)
	if transport == null:
		return
	transport.started.connect(_session_started.bind(slot_id))
	transport.stopped.connect(_session_stopped.bind(slot_id))
	if transport.is_active():
		_session_started(slot_id)


func _session_started(slot_id: int) -> void:
	_register_session(slot_id, get_session(slot_id))


func _register_session(slot_id: int, transport: Object) -> MCPGameSession:
	_session_stopped(slot_id)
	var session := MCPGameSession.new(_next_instance_id, slot_id, transport)
	_next_instance_id += 1
	_sessions[session.session_id] = session
	_slots[slot_id] = session
	return session


func _session_stopped(slot_id: int) -> void:
	var session: MCPGameSession = _slots.get(slot_id)
	if session != null:
		session.stop()
		_sessions.erase(session.session_id)
		_slots.erase(slot_id)


func get_instance(instance_id: int) -> MCPGameSession:
	var session: MCPGameSession = _sessions.get(instance_id)
	return session if session != null and session.has_active_session() else null


func list_instances() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for session: MCPGameSession in _sessions.values():
		if session.has_active_session():
			result.append(session.describe())
	return result


func resolve_session(params: Dictionary) -> Dictionary:
	if params.has("session_id"):
		var id = params["session_id"]
		if not (id is int or id is float) or float(id) != floor(float(id)) or id < 0:
			return MCPUtils.error("INVALID_PARAMS", "session_id must be a nonnegative integer")
		var session := get_instance(int(id))
		if session == null:
			return MCPUtils.error("NO_SESSION", "No active game instance has session_id %s. List instances to select a current ID." % id)
		return {"session": session}
	var instances := list_instances()
	if instances.size() > 1:
		return MCPUtils.error("AMBIGUOUS_SESSION", "Multiple game instances are running. Pass session_id from list_instances.")
	return {"session": get_instance(instances[0]["session_id"]) if instances.size() == 1 else null}
