// Copyright 2022 - Corentin Godeau and the ztun contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Self = @This();

const attr = @import("attributes.zig");
const ztun = @import("../ztun.zig");
const fmt = @import("fmt.zig");
const constants = @import("constants.zig");

const software_version_attribute = attr.common.Software{ .value = std.fmt.comptimePrint("ztun v{}", .{constants.version}) };

const log = std.log.scoped(.ztun);

/// Options to configure the STUN server.
pub const Options = struct {
    /// Type of authentication to use.
    authentication_type: ztun.auth.AuthenticationType = .none,
    /// The realm used in long-term authentication.
    realm: []const u8 = "default",
    /// The supported algorithms for long-term authentication.
    algorithms: []const attr.common.Algorithm = &.{
        .{ .type = attr.common.AlgorithmType.md5, .parameters = &.{} },
        .{ .type = attr.common.AlgorithmType.sha256, .parameters = &.{} },
    },
};

/// Server related error.
pub const Error = error{
    MethodNotAllowedForClass,
    InvalidFingerprint,
    UnknownTransaction,
} || ztun.MessageBuilder.Error || std.mem.Allocator.Error;

const Address = union(enum) {
    ipv4: std.net.Ip4Address,
    ipv6: std.net.Ip6Address,

    pub fn from(address: std.net.Address) Address {
        return switch (address.any.family) {
            std.os.AF.INET => .{ .ipv4 = address.in },
            std.os.AF.INET6 => .{ .ipv6 = address.in6 },
            else => unreachable,
        };
    }
};

/// Stores the options of the server.
options: Options,
/// Allocator used by the server internally.
allocator: std.mem.Allocator,
/// Stores the registered users.
user_map: std.StringHashMap(ztun.auth.Authentication),
/// Stores the nonce for known clients.
client_map: std.AutoHashMap(Address, ClientData),

/// Represents the data associated with each client that queried the Server.
const ClientData = struct {
    /// The nonce that was sent back and is currently valid.
    nonce: Nonce,
};

/// Represents the part of the Nonce that is unique to each client trying to authenticate.
const NonceData = packed struct {
    // TODO(Corendos): Is this required ?
    id: u64,
    // Absolute time until which the nonce is valid,
    validity: u64,
};

/// Represents the security features that are encoded in the Nonce.
const SecurityFeatures = packed struct {
    /// Bits 0-21 are unused.
    unused: u22 = 0,
    /// Bit 22 is the Username Anonymity.
    username_anonymity: bool = false,
    /// Bit 23 is the Password Algorithms.
    password_algorithms: bool = false,

    /// Encodes the 3-byte security features using base64 encoding.
    pub fn encode(self: SecurityFeatures) [4]u8 {
        var result: [4]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(result[0..4], std.mem.asBytes(&self)[0..3][0..]);
        return result;
    }

    /// Decodes the 3-byte security features from a base64 encoding.
    pub fn decode(buffer: [4]u8) !SecurityFeatures {
        var result: SecurityFeatures = undefined;
        try std.base64.standard.Decoder.decode(std.mem.asBytes(&result)[0..3], buffer[0..4]);
        return result;
    }
};

/// Represents the Nonce value.
const Nonce = struct {
    /// The security features used.
    security_features: SecurityFeatures,
    /// The data used by the server for bookkeeping.
    data: NonceData,

    pub const size = 13 + @sizeOf(NonceData);
};

/// Parses the nonce from the given buffer.
fn parseNonce(raw_nonce: []const u8) !Nonce {
    if (raw_nonce.len < Nonce.size) return error.InvalidNonce;
    const cookie_start = raw_nonce[0..9][0..];
    if (!std.mem.eql(u8, cookie_start, constants.nonce_cookie_start)) return error.InvalidCookieStart;

    const security_features = try SecurityFeatures.decode(raw_nonce[9..][0..4].*);

    var stream = std.io.fixedBufferStream(raw_nonce[13..]);
    var reader = stream.reader();

    const nonce_data = NonceData{
        .id = reader.readInt(u64, .little) catch unreachable,
        .validity = reader.readInt(u64, .little) catch unreachable,
    };

    return Nonce{ .security_features = security_features, .data = nonce_data };
}

/// Encode the nonce to a u8 array.
fn encodeNonce(nonce: Nonce) [13 + @sizeOf(NonceData)]u8 {
    var result: [Nonce.size]u8 = undefined;
    @memcpy(result[0..9][0..], constants.nonce_cookie_start);
    const encoded_security_features = nonce.security_features.encode();
    @memcpy(result[9..][0..4], encoded_security_features[0..]);

    var stream = std.io.fixedBufferStream(result[13..]);
    var writer = stream.writer();
    writer.writeInt(u64, nonce.data.id, .little) catch unreachable;
    writer.writeInt(u64, nonce.data.validity, .little) catch unreachable;

    return result;
}

/// Initializes a server using the given allocator and options.
pub fn init(allocator: std.mem.Allocator, options: Options) Self {
    return Self{
        .options = options,
        .allocator = allocator,
        .user_map = std.StringHashMap(ztun.auth.Authentication).init(allocator),
        .client_map = std.AutoHashMap(Address, ClientData).init(allocator),
    };
}

