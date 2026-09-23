import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { build } from 'esbuild';

const bundle = await build({ entryPoints: ['src/nativeFetch.ts'], bundle: true, platform: 'browser',
  format: 'iife', globalName: 'Transport', target: 'es2022', write: false });

function environment() {
  const requests: number[] = [];
  const resumed: number[] = [];
  const cancelled: number[] = [];
  const context = vm.createContext({
    nativeFetch: (id: number) => requests.push(id),
    nativeResumeHTTP: (id: number) => resumed.push(id),
    nativeCancelHTTP: (id: number) => cancelled.push(id),
    nativeEncode: (text: string) => Array.from(new TextEncoder().encode(text)),
    nativeDecode: (bytes: number[], fatal: boolean) => {
      try { return new TextDecoder('utf-8', { fatal, ignoreBOM: true }).decode(new Uint8Array(bytes)); }
      catch { return null; }
    },
  });
  vm.runInContext(bundle.outputFiles[0]!.text, context);
  return { context, requests, resumed, cancelled };
}

test('streaming UTF-8 adapter matches TextDecoder on splits, invalid bytes, BOM and fatal mode', () => {
  const { context } = environment();
  const fixtures = [
    Array.from(new TextEncoder().encode('\uFEFF东京 東京🙂')),
    [0xf0, 0x9f], [0xe0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80],
    [0x61, 0x80, 0xc0, 0xaf, 0xe2, 0x82, 0x62],
  ];
  for (const bytes of fixtures) for (let cut = 0; cut <= bytes.length; cut++) for (const fatal of [false, true]) {
    const chunks = [bytes.slice(0, cut), bytes.slice(cut)];
    let expected: string;
    const decoder = new TextDecoder('utf-8', { fatal });
    try { expected = chunks.map(chunk => decoder.decode(new Uint8Array(chunk), { stream: true })).join('') + decoder.decode(); }
    catch { expected = 'INVALID'; }
    const actual = vm.runInContext(`(() => {
      const decoder = new TextDecoder('utf-8', {fatal: ${fatal}});
      try { return ${JSON.stringify(chunks)}.map(chunk => decoder.decode(new Uint8Array(chunk), {stream: true})).join('') + decoder.decode(); }
      catch { return 'INVALID'; }
    })()`, context);
    assert.equal(actual, expected, `bytes=${bytes} split=${cut} fatal=${fatal}`);
  }
});

test('native response applies backpressure, returns read credit and cancels the producer', async () => {
  const { context, requests, resumed, cancelled } = environment();
  const promise = vm.runInContext('Transport.nativeFetch("https://fixture.invalid", {method:"POST", body:"{}"})', context);
  const id = requests[0]!;
  context.requestId = id;
  vm.runInContext(`Transport.receiveHTTP(requestId, 'headers', ${JSON.stringify(JSON.stringify({ status: 200, headers: { 'x-fixture': 'yes' }, url: 'https://fixture.invalid' }))})`, context);
  const response: Response = await promise;
  assert.equal(response.headers.get('x-fixture'), 'yes');
  assert.equal(vm.runInContext('Transport.receiveHTTP(requestId, "chunk", JSON.stringify(Array(65536).fill(97)))', context), false);
  const before = resumed.length;
  const reader = response.body!.getReader();
  assert.equal((await reader.read()).value?.length, 65536);
  assert.ok(resumed.length > before, 'reading must return credit to native producer');
  await reader.cancel();
  assert.deepEqual(cancelled, [id]);
});

test('non-2xx response retains status, headers and readable JSON body', async () => {
  const { context } = environment();
  const promise = vm.runInContext('Transport.nativeFetch("https://fixture.invalid", {method:"POST", body:"{}"})', context);
  vm.runInContext(`
    Transport.receiveHTTP(1, 'headers', JSON.stringify({status:401,headers:{'content-type':'application/json'},url:'https://fixture.invalid'}));
    Transport.receiveHTTP(1, 'chunk', JSON.stringify(Array.from(new TextEncoder().encode('{"error":"无效凭据"}'))));
    Transport.receiveHTTP(1, 'end', 'null');
  `, context);
  const response: Response = await promise;
  assert.equal(response.status, 401);
  assert.equal(response.ok, false);
  assert.equal((await response.json() as { error: string }).error, '无效凭据');
  await assert.rejects(response.text(), /consumed/);
});
