const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig").c;

pub const Data = opaque {
    pub fn createWithBytesNoCopy(data: []const u8) Allocator.Error!*Data {
        return @as(
            ?*Data,
            @ptrFromInt(@intFromPtr(c.CFDataCreateWithBytesNoCopy(
                null,
                data.ptr,
                @intCast(data.len),
                c.kCFAllocatorNull,
            ))),
        ) orelse error.OutOfMemory;
    }

    pub fn release(self: *Data) void {
        foundation.CFRelease(self);
    }

    pub fn getPointer(self: *Data) [*]const u8 {
        return @ptrCast(c.CFDataGetBytePtr(@ptrCast(self)));
    }

    pub fn getLength(self: *Data) usize {
        return @intCast(c.CFDataGetLength(@ptrCast(self)));
    }
};

test {
    //const testing = std.testing;

    const raw = "hello world";
    const data = try Data.createWithBytesNoCopy(raw);
    defer data.release();
}