/// Deinitializes the server.
pub fn deinit(self: *Self) void {
    var user_iterator = self.user_map.iterator();
    while (user_iterator.next()) |entry| switch (entry.value_ptr.*) {
        .none => {},
        .short_term => |value| {
            self.allocator.free(value.password);
        },
        .long_term => |value| {
            self.allocator.free(value.username);
            self.allocator.free(value.password);
            self.allocator.free(value.realm);
        },
    };
    self.user_map.deinit();
    self.client_map.deinit();
}

/// Returns true if the given attribute is not known by the server.
fn isUnknownAttribute(value: u16) bool {
    return switch (value) {
        @as(u16, attr.Type.mapped_address) => false,
        @as(u16, attr.Type.xor_mapped_address) => false,
        @as(u16, attr.Type.username) => false,
        @as(u16, attr.Type.userhash) => false,
        @as(u16, attr.Type.message_integrity) => false,
        @as(u16, attr.Type.message_integrity_sha256) => false,
        @as(u16, attr.Type.fingerprint) => false,
        @as(u16, attr.Type.error_code) => false,
        @as(u16, attr.Type.realm) => false,
        @as(u16, attr.Type.nonce) => false,
        @as(u16, attr.Type.password_algorithms) => false,
        @as(u16, attr.Type.password_algorithm) => false,
        @as(u16, attr.Type.unknown_attributes) => false,
        @as(u16, attr.Type.software) => false,
        @as(u16, attr.Type.alternate_server) => false,
        @as(u16, attr.Type.alternate_domain) => false,
        else => true,
    };
}

/// Returns the list of unknown attributes or null if they are all known.
fn lookForUnknownAttributes(allocator: std.mem.Allocator, message: ztun.Message) error{OutOfMemory}!?[]u16 {
    var comprehension_required_unknown_attributes = try std.ArrayList(u16).initCapacity(allocator, message.attributes.len);
    defer comprehension_required_unknown_attributes.deinit();

    for (message.attributes) |a| if (isUnknownAttribute(a.type) and attr.isComprehensionRequired(a.type)) {
        comprehension_required_unknown_attributes.appendAssumeCapacity(a.type);
    };

    return if (comprehension_required_unknown_attributes.items.len == 0) null else try comprehension_required_unknown_attributes.toOwnedSlice();
}

/// Returns a STUN message representing a Bad Request response_error.
fn makeBadRequestMessage(allocator: std.mem.Allocator, request: ztun.Message) ztun.MessageBuilder.Error!ztun.Message {
    var message_builder = ztun.MessageBuilder.init(allocator);
    defer message_builder.deinit();

    message_builder.setHeader(request.type.method, .error_response, request.transaction_id);

    const error_code_attribute = try (attr.common.ErrorCode{ .value = .bad_request, .reason = "Bad Request" }).toAttribute(allocator);
    try message_builder.addAttribute(error_code_attribute);

    const software_attribute = try software_version_attribute.toAttribute(allocator);
    errdefer allocator.free(software_attribute.data);
    try message_builder.addAttribute(software_attribute);

    return message_builder.build();
}

/// Options used to generate a Unauthenticated STUN response.
const MakeUnauthenticatedMessageOptions = struct {
    /// The reason to use.
    reason: ?[]const u8 = null,
    /// Should a NONCE attribute be added.
    add_nonce: bool = false,
    /// Should a REALM attribute be added.
    add_realm: bool = false,
    /// Should a PASSWORD-ALGORITHMS attribute be added.
    add_password_algorithms: bool = false,
};

/// Returns a STUN message representing a Unauthenticated response_error.
fn makeUnauthenticatedMessage(self: *Self, allocator: std.mem.Allocator, context: *const MessageContext, options: MakeUnauthenticatedMessageOptions) ztun.MessageBuilder.Error!ztun.Message {
    var message_builder = ztun.MessageBuilder.init(allocator);
    defer message_builder.deinit();

    message_builder.setHeader(context.message.type.method, .error_response, context.message.transaction_id);

    const reason = options.reason orelse "Unauthenticated";
    const error_code_attribute = try (attr.common.ErrorCode{ .value = .unauthenticated, .reason = reason }).toAttribute(allocator);
    try message_builder.addAttribute(error_code_attribute);

    if (options.add_realm) {
        const realm_attribute = try (attr.common.Realm{ .value = self.options.realm }).toAttribute(allocator);
        errdefer allocator.free(realm_attribute.data);
        try message_builder.addAttribute(realm_attribute);
    }

    if (options.add_nonce) {
        const nonce = try self.getOrUpdateNonce(context.source, .{ .set_password_algoritms_feature = options.add_password_algorithms });
        const encoded_nonce = encodeNonce(nonce);

        const nonce_attribute = try (attr.common.Nonce{ .value = encoded_nonce[0..] }).toAttribute(allocator);
        errdefer allocator.free(nonce_attribute.data);
        try message_builder.addAttribute(nonce_attribute);
    }

    if (options.add_password_algorithms) {
        const password_algorithms_attribute = try (attr.common.PasswordAlgorithms{ .algorithms = self.options.algorithms }).toAttribute(allocator);
        errdefer allocator.free(password_algorithms_attribute.data);
        try message_builder.addAttribute(password_algorithms_attribute);
    }

    const software_attribute = try software_version_attribute.toAttribute(allocator);
    errdefer allocator.free(software_attribute.data);
    try message_builder.addAttribute(software_attribute);

    return message_builder.build();
}

