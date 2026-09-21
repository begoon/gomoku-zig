# Gomoku (5 in row) game AI

The AI agent based on Minimax with Alpha-Beta pruning, local moves pre-sort and quiescence deepening on the leaves to mitigate the horizon problem of Minimax.

The agent is implemented in Zig 0.16.0 (console and WASM/JS).

WASM version runs [online](https://demin.ws/gomoku-zig/) from GitHub pages.

With Zig 0.16.0 and [just](https://just.systems/) installed:

```sh
just test        # Run the native tests
just run         # Run the console game
just wasm-build  # Build the standalone WASM game
just js-build    # Build site/wasm.wasm for the browser
```
