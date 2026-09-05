@tool
extends RefCounted
class_name MCPCommandRouter

var _commands: Dictionary = {}
var _plugin: EditorPlugin

const RUNTIME_COMMANDS := [
	"capture_game_screenshot", "find_nodes", "get_input_map", "execute_input_sequence", "type_text",
	"get_performance_metrics", "start_profiler", "stop_profiler", "get_profiler_data",
	"get_active_processes", "get_signal_connections", "get_runtime_state",
	"watch_start", "watch_collect", "watch_stop", "validate_meshes",
	"game_time_freeze", "game_time_step", "game_time_step_until", "game_time_thaw", "game_time_status",
	"exec_run", "exec_list", "exec_remove", "exec_clear",
]
const EDITOR_FALLBACK_COMMANDS := ["find_nodes", "get_input_map"]


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_register_handler(MCPSystemCommands.new(), plugin)
	_register_handler(MCPSceneCommands.new(), plugin)
	_register_handler(MCPNodeCommands.new(), plugin)
	_register_handler(MCPSelectionCommands.new(), plugin)
	_register_handler(MCPProjectCommands.new(), plugin)
	_register_handler(MCPDebugCommands.new(), plugin)
	_register_handler(MCPScreenshotCommands.new(), plugin)
	_register_handler(MCPAnimationCommands.new(), plugin)
	_register_handler(MCPTilemapCommands.new(), plugin)
	_register_handler(MCPResourceCommands.new(), plugin)
	_register_handler(MCPScene3DCommands.new(), plugin)
	_register_handler(MCPInputCommands.new(), plugin)
	_register_handler(MCPProfilerCommands.new(), plugin)
	_register_handler(MCPRuntimeStateCommands.new(), plugin)
	_register_handler(MCPGameTimeCommands.new(), plugin)
	_register_handler(MCPExecCommands.new(), plugin)
	_register_handler(MCPMeshCommands.new(), plugin)


func _register_handler(handler: MCPBaseCommand, plugin: EditorPlugin) -> void:
	handler.setup(plugin)
	var cmds := handler.get_commands()
	for cmd_name in cmds:
		_commands[cmd_name] = {"script": handler.get_script(), "method": (cmds[cmd_name] as Callable).get_method()}


func handle_command(command: String, params: Dictionary):
	if not _commands.has(command):
		return MCPUtils.error("UNKNOWN_COMMAND", "Unknown command: %s" % command)

	var session: MCPGameSession = null
	if command in RUNTIME_COMMANDS:
		var resolved: Dictionary = _plugin.get_debugger_plugin().resolve_session(params)
		if resolved.has("error"):
			return resolved
		session = resolved["session"]
		if session == null and command not in EDITOR_FALLBACK_COMMANDS:
			return MCPUtils.error("NOT_RUNNING", "No game instance is running")
		if session != null and not session.acquire():
			return MCPUtils.error("SESSION_BUSY", "Game instance %d still has a command in flight. Wait for it to finish or stop this instance." % session.session_id)

	var registration: Dictionary = _commands[command]
	var handler: MCPBaseCommand = registration["script"].new()
	handler.setup(_plugin, session)
	var result = await handler.call(registration["method"], params)
	if session != null:
		session.release()
	return result
