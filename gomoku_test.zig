const std = @import("std");
const eql = std.mem.eql;
const testing = std.testing;

const gomoku = @import("gomoku.zig");
const Game = gomoku.Game;
const Move = gomoku.Move;
const N = gomoku.N;
const NN = gomoku.NN;
const patterns = gomoku.patterns;

test "choose move" {
    var game = Game.init();
    game.place(Move.at(7, 7), .human);
    game.place(Move.at(8, 7), .computer);
    game.place(Move.at(8, 8), .human);

    const move = game.choose_move(3, .computer);
    // engine should return a valid, empty position near the action
    try testing.expect(move.in());
    try testing.expect(game.empty_at(move));
}

test "available moves" {
    var game = Game.init();

    var backing: [NN]Move = undefined;

    const moves = game.available_moves(&backing);
    try testing.expectEqual(1, moves.len);
    try testing.expectEqual(7, moves[0].r);
    try testing.expectEqual(7, moves[0].c);

    game.place(moves[0], .human);
    try testing.expectEqual(24, game.available_moves(&backing).len);

    game.place(Move.at(7, 8), .computer);
    try testing.expectEqual(28, game.available_moves(&backing).len);
}

test "check pattern" {
    var game = Game.init();
    game.place(Move.at(1, 2), .human);
    game.place(Move.at(2, 3), .human);
    game.place(Move.at(3, 4), .human);
    game.place(Move.at(4, 5), .human);

    game.place(Move.at(6, 7), .human);
    game.place(Move.at(7, 7), .human);
    game.place(Move.at(8, 7), .human);
    game.place(Move.at(9, 7), .human);

    const score = game.check_patterns(.human);
    try testing.expectEqual(score, 12584);
}

test "check winner" {
    var game = Game.init();
    game.place(Move.at(1, 2), .human);
    game.place(Move.at(2, 3), .human);
    game.place(Move.at(3, 4), .human);
    game.place(Move.at(4, 5), .human);
    game.place(Move.at(5, 6), .human);

    const winner = game.check_win_at(Move.at(5, 6));
    try testing.expectEqual(.human, winner);
}

test "place_unplace_empty_at" {
    var game = Game{};
    try testing.expect(game.empty_at(Move.at(7, 7)));
    game.place(Move.at(7, 7), .human);
    try testing.expect(!game.empty_at(Move.at(7, 7)));
    game.unplace(Move.at(7, 7));
    try testing.expect(game.empty_at(Move.at(7, 7)));
}

test "is_full" {
    var game = Game{};
    try testing.expect(!game.is_full());

    var r: i32 = 0;
    while (r < N) : (r += 1) {
        var c: i32 = 0;
        while (c < N) : (c += 1) {
            game.place(Move.at(r, c), .human);
        }
    }

    try testing.expect(game.is_full());
}

test "incremental eval matches full scan" {
    var game = Game.init();
    game.place(Move.at(7, 7), .human);
    game.place(Move.at(7, 8), .computer);
    game.place(Move.at(6, 6), .human);
    game.place(Move.at(8, 8), .computer);

    // incremental evaluation should equal (computer_score - human_score)
    const comp_score = game.check_patterns(.computer);
    const human_score = game.check_patterns(.human);
    const expected = comp_score - human_score;
    try testing.expectEqual(expected, game.evaluate_static());

    // after place+unplace, evaluation should be restored
    const before = game.evaluate_static();
    game.place(Move.at(5, 5), .human);
    game.unplace(Move.at(5, 5));
    try testing.expectEqual(before, game.evaluate_static());
}

test "build_patterns works" {
    comptime {
        try std.testing.expect(patterns.len == 18);

        try std.testing.expect(eql(u8, patterns[0].value, "GGGGG"));
        try std.testing.expect(patterns[0].weight == 10_000);
        try std.testing.expect(eql(u8, patterns[1].value, "_GGGG_"));
        try std.testing.expect(patterns[1].weight == 5000);

        try std.testing.expect(eql(u8, patterns[15].value, "GG_"));
        try std.testing.expect(patterns[15].weight == 1);
    }
}

