import { Agent, type AgentMessage, type AgentTool, type AgentToolResult } from '@earendil-works/pi-agent-core';
import type { Model, TSchema, UserMessage } from '@earendil-works/pi-ai';
import { streamSimple as anthropic } from '@earendil-works/pi-ai/api/anthropic-messages';
import { streamSimple as completions } from '@earendil-works/pi-ai/api/openai-completions';

export interface StoredMessage {
  id: string;
  message: AgentMessage;
}

export interface RunIdentity {
  conversationId: string;
  runId: string;
}

export type RunResult = { status: 'complete' | 'aborted' } | { status: 'failed'; error: string };

export type SessionEvent = RunIdentity & (
  | { type: 'message_start' | 'message_end'; entry: StoredMessage }
  | { type: 'text'; messageId: string; delta: string }
  | { type: 'tool_start'; messageId: string; toolCallId: string; name: string; arguments: unknown }
  | { type: 'tool_end'; messageId: string; toolCallId: string; result: unknown; isError: boolean }
  | { type: 'settled'; result: RunResult }
);

export interface SessionHost {
  fetch: typeof globalThis.fetch;
  /** Resolve only after a durable, idempotent upsert by conversationId + entry.id. */
  checkpoint(identity: RunIdentity, entry: StoredMessage): Promise<void>;
  /** Commit side effects and their replayable result atomically before resolving. */
  executeTool(call: RunIdentity & {
    messageId: string; toolCallId: string; name: string; arguments: unknown;
  }, signal: AbortSignal): Promise<AgentToolResult<unknown>>;
  onEvent(event: SessionEvent): void | Promise<void>;
}

export interface SessionConfig {
  conversationId: string;
  systemPrompt: string;
  model: Model<'anthropic-messages'> | Model<'openai-completions'>;
  apiKey: string;
  history?: StoredMessage[];
  tools: { name: string; label: string; description: string; parameters: TSchema }[];
}

/** One conversation, one active run. Swift supplies Web API globals before loading this bundle. */
export function createAgentSession(config: SessionConfig, host: SessionHost) {
  if (!config.conversationId || !config.apiKey) throw new Error('Missing conversation or API key');
  if (!['anthropic-messages', 'openai-completions'].includes(config.model.api)) {
    throw new Error('Unsupported model API');
  }
  const url = new URL(config.model.baseUrl);
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) {
    throw new Error('Invalid provider URL');
  }
  const history = structuredClone(config.history ?? []);
  const ids = new Set(history.map(entry => entry.id));
  if (ids.size !== history.length || history.some(entry => !entry.id)) throw new Error('Invalid message IDs');
  let active: { identity: RunIdentity; aborted: boolean; failure?: string; counter: number } | undefined;
  let currentMessageId = '';
  let assistantMessageId = '';
  let inputId: string | undefined;

  const tools: AgentTool[] = config.tools.map(tool => ({
    ...tool,
    execute: async (toolCallId, args, signal) => {
      if (!active || active.failure || active.aborted || !signal || signal.aborted) {
        throw new Error('Run is not active');
      }
      return host.executeTool({
        ...active.identity, messageId: assistantMessageId, toolCallId,
        name: tool.name, arguments: structuredClone(args),
      }, signal);
    },
  }));
  const agent = new Agent({
    sessionId: config.conversationId,
    toolExecution: 'sequential',
    initialState: {
      systemPrompt: config.systemPrompt, model: config.model,
      tools, messages: history.map(entry => entry.message),
    },
    streamFn: (_model, context, options) => {
      const request = { ...options, apiKey: config.apiKey, fetch: host.fetch, maxRetries: 0 };
      return config.model.api === 'anthropic-messages'
        ? anthropic(config.model, context, request)
        : completions(config.model, context, request);
    },
  });

  agent.subscribe(async event => {
    if (!active || active.failure) return;
    const identity = active.identity;
    try {
      if (event.type === 'message_start') {
        currentMessageId = event.message.role === 'user' && inputId
          ? inputId : `${identity.runId}:${++active.counter}`;
        if (ids.has(currentMessageId)) throw new Error('Duplicate message ID');
        ids.add(currentMessageId);
        if (event.message.role === 'assistant') assistantMessageId = currentMessageId;
        if (!active.aborted) await host.onEvent({ ...identity, type: 'message_start', entry: {
          id: currentMessageId, message: structuredClone(event.message),
        } });
      } else if (event.type === 'message_end') {
        const entry = { id: currentMessageId, message: structuredClone(event.message) };
        // pi awaits subscribers before executing tools or requesting the next model response.
        await host.checkpoint(identity, structuredClone(entry));
        history.push(entry);
        if (!active.aborted) await host.onEvent({ ...identity, type: 'message_end', entry: structuredClone(entry) });
      } else if (!active.aborted && event.type === 'message_update') {
        const delta = event.assistantMessageEvent;
        if (delta.type === 'text_delta') await host.onEvent({
          ...identity, type: 'text', messageId: currentMessageId, delta: delta.delta,
        });
      } else if (!active.aborted && event.type === 'tool_execution_start') {
        await host.onEvent({ ...identity, type: 'tool_start', messageId: assistantMessageId,
          toolCallId: event.toolCallId, name: event.toolName, arguments: structuredClone(event.args) });
      } else if (!active.aborted && event.type === 'tool_execution_end') {
        await host.onEvent({ ...identity, type: 'tool_end', messageId: assistantMessageId,
          toolCallId: event.toolCallId, result: structuredClone(event.result), isError: event.isError });
      }
    } catch (error) {
      active.failure = error instanceof Error ? error.message : String(error);
      agent.abort();
      throw error;
    }
  });

  async function run(runId: string, input?: { id: string; message: UserMessage }): Promise<RunResult> {
    if (active) throw new Error('Conversation already running');
    if (!runId || (input && (!input.id || ids.has(input.id)))) throw new Error('Invalid run or input ID');
    // Each run is rehydrated from durable messages, including after a failed checkpoint.
    agent.state.messages = structuredClone(history.map(entry => entry.message));
    active = { identity: { conversationId: config.conversationId, runId }, aborted: false, counter: 0 };
    inputId = input?.id;
    let result: RunResult;
    try {
      if (input) await agent.prompt(structuredClone(input.message));
      else await agent.continue();
      const last = agent.state.messages.at(-1);
      const failure = active.failure ?? agent.state.errorMessage;
      result = active.failure ? { status: 'failed', error: active.failure }
        : active.aborted || (last?.role === 'assistant' && last.stopReason === 'aborted') ? { status: 'aborted' }
        : failure || (last?.role === 'assistant' && last.stopReason === 'error')
          ? { status: 'failed', error: failure ?? 'Model request failed' } : { status: 'complete' };
    } catch (error) {
      result = active.failure ? { status: 'failed', error: active.failure }
        : active.aborted ? { status: 'aborted' }
        : { status: 'failed', error: error instanceof Error ? error.message : String(error) };
    }
    try {
      await host.onEvent({ ...active.identity, type: 'settled', result });
      return result;
    } finally {
      active = undefined;
      inputId = undefined;
    }
  }

  return {
    run,
    abort(runId: string) {
      if (!active || active.identity.runId !== runId) return;
      active.aborted = true;
      agent.abort();
    },
    get busy() { return active !== undefined; },
    get messages(): StoredMessage[] { return structuredClone(history); },
  };
}
