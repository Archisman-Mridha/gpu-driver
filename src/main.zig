const std = @import("std");

const GPUDriverError = error{
    NoXDGRuntime,
    NoWaylandDisplay,
};

// Connects to the Wayland socket.
// The wayland sockt file-descriptor is then returned.
fn createWaylandConnection(allocator: std.mem.Allocator) !std.posix.system.socket_t {
    // There is a single base directory relative to which user-specific runtime files and other
    // file objects should be placed. This directory is defined by the environment variable
    // XDG_RUNTIME_DIR.
    // REFER : https://specifications.freedesktop.org/basedir-spec/latest/.
    //
    // NOTE : XDG stands for Cross-Desktop Group, representing the members of freedesktop.org.
    // Freedesktop.org is a project to work on interoperability and shared base technology for
    // free-software desktop environments for the X Window System (X11) and Wayland on Linux and
    // other Unix-like operating systems.
    const xdgRuntimeDir =
        std.posix.getenv("XDG_RUNTIME_DIR") orelse return GPUDriverError.NoXDGRuntime;

    // Wayland uses a message based asynchronous protocol, called the Wire protocol.
    // A message sent by a client to the server is called request. A message from the server to a
    // client is called event.
    //
    // The protocol is sent over a UNIX domain stream socket, where the endpoint usually is named
    // wayland-0 (although it can be changed via WAYLAND_DISPLAY in the environment).
    //
    // NOTE : Beginning in Wayland 1.15, implementations can optionally support server socket
    // endpoints located at arbitrary locations in the filesystem by setting WAYLAND_DISPLAY to the
    // absolute path at which the server endpoint listens.
    const waylandEndpoint =
        std.posix.getenv("WAYLAND_DISPLAY") orelse return GPUDriverError.NoWaylandDisplay;

    const waylandSocketPath = try std.fs.path.join(allocator, &.{ xdgRuntimeDir, waylandEndpoint });
    defer allocator.free(waylandSocketPath);

    var waylandSocketAddress = std.posix.system.sockaddr.un{
        .path = undefined,
    };
    @memcpy(waylandSocketAddress.path[0..waylandSocketPath.len], waylandSocketPath);

    const waylandSocketFD = try std.posix.socket(std.posix.system.AF.UNIX, std.posix.system.SOCK.STREAM, 0);

    try std.posix.connect(waylandSocketFD, @ptrCast(&waylandSocketAddress), @sizeOf(@TypeOf(waylandSocketAddress)));

    return waylandSocketFD;
}

// The wire protocol is a stream of 32-bit values, encoded with the host's byte order (e.g.
// little-endian on x86 family CPUs). These values represent the primitive types, which you can
// view here : https://wayland-book.com/protocol-design/wire-protocol.html.
//
// The wire protocol is a stream of messages built with these primitives. Every message is an event
// (in the case of server to client messages) or request (client to server) which acts upon an
// object.
//
// NOTE : I am using an AMD64 CPU architecture based system, and am only considering Little
// Endiannes for now.

// The message header is two words.
const MessageHeader = packed struct {
    // The first word is the affected object ID.
    objectID: u32,

    // The second is two 16-bit values :
    //
    //	(1) The upper 16 bits are the size of the message (including the header itself)
    //
    //	(2) the lower 16 bits are the event or request opcode.
    //
    // NOTE : Why the hell do they need to make the field ordering dependent on the endianness of
    // the underlying machine?
    opcode: u16,
    messageSize: u16,
};
//
// The message arguments follow, based on a message signature agreed upon in advance by both
// parties.

const Opcodes = struct {
    const get_registry = 1;
};

// Globals in Wayland refer to objects or interfaces that are available globally to all clients.
// These are essentially interfaces that the compositor (server) advertises as available for
// clients to use.
//
// The wl_display is the core global object with ID 1. It's a special singleton object.
//
// The registry in Wayland is a special (non global) object provided by the compositor to clients
// upon connection. It acts like a directory service for all the global objects available. The
// client can get the registry by invoking wl_display::get_registry( ).

const ObjectIDs = struct {
    const WAYLAND_DISPLAY = 1;
};

const WaylandIDAllocator = struct {
    id: u32 = 2,

    fn allocate(self: *WaylandIDAllocator) u32 {
        defer self.id += 1;

        const allocatedID = self.id;
        return allocatedID;
    }
};

// This request creates a registry object that allows the client to list and bind the global
// objects available from the compositor.
//
// When a client creates a registry object, the registry object will emit a global event for each
// global currently in the registry. To mark the end of the initial burst of events, the client can
// use the wl_display.sync( ) request immediately after calling wl_display.get_registry( ).
//
// Globals come and go as a result of device or monitor hotplugs, reconfiguration or other events,
// and the registry will send out global and global_remove events to keep the client up to date
// with the changes.
//
// The error event is sent out when a fatal (non-recoverable) error has occurred. The object_id
// argument is the object where the error occurred, most often in response to a request to that
// object. The code identifies the error and is defined by the object interface. As such, each
// interface defines its own set of error codes. The message is a brief description of the error,
// for (debugging) convenience.
//
// NOTE : The server side resources consumed in events to a get_registry request can only be
// released when the client disconnects, not when the client side proxy is destroyed. Therefore,
// clients should invoke get_registry as infrequently as possible to avoid wasting memory.
fn getRegistryObject(socket: std.posix.socket_t, newId: u32) !void {
    const GetRegistryMessage = packed struct {
        header: MessageHeader,
        newId: u32,
    };

    const message = GetRegistryMessage{
        .header = MessageHeader{
            .objectID = ObjectIDs.WAYLAND_DISPLAY,

            .opcode = Opcodes.get_registry,
            .messageSize = @sizeOf(GetRegistryMessage),
        },
        .newId = newId,
    };

    const bytesWritten = try std.posix.write(socket, std.mem.asBytes(&message));
    std.debug.assert(bytesWritten == @sizeOf(GetRegistryMessage));

    // Initial burst of global events (which is specific to the client only).

    var eventsAsBytes: [4096]u8 = undefined; // event emitted for each global.
    const bytesRead = try std.posix.read(socket, &eventsAsBytes);

    var eventIterator = EventIterator{ .buffer = eventsAsBytes[0..bytesRead] };
    while (eventIterator.next()) |event| {
        std.debug.print("{any}\n", .{event});
    }
}

const EventIterator = struct {
    buffer: []const u8,

    const Event = struct {
        header: MessageHeader,
        data: []const u8,
    };

    fn next(self: *EventIterator) ?Event {
        if (self.buffer.len < @sizeOf(MessageHeader)) {
            return null;
        }

        const headerAsBytes = self.buffer[0..@sizeOf(MessageHeader)];
        const header = std.mem.bytesAsValue(MessageHeader, headerAsBytes);

        // CASE : We haven't received the complete message.
        if (self.buffer.len < header.messageSize) {
            return null;
        }

        const data = self.buffer[@sizeOf(MessageHeader)..header.messageSize];

        // Consume the bytes read, from the buffer.
        self.buffer = self.buffer[header.messageSize..];

        return Event{
            .header = header.*,
            .data = data,
        };
    }
};

pub fn main() !void {
    var generalPurposeAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = generalPurposeAllocator.deinit();

    const allocator = generalPurposeAllocator.allocator();

    const waylandSocket = try createWaylandConnection(allocator);

    var waylandIDAllocator = WaylandIDAllocator{};

    const registryObjectID = waylandIDAllocator.allocate();
    try getRegistryObject(waylandSocket, registryObjectID);
}
