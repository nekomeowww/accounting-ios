import { native } from './globals.ts';

interface HTTPMetadata { status: number; headers: Record<string, string>; url: string }
interface PendingHTTP {
  resolve(value: Response): void;
  reject(error: Error): void;
  controller: ReadableStreamDefaultController<Uint8Array>;
  body: ReadableStream<Uint8Array>;
  cleanup(): void;
}
const requests = new Map<number, PendingHTTP>();
let nextId = 0;

function response(body: ReadableStream<Uint8Array>, metadata: HTTPMetadata): Response {
  const result = new Response(null, { status: metadata.status, headers: metadata.headers });
  let used = false;
  const consume = async () => {
    if (used || body.locked) throw new TypeError('Response already consumed');
    used = true;
    const reader = body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 1024 * 1024) { await reader.cancel(); throw new Error('Non-streamed response exceeds 1 MiB'); }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return bytes;
  };
  Object.defineProperties(result, {
    body: { get: () => body }, bodyUsed: { get: () => used || body.locked },
    url: { value: metadata.url },
    text: { value: async () => new TextDecoder().decode(await consume()) },
    json: { value: async () => JSON.parse(new TextDecoder().decode(await consume())) },
    arrayBuffer: { value: async () => (await consume()).buffer },
    clone: { value: () => {
      if (used || body.locked) throw new TypeError('Response already consumed');
      const branches = body.tee(); body = branches[0];
      return response(branches[1], metadata);
    } },
  });
  return result;
}

export const nativeFetch: typeof fetch = async (input, init = {}) => {
  const url = typeof input === 'string' || input instanceof URL ? String(input) : input.url;
  const method = init.method ?? (input instanceof Request ? input.method : 'GET');
  const headers = new Headers(init.headers ?? (input instanceof Request ? input.headers : undefined));
  const signal = init.signal ?? (input instanceof Request ? input.signal : undefined);
  // The shipped providers use POST JSON. Reject unsupported bodies rather than silently dropping them.
  if (input instanceof Request && init.body === undefined) throw new TypeError('Request input requires an explicit body');
  if (init.body !== undefined && init.body !== null && typeof init.body !== 'string') throw new TypeError('Only text request bodies are supported');
  if (signal?.aborted) throw Object.assign(new Error('Aborted'), { name: 'AbortError' });
  return new Promise<Response>((resolve, reject) => {
    const id = ++nextId;
    let controller!: ReadableStreamDefaultController<Uint8Array>;
    const cleanup = () => signal?.removeEventListener('abort', abort);
    const cancel = () => { requests.delete(id); cleanup(); native.nativeCancelHTTP(id); };
    const abort = () => {
      cancel();
      const error = Object.assign(new Error('Aborted'), { name: 'AbortError' });
      controller.error(error); reject(error);
    };
    const body = new ReadableStream<Uint8Array>({
      start(value) { controller = value; },
      pull() { native.nativeResumeHTTP(id); },
      cancel,
    }, { highWaterMark: 64 * 1024, size: chunk => chunk.byteLength });
    requests.set(id, { resolve, reject, controller, body, cleanup });
    signal?.addEventListener('abort', abort, { once: true });
    native.nativeFetch(id, JSON.stringify({ url, method, headers: Object.fromEntries(headers.entries()), body: init.body ?? null }));
  });
};

/** False pauses the native producer until pull() returns credit. */
export function receiveHTTP(id: number, kind: string, json: string): boolean {
  const request = requests.get(id);
  if (!request) return true;
  const value = JSON.parse(json);
  if (kind === 'headers') request.resolve(response(request.body, value));
  else if (kind === 'chunk') {
    request.controller.enqueue(new Uint8Array(value));
    return (request.controller.desiredSize ?? 0) > 0;
  } else {
    requests.delete(id); request.cleanup();
    if (kind === 'error') {
      const error = new Error(String(value)); request.reject(error); request.controller.error(error);
    } else request.controller.close();
  }
  return true;
}

export function cancelHTTP() {
  for (const id of [...requests.keys()]) {
    native.nativeCancelHTTP(id);
    receiveHTTP(id, 'error', JSON.stringify('Runtime closed'));
  }
}
