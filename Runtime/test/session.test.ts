import assert from 'node:assert/strict';
import test from 'node:test';
import type { Model } from '@earendil-works/pi-ai';
import { createAgentSession, type SessionConfig, type SessionEvent, type SessionHost, type StoredMessage } from '../src/session.ts';

const model: Model<'openai-completions'> = {
  id: 'fixture', name: 'fixture', api: 'openai-completions', provider: 'openai',
  baseUrl: 'https://fixture.invalid/v1', reasoning: false, input: ['text'],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 256,
};
const config: SessionConfig = {
  conversationId: 'ledger-chat', systemPrompt: 'Propose an expense, never claim it is booked.',
  model, apiKey: 'fixture-key', tools: [{
    name: 'propose_expense', label: '记账卡片', description: 'Create a pending proposal',
    parameters: { type: 'object', properties: { amount: { type: 'string' } }, required: ['amount'], additionalProperties: false },
  }],
};
const input = { id: 'user-1', message: { role: 'user' as const, content: '晚饭 12.50', timestamp: 1 } };
const toolResult = { content: [{ type: 'text' as const, text: '{"proposalId":"p1","status":"pending_confirmation"}' }], details: { proposalId: 'p1' } };

function sse(deltas: unknown[], finish = 'stop') {
  const chunks = [...deltas.map(delta => ({ delta, finish_reason: null })), { delta: {}, finish_reason: finish }];
  const text = chunks.map(choice => `data: ${JSON.stringify({ id: 'response', choices: [{ index: 0, ...choice }] })}\n\n`).join('') + 'data: [DONE]\n\n';
  // Exercise UTF-8 decoding across byte boundaries in the real provider.
  const bytes = new TextEncoder().encode(text);
  return new Response(new ReadableStream({ start(controller) {
    for (const byte of bytes) controller.enqueue(new Uint8Array([byte]));
    controller.close();
  } }), { headers: { 'content-type': 'text/event-stream' } });
}
function proposal(withText = true) {
  return sse([
    ...(withText ? [{ content: '先生成卡片。' }] : []),
    { tool_calls: [{ index: 0, id: 'call-1', type: 'function', function: { name: 'propose_expense', arguments: '{"amount":' } }] },
    { tool_calls: [{ index: 0, function: { arguments: '"12.50"}' } }] },
  ], 'tool_calls');
}
function harness(fetch: SessionHost['fetch']) {
  const saved: StoredMessage[] = [];
  const events: SessionEvent[] = [];
  const calls: Parameters<SessionHost['executeTool']>[0][] = [];
  const host: SessionHost = {
    fetch,
    checkpoint: async (_identity, entry) => { saved.push(structuredClone(entry)); },
    executeTool: async call => { calls.push(call); return toolResult; },
    onEvent: event => { events.push(structuredClone(event)); },
  };
  return { host, saved, events, calls };
}

test('real pi provider completes tools, awaits checkpoints, preserves message boundaries and restores', async () => {
  let requests = 0;
  const h = harness(async (url, init) => {
    assert.equal(String(url), 'https://fixture.invalid/v1/chat/completions');
    assert.equal(new Headers(init?.headers).get('authorization'), 'Bearer fixture-key');
    const body = JSON.parse(String(init?.body));
    if (++requests === 1) return proposal();
    assert.ok(body.messages.some((m: { role: string; content: string }) => m.role === 'tool' && m.content.includes('pending_confirmation')));
    if (requests === 2) assert.equal(h.saved.at(-1)?.message.role, 'toolResult');
    return sse([{ content: '东京 東京，等待确认。' }]);
  });
  const execute = h.host.executeTool;
  h.host.executeTool = async (call, signal) => {
    assert.equal(h.saved.at(-1)?.message.role, 'assistant');
    assert.equal(h.saved.at(-1)?.id, call.messageId);
    assert.deepEqual(call.arguments, { amount: '12.50' });
    return execute(call, signal);
  };
  const checkpoint = h.host.checkpoint;
  h.host.checkpoint = async (identity, entry) => {
    await new Promise(resolve => setTimeout(resolve, 1));
    await checkpoint(identity, entry);
  };
  const session = createAgentSession(config, h.host);
  assert.deepEqual(await session.run('run-1', input), { status: 'complete' });
  assert.equal(h.calls.length, 1);
  assert.equal(requests, 2);
  assert.deepEqual(h.saved.map(e => e.message.role), ['user', 'assistant', 'toolResult', 'assistant']);
  const text = h.events.filter(e => e.type === 'text');
  assert.equal(new Set(text.map(e => e.messageId)).size, 2);
  assert.equal(text.map(e => e.delta).join(''), '先生成卡片。东京 東京，等待确认。');
  assert.equal(h.events.at(-1)?.type, 'settled');
  const snapshot = session.messages;
  snapshot.length = 0;
  assert.equal(session.messages.length, 4);

  const restored = createAgentSession({ ...config, history: h.saved.slice(0, 3) }, h.host);
  assert.deepEqual(await restored.run('restored'), { status: 'complete' });
  assert.equal(h.calls.length, 1, 'completed tool must not execute again');
});

test('checkpoint failure prevents side effects and emits failed rather than success/abort', async () => {
  const h = harness(async () => proposal());
  h.host.checkpoint = async (_identity, entry) => {
    if (entry.message.role === 'assistant') throw new Error('disk full');
  };
  const session = createAgentSession(config, h.host);
  assert.deepEqual(await session.run('run', input), { status: 'failed', error: 'disk full' });
  assert.equal(h.calls.length, 0);
  assert.equal(session.busy, false);
  assert.deepEqual(h.events.at(-1), {
    conversationId: config.conversationId, runId: 'run', type: 'settled', result: { status: 'failed', error: 'disk full' },
  });
});