/// Returns a STUN message representing a Unknown Attributes response_error.
fn makeUnknownAttributesMessage(allocator: std.mem.Allocator, request: ztun.Message, unknown_attributes: []u16) ztun.MessageBuilder.Error!ztun.Message {
    var message_builder = ztun.MessageBuilder.init(allocator);
    defer message_builder.deinit();

    message_builder.setHeader(request.type.method, .error_response, request.transaction_id);

    const error_code_attribute = try (attr.common.ErrorCode{ .value = .unknown_attribute, .reason = "Unknown comprehension-required attributes" }).toAttribute(allocator);
    errdefer allocator.free(error_code_attribute.data);
    try message_builder.addAttribute(error_code_attribute);

    const unknown_attributes_attribute = try (attr.common.UnknownAttributes{ .attribute_types = unknown_attributes }).toAttribute(allocator);
    errdefer allocator.free(unknown_attributes_attribute.data);
    try message_builder.addAttribute(unknown_attributes_attribute);

    const software_attribute = try software_version_attribute.toAttribute(allocator);
    errdefer allocator.free(software_attribute.data);
    try message_builder.addAttribute(software_attribute);

    return message_builder.build();
}

/// Returns a STUN message representing a Stale Nonce response_error.
fn makeStaleNonceMessage(self: *Self, allocator: std.mem.Allocator, context: *MessageContext) ztun.MessageBuilder.Error!ztun.Message {
    var message_builder = ztun.MessageBuilder.init(allocator);
    defer message_builder.deinit();

    message_builder.setHeader(context.message.type.method, .error_response, context.message.transaction_id);

    const error_code_attribute = try (attr.common.ErrorCode{ .value = .stale_nonce, .reason = "Stale Nonce" }).toAttribute(allocator);
    errdefer allocator.free(error_code_attribute.data);
    try message_builder.addAttribute(error_code_attribute);

    const realm_attribute = try (attr.common.Realm{ .value = self.options.realm }).toAttribute(allocator);
    errdefer allocator.free(realm_attribute.data);
    try message_builder.addAttribute(realm_attribute);

    const nonce = try self.getOrUpdateNonce(context.source, .{ .set_password_algoritms_feature = true });
    const encoded_nonce = encodeNonce(nonce);

    const nonce_attribute = try (attr.common.Nonce{ .value = encoded_nonce[0..] }).toAttribute(allocator);
    errdefer allocator.free(nonce_attribute.data);
    try message_builder.addAttribute(nonce_attribute);

    const password_algorithms_attribute = try (attr.common.PasswordAlgorithms{ .algorithms = self.options.algorithms }).toAttribute(allocator);
    errdefer allocator.free(password_algorithms_attribute.data);
    try message_builder.addAttribute(password_algorithms_attribute);

    const software_attribute = try software_version_attribute.toAttribute(allocator);
    errdefer allocator.free(software_attribute.data);
    try message_builder.addAttribute(software_attribute);

    return message_builder.build();
}

/// Represents some details about the message attributes.
const MessageAttributeDetails = struct {
    /// Stores the index of the USERNAME attribute if any.
    username_index: ?usize = null,
    /// Stores the index of the USERHASH attribute if any.
    userhash_index: ?usize = null,
    /// Stores the index of the REALM attribute if any.
    realm_index: ?usize = null,
    /// Stores the index of the NONCE attribute if any.
    nonce_index: ?usize = null,
    /// Stores the index of the PASSWORD-ALGORITHM attribute if any.
    password_algorithm_index: ?usize = null,
    /// Stores the index of the PASSWORD-ALGORITHMS attribute if any.
    password_algorithms_index: ?usize = null,
    /// Stores the index of the MESSAGE-INTEGRITY attribute if any.
    message_integrity_index: ?usize = null,
    /// Stores the index of the MESSAGE-INTEGRITY-SHA256 if any
    message_integrity_sha256_index: ?usize = null,

    /// Extracts details from a list of attribute.
    pub fn fromAttributes(attributes: []const ztun.Attribute) MessageAttributeDetails {
        var details = MessageAttributeDetails{};
        for (attributes, 0..) |attribute, i| {
            switch (attribute.type) {
                @as(u16, ztun.attr.Type.username) => details.username_index = i,
                @as(u16, ztun.attr.Type.userhash) => details.userhash_index = i,
                @as(u16, ztun.attr.Type.realm) => details.realm_index = i,
                @as(u16, ztun.attr.Type.nonce) => details.nonce_index = i,
                @as(u16, ztun.attr.Type.password_algorithm) => details.password_algorithm_index = i,
                @as(u16, ztun.attr.Type.password_algorithms) => details.password_algorithms_index = i,
                @as(u16, ztun.attr.Type.message_integrity) => details.message_integrity_index = i,
                @as(u16, ztun.attr.Type.message_integrity_sha256) => details.message_integrity_sha256_index = i,
                else => {},
            }
        }
        return details;
    }
};

/// Potential errors that can happen when trying to authenticate usign the Short-Term method.
pub const ShortTermAuthenticationError = error{
    MissingMessageIntegrity,
    MissingUsername,
    UnknownUser,
    InvalidMessageIntegrity,
    Unrecoverable,
};

