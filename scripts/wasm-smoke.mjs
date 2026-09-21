import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2] ?? new URL('../site/wasm.wasm', import.meta.url)), {
    env: { console() {}, status() {}, enter() {}, now_ms: () => performance.now() },
});
const e = instance.exports;
const h = e.alloc();
try {
    e.init(h);
    assert.equal(e.choose_move_timed(h, 25, 2), (7 << 8) | 7);
    e.place(h, 7, 7, 1);
    const start = performance.now();
    const move = e.choose_move_timed(h, 50, 2);
    const elapsed = performance.now() - start;
    const r = move >> 8, c = move & 255;
    assert(r >= 0 && r < 15 && c >= 0 && c < 15);
    assert.notEqual(move, (7 << 8) | 7);
    assert(elapsed < 1000, `50 ms search took ${elapsed} ms`);
    e.place(h, r, c, 2);
    e.unplace(h, r, c);
    for (let c = 8; c <= 11; c++) e.place(h, 7, c, 1);
    assert.equal(e.is_winner(h, 7, 11), 1);
    // Reset also resets hash, undo history, and transposition entries.
    e.init(h);
    for (const c of [2, 3, 5, 6]) e.place(h, 0, c, 1);
    assert.equal(e.choose_move_timed(h, 25, 2), 4);
    assert.equal(e.choose_move_timed(h, 25, 1), 4);
    e.init(h);
    for (let r = 0; r < 15; r++) for (let c = 0; c < 15; c++) e.place(h, r, c, 1);
    assert.equal(e.choose_move_timed(h, 25, 2), -1);
    assert.equal(e.choose_move(h, 1, 2), -1);
    console.log(`WASM smoke test passed; 50 ms search took ${elapsed.toFixed(1)} ms`);
} finally {
    e.free(h);
}

// Exercise the actual browser-worker RPC adapter without needing a browser UI.
const { createContext, runInContext } = await import('node:vm');
const messages = [];
const workerContext = createContext({
    WebAssembly, Uint8Array, TextDecoder, performance,
    fetch: async () => new Response(readFileSync(new URL('../site/wasm.wasm', import.meta.url)), {
        headers: { 'Content-Type': 'application/wasm' },
    }),
    postMessage: message => messages.push(message),
});
runInContext(readFileSync(new URL('../site/wasm-worker.js', import.meta.url), 'utf8'), workerContext);
let id = 0;
async function rpc(type, args = {}) {
    const requestID = ++id;
    await workerContext.onmessage({ data: { id: requestID, type, ...args } });
    const response = messages.find(m => m.type === 'response' && m.id === requestID);
    assert(response?.ok, response?.error ?? `No response for ${type}`);
    return response.result;
}
await rpc('start');
await rpc('place', { r: 7, c: 7, player: 1 });
const result = await rpc('choose_move', { time_ms: 25, player: 2 });
assert.notEqual(result.move, (7 << 8) | 7);
assert(Number.isInteger(result.nodes) && result.nodes > 0);
assert(Number.isInteger(result.depth) && result.depth >= 0);
await rpc('place', { r: result.move >> 8, c: result.move & 255, player: 2 });
assert.equal(await rpc('is_winner', { r: result.move >> 8, c: result.move & 255 }), 0);
await rpc('free');
await rpc('start');
assert.equal((await rpc('choose_move', { time_ms: 25, player: 2 })).move, (7 << 8) | 7);
await rpc('free');
console.log('Browser worker RPC smoke test passed');
