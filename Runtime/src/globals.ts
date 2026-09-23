import 'core-js/actual/structured-clone.js';
import 'core-js/actual/url/index.js';
import 'core-js/actual/url-search-params/index.js';
// The browser entry reexports nonexistent JSC globals; use the implementation.
// @ts-expect-error Package ships declarations only for its public entry.
import { AbortController, AbortSignal } from 'abort-controller/dist/abort-controller.mjs';
import { ReadableStream } from 'web-streams-polyfill';
import { Headers, Request, Response } from 'whatwg-fetch';
import { Blob, File, FileReader } from 'blob-polyfill';

export const native = globalThis as typeof globalThis & {
  nativeCall(id: number, method: string, json: string): void;
  nativeCancelCall(id: number): void;
  nativeFetch(id: number, json: string): void;
  nativeCancelHTTP(id: number): void;
  nativeResumeHTTP(id: number): void;
  nativeTimer(id: number, milliseconds: number): void;
  nativeClearTimer(id: number): void;
  nativeEncode(text: string): number[];
  nativeDecode(bytes: number[], fatal: boolean): string | null;
  nativeFinish(runId: string, json: string): void;
};

class UTF8Encoder {
  readonly encoding = 'utf-8';
  encode(text = '') { return new Uint8Array(native.nativeEncode(String(text))); }
}

class UTF8Decoder {
  readonly encoding = 'utf-8';
  readonly fatal: boolean;
  readonly ignoreBOM: boolean;
  private pending: number[] = [];
  private beginning = true;
  constructor(label = 'utf-8', options: TextDecoderOptions = {}) {
    if (!['utf-8', 'utf8', 'unicode-1-1-utf-8'].includes(label.trim().toLowerCase())) throw new RangeError('Only UTF-8 is supported');
    this.fatal = options.fatal ?? false;
    this.ignoreBOM = options.ignoreBOM ?? false;
  }
  decode(input?: ArrayBuffer | ArrayBufferView, options: TextDecodeOptions = {}) {
    const bytes = input === undefined ? [] : Array.from(input instanceof ArrayBuffer
      ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength));
    const data = this.pending.concat(bytes);
    let end = data.length;
    if (options.stream) {
      // Keep only a potentially valid incomplete UTF-8 suffix. Foundation decodes the rest.
      let start = end - 1;
      while (start >= 0 && end - start <= 3 && (data[start]! & 0xc0) === 0x80) start--;
      const lead = data[start] ?? 0;
      const width = lead >= 0xc2 && lead <= 0xdf ? 2 : lead >= 0xe0 && lead <= 0xef ? 3 : lead >= 0xf0 && lead <= 0xf4 ? 4 : 0;
      const second = data[start + 1];
      const validSecond = second === undefined || ((lead !== 0xe0 || second >= 0xa0) && (lead !== 0xed || second < 0xa0)
        && (lead !== 0xf0 || second >= 0x90) && (lead !== 0xf4 || second < 0x90));
      if (width > end - start && validSecond) end = start;
    }
    this.pending = data.slice(end);
    let text = native.nativeDecode(data.slice(0, end), this.fatal);
    if (text === null) { this.pending = []; this.beginning = true; throw new TypeError('Invalid UTF-8'); }
    if (text.length && this.beginning) {
      if (!this.ignoreBOM && text.startsWith('\uFEFF')) text = text.slice(1);
      this.beginning = false;
    }
    if (!options.stream) this.beginning = true;
    return text;
  }
}

const timers = new Map<number, () => void>();
let timerId = 0;
export function fireTimer(id: number) { const fn = timers.get(id); timers.delete(id); fn?.(); }
export function clearTimers() { for (const id of timers.keys()) native.nativeClearTimer(id); timers.clear(); }

Object.assign(globalThis, {
  AbortController, AbortSignal, ReadableStream, Headers, Request, Response, Blob, File, FileReader,
  TextEncoder: UTF8Encoder, TextDecoder: UTF8Decoder,
  // Provider debug logs can contain credentials and prompts; use explicit host events instead.
  console: { log() {}, warn() {}, error() {}, info() {}, debug() {}, assert() {} },
  setTimeout(fn: (...args: unknown[]) => void, delay = 0, ...args: unknown[]) {
    const id = ++timerId;
    timers.set(id, () => fn(...args));
    native.nativeTimer(id, Math.max(0, Number(delay) || 0));
    return id;
  },
  clearTimeout(id: number) { timers.delete(id); native.nativeClearTimer(id); },
});