/// Potential errors that can happen when trying to authenticate usign the Long-Term method.
pub const LongTermAuthenticationError = error{
    MissingMessageIntegrity,
    MissingAttributes,
    MissingPasswordAlgorithm,
    PasswordAlgorithmMismatch,
    UnknownUser,
    InvalidMessageIntegrity,
    InvalidPasswordAlgorithm,
    StaleNonce,
    Unrecoverable,
};

/// Authenticates the sender of a STUN message using the short-term mechanism.
fn authenticateShortTerm(self: *Self, context: *MessageContext) ShortTermAuthenticationError!void {
    const message_attribute_details = context.message_attribute_details.?;
    // Handle MessageIntegrityDetails validity.
    if (message_attribute_details.message_integrity_index == null and message_attribute_details.message_integrity_sha256_index == null) return error.MissingMessageIntegrity;
    if (message_attribute_details.username_index == null) return error.MissingUsername;

    const message_integrity_type: ztun.MessageIntegrityType = if (message_attribute_details.message_integrity_sha256_index != null) .sha256 else .classic;
    const message_integrity_attribute_index = message_attribute_details.message_integrity_sha256_index orelse message_attribute_details.message_integrity_index orelse unreachable;
    const username = context.message.attributes[message_attribute_details.username_index.?].data;
    const authentication = self.user_map.get(username) orelse return error.UnknownUser;

    const key = authentication.computeKeyAlloc(context.arena) catch return error.Unrecoverable;

    const result = context.message.checkMessageIntegrity(context.arena, message_integrity_type, message_integrity_attribute_index, key) catch return error.Unrecoverable;

    if (!result) return error.InvalidMessageIntegrity;

    context.authentication = authentication;
}

/// Checks that the given algorithms match the ones provided by the server.
fn hasSamePasswordAlgorithms(self: Self, algorithms: []const attr.common.Algorithm) bool {
    if (algorithms.len != self.options.algorithms.len) return false;

    // TODO(Corendos,@Improvement): Handle cases where the algorithms are shuffled.
    return for (algorithms, self.options.algorithms) |server_algorithm, algorithm| {
        if (server_algorithm.type != algorithm.type or !std.mem.eql(u8, server_algorithm.parameters, algorithm.parameters)) break false;
    } else true;
}

/// Checks that the message contains valid PASSWORD-ALGORITHM and PASSWORD-ALGORITHMS attributes.
/// This is used when the Password Algorithms bit of the security features is set.
fn checkPasswordAlgorithms(self: Self, context: *MessageContext) LongTermAuthenticationError!void {
    const message_attribute_details = context.message_attribute_details.?;

    if (message_attribute_details.password_algorithm_index == null and message_attribute_details.password_algorithms_index == null) return;

    if (message_attribute_details.password_algorithm_index == null or message_attribute_details.password_algorithms_index == null) {
        return error.MissingPasswordAlgorithm;
    }

    const password_algorithms_attribute = attr.common.PasswordAlgorithms.fromAttribute(context.message.attributes[message_attribute_details.password_algorithms_index.?], context.arena) catch return error.Unrecoverable;

    if (!self.hasSamePasswordAlgorithms(password_algorithms_attribute.algorithms)) {
        return error.PasswordAlgorithmMismatch;
    }

    const password_algorithm_attribute = attr.common.PasswordAlgorithm.fromAttribute(context.message.attributes[message_attribute_details.password_algorithm_index.?]) catch return error.Unrecoverable;

    context.algorithm = for (password_algorithms_attribute.algorithms) |algorithm| {
        if (password_algorithm_attribute.algorithm.type == algorithm.type) break password_algorithm_attribute.algorithm;
    } else return error.InvalidPasswordAlgorithm;
}

/// Authenticates the sender of a STUN message using the long-term mechanism.
fn authenticateLongTerm(self: Self, context: *MessageContext) LongTermAuthenticationError!void {
    const message_attribute_details = context.message_attribute_details.?;
    if (message_attribute_details.message_integrity_index == null and message_attribute_details.message_integrity_sha256_index == null) {
        return error.MissingMessageIntegrity;
    }

    if ((message_attribute_details.username_index == null and message_attribute_details.userhash_index == null) or
        message_attribute_details.realm_index == null or
        message_attribute_details.nonce_index == null)
    {
        return error.MissingAttributes;
    }

    // If the nonce is ill-formed, we consider that it's no longer valid.
    const nonce = parseNonce(context.message.attributes[message_attribute_details.nonce_index.?].data) catch return error.StaleNonce;

    if (nonce.security_features.password_algorithms) {
        try self.checkPasswordAlgorithms(context);
    }
    const username = context.message.attributes[message_attribute_details.username_index.?].data;
    const authentication = self.user_map.get(username) orelse {
        return error.UnknownUser;
    };

    // TODO(Corendos): Handle USERHASH if present.

    const key = authentication.computeKeyAlloc(context.arena) catch return error.Unrecoverable;

    const message_integrity_type: ztun.MessageIntegrityType = if (message_attribute_details.message_integrity_sha256_index != null) .sha256 else .classic;
    const message_integrity_attribute_index = message_attribute_details.message_integrity_sha256_index orelse message_attribute_details.message_integrity_index orelse unreachable;
    const result = context.message.checkMessageIntegrity(context.arena, message_integrity_type, message_integrity_attribute_index, key) catch return error.Unrecoverable;

    if (!result) return error.InvalidMessageIntegrity;

    const now: u64 = @intCast(std.time.microTimestamp());

    if (nonce.data.validity < now) {
        return error.StaleNonce;
    }

    context.authentication = authentication;
}

