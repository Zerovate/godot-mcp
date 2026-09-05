import { describe, it, expect } from 'vitest';
import type { z } from 'zod';
import type { AnyToolDefinition, ToolDefinition } from '../../core/types.js';
import { exec } from '../../tools/exec.js';
import { gameTime } from '../../tools/game-time.js';
import { input } from '../../tools/input.js';
import { profiler } from '../../tools/profiler.js';
import { runtimeState } from '../../tools/runtime-state.js';
import { validateMeshes } from '../../tools/validate-meshes.js';
import { nodeRead } from '../../tools/node.js';
import { editorRead, editorEdit } from '../../tools/editor.js';
import { createMockGodot, createToolContext, structuredOf } from '../helpers/mock-godot.js';

function validatedTool<TSchema extends z.ZodType>(tool: ToolDefinition<TSchema>): AnyToolDefinition {
  return { ...tool, execute: (args, ctx) => tool.execute(tool.schema.parse(args), ctx) };
}

const cases: Array<{ tool: AnyToolDefinition; args: Record<string, unknown>; command: string }> = [
  { tool: validatedTool(exec), args: { action: 'run', source: 'return 1' }, command: 'exec_run' },
  { tool: validatedTool(exec), args: { action: 'list' }, command: 'exec_list' },
  { tool: validatedTool(exec), args: { action: 'remove', name: 'probe' }, command: 'exec_remove' },
  { tool: validatedTool(exec), args: { action: 'clear' }, command: 'exec_clear' },
  { tool: validatedTool(gameTime), args: { action: 'freeze' }, command: 'game_time_freeze' },
  { tool: validatedTool(gameTime), args: { action: 'step', frames: 1 }, command: 'game_time_step' },
  { tool: validatedTool(gameTime), args: { action: 'step_until', until: 'true' }, command: 'game_time_step_until' },
  { tool: validatedTool(gameTime), args: { action: 'thaw' }, command: 'game_time_thaw' },
  { tool: validatedTool(gameTime), args: { action: 'status' }, command: 'game_time_status' },
  { tool: validatedTool(input), args: { action: 'get_map' }, command: 'get_input_map' },
  { tool: validatedTool(input), args: { action: 'sequence', inputs: [{ key: 'a' }] }, command: 'execute_input_sequence' },
  { tool: validatedTool(input), args: { action: 'type_text', text: 'hello' }, command: 'type_text' },
  { tool: validatedTool(profiler), args: { action: 'snapshot' }, command: 'get_performance_metrics' },
  { tool: validatedTool(profiler), args: { action: 'start' }, command: 'start_profiler' },
  { tool: validatedTool(profiler), args: { action: 'stop' }, command: 'stop_profiler' },
  { tool: validatedTool(profiler), args: { action: 'get_data' }, command: 'get_profiler_data' },
  { tool: validatedTool(profiler), args: { action: 'get_active_processes' }, command: 'get_active_processes' },
  { tool: validatedTool(profiler), args: { action: 'get_signal_connections' }, command: 'get_signal_connections' },
  { tool: validatedTool(runtimeState), args: { action: 'digest' }, command: 'get_runtime_state' },
  { tool: validatedTool(runtimeState), args: { action: 'watch_start', specs: [{ path: '/root/Main', fields: ['health'] }] }, command: 'watch_start' },
  { tool: validatedTool(runtimeState), args: { action: 'watch_collect' }, command: 'watch_collect' },
  { tool: validatedTool(runtimeState), args: { action: 'watch_stop' }, command: 'watch_stop' },
  { tool: validatedTool(validateMeshes), args: {}, command: 'validate_meshes' },
  { tool: validatedTool(nodeRead), args: { action: 'find', name_pattern: '*' }, command: 'find_nodes' },
  { tool: validatedTool(editorRead), args: { action: 'screenshot_game' }, command: 'capture_game_screenshot' },
  { tool: validatedTool(editorEdit), args: { action: 'stop' }, command: 'stop_project' },
];

