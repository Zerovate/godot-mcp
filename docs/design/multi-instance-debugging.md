# Multi-instance debugging

An MCP client can target separate game processes attached to one Godot editor. The editor addon still accepts one MCP connection. Runtime calls choose a game with `session_id`; they do not change a global selection.

## Contract

- `godot_editor_read list_instances` returns the connected instances and their readiness, scene and process IDs.
- `godot_editor_edit run instances=2 frozen=true` starts a fresh pair. An existing active game makes `run` fail, so it cannot restart another test implicitly.
- `godot_editor_edit launch` appends one instance. It accepts game arguments after `--` and requires an existing ready instance to discover the actual debugger endpoint.
- Runtime tools accept `session_id`. A single active instance remains the default. Multiple active instances without a target produce an ambiguity error. An invalid target never falls back to another instance or the editor scene.
- `godot_editor_edit stop session_id=N` stops one instance. `stop_all` explicitly stops the complete run. After a two-second graceful exit window, a still-active ready session can be killed by its reported PID; `forced` lists those instance IDs. Unknown PIDs are never guessed.

Instance IDs are allocated for each new run within the editor lifetime. Reusing a Godot debugger slot does not reuse the exposed ID. List instances again after restarting the editor.

## Chosen structure

The debugger plugin owns a registry of game-session objects. Each object owns one Godot debugger session, readiness, pending replies and signals. Each tool call creates its own command handler bound to the resolved game session, so handler-local result buffers cannot cross between games.

Calls to different games may overlap. Overlapping calls to the same game fail with a busy error. If a call times out, its outstanding reply remains tracked until it arrives or that session stops; a later call cannot consume an old response. Targeted stop remains available to end a stuck instance.

The alternative design passed a request context and correlation envelope through every editor and game handler. It would permit finer concurrency within a game, but required changing every existing wire message. The selected design isolates the game state with a smaller migration. It incorporates fresh session objects on slot reuse and explicit target binding from that alternative.

The lifecycle implementation starts the first game through Godot's editor API. Additional games attach to the actual debugger URI reported by the first game, including any port fallback chosen by Godot. Setting editor project metadata alone cannot change the open Run Instances dialog's cached configuration.

Godot consumes `--remote-debug` before exposing `OS.get_cmdline_args()`. The first game reads its original process arguments through Windows PowerShell/CIM, Linux `/proc/self/cmdline`, or macOS `ps`. Additional games inherit the known URI in a temporary environment variable. Only the Windows path has been exercised against a live editor. A missing URI produces `DEBUG_ENDPOINT_UNAVAILABLE`, rather than guessing the configured port.

If the first game never announces readiness, the run fails and reclaims its editor-managed process, provided no unrelated session needs preservation. Normal targeted stop never uses the editor's stop-all API.

## Verification

Check the schema and forwarding contracts with the server test suite, then build and run the protocol checks. The addon session test covers interleaved replies, stopped instances, reused slots, busy admission and late responses.

For live verification, use native MCP tools:

1. Run two instances frozen and record their IDs and process IDs.
2. Write a distinct temporary marker into each game's exec holder. Read both back.
3. Inject an input while stepping the first game. Confirm only its game state changed.
4. Capture each game separately.
5. Verify an omitted target is rejected while both games are active.
6. Stop the first game, confirm the second remains usable, and confirm the stopped ID is rejected.
7. Launch another instance with distinct game arguments. Confirm a new ID, the actual arguments and independent state.
8. Stop all games and verify the instance list is empty.

This procedure tests independent runtime routing. Networked games can still affect each other through their own network protocol; pausing one peer may cause a timeout in another peer's game logic.

The executable integration check is `node scripts/multi-instance-live-smoke.mjs`, run from `server/` after building and opening the editor with the matching addon. Disconnect other MCP clients first. It launches and stops games, including a deliberately hung exec to exercise targeted recovery. `MCP_TEST_ARTIFACTS` selects the evidence directory; optional `MCP_TEST_FAILED_SCENE` selects a deliberately blocked startup scene for failure recovery. It is a test client, not an alternate control interface.

On Windows with Godot 4.7.2 custom build, the live check passed 26 assertions, including input isolation, separate screenshots, concurrent routing, first-instance stop, append arguments, forced recovery, and failed-start cleanup. A separate run reserved port 6007 and verified four game processes all attached to Godot's actual fallback at 6008. The server suite passed 695 tests (7 skipped); protocol checks, 58 session-isolation assertions, 9 argument parser cases and the real-child-process stop test passed.
