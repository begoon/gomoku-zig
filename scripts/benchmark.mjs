// Equal wall-clock budgets, paired openings, colors swapped. Supports the old
// depth-only WASM ABI by publishing completed iterations from a worker, then
// terminating it at the deadline. Worker startup/replaying moves is not timed.
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

if (!isMainThread) {
    const { instance } = await WebAssembly.instantiate(readFileSync(workerData.path), {
        env: { console() {}, status() {}, enter() {}, now_ms: () => performance.now() },
    });
    const e = instance.exports, h = e.alloc();
    e.init(h);
    for (const [r, c, p] of workerData.moves) e.place(h, r, c, p);
    parentPort.once('message', () => {
        if (e.choose_move_timed) {
            const move = e.choose_move_timed(h, workerData.budget, workerData.player);
            parentPort.postMessage({ move, depth: e.search_depth(h), nodes: e.search_nodes(h), done: true });
        } else {
            for (let depth = 1; depth <= 16; depth++) {
                const move = e.choose_move(h, depth, workerData.player);
                parentPort.postMessage({ move, depth, nodes: null });
            }
        }
    });
    parentPort.postMessage({ ready: true, timed: Boolean(e.choose_move_timed) });
} else {
    const baseline = process.argv[2];
    if (!baseline) throw new Error('Usage: node scripts/benchmark.mjs BASELINE.wasm [milliseconds=100] [opening-pairs=2]');
    const budget = Number(process.argv[3] ?? 100);
    const pairs = Number(process.argv[4] ?? 2);
    if (!Number.isInteger(budget) || budget < 1 || !Number.isInteger(pairs) || pairs < 1 || pairs > 3) throw new Error('Use a positive integer budget and 1–3 opening pairs');
    const paths = [resolve(baseline), resolve('site/wasm.wasm')];
    const openings = [
        [[7, 7, 1], [8, 8, 2], [7, 8, 1]],
        [[7, 7, 1], [6, 8, 2], [8, 6, 1]],
        [[7, 7, 1], [7, 8, 2], [8, 7, 1]],
    ];
    const totals = [{ wins: 0, moves: 0, depth: 0, fallbacks: 0 }, { wins: 0, moves: 0, depth: 0, fallbacks: 0 }];
    let draws = 0;
    async function choose(engine, moves, board, player) {
        const worker = new Worker(new URL(import.meta.url), { workerData: { path: paths[engine], moves, player, budget } });
        let latest, timer, settled = false;
        return new Promise((resolve, reject) => {
            const finish = async (error) => {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                await worker.terminate();
                if (error) return reject(error);
                if (!latest) {
                    // A legal fallback is required if even depth one did not finish.
                    outer: for (let r = 0; r < 15; r++) for (let c = 0; c < 15; c++) {
                        if (!board[r][c]) { latest = { move: (r << 8) | c, depth: 0 }; break outer; }
                    }
                    totals[engine].fallbacks++;
                }
                totals[engine].moves++;
                totals[engine].depth += latest.depth;
                resolve(latest.move);
            };
            worker.on('error', finish);
            worker.on('exit', code => { if (!settled) finish(code === 0 && latest ? undefined : new Error(`Engine worker exited unexpectedly: ${code}`)); });
            worker.on('message', message => {
                if (message.ready) {
                    timer = message.timed
                        ? setTimeout(() => finish(new Error("Timed engine failed to return within its deadline tolerance")), budget + 1000)
                        : setTimeout(() => finish(), budget);
                    worker.postMessage('go');
                } else {
                    latest = message;
                    if (message.done) finish();
                }
            });
        });
    }
    function won(board, r, c, p) {
        return [[1, 0], [0, 1], [1, 1], [1, -1]].some(([dr, dc]) => {
            let count = 1;
            for (const sign of [-1, 1]) {
                let rr = r + dr * sign, cc = c + dc * sign;
                while (rr >= 0 && rr < 15 && cc >= 0 && cc < 15 && board[rr][cc] === p) {
                    count++; rr += dr * sign; cc += dc * sign;
                }
            }
            return count >= 5;
        });
    }
    for (let pair = 0; pair < pairs; pair++) for (let swap = 0; swap < 2; swap++) {
        const moves = openings[pair].map(m => [...m]);
        const board = Array.from({ length: 15 }, () => Array(15).fill(0));
        for (const [r, c, p] of moves) board[r][c] = p;
        let player = 2, winner = null;
        while (moves.length < 225) {
            const engine = (player - 1) ^ swap;
            const move = await choose(engine, moves, board, player);
            const r = move >> 8, c = move & 255;
            if (r < 0 || r >= 15 || c < 0 || c >= 15 || board[r][c]) throw new Error(`Engine ${engine} returned illegal move ${move}`);
            board[r][c] = player;
            moves.push([r, c, player]);
            if (won(board, r, c, player)) { winner = engine; totals[engine].wins++; break; }
            player = 3 - player;
        }
        if (winner === null) draws++;
        console.log(JSON.stringify({ pair, swap, winner: winner === null ? 'draw' : winner === 0 ? 'baseline' : 'new', plies: moves.length, moves }));
    }
    console.log(JSON.stringify({ budget_ms: budget, games: pairs * 2, draws, engines: totals.map((t, i) => ({ name: i === 0 ? 'baseline' : 'new', ...t, average_depth: t.depth / t.moves })) }));
}
