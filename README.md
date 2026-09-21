# Gomoku (5 in row) game AI

A Gomoku player implemented in Zig 0.16.0 for the console and WASM/JavaScript. Five or more contiguous stones win (freestyle rules).

The engine uses iterative-deepening alpha-beta search, threat-aware move selection, a Zobrist transposition table, incremental evaluation with cached undo, and forced-response quiescence. A bounded continuous-four solver looks for provable forcing attacks. The browser offers 0.25, 1, and 3 second thinking budgets; the console uses 1 second.

WASM version runs [online](https://demin.ws/gomoku-zig/) from GitHub pages.

With Zig 0.16.0 and [just](https://just.systems/) installed:

```sh
just test        # Native regression tests
just run         # Console game
just wasm-build  # Standalone WASM game (bun gomoku.js)
just js-build    # Build site/wasm.wasm for the browser
just serve       # Open http://localhost:8000
just wasm-test   # Rebuild and test the WASM API (requires Bun)
```

The committed `site/wasm.wasm` is the browser deployment artifact. Rebuild it after changing Zig sources. WASM hosts must provide `env.now_ms` using a monotonic clock such as `performance.now()`, alongside the existing console/status callbacks. Builds reserve a 2 MiB stack for search and game state.

The native API is `game.search(options, player)`. It returns a legal fallback if interrupted before depth one, otherwise the best result from the last completed iteration (or a proven tactical win). A full board returns an invalid move. `game.choose_move(depth, player)` retains the depth-limited interface; WASM additionally exports `choose_move_timed(handle, milliseconds, player)`, which returns `-1` on a full board.

Search options include `max_depth`, `time_ms` (zero means unlimited), `node_limit`, `use_tt`, `threat_depth`, `profile`, and `progress`. Fine-grained pattern timers are off by default, and progress updates are limited to about 10 per second. Budgets are cooperative: the current node's work may finish slightly after the deadline.

`game.counters` distinguishes search nodes, quiescence nodes, threat-solver nodes, transposition hits, completed depth, and placements used by evaluation. The continuous-four solver is bounded to 256 nodes and at most 16 attacking moves. Failure to find a proof means unknown, not a loss. General search keeps 32 candidates plus every identified immediate win, four creation, or open-three creation; it is selective, not an exhaustive game solver.

To compare versions, save the previous browser binary before rebuilding, then run paired games with equal thinking budgets:

```sh
git show f0dabf6:site/wasm.wasm > /tmp/gomoku-baseline.wasm
just benchmark /tmp/gomoku-baseline.wasm 100 2
```

The benchmark runs two games per opening with engine colors swapped (1–3 opening pairs), independently validates moves and wins, and emits JSON game records plus a summary. Old depth-only engines run iterative deepening in an isolated worker and return their last completed result when the budget expires. Startup and replaying the position are excluded from thinking time. Short matches are a smoke check, not an Elo estimate; use multiple budgets and more opening positions for strength evaluation.
