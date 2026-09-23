import { native, clearTimers } from './globals.ts';
import 'formdata-polyfill/formdata.min.js';
import { createAgentSession, type SessionConfig } from './session.ts';
import { nativeFetch, cancelHTTP } from './nativeFetch.ts';
export { fireTimer } from './globals.ts';
export { receiveHTTP } from './nativeFetch.ts';

let nextId = 0;
let closed = false;
let session: ReturnType<typeof createAgentSession> | undefined;
const calls = new Map<number, { resolve(value: unknown): void; reject(error: Error): void; cleanup(): void }>();

function call(method: string, payload: unknown, signal?: AbortSignal): Promise<any> {
  if (closed || signal?.aborted) return Promise.reject(new Error('Runtime closed or cancelled'));
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    const abort = () => { native.nativeCancelCall(id); settle(id, false, JSON.stringify('Aborted')); };
    calls.set(id, { resolve, reject, cleanup: () => signal?.removeEventListener('abort', abort) });
    signal?.addEventListener('abort', abort, { once: true });
    native.nativeCall(id, method, JSON.stringify(payload));
  });
}

export function settle(id: number, success: boolean, json: string) {
  const pending = calls.get(id);
  if (!pending) return;
  calls.delete(id); pending.cleanup();
  try {
    const value = JSON.parse(json);
    if (success) pending.resolve(value); else pending.reject(new Error(String(value)));
  } catch { pending.reject(new Error('Invalid native response JSON')); }
}

export function configure(json: string) {
  if (session || closed) throw new Error('Runtime already configured or closed');
  const config: SessionConfig = JSON.parse(json);
  session = createAgentSession(config, {
    fetch: nativeFetch,
    checkpoint: (identity, entry) => call('checkpoint', { ...identity, entry }),
    executeTool: (tool, signal) => call('tool', tool, signal),
    onEvent: event => call('event', event),
  });
}

export function run(runId: string, inputJSON: string) {
  if (!session || closed) throw new Error('Runtime unavailable');
  session.run(runId, inputJSON ? JSON.parse(inputJSON) : undefined).then(
    result => native.nativeFinish(runId, JSON.stringify(result)),
    error => native.nativeFinish(runId, JSON.stringify({ status: 'failed', error: String(error) })),
  );
}
export function abort(runId: string) { session?.abort(runId); }
export function dispose() {
  closed = true;
  cancelHTTP(); clearTimers();
  for (const id of [...calls.keys()]) {
    native.nativeCancelCall(id); settle(id, false, JSON.stringify('Runtime closed'));
  }
  session = undefined;
}
