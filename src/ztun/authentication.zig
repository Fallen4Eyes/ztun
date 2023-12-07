// Copyright 2022 - Corentin Godeau and the ztun contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const io = @import("io.zig");

/// Stores the parameter required for the Short-term authentication mechanism.
pub const ShortTermAuthentication = struct {
    /// Stores the password of the user.
    password: []const u8,

    /// Computes the authentication key corresponding to the stored parameters and tries to place the result in the given buffer.
    /// Returns the amount of bytes written.
    pub fn computeKey(self: ShortTermAuthentication, out: []u8) !usize {
        var stream = std.io.fixedBufferStream(out);
        try io.writeOpaqueString(self.password, stream.writer());
        return stream.getWritten().len;
    }

    /// Computes the authentication key corresponding to the stored parameters and tries to allocate the required.
    /// Returns the buffer containing the computed key.
    pub fn computeKeyAlloc(self: ShortTermAuthentication, allocator: std.mem.Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, self.password.len * 2);
        errdefer allocator.free(buffer);
        const bytes_written = try self.computeKey(buffer);
        return try allocator.realloc(buffer, bytes_written);
    }
};

/// Stores the parameter required for the Long-term authentication mechanism.
pub const LongTermAuthentication = struct {
    /// Stores the username of the user.
    username: []const u8,
    /// Stores the password of the user.
    password: []const u8,
    /// Stores the realm given to the user.
    realm: []const u8,

    /// Computes the authentication key corresponding to the stored parameters and tries to place the result in the given buffer.
    /// Returns the amount of bytes written.
    pub fn computeKey(self: LongTermAuthentication, out: []u8) !usize {
        var md5_stream = io.Md5Stream.init();
        var md5_writer = md5_stream.writer();
        try md5_writer.writeAll(self.username);
        try md5_writer.writeByte(':');
        try io.writeOpaqueString(self.realm, md5_writer);
        try md5_writer.writeByte(':');
        try io.writeOpaqueString(self.password, md5_writer);
        md5_writer.context.state.final(out[0..std.crypto.hash.Md5.digest_length]);
        return std.crypto.hash.Md5.digest_length;
    }

    /// Computes the authentication key corresponding to the stored parameters and tries to allocate the required.
    /// Returns the buffer containing the computed key.
    pub fn computeKeyAlloc(self: LongTermAuthentication, allocator: std.mem.Allocator) ![]u8 {
        var buffer = try allocator.alloc(u8, std.crypto.hash.Md5.digest_length);
        errdefer allocator.free(buffer);
        const bytes_written = try self.computeKey(buffer);
        return buffer[0..bytes_written];
    }
};

/// Dummy struct to handle the case when there is no authentication
pub const NoneAuthentication = struct {
    pub fn computeKey(self: NoneAuthentication, out: []u8) !usize {
        _ = self;
        _ = out;
        return 0;
    }

    pub fn computeKeyAlloc(self: NoneAuthentication, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        _ = allocator;
        return &[_]u8{};
    }
};

/// Represents the type of authentication.
pub const AuthenticationType = enum {
    none,
    short_term,
    long_term,
};

/// Represents an authentication mechanism.
pub const Authentication = union(AuthenticationType) {
    none: NoneAuthentication,
    short_term: ShortTermAuthentication,
    long_term: LongTermAuthentication,

    /// Computes the authentication key corresponding to the stored parameters and tries to place the result in the given buffer.
    /// Returns the amount of bytes written.
    pub fn computeKey(self: Authentication, out: []u8) !usize {
        return switch (self) {
            inline else => |auth| auth.computeKey(out),
        };
    }

    /// Computes the authentication key corresponding to the stored parameters and tries to allocate the required.
    /// Returns the buffer containing the computed key.
    pub fn computeKeyAlloc(self: Authentication, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            inline else => |auth| auth.computeKeyAlloc(allocator),
        };
    }
};

test "compute short-term authentication key" {
    const password = "password";
    const authentication = ShortTermAuthentication{ .password = password };
    const key = try authentication.computeKeyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(key);

    const true_key = "password";

    try std.testing.expectEqualSlices(u8, true_key, key);
}

test "compute long-term authentication key" {
    const username = "user";
    const password = "pass";
    const realm = "realm";
    const authentication = LongTermAuthentication{ .username = username, .password = password, .realm = realm };
    const key = try authentication.computeKeyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(key);

    const true_key = [_]u8{ 0x84, 0x93, 0xFB, 0xC5, 0x3B, 0xA5, 0x82, 0xFB, 0x4C, 0x04, 0x4C, 0x45, 0x6B, 0xDC, 0x40, 0xEB };

    try std.testing.expectEqualSlices(u8, &true_key, key);
}
