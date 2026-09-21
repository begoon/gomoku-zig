const std = @import("std");
const allocator = std.heap.wasm_allocator;

const gomoku = @import("gomoku.zig");

inline fn castHandle(handle: usize) *gomoku.Game {
    if (handle == 0) @panic("invalid handle: 0");
    return @ptrFromInt(handle);
}

pub export fn alloc() usize {
    const game = allocator.create(gomoku.Game) catch @panic("allocation failed");
    return @intFromPtr(game);
}

pub export fn free(handle: usize) void {
    allocator.destroy(castHandle(handle));
}

pub export fn init(handle: usize) void {
    const game = castHandle(handle);
    game.* = gomoku.Game.init();
}

pub export fn place(handle: usize, r: i32, c: i32, player: i32) void {
    gomoku.output("wasm/place: r={}, c={}, player={}\n", .{ r, c, player });
    const move = gomoku.Move{ .r = r, .c = c };
    if (player == 0) {
        gomoku.output("wasm/place: invalid player: {}\n", .{player});
        @panic("wasm/place: invalid player: 0");
    }
    castHandle(handle).place(move, if (player == 1) gomoku.Field.human else gomoku.Field.computer);
}

pub export fn unplace(handle: usize, r: i32, c: i32) void {
    const move = gomoku.Move{ .r = r, .c = c };
    castHandle(handle).unplace(move);
}

pub export fn choose_move(handle: usize, depth: i32, player: i32) i32 {
    gomoku.output("wasm/choose_move: depth={}, player={}\n", .{ depth, player });
    const game = castHandle(handle);
    if (player == 0) {
        gomoku.output("wasm/choose_move: invalid player: {}\n", .{player});
        @panic("wasm/choose_move: invalid player: 0");
    }
    const field = if (player == 1) gomoku.Field.human else gomoku.Field.computer;
    const move = game.choose_move(depth, field);
    if (move.invalid()) return -1;
    return (move.r << 8) + move.c;
}

// A negative move means the board is full.
pub export fn choose_move_timed(handle: usize, time_ms: u32, player: i32) i32 {
    if (player != 1 and player != 2) @panic("invalid player");
    const result = castHandle(handle).search(.{
        .time_ms = @max(1, time_ms),
        .progress = true,
    }, if (player == 1) .human else .computer);
    if (result.move.invalid()) return -1;
    return (result.move.r << 8) + result.move.c;
}

pub export fn search_nodes(handle: usize) usize {
    return castHandle(handle).counters.nodes;
}

pub export fn search_depth(handle: usize) i32 {
    return castHandle(handle).counters.completed_depth;
}

pub export fn is_winner(handle: usize, r: i32, c: i32) i32 {
    const game = castHandle(handle);
    const move = gomoku.Move{ .r = r, .c = c };
    const v = game.check_win_at(move);
    return switch (v) {
        gomoku.Field.empty => 0,
        gomoku.Field.human => 1,
        gomoku.Field.computer => 2,
    };
}

pub export fn print_board(handle: usize) void {
    castHandle(handle).print_board();
}

pub export fn print_board_at(handle: usize, r: i32, c: i32) void {
    castHandle(handle).print_board_at((gomoku.Move{ .r = r, .c = c }));
}
