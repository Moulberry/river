// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2021 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// This is an implementation of the  default "tiled" layout of dwm and the
// 3 other orientations thereof. This code is written for the main stack
// to the left and then the input/output values are adjusted to apply
// the necessary transformations to derive the other orientations.
//
// With 4 views and one main on the left, the layout looks something like this:
//
// +-----------------------+------------+
// |                       |            |
// |                       |            |
// |                       |            |
// |                       +------------+
// |                       |            |
// |                       |            |
// |                       |            |
// |                       +------------+
// |                       |            |
// |                       |            |
// |                       |            |
// +-----------------------+------------+

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Location = enum {
    top,
    right,
    bottom,
    left,
};

const default_main_location: Location = .left;
const default_main_count = 1;
const default_main_factor = 0.6;
const default_view_padding = 6;
const default_outer_padding = 6;

/// We don't free resources on exit, only when output globals are removed.
const gpa = std.heap.c_allocator;

const Context = struct {
    initialized: bool = false,
    layout_manager: ?*river.LayoutManagerV1 = null,
    outputs: std.TailQueue(Output) = .{},

    fn addOutput(context: *Context, registry: *wl.Registry, name: u32) !void {
        const wl_output = try registry.bind(name, wl.Output, 3);
        errdefer wl_output.release();
        const node = try gpa.create(std.TailQueue(Output).Node);
        errdefer gpa.destroy(node);
        try node.data.init(context, wl_output, name);
        context.outputs.append(node);
    }
};

const Output = struct {
    wl_output: *wl.Output,
    name: u32,

    layout: *river.LayoutV1 = undefined,

    fn init(output: *Output, context: *Context, wl_output: *wl.Output, name: u32) !void {
        output.* = .{ .wl_output = wl_output, .name = name };
        if (context.initialized) try output.getLayout(context);
    }

    fn getLayout(output: *Output, context: *Context) !void {
        assert(context.initialized);
        output.layout = try context.layout_manager.?.getLayout(output.wl_output, "rivertile");
        output.layout.setListener(*Output, layoutListener, output) catch unreachable;
    }

    fn deinit(output: *Output) void {
        output.wl_output.release();
        output.layout.destroy();
    }

    fn layoutListener(layout: *river.LayoutV1, event: river.LayoutV1.Event, output: *Output) void {
        switch (event) {
            .namespace_in_use => fatal("namespace 'rivertile' already in use.", .{}),

            .layout_demand => |ev| {
                const secondary_count = if (ev.view_count > default_main_count)
                    ev.view_count - default_main_count
                else
                    0;

                const usable_width = switch (default_main_location) {
                    .left, .right => ev.usable_width - 2 * default_outer_padding,
                    .top, .bottom => ev.usable_height - 2 * default_outer_padding,
                };
                const usable_height = switch (default_main_location) {
                    .left, .right => ev.usable_height - 2 * default_outer_padding,
                    .top, .bottom => ev.usable_width - 2 * default_outer_padding,
                };

                // to make things pixel-perfect, we make the first main and first secondary
                // view slightly larger if the height is not evenly divisible
                var main_width: u32 = undefined;
                var main_height: u32 = undefined;
                var main_height_rem: u32 = undefined;

                var secondary_width: u32 = undefined;
                var secondary_height: u32 = undefined;
                var secondary_height_rem: u32 = undefined;

                if (default_main_count > 0 and secondary_count > 0) {
                    main_width = @floatToInt(u32, default_main_factor * @intToFloat(f64, usable_width));
                    main_height = usable_height / default_main_count;
                    main_height_rem = usable_height % default_main_count;

                    secondary_width = usable_width - main_width;
                    secondary_height = usable_height / secondary_count;
                    secondary_height_rem = usable_height % secondary_count;
                } else if (default_main_count > 0) {
                    main_width = usable_width;
                    main_height = usable_height / default_main_count;
                    main_height_rem = usable_height % default_main_count;
                } else if (secondary_width > 0) {
                    main_width = 0;
                    secondary_width = usable_width;
                    secondary_height = usable_height / secondary_count;
                    secondary_height_rem = usable_height % secondary_count;
                }

                var i: u32 = 0;
                while (i < ev.view_count) : (i += 1) {
                    var x: i32 = undefined;
                    var y: i32 = undefined;
                    var width: u32 = undefined;
                    var height: u32 = undefined;

                    if (i < default_main_count) {
                        x = 0;
                        y = @intCast(i32, (i * main_height) + if (i > 0) main_height_rem else 0);
                        width = main_width;
                        height = main_height + if (i == 0) main_height_rem else 0;
                    } else {
                        x = @intCast(i32, main_width);
                        y = @intCast(i32, (i - default_main_count) * secondary_height +
                            if (i > default_main_count) secondary_height_rem else 0);
                        width = secondary_width;
                        height = secondary_height + if (i == default_main_count) secondary_height_rem else 0;
                    }

                    x += @intCast(i32, default_view_padding);
                    y += @intCast(i32, default_view_padding);
                    width -= 2 * default_view_padding;
                    height -= 2 * default_view_padding;

                    switch (default_main_location) {
                        .left => layout.pushViewDimensions(
                            ev.serial,
                            x + @intCast(i32, default_outer_padding),
                            y + @intCast(i32, default_outer_padding),
                            width,
                            height,
                        ),
                        .right => layout.pushViewDimensions(
                            ev.serial,
                            @intCast(i32, usable_width - width) - x + @intCast(i32, default_outer_padding),
                            y + @intCast(i32, default_outer_padding),
                            width,
                            height,
                        ),
                        .top => layout.pushViewDimensions(
                            ev.serial,
                            y + @intCast(i32, default_outer_padding),
                            x + @intCast(i32, default_outer_padding),
                            height,
                            width,
                        ),
                        .bottom => layout.pushViewDimensions(
                            ev.serial,
                            y + @intCast(i32, default_outer_padding),
                            @intCast(i32, usable_width - width) - x + @intCast(i32, default_outer_padding),
                            height,
                            width,
                        ),
                    }
                }

                layout.commit(ev.serial);
            },

            .advertise_view => {},
            .advertise_done => {},
        }
    }
};

pub fn main() !void {
    const display = wl.Display.connect(null) catch {
        std.debug.warn("Unable to connect to Wayland server.\n", .{});
        std.os.exit(1);
    };
    defer display.disconnect();

    var context: Context = .{};

    const registry = try display.getRegistry();
    registry.setListener(*Context, registryListener, &context) catch unreachable;
    _ = try display.roundtrip();

    if (context.layout_manager == null) {
        fatal("wayland compositor does not support river_layout_v1.\n", .{});
    }

    context.initialized = true;

    var it = context.outputs.first;
    while (it) |node| : (it = node.next) {
        const output = &node.data;
        try output.getLayout(&context);
    }

    while (true) _ = try display.dispatch();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, river.LayoutManagerV1.getInterface().name) == 0) {
                context.layout_manager = registry.bind(global.name, river.LayoutManagerV1, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                context.addOutput(registry, global.name) catch |err| fatal("failed to bind output: {}", .{err});
            }
        },
        .global_remove => |ev| {
            var it = context.outputs.first;
            while (it) |node| : (it = node.next) {
                const output = &node.data;
                if (output.name == ev.name) {
                    context.outputs.remove(node);
                    output.deinit();
                    gpa.destroy(node);
                    break;
                }
            }
        },
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.os.exit(1);
}
