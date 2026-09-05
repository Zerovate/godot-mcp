# Profiler Tools

Performance profiling: snapshots, per-frame time series with spike detection, active process inspection, signal connections

## Tools

- [godot_profiler](#godot_profiler)

---

## godot_profiler

Profile a running game; every action errors if no game is playing. Use snapshot for one-shot engine metrics, or start → get_data for a per-frame time series with percentile stats, frame-budget usage, spike detection, and monitor trends. get_active_processes lists scripts with live _process/_physics_process callbacks across the whole tree, tagged scene/autoload/exec (useful for finding per-frame cost sources); get_signal_connections maps signal wiring, including an autoload's outgoing connections. get_data's per-frame detail is a ring of the last 300 frames; its run block covers the whole profile. For observing game state rather than performance, use godot_runtime_state.

### Actions

#### `snapshot`

Full performance snapshot (all engine metrics)

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_id` | integer | No | Target instance session_id from godot_editor_read list_instances. This ID is distinct from the debugger slot and is never reassigned within an editor lifetime. May be omitted when only one game is running. Multiple games require an explicit ID; a stopped ID never selects another game. Run operations on the same instance sequentially; a busy instance rejects overlapping requests. Different instances can run concurrently. |

#### `start`

Start per-frame time-series profiling

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_id` | integer | No | Target instance session_id from godot_editor_read list_instances. This ID is distinct from the debugger slot and is never reassigned within an editor lifetime. May be omitted when only one game is running. Multiple games require an explicit ID; a stopped ID never selects another game. Run operations on the same instance sequentially; a busy instance rejects overlapping requests. Different instances can run concurrently. |

#### `stop`

Stop time-series profiling

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_id` | integer | No | Target instance session_id from godot_editor_read list_instances. This ID is distinct from the debugger slot and is never reassigned within an editor lifetime. May be omitted when only one game is running. Multiple games require an explicit ID; a stopped ID never selects another game. Run operations on the same instance sequentially; a busy instance rejects overlapping requests. Different instances can run concurrently. |

#### `get_data`

Get collected time-series data with spike detection. Per-frame detail (percentiles, spikes, monitor trends) covers a ring buffer of the LAST 300 frames only — the `window` field says how much of the run that is; `run` carries whole-run aggregates (frames, duration, avg/max, frames over budget, a frame-time histogram) so a ten-second profile can still answer "did anything spike".

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_id` | integer | No | Target instance session_id from godot_editor_read list_instances. This ID is distinct from the debugger slot and is never reassigned within an editor lifetime. May be omitted when only one game is running. Multiple games require an explicit ID; a stopped ID never selects another game. Run operations on the same instance sequentially; a busy instance rejects overlapping requests. Different instances can run concurrently. |

#### `get_active_processes`

List scripts with live _process/_physics_process callbacks across the whole tree — scene, autoloads, and nodes attached by godot_exec — tagged by location.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_id` | integer | No | Target instance session_id from godot_editor_read list_instances. This ID is distinct from the debugger slot and is never reassigned within an editor lifetime. May be omitted when only one game is running. Multiple games require an explicit ID; a stopped ID never selects another game. Run operations on the same instance sequentially; a busy instance rejects overlapping requests. Different instances can run concurrently. |

#### `get_signal_connections`

Inspect signal connections

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_id` | integer | No | Target instance session_id from godot_editor_read list_instances. This ID is distinct from the debugger slot and is never reassigned within an editor lifetime. May be omitted when only one game is running. Multiple games require an explicit ID; a stopped ID never selects another game. Run operations on the same instance sequentially; a busy instance rejects overlapping requests. Different instances can run concurrently. |
| `node_path` | string | No | Node to walk from (default: the whole tree — scene, autoloads and exec-attached nodes). An absolute /root/... path may name an autoload. |

### Examples

```json
// snapshot
{
  "action": "snapshot"
}
```

```json
// start
{
  "action": "start"
}
```

```json
// stop
{
  "action": "stop"
}
```

*3 more actions available: `get_data`, `get_active_processes`, `get_signal_connections`*

---