/// Options used when getting/updating a Nonce.
const getOrUpdateNonceOptions = struct {
    /// Should the Password Algorithms bit of the security features be set.
    set_password_algoritms_feature: bool = false,
    /// Should the Username Anonymity bit of the security features be set.
    set_username_anonymity_feature: bool = false,
};

/// Get the current nonce for the given client address or generate a new one if it's not valid anymore.
fn getOrUpdateNonce(self: *Self, source: std.net.Address, options: getOrUpdateNonceOptions) !Nonce {
    const now: u64 = @intCast(std.time.microTimestamp());
    const address = Address.from(source);

    const gop = try self.client_map.getOrPut(address);
    if (!gop.found_existing) {
        const nonce = Nonce{
            .security_features = SecurityFeatures{
                .password_algorithms = options.set_password_algoritms_feature,
                .username_anonymity = options.set_username_anonymity_feature,
            },
            .data = NonceData{
                .validity = now + 60_000_000,
                .id = 0,
            },
        };
        gop.value_ptr.* = ClientData{ .nonce = nonce };
        return nonce;
    }

    if (now > gop.value_ptr.nonce.data.validity or
        gop.value_ptr.nonce.security_features.password_algorithms != options.set_password_algoritms_feature or
        gop.value_ptr.nonce.security_features.username_anonymity != options.set_username_anonymity_feature)
    {
        const nonce = Nonce{
            .security_features = SecurityFeatures{
                .password_algorithms = options.set_password_algoritms_feature,
                .username_anonymity = options.set_username_anonymity_feature,
            },
            .data = NonceData{
                .validity = now + 60_000_000,
                .id = 0,
            },
        };
        gop.value_ptr.* = ClientData{ .nonce = nonce };
        return nonce;
    }

    return gop.value_ptr.nonce;
}

/// Represents the context associated with a received STUN message.
const MessageContext = struct {
    /// The received message.
    message: ztun.Message,
    /// The source of the message.
    source: std.net.Address,
    /// An arena that can be used and has the same lifetime than the message.
    arena: std.mem.Allocator,
    /// Details concerning the attributes of the message.
    message_attribute_details: ?MessageAttributeDetails = null,
    /// The authentication parameters.
    /// This is set if the user is authenticated.
    authentication: ?ztun.auth.Authentication = null,
    /// The password algorithm to use if it has been specified using attributes.
    algorithm: ?ztun.attr.common.Algorithm = null,
};

/// Make a
fn makeXorMappedAddressAttribute(allocator: std.mem.Allocator, source: std.net.Address, transaction_id: u96) !attr.Attribute {
    const xor_mapped_attribute = switch (source.any.family) {
        std.os.AF.INET => blk: {
            const ipv4 = source.in;
            break :blk attr.common.encode(attr.common.MappedAddress{
                .port = std.mem.bigToNative(u16, ipv4.sa.port),
                .family = attr.common.AddressFamily{ .ipv4 = std.mem.toBytes(ipv4.sa.addr) },
            }, transaction_id);
        },
        std.os.AF.INET6 => blk: {
            const ipv6 = source.in6;
            break :blk attr.common.encode(attr.common.MappedAddress{
                .port = std.mem.bigToNative(u16, ipv6.sa.port),
                .family = attr.common.AddressFamily{ .ipv6 = ipv6.sa.addr[0..16].* },
            }, transaction_id);
        },
        else => return error.UnknownAddressFamily,
    };
    return xor_mapped_attribute.toAttribute(allocator);
}