fn transform(m: Move, symmetry: usize) Move {
    var r = m.r;
    var c = m.c;
    if (symmetry >= 4) c = N - 1 - c;
    for (0..symmetry % 4) |_| {
        const old_r = r;
        r = c;
        c = N - 1 - old_r;
    }
    return Move.at(r, c);
}

test "immediate broken-four wins and compulsory blocks in every orientation" {
    for (0..8) |symmetry| {
        for ([_]gomoku.Field{ .human, .computer }) |player| {
            var game = Game.init();
            for ([_]i32{ 2, 3, 5, 6 }) |c| game.place(transform(Move.at(0, c), symmetry), .human);
            const expected = transform(Move.at(0, 4), symmetry);
            const before = game.hash;
            const result = game.search(.{ .max_depth = 1, .time_ms = 0, .threat_depth = 0 }, player);
            try testing.expectEqualDeep(expected, result.move);
            try testing.expectEqual(before, game.hash);
        }
    }
}

test "win takes priority over opponent threat and open four is a forced loss" {
    var game = Game.init();
    for (4..8) |c| game.place(Move.at(7, @intCast(c)), .human);
    const loss = game.search(.{ .time_ms = 0, .max_depth = 1 }, .computer);
    try testing.expectEqual(-gomoku.WIN + 2, loss.score);
    for (4..8) |c| game.place(Move.at(3, @intCast(c)), .computer);
    const win = game.search(.{ .time_ms = 0, .max_depth = 1 }, .computer);
    try testing.expect(game.would_win(win.move, .computer));
    try testing.expectEqual(gomoku.WIN - 1, win.score);
}

test "threat classification detects broken threes and crossing forks" {
    for (0..8) |symmetry| {
        var game = Game.init();
        game.place(transform(Move.at(7, 4), symmetry), .computer);
        game.place(transform(Move.at(7, 7), symmetry), .computer);
        const t = game.threat_at(transform(Move.at(7, 5), symmetry), .computer);
        try testing.expectEqual(1, t.threes);
        try testing.expectEqual(0, t.fours);
    }
    var game = Game.init();
    for ([_]Move{ Move.at(7, 6), Move.at(7, 8), Move.at(6, 7), Move.at(8, 7) }) |m| game.place(m, .computer);
    try testing.expectEqual(2, game.threat_at(Move.at(7, 7), .computer).threes);
}

test "candidate set and hash depend on board rather than placement history" {
    const stones = [_]Move{ Move.at(3, 3), Move.at(7, 7), Move.at(11, 11), Move.at(3, 11), Move.at(11, 3), Move.at(8, 8) };
    var a = Game.init();
    var b = Game.init();
    for (stones, 0..) |m, i| a.place(m, if (i % 2 == 0) .human else .computer);
    for (0..stones.len) |j| {
        const i = stones.len - 1 - j;
        b.place(stones[i], if (i % 2 == 0) .human else .computer);
    }
    var aa: [NN]Move = undefined;
    var bb: [NN]Move = undefined;
    try testing.expectEqual(a.hash, b.hash);
    try testing.expectEqualDeep(a.available_moves(&aa), b.available_moves(&bb));
}

test "candidate cap preserves every four and open-three creation" {
    var game = Game.init();
    var random_source = std.Random.DefaultPrng.init(2026);
    const random = random_source.random();
    for (0..80) |_| {
        const m = Move.at(random.intRangeLessThan(i32, 0, N), random.intRangeLessThan(i32, 0, N));
        if (game.empty_at(m)) game.place(m, if (random.boolean()) .human else .computer);
    }
    var backing: [NN]Move = undefined;
    const moves = game.available_moves(&backing);
    for (0..N) |r| {
        for (0..N) |c| {
            const m = Move.at(@intCast(r), @intCast(c));
            if (!game.empty_at(m)) continue;
            for ([_]gomoku.Field{ .human, .computer }) |player| {
                const t = game.threat_at(m, player);
                if (t.win or t.fours > 0 or t.threes > 0) {
                    var found = false;
                    for (moves) |candidate| {
                        if (std.meta.eql(candidate, m)) found = true;
                    }
                    try testing.expect(found);
                }
            }
        }
    }
}

