@tool
class_name MCPBaseCommand
extends RefCounted

var _plugin: EditorPlugin
var _game_session: MCPGameSession


func setup(plugin: EditorPlugin, session: MCPGameSession = null) -> void:
	_plugin = plugin
	_game_session = session


func _get_debugger_plugin() -> MCPGameSession:
	return _game_session


func _has_game_session() -> bool:
	return _game_session != null and _game_session.has_active_session()


func get_commands() -> Dictionary:
	return {}


func _success(result: Dictionary) -> Dictionary:
	return MCPUtils.success(result)


func _error(code: String, message: String) -> Dictionary:
	return MCPUtils.error(code, message)


func _get_node(path: String) -> Node:
	return MCPUtils.get_node_from_path(path)


func _serialize_value(value: Variant) -> Variant:
	return MCPUtils.serialize_value(value)


func _require_scene_open() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return _error("NO_SCENE", "No scene is currently open")
	return {}
