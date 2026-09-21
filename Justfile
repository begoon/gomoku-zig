run:
    zig run -O ReleaseFast gomoku.zig

test:
    zig test -O ReleaseSafe gomoku_test.zig

serve:
	python3 -m http.server -d site 8000

wasm: wasm-build wasm-run

wasm-run:
    bun gomoku.js

wasm-build:
    zig build-exe -O ReleaseFast -target wasm32-freestanding \
    -fstrip --stack 2097152 \
    -fno-entry \
    --export=loopback \
    -femit-bin=gomoku.wasm \
    gomoku.zig
    ls -al gomoku.wasm

js: js-build js-run

js-build:
    zig build-exe -O ReleaseFast -target wasm32-freestanding \
    -fstrip --stack 2097152 \
    -fno-entry \
    --export=alloc --export=free \
    --export=init \
    --export=place --export=unplace \
    --export=choose_move --export=choose_move_timed \
    --export=search_nodes --export=search_depth \
    --export=is_winner \
    --export=print_board --export=print_board_at \
    -femit-bin=site/wasm.wasm \
    wasm.zig

js-run:
    bun index.js

wasm-test: js-build
    node scripts/wasm-smoke.mjs

# Compare against a saved older site/wasm.wasm with equal thinking budgets.
benchmark baseline milliseconds="100" pairs="2":
    node scripts/benchmark.mjs "{{baseline}}" {{milliseconds}} {{pairs}}
