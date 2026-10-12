#+build linux
package gbm
foreign import gbm "system:gbm"
import "core:sys/linux"

Device :: distinct rawptr
Surface :: distinct rawptr
BufferObject :: distinct rawptr
Bitfield :: Bo_Use_Flags

// same as DRM fourcc codes
Formats :: enum u32 {
	XRGB8888 = 0x34325258,
	ARGB8888 = 0x34325241,
}

Boa_Use_Flag_Bits :: enum {
	// Buffer is going to be presented to the screen using an API such as KMS
	USE_SCANOUT         = 0,
	// Buffer is going to be used as cursor
	USE_CURSOR          = 1,
	// as the storage for a color buffer
	USE_RENDERING       = 2,
	// with GBM_BO_USE_CURSOR, but may not work for other combinations.
	USE_WRITE           = 3,
	// Buffer is linear, i.e. not tiled.
	USE_LINEAR          = 4,
	// Buffer is protected, i.e. encrypted and not readable by CPU or any
	// OpenCL, and Vulkan applications.
	USE_PROTECTED       = 5,
	// The buffer will be used for front buffer rendering.  On some
	// platforms this may (for example) disable framebuffer compression
	// with pixel data.
	USE_FRONT_RENDERING = 6,
}
Bo_Use_Flags :: bit_set[Boa_Use_Flag_Bits]

Bo_Fixed_Compression_Flag_Bits :: enum u8 {
	// Allow the driver to select fixed-rate compression parameters.
	DEFAULT = 1,
	// Fixed-rate compression= at least 1bpc, less than 2bpc
	BPC_1   = 2,
	// Fixed-rate compression= at least 2bpc, less than 3bpc
	BPC_2   = 3,
	// Fixed-rate compression= at least 3bpc, less than 4bpc
	BPC_3   = 4,
	// Fixed-rate compression= at least 4bpc, less than 5bpc
	BPC_4   = 5,
	// Fixed-rate compression= at least 5bpc, less than 6bpc
	BPC_5   = 6,
	// Fixed-rate compression= at least 6bpc, less than 7bpc
	BPC_6   = 7,
	// Fixed-rate compression= at least 7bpc, less than 8bpc
	BPC_7   = 8,
	// Fixed-rate compression= at least 8bpc, less than 9bpc
	BPC_8   = 9,
	// Fixed-rate compression= at least 9bpc, less than 10bpc
	BPC_9   = 10,
	// Fixed-rate compression= at least 10bpc, less than 11bpc
	BPC_10  = 11,
	// Fixed-rate compression= at least 11bpc, less than 12bpc
	BPC_11  = 12,
	// Fixed-rate compression= at least 12bpc, no maximum rate
	BPC_12  = 13,
}
Bo_Fixed_Compression_Flags :: bit_set[Bo_Fixed_Compression_Flag_Bits;u32]

// Abstraction representing the handle
// to a buffer allocated by the manager
Bo_Handle :: struct #raw_union {
	ptr: rawptr,
	s32: i32,
	u32: u32,
	s64: i64,
	u64: u64,
}

// /usr/include/gbm.h
// https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/gbm/main/gbm.h
@(default_calling_convention = "c", link_prefix = "gbm_")
foreign gbm {
	bo_create :: proc(device: Device, width: u32, height: u32, format: Formats, flags: Bitfield) -> BufferObject ---
	bo_create_with_modifiers :: proc(device: Device, width: u32, height: u32, format: Formats, modifiers: ^u64, count: u32) -> BufferObject ---
	bo_create_with_modifiers2 :: proc(device: Device, width: u32, height: u32, format: Formats, modifiers: ^u64, count: u32, flags: Bitfield) -> BufferObject ---
	bo_destroy :: proc(bo: BufferObject) ---

	create_device :: proc(fd: linux.Fd) -> Device ---
	device_destroy :: proc(device: Device) ---

	surface_create :: proc(device: Device, width: u32, height: u32, format: Formats, flags: Bitfield) -> Surface ---
	surface_create_with_modifiers :: proc(device: Device, width: u32, height: u32, format: Formats, modifiers: ^u64, count: u32) -> Surface ---
	surface_create_with_modifiers2 :: proc(device: Device, width: u32, height: u32, format: Formats, modifiers: ^u64, count: u32, flags: Bitfield) -> Surface ---
	surface_destroy :: proc(surface: Surface) ---
	surface_lock_front_buffer :: proc(surface: Surface) -> BufferObject ---
	surface_release_buffer :: proc(surface: Surface, bo: BufferObject) ---
	surface_has_free_buffers :: proc(surface: Surface) -> u32 ---

	bo_get_width :: proc(bo: BufferObject) -> u32 ---
	bo_get_height :: proc(bo: BufferObject) -> u32 ---
	bo_get_stride :: proc(bo: BufferObject) -> u32 ---
	bo_get_format :: proc(bo: BufferObject) -> u32 ---
	bo_get_fd :: proc(bo: BufferObject) -> i32 ---
	bo_get_plane_count :: proc(bo: BufferObject) -> i32 ---
	bo_get_offset :: proc(bo: BufferObject, plane: i32) -> u32 ---
	bo_get_stride_for_plane :: proc(bo: BufferObject, plane: i32) -> u32 ---
	bo_get_handle_for_plane :: proc(bo: BufferObject, plane: i32) -> Bo_Handle ---
	bo_get_fd_for_plane :: proc(bo: BufferObject, plane: i32) -> i32 ---
	bo_get_modifier :: proc(bo: BufferObject) -> u64 ---
}