test('HTTP failure is reported even when pi resolves its prompt; no automatic retries', async () => {
  let requests = 0;
  const h = harness(async () => {
    requests++;
    return new Response('{"error":{"message":"invalid credential"}}', { status: 401 });
  });
  const result = await createAgentSession(config, h.host).run('run', input);
  assert.equal(result.status, 'failed');
  assert.equal(requests, 1);
});

test('abort reaches fetch, rejects concurrent runs and suppresses late display events', async () => {
  let receivedSignal: AbortSignal | undefined;
  let started!: () => void;
  const waiting = new Promise<void>(resolve => { started = resolve; });
  const h = harness(async (_url, init) => {
    receivedSignal = init?.signal ?? undefined;
    started();
    return new Promise<Response>((_resolve, reject) => {
      receivedSignal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
    });
  });
  const session = createAgentSession(config, h.host);
  const running = session.run('run', input);
  await waiting;
  await assert.rejects(session.run('second', { ...input, id: 'user-2' }), /already running/);
  session.abort('stale-run');
  assert.equal(receivedSignal?.aborted, false);
  const eventCount = h.events.length;
  session.abort('run');
  assert.deepEqual(await running, { status: 'aborted' });
  assert.equal(receivedSignal?.aborted, true);
  assert.deepEqual(h.events.slice(eventCount).map(e => e.type), ['settled']);
  assert.equal(session.busy, false);
});

test('tool-only success is valid and tool errors are returned to the model', async () => {
  const h = harness(async () => proposal(false));
  h.host.executeTool = async () => ({ ...toolResult, terminate: true });
  assert.deepEqual(await createAgentSession(config, h.host).run('run', input), { status: 'complete' });
  assert.equal(h.saved.at(-1)?.message.role, 'toolResult');
  assert.equal(h.events.filter(e => e.type === 'text').length, 0);

  let requests = 0;
  h.host.fetch = async (_url, init) => {
    if (++requests === 1) return proposal();
    assert.ok(String(init?.body).includes('Unknown payer'));
    return sse([{ content: '请确认付款人。' }]);
  };
  h.host.executeTool = async () => { throw new Error('Unknown payer'); };
  assert.deepEqual(await createAgentSession(config, h.host).run('another', input), { status: 'complete' });
  assert.ok(h.events.some(e => e.type === 'tool_end' && e.isError));
});

test('tool result checkpoint failure blocks the follow-up model request', async () => {
  let requests = 0;
  const h = harness(async () => { requests++; return proposal(); });
  const checkpoint = h.host.checkpoint;
  h.host.checkpoint = async (identity, entry) => {
    if (entry.message.role === 'toolResult') throw new Error('checkpoint unavailable');
    await checkpoint(identity, entry);
  };
  assert.deepEqual(await createAgentSession(config, h.host).run('run', input), {
    status: 'failed', error: 'checkpoint unavailable',
  });
  assert.equal(h.calls.length, 1);
  assert.equal(requests, 1);
});

test('abort during streamed text reaches transport and persists the partial response', async () => {
  let cancelled = false;
  const h = harness(async (_url, init) => new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('data: {"id":"stream","choices":[{"index":0,"delta":{"content":"等待"},"finish_reason":null}]}\n\n'));
      init?.signal?.addEventListener('abort', () => {
        cancelled = true;
        controller.error(new DOMException('Aborted', 'AbortError'));
      }, { once: true });
    },
  }), { headers: { 'content-type': 'text/event-stream' } }));
  const session = createAgentSession(config, h.host);
  h.host.onEvent = event => {
    h.events.push(structuredClone(event));
    if (event.type === 'text') session.abort(event.runId);
  };
  assert.deepEqual(await session.run('run', input), { status: 'aborted' });
  assert.equal(cancelled, true);
  assert.equal(h.events.filter(e => e.type === 'text').map(e => e.delta).join(''), '等待');
  const last = h.saved.at(-1)?.message;
  assert.ok(last?.role === 'assistant' && last.stopReason === 'aborted');
  assert.ok(last.content.some(block => block.type === 'text' && block.text === '等待'));
});

test('Anthropic provider uses native fetch and preserves streamed Unicode', async () => {
  const h = harness(async (url, init) => {
    assert.equal(new URL(String(url)).origin, 'https://fixture.invalid');
    assert.equal(new URL(String(url)).pathname, '/v1/messages');
    assert.equal(new Headers(init?.headers).get('x-api-key'), config.apiKey);
    const events = [
      { type: 'message_start', message: { id: 'msg', type: 'message', role: 'assistant', model: 'fixture', content: [], stop_reason: null, usage: { input_tokens: 1, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
      { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '等待确认。' } },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 2 } },
      { type: 'message_stop' },
    ];
    return new Response(events.map(e => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(''), { headers: { 'content-type': 'text/event-stream' } });
  });
  const session = createAgentSession({ ...config, model: { ...model, api: 'anthropic-messages', provider: 'anthropic', baseUrl: 'https://fixture.invalid' } }, h.host);
  assert.deepEqual(await session.run('run', input), { status: 'complete' });
  assert.equal(h.events.filter(e => e.type === 'text').map(e => e.delta).join(''), '等待确认。');
});
