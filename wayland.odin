package wayland

import "base:intrinsics"

import "core:slice"
import "core:sys/linux"

import "common"
import "wl"

WAYLAND_BUFFER_SIZE :: #config(WAYLAND_BUFFER_SIZE, 1 << 12)

Connection      :: common.Connection
Object_Type     :: common.Object_Type
SERVER_ID_START :: common.SERVER_ID_START

@(require_results)
display_connect :: proc(
	socket: linux.Fd,
	allocator := context.allocator,
	log_fn: proc(message: string, user_data: rawptr) = nil,
	user_data: rawptr = nil,
) -> (connection: Connection, display: wl.Display) {
	wl.resolve_type = resolve_type

	connection.socket                 = socket
	connection.buffer_in              = make([]byte, WAYLAND_BUFFER_SIZE,    allocator)
	connection.fds_in                 = make([dynamic]linux.Fd,              allocator)
	connection.fds_out                = make([dynamic]linux.Fd,              allocator)
	connection.free_ids               = make([dynamic]u32,                   allocator)
	connection.server_object_types    = make([dynamic]common.Object_Type,    allocator)
	connection.client_object_types    = make([dynamic]common.Object_Type, 2, allocator)
	connection.client_object_types[1] = .Wl_Display
	connection.log_fn                 = log_fn
	connection.user_data              = user_data
	display                           = 1
	return
}

connection_destroy :: proc(connection: Connection) {
	delete(connection.buffer_in, connection.buffer_out.allocator)
	delete(connection.buffer_out)
	delete(connection.client_object_types)
	delete(connection.server_object_types)
	delete(connection.fds_in)
	delete(connection.fds_out)
	delete(connection.free_ids)
}

CMsg_Hdr :: struct {
	len:          uint,
	level, type:  i32,
}

CMSG_ALIGN :: #force_inline proc "contextless" (len: $T) -> T {
	align :: int(size_of(uint) - 1)
	return (len + align) & ~align
}

CMSG_LEN :: #force_inline proc "contextless" (data_len: int) -> int {
	return size_of(CMsg_Hdr) + data_len
}

CMSG_SPACE :: #force_inline proc "contextless" (data_len: $T) -> T {
	return size_of(CMsg_Hdr) + CMSG_ALIGN(data_len)
}

connection_flush :: proc(connection: ^Connection) {
  if len(connection.buffer_out) == 0 && len(connection.fds_out) == 0 do return

	data := len(connection.fds_out) * size_of(linux.Fd)
  msg := linux.Msg_Hdr{
    iov = {{
      base = raw_data(connection.buffer_out),
      len = len(connection.buffer_out),
    }},
    control = make([]byte, CMSG_SPACE(data), context.temp_allocator),
  }

	hdr      := cast(^CMsg_Hdr)raw_data(msg.control)
	hdr.len   = uint(CMSG_LEN(data))
	hdr.level = i32(linux.SOL_SOCKET)
	hdr.type  = 1

	copy(msg.control[size_of(CMsg_Hdr):], slice.to_bytes(connection.fds_out[:]))

	_, errno := linux.sendmsg(connection.socket, &msg, { .CMSG_CLOEXEC, .NOSIGNAL, })
	if errno == .EAGAIN {
		return
	}
	assert(errno == .NONE)

	clear(&connection.buffer_out)
	clear(&connection.fds_out)
}

connection_poll :: proc(connection: ^Connection) {
	copy(connection.buffer_in, connection.buffer_in[connection.start_in:connection.end_in])
	connection.end_in   = connection.end_in - connection.start_in
	connection.start_in = 0

	msg: linux.Msg_Hdr = {
		iov     = { transmute(linux.IO_Vec)connection.buffer_in[connection.end_in:], },
		control = make([]byte, 16 + 8 * 4, context.temp_allocator),
	}
	hdr      := cast(^struct { len: u64, level, type: i32 })raw_data(msg.control)
	hdr.len   = u64(len(msg.control))
	hdr.level = i32(linux.SOL_SOCKET)
	hdr.type  = 1
	n, errno := linux.recvmsg(connection.socket, &msg, { .CMSG_CLOEXEC, .NOSIGNAL, })
	if errno != nil {
		return
	}
	connection.end_in += n
	if len(msg.control) != 0 {
		append(&connection.fds_in, ..slice.reinterpret([]linux.Fd, msg.control[size_of(hdr^):]))
	}
	assert(errno == .NONE || errno == .EAGAIN)
}

@(require_results)
peek_event :: proc(connection: ^Connection) -> (event: Event, ok: bool) {
	for {
		event, ok = _peek_event(connection)
		if !ok {
			return
		}
		if deleted, ok := event.(wl.Display_Delete_Id_Event); ok {
			append(&connection.free_ids, deleted.id)
		} else {
			return
		}
	}
}

@(require_results)
_peek_event :: proc(connection: ^Connection) -> (event: Event, ok: bool) {
	if connection.end_in - connection.start_in < 8 {
		return
	}

	object: u32
	intrinsics.mem_copy(&object, &connection.buffer_in[connection.start_in], 4)
	opcode, size: u16
	intrinsics.mem_copy(&opcode, &connection.buffer_in[connection.start_in + 4], 2)
	intrinsics.mem_copy(&size,   &connection.buffer_in[connection.start_in + 6], 2)

	assert(int(size) <= len(connection.buffer_in))
	assert(size % 4 == 0)
	assert(size >= 8)

	if connection.end_in - connection.start_in < int(size) {
		return
	}

	object_type: Object_Type
	if int(object) >= SERVER_ID_START {
		object := object - SERVER_ID_START
		if int(object) >= len(connection.server_object_types) {
			return
		}
		object_type = connection.server_object_types[object]
	} else {
		if int(object) >= len(connection.client_object_types) {
			return
		}
		object_type = connection.client_object_types[object]
	}

	prev_start := connection.start_in
	defer if !ok {
		connection.start_in = prev_start
	}

	connection.start_in += 8
	return parse_event(connection, object, object_type, u32(opcode))
}