describe('runtime instance targeting', () => {
  it.each(cases)('$command preserves the target through validation and forwarding', async ({ tool, args, command }) => {
    const mock = createMockGodot();
    const request = tool.schema.parse({ ...args, session_id: 17 });
    const responseFailure = new Error('Target response rejected');
    mock.mockError(responseFailure);
    await expect(tool.execute(request, createToolContext(mock))).rejects.toBe(responseFailure);
    expect(mock.calls).toHaveLength(1);
    expect(mock.calls[0].command).toBe(command);
    expect(mock.calls[0].params.session_id).toBe(17);
  });

  it.each(cases)('$command validates target IDs and preserves omission', ({ tool, args }) => {
    expect(tool.schema.safeParse(args).success).toBe(true);
    expect(tool.schema.safeParse({ ...args, session_id: 0 }).success).toBe(true);
    for (const session_id of [-1, 1.5, '1', null, Infinity]) {
      expect(tool.schema.safeParse({ ...args, session_id }).success).toBe(false);
    }
  });

  it('keeps overlapping exec requests attached to their own target', async () => {
    const mock = createMockGodot();
    const pending = new Map<number, (result: unknown) => void>();
    mock.sendCommand.mockImplementation((_command: string, params: { session_id: number }) =>
      new Promise((resolve) => pending.set(params.session_id, resolve))
    );
    const ctx = createToolContext(mock);
    const first = exec.execute({ action: 'run', session_id: 4, source: 'return 4' }, ctx);
    const second = exec.execute({ action: 'run', session_id: 8, source: 'return 8' }, ctx);
    const completeSecond = pending.get(8);
    if (!completeSecond) throw new Error('Second request did not reach its target');
    completeSecond({ completed: true, result: 8, duration_ms: 1, holder_children: 0 });
    expect(structuredOf(await second).result).toBe(8);
    const completeFirst = pending.get(4);
    if (!completeFirst) throw new Error('First request did not reach its target');
    completeFirst({ completed: true, result: 4, duration_ms: 1, holder_children: 0 });
    expect(structuredOf(await first).result).toBe(4);
  });

  it('returns instance inventory without dropping lifecycle fields', async () => {
    const mock = createMockGodot();
    const inventory = { instances: [{ session_id: 9, debugger_session_id: 0, process_id: 123, scene_path: 'res://main.tscn', ready: true }] };
    mock.mockResponse(inventory);
    expect(structuredOf(await editorRead.execute({ action: 'list_instances' }, createToolContext(mock)))).toEqual(inventory);
    expect(mock.calls[0].command).toBe('list_instances');
  });

  it('launches with exact user arguments and stops all only on explicit action', async () => {
    const mock = createMockGodot();
    const ctx = createToolContext(mock);
    const args = ['--role=client', '--port=7002', 'name with spaces'];
    mock.mockResponse({ session_id: 2 });
    await editorEdit.execute({ action: 'launch', frozen: true, scene_path: 'res://client.tscn', args }, ctx);
    expect(mock.calls[0]).toMatchObject({ command: 'launch_instance', params: { args, frozen: true, scene_path: 'res://client.tscn' } });
    mock.mockResponse({ stopped: [1, 2] });
    expect(structuredOf(await editorEdit.execute({ action: 'stop_all' }, ctx))).toEqual({ stopped: [1, 2] });
    expect(mock.calls[1].command).toBe('stop_all_instances');
  });

  it('bounds fresh runs and validates argument arrays', () => {
    for (const instances of [0, 5, 1.5]) {
      expect(editorEdit.schema.safeParse({ action: 'run', instances }).success).toBe(false);
    }
    expect(editorEdit.schema.safeParse({ action: 'run', instances: 4 }).success).toBe(true);
    expect(editorEdit.schema.safeParse({ action: 'launch', args: ['--client'] }).success).toBe(true);
    expect(editorEdit.schema.safeParse({ action: 'launch', args: '--client' }).success).toBe(false);
  });
});
