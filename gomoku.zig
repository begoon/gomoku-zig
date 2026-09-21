const std = @import("std");
const eql = std.mem.eql;
const testing = std.testing;
const builtin = @import("builtin");

const WASM = builtin.target.cpu.arch == .wasm32;

// The native console and profiling clocks use synchronous I/O.
const io = if (WASM) {} else std.Io.Threaded.global_single_threaded.io();

extern fn console(msg: [*]const u8, len: usize) void;
extern fn status(msg: [*]const u8, len: usize) void;
extern fn enter() void;

const QDEPTH: i32 = 2;
const MAX_DEPTH: usize = 64;
pub const WIN: i32 = 1_000_000;
const TT_SIZE = 4096;
extern fn now_ms() f64;

fn milliseconds() f64 {
    if (WASM) return now_ms();
    return @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).toNanoseconds())) / std.time.ns_per_ms;
}

pub const SearchOptions = struct {
    max_depth: i32 = 32,
    time_ms: u32 = 1000,
    node_limit: usize = 0, // Deterministic budget for tests and benchmarks; 0 is unlimited.
    use_tt: bool = true,
    threat_depth: i32 = 8, // Bounded continuous-four search; 0 disables it.
    profile: bool = false,
    progress: bool = false,
};

pub const SearchResult = struct {
    move: Move,
    score: i32 = 0, // From the computer's perspective.
    completed_depth: i32 = 0,
    timed_out: bool = false,
};

const Bound = enum { exact, lower, upper };
const TTEntry = struct {
    key: u64 = 0,
    depth: i32 = -1,
    score: i32 = 0, // Mate distance normalized to this position.
    bound: Bound = .exact,
    move: Move = .{ .r = -1, .c = -1 },
};

