// Integration test against an open editor with the matching addon installed.
// Build first. This launches and stops games in the connected editor.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const artifacts = resolve(process.env.MCP_TEST_ARTIFACTS ?? 'artifacts/multi-instance-live');
await mkdir(artifacts, { recursive: true });
const client = new Client({ name: 'multi-instance-live-smoke', version: '1' });
const evidence = [];
let checks = 0;
function check(label, value) {
  assert.ok(value, label);
  console.log(`PASS ${++checks}: ${label}`);
}
async function call(name, args, expectedError) {
  const result = await client.callTool({ name, arguments: args }, undefined, { timeout: 60000 });
  const texts = result.content.filter(x => x.type === 'text').map(x => x.text).join('\n');
  evidence.push({ name, args, result: { ...result, content: result.content.map(x => x.type === 'image' ? { type: 'image', mimeType: x.mimeType, bytes: x.data.length } : x) } });
  if (expectedError) {
    check(expectedError, result.isError && texts.includes(expectedError));
    return;
  }
  assert.ok(!result.isError, `${name}: ${texts}`);
  for (const img of result.content.filter(x => x.type === 'image')) {
    await writeFile(resolve(artifacts, `session-${args.session_id}.png`), Buffer.from(img.data, 'base64'));
  }
  if (result.structuredContent) return result.structuredContent;
  try { return JSON.parse(texts); } catch { return texts; }
}
const edit = (action, args = {}, error) => call('godot_editor_edit', { action, ...args }, error);
const read = (action, args = {}) => call('godot_editor_read', { action, ...args });
const exec = (session_id, source) => call('godot_exec', { action: 'run', session_id, source });
try {
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [resolve('dist/cli.js')], stderr: 'inherit' }));
  await new Promise(r => setTimeout(r, 1500));
  await edit('stop_all');
  const run = await edit('run', { instances: 2, frozen: true });
  check('two ready game processes', run.instances.length === 2 && run.instances.every(x => x.ready));
  const [a, b] = run.instances.map(x => x.session_id);
  check('distinct PIDs and IDs', a !== b && run.instances[0].process_id !== run.instances[1].process_id);
  for (const id of [a, b]) {
    const status = await call('godot_game_time', { action: 'status', session_id: id });
    check(`instance ${id} frozen from launch`, status.frozen && status.launched_frozen);
    await exec(id, `holder.set_meta("identity", ${id})\nroot.title = "MCP instance ${id}"\nreturn holder.get_meta("identity")`);
    await exec(id, `var script = GDScript.new()
script.source_code = "extends Node\nvar presses = 0\nfunc _input(event):\n\tif event is InputEventKey and event.pressed and event.keycode == KEY_F6:\n\t\tpresses += 1\n"
if script.reload() != OK: return false
var probe = Node.new()
probe.name = "InputProbe"
probe.set_script(script)
holder.add_child(probe)
var label = Label.new()
label.text = "MCP instance ${id}"
label.position = Vector2(400, 5)
label.add_theme_color_override("font_color", Color.YELLOW)
root.add_child(label)
return true`);
  }
  await call('godot_exec', { action: 'run', source: 'return 0' }, 'AMBIGUOUS_SESSION');
  await edit('stop', {}, 'AMBIGUOUS_SESSION');
  const parallel = await Promise.all([exec(a, 'return holder.get_meta("identity")'), exec(b, 'return holder.get_meta("identity")')]);
  check('parallel exec results stay with their target', parallel[0].result === a && parallel[1].result === b);
  await call('godot_game_time', { action: 'step', session_id: a, duration_ms: 100, inputs: [{ key: 'f6', start_ms: 0, duration_ms: 40 }] });
  const inputCounts = await Promise.all([exec(a, 'return holder.get_node("InputProbe").presses'), exec(b, 'return holder.get_node("InputProbe").presses')]);
  check('key input reaches only the target process', inputCounts[0].result === 1 && inputCounts[1].result === 0);
  const stepping = call('godot_game_time', { action: 'step', session_id: a, duration_ms: 1800 });
  await new Promise(r => setTimeout(r, 200));
  await call('godot_exec', { action: 'run', session_id: a, source: 'return 0' }, 'SESSION_BUSY');
  check('other instance responds during a step', (await exec(b, 'return holder.get_meta("identity")')).result === b);
  await stepping;
  for (const id of [a, b]) await read('screenshot_game', { session_id: id, max_width: 640 });
  await edit('stop', { session_id: a });
  check('stopping first game preserves second', (await read('list_instances')).instances.map(x => x.session_id).join() === String(b));
  await call('godot_exec', { action: 'run', session_id: a, source: 'return 0' }, 'NO_SESSION');
  await edit('stop', { session_id: a }, 'NO_SESSION');
  check('second game still controllable', (await exec(b, 'return holder.get_meta("identity")')).result === b);
  const launch = await edit('launch', { frozen: true, args: ['--port=34567', '--agent-instance=third'] });
  const c = launch.instance.session_id;
  check('new launch gets a fresh ID', c !== a && c !== b);
  check('launch arguments arrive intact', (await exec(c, 'return JSON.stringify(OS.get_cmdline_user_args())')).result === JSON.stringify(['--port=34567', '--agent-instance=third']));
  check('append preserves existing game', (await exec(b, 'return holder.get_meta("identity")')).result === b);
  const hungCall = call('godot_exec', { action: 'run', session_id: c, source: 'while true:\n\tpass' }, 'GAME_EXITED');
  await new Promise(r => setTimeout(r, 300));
  const recovered = await edit('stop', { session_id: c });
  await hungCall;
  check('hung game stopped by its PID', recovered.forced.includes(c));
  check('other game survives forced stop', (await exec(b, 'return holder.get_meta("identity")')).result === b);
  await edit('stop_all');
  check('all sessions removed', (await read('list_instances')).instances.length === 0);
  check('editor run state reset', !(await read('get_state')).is_playing);
  const rerun = await edit('run', { frozen: true });
  check('fresh run after stop_all', rerun.instances.length === 1 && rerun.instances[0].session_id > c);
  await edit('stop');
  if (process.env.MCP_TEST_FAILED_SCENE) {
    await edit('run', { scene_path: process.env.MCP_TEST_FAILED_SCENE }, 'BRIDGE_NOT_READY');
    check('failed first boot cleans up the editor', !(await read('get_state')).is_playing && (await read('list_instances')).instances.length === 0);
    check('can run after a failed first boot', (await edit('run', { frozen: true })).instances.length === 1);
    await edit('stop');
  }
  console.log(`Live multi-instance smoke: ${checks} checks passed`);
} finally {
  await writeFile(resolve(artifacts, 'evidence.json'), JSON.stringify(evidence, null, 2));
  try { await edit('stop_all'); } catch { /* Preserve the original test failure. */ }
  await client.close();
}