/// Handles a request after the basic checks and authentication (if needed) has been done.
pub fn handleRequest(self: *Self, allocator: std.mem.Allocator, context: *MessageContext) Error!MessageResult {
    log.debug("Received {s} request from {any}", .{ @tagName(context.message.type.method), context.source });

    // Take care of unknown attributes, as mentioned in Section 6.3.1
    const unknown_attributes_opt = try lookForUnknownAttributes(context.arena, context.message);
    if (unknown_attributes_opt) |unknown_attributes| {
        return .{ .response = try makeUnknownAttributesMessage(allocator, context.message, unknown_attributes) };
    }

    context.message_attribute_details = MessageAttributeDetails.fromAttributes(context.message.attributes);

    // Take care of authentication.
    switch (self.options.authentication_type) {
        .none => {},
        .short_term => {
            self.authenticateShortTerm(context) catch |err| {
                return switch (err) {
                    error.MissingMessageIntegrity, error.MissingUsername => .{ .response = try makeBadRequestMessage(allocator, context.message) },
                    error.UnknownUser => .{ .response = try self.makeUnauthenticatedMessage(allocator, context, .{}) },
                    error.InvalidMessageIntegrity => .{ .response = try self.makeUnauthenticatedMessage(allocator, context, .{}) },
                    error.Unrecoverable => .{ .discard = {} },
                };
            };
        },
        .long_term => {
            self.authenticateLongTerm(context) catch |err| {
                return switch (err) {
                    error.MissingMessageIntegrity => .{ .response = try self.makeUnauthenticatedMessage(allocator, context, .{ .add_nonce = true, .add_realm = true }) },
                    error.MissingAttributes, error.MissingPasswordAlgorithm, error.PasswordAlgorithmMismatch => .{ .response = try makeBadRequestMessage(allocator, context.message) },
                    error.UnknownUser => .{ .response = try self.makeUnauthenticatedMessage(allocator, context, .{ .add_nonce = true, .add_realm = true, .add_password_algorithms = true }) },
                    error.InvalidMessageIntegrity => .{ .response = try self.makeUnauthenticatedMessage(allocator, context, .{ .add_nonce = true, .add_realm = true }) },
                    error.InvalidPasswordAlgorithm => .{ .response = try makeBadRequestMessage(allocator, context.message) },
                    error.StaleNonce => .{ .response = try self.makeStaleNonceMessage(allocator, context) },
                    error.Unrecoverable => .{ .discard = {} },
                };
            };
        },
    }

    var message_builder = ztun.MessageBuilder.init(allocator);
    defer message_builder.deinit();
    message_builder.setHeader(context.message.type.method, .error_response, context.message.transaction_id);
    message_builder.setClass(.success_response);

    const xor_mapped_address_attribute = makeXorMappedAddressAttribute(allocator, context.source, context.message.transaction_id) catch {
        return MessageResult{ .response = try makeBadRequestMessage(allocator, context.message) };
    };
    errdefer allocator.free(xor_mapped_address_attribute.data);
    try message_builder.addAttribute(xor_mapped_address_attribute);

    const software_attribute = try software_version_attribute.toAttribute(allocator);
    errdefer allocator.free(software_attribute.data);
    try message_builder.addAttribute(software_attribute);

    switch (self.options.authentication_type) {
        .none => {},
        .short_term => {
            const message_attribute_details = context.message_attribute_details.?;
            const key = try context.authentication.?.computeKeyAlloc(context.arena);

            if (message_attribute_details.message_integrity_sha256_index != null) {
                message_builder.addMessageIntegritySha256(key);
            } else if (message_attribute_details.message_integrity_index != null) {
                message_builder.addMessageIntegrity(key);
            } else unreachable;
        },
        .long_term => {
            if (context.algorithm) |algorithm| {
                // TODO(Corendos): use the algorithm to compute the correct key.
                _ = algorithm;

                const key = try context.authentication.?.long_term.computeKeyAlloc(context.arena);
                message_builder.addMessageIntegritySha256(key);
            } else {
                const key = try context.authentication.?.long_term.computeKeyAlloc(context.arena);
                message_builder.addMessageIntegrity(key);
            }
        },
    }

    message_builder.addFingerprint();
    return .{ .response = try message_builder.build() };
}

/// Handles an indication after the basic checks and authentication (if needed) has been done.
pub fn handleIndication(self: Self, allocator: std.mem.Allocator, context: *MessageContext) Error!MessageResult {
    _ = context;
    _ = self;
    _ = allocator;
    @panic("Indication handling is not implemented");
}

/// Represents the type of result that can be returned by the server when handling a message.
pub const MessageResultType = enum {
    discard,
    ok,
    response,
};

/// Represents the result returned by the server when handling a message.
pub const MessageResult = union(MessageResultType) {
    /// The message should be discarded.
    discard: void,
    /// The message has been handled correctly, but doesn't require any response to be send back.
    ok: void,
    /// The message has been handled correctly and this contains the response to send back.
    response: ztun.Message,
};

/// Handles a message sent to the server and returns a `MessageResult` result or an error in case of critical failure.
pub fn handleMessage(self: *Self, allocator: std.mem.Allocator, message: ztun.Message, source: std.net.Address) !MessageResult {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var context = MessageContext{ .message = message, .source = source, .arena = arena };

    // NOTE(Corendos): If the message has been successfully decoded, some basic checks already have been done.

    // Check that the method is allowed for the given class. If not, discard message as described in Section 6.3.
    if (!ztun.isMethodAllowedForClass(message.type.method, message.type.class)) return .{ .discard = {} };

    // Check the fingerprint if it's present
    if (!message.checkFingerprint(arena)) return .{ .discard = {} };

    // Handle the message depending on its type.
    return switch (message.type.class) {
        .request => try self.handleRequest(allocator, &context),
        .indication => try self.handleIndication(allocator, &context),
        .success_response, .error_response => .{ .discard = {} },
    };
}

/// Registers a user on the Server.
pub fn registerUser(self: *Self, username: []const u8, authentication: ztun.auth.Authentication) !void {
    if (authentication == .none) return;

    const gop = try self.user_map.getOrPut(username);
    if (gop.found_existing) switch (gop.value_ptr.*) {
        .none => {},
        .short_term => |value| {
            self.allocator.free(value.password);
        },
        .long_term => |value| {
            self.allocator.free(value.username);
            self.allocator.free(value.password);
            self.allocator.free(value.realm);
        },
    };
    gop.value_ptr.* = switch (authentication) {
        .none => @unionInit(ztun.auth.Authentication, "none", .{}),
        .short_term => |value| @unionInit(ztun.auth.Authentication, "short_term", .{
            .password = try self.allocator.dupe(u8, value.password),
        }),
        .long_term => |value| @unionInit(ztun.auth.Authentication, "long_term", .{
            .username = try self.allocator.dupe(u8, value.username),
            .password = try self.allocator.dupe(u8, value.password),
            .realm = try self.allocator.dupe(u8, value.realm),
        }),
    };
}

