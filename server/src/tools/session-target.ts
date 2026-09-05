import { z } from 'zod';

export const sessionId = z.number().int().nonnegative().optional().describe(
  'Target instance session_id from godot_editor_read list_instances. This ID is distinct from the debugger slot and is never reassigned within an editor lifetime. May be omitted when only one game is running. Multiple games require an explicit ID; a stopped ID never selects another game. Run operations on the same instance sequentially; a busy instance rejects overlapping requests. Different instances can run concurrently.'
);