test "random undo restores all line caches evaluation and hash without rescanning" {
    var game = Game.init();
    const initial = game;
    var random_source = std.Random.DefaultPrng.init(17);
    const random = random_source.random();
    for (0..60) |_| {
        const m = Move.at(random.intRangeLessThan(i32, 0, N), random.intRangeLessThan(i32, 0, N));
        if (!game.empty_at(m)) continue;
        game.place(m, if (random.boolean()) .human else .computer);
        try testing.expectEqual(game.check_patterns(.computer) - game.check_patterns(.human), game.evaluate_static());
    }
    const scans = game.counters.check_pattern_calls;
    while (game.stack_len > 0) game.unplace(game.move_stack[game.stack_len - 1]);
    try testing.expectEqual(scans, game.counters.check_pattern_calls);
    try testing.expectEqual(initial.hash, game.hash);
    try testing.expectEqual(initial.evaluation, game.evaluation);
    try testing.expectEqualDeep(initial.row_cache, game.row_cache);
    try testing.expectEqualDeep(initial.col_cache, game.col_cache);
    try testing.expectEqualDeep(initial.diagonal_left_cache, game.diagonal_left_cache);
    try testing.expectEqualDeep(initial.diagonal_right_cache, game.diagonal_right_cache);
}

fn opening(game: *Game) void {
    game.place(Move.at(7, 7), .human);
    game.place(Move.at(8, 8), .computer);
    game.place(Move.at(7, 8), .human);
}

test "transposition bounds agree with uncached search for both players" {
    var game = Game.init();
    opening(&game);
    var hits: usize = 0;
    for ([_]gomoku.Field{ .human, .computer }) |player| {
        const cached = game.search(.{ .max_depth = 3, .time_ms = 0, .threat_depth = 0 }, player);
        hits += game.counters.tt_hits;
        const plain = game.search(.{ .max_depth = 3, .time_ms = 0, .threat_depth = 0, .use_tt = false }, player);
        try testing.expectEqual(plain.score, cached.score);
        try testing.expectEqualDeep(plain.move, cached.move);
    }
    try testing.expect(hits > 0);
}

test "interrupted iteration returns last completed result and restores board" {
    var game = Game.init();
    opening(&game);
    const board = game.board;
    const hash = game.hash;
    const evaluation = game.evaluation;
    const shallow = game.search(.{ .max_depth = 1, .time_ms = 0, .threat_depth = 0 }, .computer);
    const budget = game.counters.nodes + 2;
    const interrupted = game.search(.{ .max_depth = 8, .time_ms = 0, .node_limit = budget, .threat_depth = 0 }, .computer);
    try testing.expect(interrupted.timed_out);
    try testing.expectEqual(1, interrupted.completed_depth);
    try testing.expectEqualDeep(shallow.move, interrupted.move);
    try testing.expectEqual(shallow.score, interrupted.score);
    try testing.expectEqualDeep(board, game.board);
    try testing.expectEqual(hash, game.hash);
    try testing.expectEqual(evaluation, game.evaluation);
    try testing.expectEqual(3, game.stack_len);
    const immediate = game.search(.{ .time_ms = 0, .node_limit = 1 }, .computer);
    try testing.expect(immediate.timed_out);
    try testing.expect(game.empty_at(immediate.move));
    try testing.expectEqual(0, immediate.completed_depth);
}

test "time budget returns a legal move and full board returns no move" {
    var game = Game.init();
    opening(&game);
    const result = game.search(.{ .time_ms = 1 }, .computer);
    try testing.expect(result.timed_out);
    try testing.expect(result.move.in() and game.empty_at(result.move));
    try testing.expect(game.counters.choose_move_time_ns < 500 * std.time.ns_per_ms);
    for (0..N) |r| {
        for (0..N) |c| {
            const m = Move.at(@intCast(r), @intCast(c));
            if (game.empty_at(m)) game.place(m, .human);
        }
    }
    try testing.expect(game.search(.{}, .computer).move.invalid());
}