fn stone_key(move: Move, player: Field) u64 {
    var z = @as(u64, @intCast((move.r * N + move.c) * 2)) + @as(u64, @intCast(player_index(player))) + 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn opponent(player: Field) Field {
    return if (player == .computer) .human else .computer;
}

fn mate(player: Field, ply: i32) i32 {
    return if (player == .computer) WIN - ply else -WIN + ply;
}

fn same_move(a: Move, b: Move) bool {
    return a.r == b.r and a.c == b.c;
}

pub const Threat = struct {
    win: bool = false,
    fours: u8 = 0, // Distinct next-move winning squares.
    threes: u8 = 0, // Directions containing an open straight or broken three.
    twos: u8 = 0,

    fn critical(t: Threat) bool {
        return t.win or t.fours > 0 or t.threes > 0;
    }

    fn value(t: Threat) i32 {
        if (t.win) return WIN;
        if (t.fours >= 2) return 100_000;
        if (t.fours > 0 and t.threes > 0) return 50_000;
        if (t.fours > 0) return 10_000;
        if (t.threes >= 2) return 8000;
        return @as(i32, t.threes) * 1000 + @as(i32, t.twos) * 40;
    }
};

const Undo = struct {
    row: [2]i32,
    col: [2]i32,
    left: [2]i32,
    right: [2]i32,
    totals: [2]i32,
};

pub const N: i32 = 15;
pub const NN: usize = N * N;

// Keep evaluation sensitive to shortest scored pattern (currently 3..7).
const MIN_EVAL_PATTERN_LEN: usize = 3;

pub const Field = enum {
    empty,
    human,
    computer,
};

inline fn player_index(player: Field) usize {
    return switch (player) {
        .human => 0,
        .computer => 1,
        else => unreachable,
    };
}

inline fn left_to_right_diagonal_index(r: i32, c: i32) usize {
    // r - c in [-(N-1) .. N-1]  => shift by (N-1)
    return @intCast(r - c + (N - 1));
}

inline fn left_to_right_diagonal_start(n: usize) Move {
    const offset: i32 = @as(i32, @intCast(n)) - (N - 1);
    const start_r: i32 = if (offset >= 0) offset else 0;
    const start_c: i32 = if (offset >= 0) 0 else -offset;
    return Move.at(start_r, start_c);
}

inline fn left_to_right_diagonal_length(i: usize) usize {
    const offset: i32 = @as(i32, @intCast(i)) - (N - 1); // r-c
    return @intCast(N - @as(i32, @intCast(@abs(offset)))); // length = N - |r-c|
}

inline fn right_to_left_diagonal_index(r: i32, c: i32) usize {
    // r + c in [0 .. 2*N-2]
    return @intCast(r + c);
}

inline fn right_to_left_diagonal_start(n: usize) Move {
    const i: i32 = @intCast(n);
    const start_r: i32 = if (i < N) 0 else i - (N - 1);
    const start_c: i32 = if (i < N) i else N - 1;
    return Move.at(start_r, start_c);
}

inline fn right_to_left_diagonal_length(i: usize) usize {
    const index: i32 = @as(i32, @intCast(i)); // r+c
    return @intCast(if (index < N) (index + 1) else ((2 * N - 1) - index));
}

const DIRECTIONS = [_]struct { r: i32, c: i32 }{
    .{ .r = 1, .c = 0 },
    .{ .r = 0, .c = 1 },
    .{ .r = 1, .c = 1 },
    .{ .r = 1, .c = -1 },
};

pub const Move = struct {
    r: i32,
    c: i32,

    pub inline fn at(r: i32, c: i32) Move {
        return .{ .r = r, .c = c };
    }

    pub inline fn in(self: Move) bool {
        return self.r >= 0 and self.r < N and self.c >= 0 and self.c < N;
    }

    pub inline fn invalid(self: Move) bool {
        return !self.in();
    }
};

pub const Stats = struct {
    analyzed_moves: usize = 0,
    choose_move_time_ns: u64 = 0,

    quiescence_count: usize = 0,

    available_moves_calls: usize = 0,

    check_pattern_calls: usize = 0,
    check_pattern_time_ns: u64 = 0,
    check_pattern_time_avg_ns: u64 = 0,

    check_patterns_calls: usize = 0,
    check_patterns_time_ns: u64 = 0,
    check_patterns_time_avg_ns: u64 = 0,

    pruning_count: usize = 0,
    nodes: usize = 0,
    tt_hits: usize = 0,
    threat_nodes: usize = 0,
    completed_depth: i32 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    pub fn print(self: *const Stats) void {
        output("stats: nodes={}, tt hits={}, threat nodes={}, completed depth={}\n", .{ self.nodes, self.tt_hits, self.threat_nodes, self.completed_depth });
        if (!WASM) {
            output("- placements: {any} in {any}s\n", .{ self.analyzed_moves, ns_to_s(self.choose_move_time_ns) });
            output("- quiescence nodes: {}\n", .{self.quiescence_count});
            output("- available_moves calls: {}\n", .{self.available_moves_calls});
            output("- check_pattern calls: {any}, time(s): {any}, avg(s): {any}\n", .{ self.check_pattern_calls, ns_to_s(self.check_pattern_time_ns), ns_to_s(self.check_pattern_time_avg_ns) });
            output("- a/b pruning count: {any}\n", .{self.pruning_count});
        } else {
            output("- placements: {any}\n", .{self.analyzed_moves});
            output("- quiescence_count: {any}\n", .{self.quiescence_count});
            output("- available_moves calls: {any}\n", .{self.available_moves_calls});
            output("- check_pattern calls: {any}\n", .{self.check_pattern_calls});
            output("- a/b pruning count: {any}\n", .{self.pruning_count});
        }
    }
};

inline fn ns_to_s(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

const DIAGONALS: usize = @intCast(2 * @as(i32, N) - 1);

pub const Game = struct {
    board: [N][N]Field = [_][N]Field{[_]Field{.empty} ** N} ** N,

    // running evaluation = totals[computer] - totals[human]
    evaluation: i32 = 0,

    counters: Stats = Stats{},

    // running sum of all line scores per player:
    // totals[0] = human, totals[1] = computer
    totals: [2]i32 = .{ 0, 0 },

    // caches: score of a single line for each player, -1 = unknown
    row_cache: [N][2]i32 = [_][2]i32{[_]i32{-1} ** 2} ** N,
    col_cache: [N][2]i32 = [_][2]i32{[_]i32{-1} ** 2} ** N,

    // diagonals (↘ and ↙) have 2*N - 1 lines each
    diagonal_left_cache: [DIAGONALS][2]i32 = [_][2]i32{[_]i32{-1} ** 2} ** DIAGONALS, // ↘ (r - c constant)
    diagonal_right_cache: [DIAGONALS][2]i32 = [_][2]i32{[_]i32{-1} ** 2} ** DIAGONALS, // ↙ (r + c constant)

    // Move history for LIFO undo
    move_stack: [NN]Move = undefined,
    stack_len: usize = 0,

    undo_stack: [NN]Undo = undefined,
    hash: u64 = 0,
    tt: [TT_SIZE]TTEntry = @splat(.{}),
    options: SearchOptions = .{},
    deadline: f64 = 0,
    stopped: bool = false,
    last_progress: f64 = 0,
    killers: [MAX_DEPTH][2]Move = @splat(@splat(Move.at(-1, -1))),

    pub inline fn at(self: *const Game, move: Move) Field {
        const r: usize = @intCast(move.r);
        const c: usize = @intCast(move.c);
        return self.board[r][c];
    }

    pub inline fn empty_at(self: *const Game, move: Move) bool {
        return self.at(move) == .empty;
    }

    pub inline fn place_at(self: *Game, r: i32, c: i32, player: Field) void {
        self.place(Move.at(r, c), player);
    }

    pub inline fn place(self: *Game, move: Move, player: Field) void {
        if (move.invalid()) @panic("place: invalid position");
        if (player == .empty) @panic("place: cannot place empty");
        if (self.at(move) != .empty) @panic("place: position already occupied");

        self.counters.analyzed_moves += 1;

        const r: usize = @intCast(move.r);
        const c: usize = @intCast(move.c);
        self.undo_stack[self.stack_len] = .{
            .row = self.row_cache[r],
            .col = self.col_cache[c],
            .left = self.diagonal_left_cache[left_to_right_diagonal_index(move.r, move.c)],
            .right = self.diagonal_right_cache[right_to_left_diagonal_index(move.r, move.c)],
            .totals = self.totals,
        };
        self.hash ^= stone_key(move, player);
        self.board[r][c] = player;

        self.move_stack[self.stack_len] = move;
        self.stack_len += 1;

        self.recompute_lines_at(move);
    }

    pub inline fn unplace_at(self: *Game, r: i32, c: i32) void {
        self.unplace(Move.at(r, c));
    }

    pub inline fn unplace(self: *Game, move: Move) void {
        if (move.invalid()) @panic("unplace: invalid position");
        if (self.at(move) == .empty) @panic("unplace: position already empty");

        const r: usize = @intCast(move.r);
        const c: usize = @intCast(move.c);
        self.hash ^= stone_key(move, self.board[r][c]);
        self.board[r][c] = .empty;

        self.stack_len -= 1;
        std.debug.assert(self.move_stack[self.stack_len].r == move.r and self.move_stack[self.stack_len].c == move.c);

        const undo = self.undo_stack[self.stack_len];
        self.row_cache[r] = undo.row;
        self.col_cache[c] = undo.col;
        self.diagonal_left_cache[left_to_right_diagonal_index(move.r, move.c)] = undo.left;
        self.diagonal_right_cache[right_to_left_diagonal_index(move.r, move.c)] = undo.right;
        self.totals = undo.totals;
        self.evaluation = self.totals[1] - self.totals[0];
    }

    pub fn is_full(self: *const Game) bool {
        var r: i32 = 0;
        while (r < N) : (r += 1) {
            var c: i32 = 0;
            while (c < N) : (c += 1) {
                if (self.empty_at(Move.at(r, c))) return false;
            }
        }
        return true;
    }

    pub fn check_win_at(self: *const Game, move: Move) Field {
        const player = self.at(move);
        if (player == .empty) return .empty;
        inline for (DIRECTIONS) |dir| {
            var count: i32 = 1;
            // forward
            var v = Move.at(move.r + dir.r, move.c + dir.c);
            while (v.in() and self.at(v) == player) : (v = Move.at(v.r + dir.r, v.c + dir.c)) {
                count += 1;
            }
            // backward
            v = Move.at(move.r - dir.r, move.c - dir.c);
            while (v.in() and self.at(v) == player) : (v = Move.at(v.r - dir.r, v.c - dir.c)) {
                count += 1;
            }
            if (count >= 5) return player;
        }
        return .empty;
    }

    pub fn check_pattern(self: *Game, from: Move, dir: Move, player: Field) i32 {
        self.counters.check_pattern_calls += 1;

        var start_time: TimerType = undefined;
        if (!WASM and self.options.profile) {
            start_time = std.Io.Clock.awake.now(io);
        }
        defer {
            if (!WASM and self.options.profile) {
                const elapsed: u64 = @intCast(start_time.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
                self.counters.check_pattern_time_ns += elapsed;
                self.counters.check_pattern_time_avg_ns = (self.counters.check_pattern_time_avg_ns + elapsed) / 2;
            }
        }

        var v = from;
        var buf: [N]u8 = undefined;
        var i: usize = 0;
        while (v.in()) : (v = Move.at(v.r + dir.r, v.c + dir.c)) {
            const field = self.at(v);
            if (field == player) {
                buf[i] = 'G';
            } else if (field == .empty) {
                buf[i] = '_';
            } else {
                buf[i] = '.';
            }
            i += 1;
        }
        const line = buf[0..i];

        var score: i32 = 0;
        inline for (patterns) |pattern| {
            var j: usize = 0;
            const L = pattern.value.len;
            while (j + L <= line.len) : (j += 1) {
                const match = std.mem.eql(u8, line[j .. j + L], pattern.value);
                if (match) {
                    score += pattern.weight;
                    if (score >= 10_000) return score;
                }
            }
        }
        return score;
    }

    inline fn update_player_total(self: *Game, prev: i32, new: i32, player: Field) void {
        const i = player_index(player);
        self.totals[i] += (new - prev);
    }

    fn recompute_row(self: *Game, r: i32) void {
        const start = Move.at(r, 0);
        const dir = Move.at(0, 1);
        inline for (.{ .human, .computer }) |player| {
            const i = player_index(player);
            const prev = if (self.row_cache[@intCast(r)][i] != -1)
                self.row_cache[@intCast(r)][i]
            else
                0;
            const new = self.check_pattern(start, dir, player);
            self.row_cache[@intCast(r)][i] = new;
            self.update_player_total(prev, new, player);
        }
    }

    fn recompute_column(self: *Game, c: i32) void {
        const start = Move.at(0, c);
        const dir = Move.at(1, 0);
        inline for (.{ .human, .computer }) |player| {
            const i = player_index(player);
            const prev = if (self.col_cache[@intCast(c)][i] != -1)
                self.col_cache[@intCast(c)][i]
            else
                0;
            const new = self.check_pattern(start, dir, player);
            self.col_cache[@intCast(c)][i] = new;
            self.update_player_total(prev, new, player);
        }
    }

    fn recompute_left_to_right_diagonal(self: *Game, diagonal: usize) void {
        if (left_to_right_diagonal_length(diagonal) < MIN_EVAL_PATTERN_LEN) {
            inline for (.{ .human, .computer }) |player| {
                const i = player_index(player);
                const prev = if (self.diagonal_left_cache[diagonal][i] != -1) self.diagonal_left_cache[diagonal][i] else 0;
                const new = 0;
                self.diagonal_left_cache[diagonal][i] = new;
                self.update_player_total(prev, new, player);
            }
            return;
        }

        const start = left_to_right_diagonal_start(diagonal);
        const dir = Move.at(1, 1);
        inline for (.{ .human, .computer }) |player| {
            const i = player_index(player);
            const prev = if (self.diagonal_left_cache[diagonal][i] != -1)
                self.diagonal_left_cache[diagonal][i]
            else
                0;
            const new = self.check_pattern(start, dir, player);
            self.diagonal_left_cache[diagonal][i] = new;
            self.update_player_total(prev, new, player);
        }
    }

    fn recompute_right_to_left_diagonal(self: *Game, diagonal: usize) void {
        if (right_to_left_diagonal_length(diagonal) < MIN_EVAL_PATTERN_LEN) {
            inline for (.{ .human, .computer }) |player| {
                const i = player_index(player);
                const prev = if (self.diagonal_right_cache[diagonal][i] != -1) self.diagonal_right_cache[diagonal][i] else 0;
                const new = 0;
                self.diagonal_right_cache[diagonal][i] = new;
                self.update_player_total(prev, new, player);
            }
            return;
        }

        const start = right_to_left_diagonal_start(diagonal);
        const dir = Move.at(1, -1);
        inline for (.{ .human, .computer }) |player| {
            const i = player_index(player);
            const prev = if (self.diagonal_right_cache[diagonal][i] != -1)
                self.diagonal_right_cache[diagonal][i]
            else
                0;
            const new = self.check_pattern(start, dir, player);
            self.diagonal_right_cache[diagonal][i] = new;
            self.update_player_total(prev, new, player);
        }
    }

    fn recompute_lines_at(self: *Game, rc: Move) void {
        self.recompute_row(rc.r);
        self.recompute_column(rc.c);
        self.recompute_left_to_right_diagonal(left_to_right_diagonal_index(rc.r, rc.c));
        self.recompute_right_to_left_diagonal(right_to_left_diagonal_index(rc.r, rc.c));

        self.evaluation = self.totals[player_index(.computer)] - self.totals[player_index(.human)];
    }

    // Batch scanner: useful for validation or profiling.
    pub fn check_patterns(self: *Game, player: Field) i32 {
        self.counters.check_patterns_calls += 1;

        var start_time: TimerType = undefined;
        if (!WASM and self.options.profile) {
            start_time = std.Io.Clock.awake.now(io);
        }
        defer {
            if (!WASM and self.options.profile) {
                const elapsed: u64 = @intCast(start_time.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
                self.counters.check_patterns_time_ns += elapsed;
                self.counters.check_patterns_time_avg_ns = (self.counters.check_patterns_time_avg_ns + elapsed) / 2;
            }
        }

        var score: i32 = 0;

        // rows
        inline for (0..N) |r|
            score += self.check_pattern(Move.at(@intCast(r), 0), Move.at(0, 1), player);

        // columns
        inline for (0..N) |c|
            score += self.check_pattern(Move.at(0, @intCast(c)), Move.at(1, 0), player);

        // diagonal ↘
        inline for (0..@intCast(DIAGONALS)) |k| {
            if (left_to_right_diagonal_length(k) >= MIN_EVAL_PATTERN_LEN) {
                score += self.check_pattern(left_to_right_diagonal_start(k), Move.at(1, 1), player);
            }
        }

        // diagonal ↙
        inline for (0..@intCast(DIAGONALS)) |k| {
            if (right_to_left_diagonal_length(k) >= MIN_EVAL_PATTERN_LEN) {
                score += self.check_pattern(right_to_left_diagonal_start(k), Move.at(1, -1), player);
            }
        }
        return score;
    }

    pub inline fn evaluate_static(self: *Game) i32 {
        return self.evaluation;
    }

    const TimerType = if (WASM) void else std.Io.Timestamp;

    // Inspect a hypothetical move without modifying caches, counters, or history.
    pub fn would_win(self: *const Game, move: Move, player: Field) bool {
        if (!move.in() or !self.empty_at(move)) return false;
        for (DIRECTIONS) |dir| {
            var count: usize = 1;
            for ([_]i32{ -1, 1 }) |sign| {
                var m = Move.at(move.r + sign * dir.r, move.c + sign * dir.c);
                while (m.in() and self.at(m) == player) : (m = Move.at(m.r + sign * dir.r, m.c + sign * dir.c)) {
                    count += 1;
                }
            }
            if (count >= 5) return true;
        }
        return false;
    }

    pub fn threat_at(self: *const Game, move: Move, player: Field) Threat {
        var result: Threat = .{};
        if (!move.in() or !self.empty_at(move)) return result;
        for (DIRECTIONS) |dir| {
            var line: [11]u8 = undefined;
            for (&line, 0..) |*cell, i| {
                const offset = @as(i32, @intCast(i)) - 5;
                const m = Move.at(move.r + offset * dir.r, move.c + offset * dir.c);
                cell.* = if (i == 5) 'X' else if (!m.in()) '.' else switch (self.at(m)) {
                    .empty => '_',
                    else => |p| if (p == player) 'X' else '.',
                };
            }
            var gaps: [11]bool = @splat(false);
            for (1..6) |start| {
                var stones: usize = 0;
                var empty: usize = 0;
                var gap: usize = 0;
                for (start..start + 5) |i| {
                    if (line[i] == 'X') stones += 1;
                    if (line[i] == '_') {
                        empty += 1;
                        gap = i;
                    }
                }
                if (stones == 5) result.win = true;
                if (stones == 4 and empty == 1) gaps[gap] = true;
            }
            for (gaps) |gap| {
                if (gap) result.fours += 1;
            }
            var three = false;
            var two = false;
            inline for (.{ "_XXX_", "_XX_X_", "_X_XX_" }) |pattern| {
                for (0..line.len - pattern.len + 1) |start| {
                    if (start <= 5 and start + pattern.len > 5 and std.mem.eql(u8, line[start..][0..pattern.len], pattern)) three = true;
                }
            }
            inline for (.{ "_XX_", "_X_X_" }) |pattern| {
                for (0..line.len - pattern.len + 1) |start| {
                    if (start <= 5 and start + pattern.len > 5 and std.mem.eql(u8, line[start..][0..pattern.len], pattern)) two = true;
                }
            }
            if (three) result.threes += 1;
            if (two) result.twos += 1;
        }
        return result;
    }

    fn nearby(self: *const Game, m: Move) bool {
        var dr: i32 = -2;
        while (dr <= 2) : (dr += 1) {
            var dc: i32 = -2;
            while (dc <= 2) : (dc += 1) {
                const v = Move.at(m.r + dr, m.c + dc);
                if (v.in() and !self.empty_at(v)) return true;
            }
        }
        return false;
    }

    // Canonical board scan and coordinate tie breaks make pruning independent
    // of move history, which is essential for transposition-table reuse.
    pub fn available_moves(self: *Game, backing: *[NN]Move) []Move {
        self.counters.available_moves_calls += 1;
        if (self.stack_len == 0) {
            backing[0] = Move.at(N / 2, N / 2);
            return backing[0..1];
        }
        var scores: [NN]i32 = undefined;
        var n: usize = 0;
        var critical_count: usize = 0;
        for (0..N) |r| {
            for (0..N) |c| {
                const m = Move.at(@intCast(r), @intCast(c));
                if (!self.empty_at(m) or !self.nearby(m)) continue;
                const a = self.threat_at(m, .computer);
                const b = self.threat_at(m, .human);
                const critical = a.critical() or b.critical();
                if (critical) critical_count += 1;
                const score = @max(a.value(), b.value()) * 2 + @min(a.value(), b.value()) + @as(i32, if (critical) 4_000_000 else 0);
                var j = n;
                while (j > 0 and scores[j - 1] < score) : (j -= 1) {
                    scores[j] = scores[j - 1];
                    backing[j] = backing[j - 1];
                }
                scores[j] = score;
                backing[j] = m;
                n += 1;
            }
        }
        return backing[0..@min(n, @max(32, critical_count))];
    }

    const Tactics = struct {
        win: ?Move = null,
        block: ?Move = null,
        opponent_wins: usize = 0,
    };

    fn tactics(self: *const Game, player: Field) Tactics {
        var result: Tactics = .{};
        for (0..N) |r| {
            for (0..N) |c| {
                const m = Move.at(@intCast(r), @intCast(c));
                if (!self.empty_at(m)) continue;
                if (self.would_win(m, player)) result.win = m;
                if (self.would_win(m, opponent(player))) {
                    result.block = m;
                    result.opponent_wins += 1;
                }
            }
        }
        return result;
    }

    fn stop(self: *Game) bool {
        if (self.stopped) return true;
        if (self.options.node_limit > 0 and self.counters.nodes + self.counters.threat_nodes >= self.options.node_limit) self.stopped = true;
        if (self.options.time_ms > 0 and milliseconds() >= self.deadline) self.stopped = true;
        return self.stopped;
    }

    fn order_moves(self: *const Game, moves: []Move, player: Field, preferred: Move, ply: i32) void {
        var scores: [NN]i32 = undefined;
        for (moves, 0..) |m, i| {
            const own = self.threat_at(m, player);
            const other = self.threat_at(m, opponent(player));
            const killers = self.killers[@min(MAX_DEPTH - 1, @as(usize, @intCast(ply)))];
            const killer_bonus: i32 = if (same_move(m, killers[0]) or same_move(m, killers[1])) 300 else 0;
            const score = if (same_move(m, preferred)) 10_000_000 else own.value() * 2 + other.value() + killer_bonus;
            var j = i;
            while (j > 0 and scores[j - 1] < score) : (j -= 1) {
                scores[j] = scores[j - 1];
                moves[j] = moves[j - 1];
            }
            scores[j] = score;
            moves[j] = m;
        }
    }

    pub fn choose_move(self: *Game, depth: i32, player: Field) Move {
        return self.search(.{ .max_depth = depth, .time_ms = 0, .progress = !builtin.is_test }, player).move;
    }

    pub fn search(self: *Game, options: SearchOptions, player: Field) SearchResult {
        std.debug.assert(player != .empty);
        self.options = options;
        self.counters.reset();
        self.stopped = false;
        self.killers = @splat(@splat(Move.at(-1, -1)));
        // Clear across calls because extension settings may have changed. Entries
        // remain reusable across all iterations within this search.
        for (&self.tt) |*entry| entry.depth = -1;
        const start = milliseconds();
        self.deadline = start + @as(f64, @floatFromInt(options.time_ms));
        self.last_progress = start;
        defer self.counters.choose_move_time_ns = @intFromFloat(@max(0, milliseconds() - start) * std.time.ns_per_ms);
        if (self.is_full()) return .{ .move = Move.at(-1, -1) };

        const tactical = self.tactics(player);
        if (tactical.win) |win| return .{ .move = win, .score = mate(player, 1) };
        if (tactical.opponent_wins >= 2) return .{ .move = tactical.block.?, .score = mate(opponent(player), 2) };
        var backing: [NN]Move = undefined;
        const moves = if (tactical.block) |block| blk: {
            backing[0] = block;
            break :blk backing[0..1];
        } else self.available_moves(&backing);
        self.order_moves(moves, player, Move.at(-1, -1), 0);
        var result: SearchResult = .{ .move = moves[0], .score = self.evaluate_static() };
        if (self.stack_len == 0) return result;
        var depth: i32 = 1;
        while (depth <= @min(MAX_DEPTH - 1, @max(1, options.max_depth))) : (depth += 1) {
            self.order_moves(moves, player, result.move, 0);
            var best = moves[0];
            var score: i32 = if (player == .computer) -WIN * 2 else WIN * 2;
            var alpha: i32 = -WIN * 2;
            var beta: i32 = WIN * 2;
            for (moves, 0..) |m, i| {
                if (self.stop()) break;
                self.place(m, player);
                const value = self.minimax(depth - 1, opponent(player), alpha, beta, m, 1);
                self.unplace(m);
                if (self.stopped) break;
                if ((player == .computer and value > score) or (player == .human and value < score)) {
                    score = value;
                    best = m;
                }
                if (player == .computer) alpha = @max(alpha, score) else beta = @min(beta, score);
                if (options.progress and milliseconds() - self.last_progress >= 100) {
                    progress(i + 1, moves.len, best, self);
                    self.last_progress = milliseconds();
                }
            }
            if (self.stopped) break;
            result = .{ .move = best, .score = score, .completed_depth = depth };
            self.counters.completed_depth = depth;
            if (@abs(score) >= WIN - NN) break;
            // Prove continuous-four attacks separately from the general search.
            // Failure means unknown, never a proven loss.
            if (depth == 1 and options.threat_depth > 0) {
                if (self.prove_fours(player, @min(options.threat_depth, 16))) |proof| {
                    if (!self.stopped) {
                        result.move = proof.move;
                        result.score = mate(player, proof.plies);
                    }
                    break;
                }
            }
        }
        result.timed_out = self.stopped;
        return result;
    }

    fn tt_score(score: i32, ply: i32, store: bool) i32 {
        const adjustment = if (store) ply else -ply;
        if (score >= WIN - NN) return score + adjustment;
        if (score <= -WIN + @as(i32, NN)) return score - adjustment;
        return score;
    }

    fn minimax(self: *Game, depth: i32, player: Field, alpha_: i32, beta_: i32, entry_move: Move, ply: i32) i32 {
        if (self.check_win_at(entry_move) != .empty) return mate(opponent(player), ply);
        if (depth <= 0) return self.quiescence(QDEPTH, player, alpha_, beta_, ply);
        self.counters.nodes += 1;
        if (self.stop()) return 0;
        if (self.is_full()) return 0;
        const tactical = self.tactics(player);
        if (tactical.win != null) return mate(player, ply + 1);
        if (tactical.opponent_wins >= 2) return mate(opponent(player), ply + 2);
        const key = self.hash ^ (if (player == .computer) @as(u64, 0xa0761d6478bd642f) else 0xe7037ed1a0b428db);
        const slot: usize = @intCast(key % TT_SIZE);
        const entry = self.tt[slot];
        var preferred = Move.at(-1, -1);
        if (self.options.use_tt and entry.depth >= 0 and entry.key == key) {
            preferred = entry.move;
            self.counters.tt_hits += 1;
            const score = tt_score(entry.score, ply, false);
            if (entry.depth >= depth) {
                if (entry.bound == .exact or (entry.bound == .lower and score >= beta_) or (entry.bound == .upper and score <= alpha_)) return score;
            }
        }
        var backing: [NN]Move = undefined;
        const moves = if (tactical.block) |block| blk: {
            backing[0] = block;
            break :blk backing[0..1];
        } else self.available_moves(&backing);
        self.order_moves(moves, player, preferred, ply);
        var alpha = alpha_;
        var beta = beta_;
        var best = moves[0];
        var value: i32 = if (player == .computer) -WIN * 2 else WIN * 2;
        for (moves) |m| {
            self.place(m, player);
            const score = self.minimax(depth - 1, opponent(player), alpha, beta, m, ply + 1);
            self.unplace(m);
            if (self.stopped) return 0;
            if ((player == .computer and score > value) or (player == .human and score < value)) {
                value = score;
                best = m;
            }
            if (player == .computer) alpha = @max(alpha, value) else beta = @min(beta, value);
            if (alpha >= beta) {
                self.counters.pruning_count += 1;
                const killers = &self.killers[@min(MAX_DEPTH - 1, @as(usize, @intCast(ply)))];
                if (!same_move(m, killers[0])) {
                    killers[1] = killers[0];
                    killers[0] = m;
                }
                break;
            }
        }
        if (self.options.use_tt) self.tt[slot] = .{
            .key = key,
            .depth = depth,
            .score = tt_score(value, ply, true),
            .bound = if (value <= alpha_) .upper else if (value >= beta_) .lower else .exact,
            .move = best,
        };
        return value;
    }

    fn quiescence(self: *Game, depth: i32, player: Field, alpha_: i32, beta_: i32, ply: i32) i32 {
        self.counters.nodes += 1;
        self.counters.quiescence_count += 1;
        if (self.stop()) return 0;
        if (self.is_full()) return 0;
        const tactical = self.tactics(player);
        if (tactical.win != null) return mate(player, ply + 1);
        if (tactical.opponent_wins >= 2) return mate(opponent(player), ply + 2);
        // Never stand pat while a forced block is pending, even at depth zero.
        if (tactical.block) |block| {
            self.place(block, player);
            defer self.unplace(block);
            return self.quiescence(depth - 1, opponent(player), alpha_, beta_, ply + 1);
        }
        var value = self.evaluate_static();
        if (depth <= 0) return value;
        var alpha = alpha_;
        var beta = beta_;
        if (player == .computer) {
            if (value >= beta) return value;
            alpha = @max(alpha, value);
        } else {
            if (value <= alpha) return value;
            beta = @min(beta, value);
        }
        var backing: [NN]Move = undefined;
        const candidates = self.available_moves(&backing);
        var n: usize = 0;
        for (candidates) |m| {
            const threat = self.threat_at(m, player);
            if (threat.fours > 0 or threat.threes >= 2) {
                backing[n] = m;
                n += 1;
            }
        }
        const moves = backing[0..n];
        self.order_moves(moves, player, Move.at(-1, -1), ply);
        for (moves) |m| {
            self.place(m, player);
            const score = self.quiescence(depth - 1, opponent(player), alpha, beta, ply + 1);
            self.unplace(m);
            if (self.stopped) return 0;
            if (player == .computer) {
                value = @max(value, score);
                alpha = @max(alpha, value);
            } else {
                value = @min(value, score);
                beta = @min(beta, value);
            }
            if (alpha >= beta) break;
        }
        return value;
    }

    const Proof = struct { move: Move, plies: i32 };

    fn prove_fours(self: *Game, attacker: Field, depth: i32) ?Proof {
        if (depth <= 0 or self.counters.threat_nodes >= 256) return null;
        self.counters.threat_nodes += 1;
        if (self.stop()) return null;
        const tactical = self.tactics(attacker);
        if (tactical.win) |m| return .{ .move = m, .plies = 1 };
        if (tactical.opponent_wins >= 2) return null;
        var backing: [NN]Move = undefined;
        const moves = self.available_moves(&backing);
        for (moves) |m| {
            if (self.stop()) return null;
            if (tactical.block) |block| {
                if (!same_move(m, block)) continue;
            }
            if (self.threat_at(m, attacker).fours == 0) continue;
            self.place(m, attacker);
            const defense = self.tactics(opponent(attacker));
            var proof: ?Proof = null;
            if (defense.win == null) {
                if (defense.opponent_wins >= 2) {
                    proof = .{ .move = m, .plies = 3 };
                } else if (defense.block) |block| {
                    self.place(block, opponent(attacker));
                    const continuation = self.prove_fours(attacker, depth - 1);
                    self.unplace(block);
                    if (continuation) |p| proof = .{ .move = m, .plies = p.plies + 2 };
                }
            }
            self.unplace(m);
            if (proof != null) return proof;
        }
        return null;
    }

    pub fn print_board(self: *const Game) void {
        output("\n", .{});
        for (self.board, 0..) |row, r| {
            output("{d: <2} | ", .{r});
            for (row) |field| {
                const c: u8 = switch (field) {
                    .empty => '.',
                    .human => 'X',
                    .computer => 'O',
                };
                output("{c} ", .{c});
            }
            output("\n", .{});
        }
    }

    const ANSI_RESET = "\x1b[0m";

    const ANSI_GREEN = "\x1b[32m";
    const ANSI_YELLOW = "\x1b[33m";
    const ANSI_MAGENTA = "\x1b[35m";
    const ANSI_CYAN = "\x1b[36m";

    const ANSI_BOLD = "\x1b[1m";

    pub fn print_board_at(self: *const Game, move: Move) void {
        output("\n", .{});
        for (self.board, 0..) |row, r| {
            output("{d: <2} | ", .{r});
            const first: u8 = if (r == move.r and move.c == 0) '[' else ' ';
            output("{c}", .{first});
            for (row, 0..) |field, c| {
                const v: struct { color: []const u8, player: u8 } = switch (field) {
                    .empty => .{ .color = ANSI_GREEN, .player = '.' },
                    .human => .{ .color = ANSI_MAGENTA, .player = 'X' },
                    .computer => .{ .color = ANSI_CYAN, .player = 'O' },
                };
                const f = Move.at(@intCast(r), @intCast(c));
                const is_move = (move.r == f.r and move.c == f.c);
                const bold = if (is_move) ANSI_BOLD else "";

                const bracket: u8 = if (r == move.r and c == move.c) ']' else (if (r == move.r and c == move.c - 1) '[' else ' ');
                output("{s}{s}{c}{s}{c}", .{ v.color, bold, v.player, ANSI_RESET, bracket });
            }
            output("\n", .{});
        }
    }

    pub fn init() Game {
        var game = Game{};
        for (0..N) |r| {
            for (0..N) |c| {
                game.board[@intCast(r)][@intCast(c)] = .empty;
            }
        }
        return game;
    }
};

pub fn main() void {
    loopback();
}

pub export fn loopback() void {
    var game = Game.init();

    const first_move = Move.at(7, 7);
    game.place(first_move, .human);
    game.print_board_at(first_move);

    var player: Field = .computer;
    while (true) {
        output("thinking...\n", .{});
        const move = game.search(.{ .time_ms = 1000, .progress = true }, player).move;
        if (move.invalid()) {
            output("draw\n", .{});
            break;
        }
        game.place(move, player);
        game.print_board_at(move);
        output("{any}: {any}\n", .{ player, move });

        const winner = game.check_win_at(move);
        if (winner != .empty) {
            output("winner: {any}\n", .{winner});
            break;
        }
        player = if (player == .computer) .human else .computer;

        game.counters.print();

        wait_enter() catch {};
    }
}

pub const patterns: [18]Pattern = [_]Pattern{
    Pattern{ .value = "GGGGG", .weight = 10000 },
    Pattern{ .value = "_GGGG_", .weight = 5000 },
    Pattern{ .value = "GGG_G", .weight = 500 },
    Pattern{ .value = "GG_GG", .weight = 500 },
    Pattern{ .value = "G_GGG", .weight = 500 },
    Pattern{ .value = "_GGGG", .weight = 500 },
    Pattern{ .value = "GGGG_", .weight = 500 },
    Pattern{ .value = "_GGG_", .weight = 200 },
    Pattern{ .value = "_GG_G_", .weight = 100 },
    Pattern{ .value = "_G_GG_", .weight = 100 },
    Pattern{ .value = "GGG_", .weight = 20 },
    Pattern{ .value = "_GGG", .weight = 20 },
    Pattern{ .value = "_GG_", .weight = 5 },
    Pattern{ .value = "_G_G_", .weight = 5 },
    Pattern{ .value = "_GG", .weight = 1 },
    Pattern{ .value = "GG_", .weight = 1 },
    Pattern{ .value = "_G__G_", .weight = 5 },
    Pattern{ .value = "_G_G_G_", .weight = 100 },
};

const Pattern = struct {
    value: []const u8,
    weight: i32,
};

pub fn wait_enter() !void {
    if (WASM) {
        enter();
        return;
    }

    output("press enter to continue...\n", .{});

    var in_buf: [64]u8 = undefined;
    var in_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const input = &in_reader.interface;
    while (true) {
        const b = input.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (b == '\n') break;
    }
}

pub fn output(comptime fmt: []const u8, args: anytype) void {
    if (WASM) {
        var buffer: [1024]u8 = undefined;
        const v = std.fmt.bufPrint(&buffer, fmt, args) catch return;
        console(v.ptr, v.len);
    } else {
        std.debug.print(fmt, args);
    }
}

pub fn progress(i: usize, n: usize, move: Move, game: *const Game) void {
    if (builtin.is_test) {
        return;
    }

    const crlf = if (i == n) "\n" else "\r";
    const percent: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) * 100.0;

    var buffer: [1024]u8 = undefined;
    const fmt = "{any: <.2}% ({any}/{any}) ({d}) [{d} : {d}] {s}";

    const stats = game.counters;
    const args = .{ percent, i, n, stats.nodes, move.r, move.c, crlf };

    const v = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    output("{s}", .{v});

    if (WASM) {
        status(v.ptr, v.len);
    }
}

test "quiescence recognizes forced loss and extends mandatory blocks beyond horizon" {
    var game = Game.init();
    game.options.time_ms = 0;
    for (4..8) |c| game.place(Move.at(7, @intCast(c)), .human);
    try testing.expectEqual(-WIN + 2, game.quiescence(0, .computer, -WIN * 2, WIN * 2, 0));
    game.place(Move.at(7, 3), .computer);
    const hash = game.hash;
    const score = game.quiescence(0, .computer, -WIN * 2, WIN * 2, 0);
    game.place(Move.at(7, 8), .computer);
    try testing.expectEqual(game.evaluate_static(), score);
    game.unplace(Move.at(7, 8));
    try testing.expectEqual(hash, game.hash);
}

test "continuous-four proof finds a forcing chain and restores state" {
    var game = Game.init();
    game.options.time_ms = 0;
    for ([_]Move{ Move.at(7, 4), Move.at(7, 5), Move.at(7, 6), Move.at(4, 7), Move.at(5, 7) }) |m| game.place(m, .computer);
    game.place(Move.at(7, 3), .human);
    const hash = game.hash;
    const evaluation = game.evaluation;
    const proof = game.prove_fours(.computer, 4);
    try testing.expect(proof != null);
    try testing.expect(proof.?.plies >= 3 and proof.?.plies <= 9);
    try testing.expectEqual(hash, game.hash);
    try testing.expectEqual(evaluation, game.evaluation);
    try testing.expectEqual(6, game.stack_len);
    // An opponent's immediate win must not be ignored by a purported proof.
    for (2..6) |c| game.place(Move.at(0, @intCast(c)), .human);
    try testing.expect(game.prove_fours(.computer, 4) == null);
}