// Test utils
fn findAttribute(message: ztun.Message, attribute_type: u16) ?ztun.Attribute {
    return for (message.attributes) |a| {
        if (a.type == attribute_type) break a;
    } else null;
}

test "check fingerprint while processing a message" {
    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);
        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);
    const true_fingerprint_attribute = try attr.common.Fingerprint.fromAttribute(message.attributes[0]);

    var server = Self.init(std.testing.allocator, .{});
    defer server.deinit();

    const wrong_fingerprint_attribute = try (attr.common.Fingerprint{ .value = true_fingerprint_attribute.value + 1 }).toAttribute(std.testing.allocator);
    std.testing.allocator.free(wrong_fingerprint_attribute.data);

    const wrong_message = ztun.Message{
        .type = message.type,
        .transaction_id = message.transaction_id,
        .length = message.length,
        .attributes = &.{wrong_fingerprint_attribute},
    };
    try std.testing.expectEqual(MessageResultType.discard, try server.handleMessage(std.testing.allocator, wrong_message, undefined));
}

test "Short Term Authentication: missing MESSAGE-INTEGRITY/MESSAGE-INTEGRITY-SHA256" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .short_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .short_term = .{ .password = "password" } };

    try server.registerUser("corendos", authentication);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);
        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try server.handleMessage(arena_state.allocator(), message, try std.net.Address.parseIp4("192.168.1.18", 18232));
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.bad_request, error_code_attribute.value);
}

test "Short Term Authentication: missing USERNAME" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .short_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .short_term = .{ .password = "password" } };

    try server.registerUser("corendos", authentication);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const key = try authentication.computeKeyAlloc(std.testing.allocator);
        defer std.testing.allocator.free(key);

        builder.addMessageIntegrity(key);

        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try server.handleMessage(arena_state.allocator(), message, try std.net.Address.parseIp4("192.168.1.18", 18232));
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.bad_request, error_code_attribute.value);
}

test "Short Term Authentication: unknown USERNAME" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .short_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .short_term = .{ .password = "password" } };

    try server.registerUser("corendos", authentication);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const username_attribute = try (ztun.attr.common.Username{ .value = "unknown" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(username_attribute.data);
        try builder.addAttribute(username_attribute);

        const key = try authentication.computeKeyAlloc(std.testing.allocator);
        defer std.testing.allocator.free(key);

        builder.addMessageIntegrity(key);

        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try server.handleMessage(arena_state.allocator(), message, try std.net.Address.parseIp4("192.168.1.18", 18232));
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.unauthenticated, error_code_attribute.value);
}

test "Short Term Authentication: wrong MESSAGE-INTEGRITY" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .short_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .short_term = .{ .password = "password" } };

    try server.registerUser("corendos", authentication);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const username_attribute = try (ztun.attr.common.Username{ .value = "corendos" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(username_attribute.data);
        try builder.addAttribute(username_attribute);

        const key = "wrong";

        builder.addMessageIntegrity(key);

        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try server.handleMessage(arena_state.allocator(), message, try std.net.Address.parseIp4("192.168.1.18", 18232));
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.unauthenticated, error_code_attribute.value);
}

test "Long Term Authentication: missing MESSAGE-INTEGRITY/MESSAGE-INTEGRITY-SHA256" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .long_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .long_term = .{ .username = "corendos", .password = "password", .realm = "default" } };
    try server.registerUser("corendos", authentication);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);
        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try server.handleMessage(arena_state.allocator(), message, try std.net.Address.parseIp4("192.168.1.18", 18232));
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.unauthenticated, error_code_attribute.value);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.realm) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.nonce) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.username) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.userhash) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.message_integrity) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.message_integrity_sha256) == null);
}

test "Long Term Authentication: missing USERNAME" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .long_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .long_term = .{ .username = "corendos", .password = "password", .realm = "default" } };

    try server.registerUser("corendos", authentication);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const key = try authentication.computeKeyAlloc(std.testing.allocator);
        defer std.testing.allocator.free(key);

        builder.addMessageIntegrity(key);
        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try server.handleMessage(arena_state.allocator(), message, try std.net.Address.parseIp4("192.168.1.18", 18232));
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.bad_request, error_code_attribute.value);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.realm) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.nonce) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.username) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.userhash) == null);
}

test "Long Term Authentication: missing REALM" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .long_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .long_term = .{ .username = "corendos", .password = "password", .realm = "default" } };

    try server.registerUser("corendos", authentication);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const username_attribute = try (ztun.attr.common.Username{ .value = "corendos" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(username_attribute.data);
        try builder.addAttribute(username_attribute);

        const key = try authentication.computeKeyAlloc(std.testing.allocator);
        defer std.testing.allocator.free(key);

        builder.addMessageIntegrity(key);
        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try server.handleMessage(arena_state.allocator(), message, try std.net.Address.parseIp4("192.168.1.18", 18232));
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.bad_request, error_code_attribute.value);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.realm) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.nonce) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.username) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.userhash) == null);
}

