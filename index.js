import { fileURLToPath } from "node:url";

const url = fileURLToPath(new URL("./site/wasm.wasm", import.meta.url));
console.log("loading wasm from:", url);
const { instance } = await WebAssembly.instantiateStreaming(fetch("file://" + url), {
    env: {
        now_ms: () => performance.now(),
        console: (ptr, len) => {
            const memory = instance.exports.memory;
            const bytes = new Uint8Array(memory.buffer, ptr, len);
            const text = new TextDecoder("utf-8").decode(bytes);
            process.stdout.write(text);
        },
        enter: () => {
            prompt("press enter to continue...");
        },
        status: (ptr, len) => {},
    },
});

const h = instance.exports.alloc();
if (h === 0) throw new Error("game alloc failed");

console.log("WASM exports:", Object.keys(instance.exports));

const { free, init, is_winner, place, unplace, print_board, print_board_at, choose_move_timed } = instance.exports;

console.log("game initialized in wasm memory");

init(h);

const HUMAN = 1;
const COMPUTER = 2;

place(h, 7, 7, HUMAN);
print_board_at(h, 7, 7);

let player = COMPUTER;
let lastRow = 7;
let lastCol = 7;
while (true) {
    const winner = is_winner(h, lastRow, lastCol);
    if (winner !== 0) {
        const v = [undefined, "human (X)", "computer (O)"][winner];
        console.log(`${v} wins!`);
        break;
    }
    console.log("thinking...");
    const move = choose_move_timed(h, 1000, player);
    if (move < 0) {
        console.log("draw");
        break;
    }
    const r = (move >> 8) & 0xff;
    const c = move & 0xff;
    place(h, r, c, player);
    lastRow = r;
    lastCol = c;
    print_board_at(h, r, c);
    player = player === HUMAN ? COMPUTER : HUMAN;
    prompt("press enter to continue...");
}

free(h);
console.log("game deinitialized in wasm memory");