test "Long Term Authentication: missing NONCE" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .long_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .long_term = .{ .username = "corendos", .password = "password", .realm = "default" } };

    try server.registerUser("corendos", authentication);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const username_attribute = try (ztun.attr.common.Username{ .value = "corendos" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(username_attribute.data);
        try builder.addAttribute(username_attribute);

        const realm_attribute = try (ztun.attr.common.Realm{ .value = "default" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(realm_attribute.data);
        try builder.addAttribute(realm_attribute);

        const key = try authentication.computeKeyAlloc(std.testing.allocator);
        defer std.testing.allocator.free(key);

        builder.addMessageIntegrity(key);
        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try server.handleMessage(arena_state.allocator(), message, try std.net.Address.parseIp4("192.168.1.18", 18232));
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.bad_request, error_code_attribute.value);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.realm) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.nonce) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.username) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.userhash) == null);
}

test "Long Term Authentication: invalid USERNAME" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .long_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .long_term = .{ .username = "corendos", .password = "password", .realm = "default" } };
    try server.registerUser("corendos", authentication);

    const source = try std.net.Address.parseIp4("192.168.1.18", 18232);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const username_attribute = try (ztun.attr.common.Username{ .value = "wrong" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(username_attribute.data);
        try builder.addAttribute(username_attribute);

        const realm_attribute = try (ztun.attr.common.Realm{ .value = "default" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(realm_attribute.data);
        try builder.addAttribute(realm_attribute);

        const nonce = Nonce{ .security_features = .{}, .data = NonceData{ .validity = 0, .id = 0 } };
        const nonce_attribute = try (ztun.attr.common.Nonce{ .value = encodeNonce(nonce)[0..] }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(nonce_attribute.data);
        try builder.addAttribute(nonce_attribute);

        const key = try authentication.computeKeyAlloc(std.testing.allocator);
        defer std.testing.allocator.free(key);
        builder.addMessageIntegrity(key);

        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const result = try server.handleMessage(arena, message, source);
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.unauthenticated, error_code_attribute.value);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.realm) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.nonce) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.password_algorithms) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.username) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.userhash) == null);
}

test "Long Term Authentication: invalid MESSAGE-INTEGRITY" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .long_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .long_term = .{ .username = "corendos", .password = "password", .realm = "default" } };
    try server.registerUser("corendos", authentication);

    const source = try std.net.Address.parseIp4("192.168.1.18", 18232);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const username_attribute = try (ztun.attr.common.Username{ .value = "corendos" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(username_attribute.data);
        try builder.addAttribute(username_attribute);

        const realm_attribute = try (ztun.attr.common.Realm{ .value = "default" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(realm_attribute.data);
        try builder.addAttribute(realm_attribute);

        const nonce = Nonce{ .security_features = .{}, .data = NonceData{ .validity = 0, .id = 0 } };
        const nonce_attribute = try (ztun.attr.common.Nonce{ .value = encodeNonce(nonce)[0..] }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(nonce_attribute.data);
        try builder.addAttribute(nonce_attribute);

        const key = "wrong";
        builder.addMessageIntegrity(key);

        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const result = try server.handleMessage(arena, message, source);
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.unauthenticated, error_code_attribute.value);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.realm) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.nonce) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.username) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.userhash) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.message_integrity) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.message_integrity_sha256) == null);
}

test "Long Term Authentication: stale nonce" {
    var server = Self.init(std.testing.allocator, Options{ .authentication_type = .long_term });
    defer server.deinit();

    const authentication = ztun.auth.Authentication{ .long_term = .{ .username = "corendos", .password = "password", .realm = "default" } };
    try server.registerUser("corendos", authentication);

    const source = try std.net.Address.parseIp4("192.168.1.18", 18232);

    const message = msg: {
        var builder = ztun.MessageBuilder.init(std.testing.allocator);
        defer builder.deinit();

        builder.setClass(.request);
        builder.setMethod(.binding);
        builder.transactionId(0x0102030405060708090A0B);

        const username_attribute = try (ztun.attr.common.Username{ .value = "corendos" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(username_attribute.data);
        try builder.addAttribute(username_attribute);

        const realm_attribute = try (ztun.attr.common.Realm{ .value = "default" }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(realm_attribute.data);
        try builder.addAttribute(realm_attribute);

        const nonce = Nonce{ .security_features = .{}, .data = NonceData{ .validity = 0, .id = 0 } };
        const nonce_attribute = try (ztun.attr.common.Nonce{ .value = encodeNonce(nonce)[0..] }).toAttribute(std.testing.allocator);
        errdefer std.testing.allocator.free(nonce_attribute.data);
        try builder.addAttribute(nonce_attribute);

        const key = try authentication.computeKeyAlloc(std.testing.allocator);
        defer std.testing.allocator.free(key);
        builder.addMessageIntegrity(key);

        builder.addFingerprint();
        break :msg try builder.build();
    };
    defer message.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const result = try server.handleMessage(arena, message, source);
    try std.testing.expectEqual(MessageResultType.response, result);
    try std.testing.expectEqual(@as(ztun.Class, .error_response), result.response.type.class);

    const error_code_attribute = try ztun.attr.common.ErrorCode.fromAttribute(findAttribute(result.response, ztun.attr.Type.error_code).?);
    try std.testing.expectEqual(ztun.attr.common.RawErrorCode.stale_nonce, error_code_attribute.value);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.realm) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.nonce) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.password_algorithms) != null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.username) == null);
    try std.testing.expect(findAttribute(result.response, ztun.attr.Type.userhash) == null);
}
