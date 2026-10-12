#+build linux
#+feature using-stmt
package dmabuf_ui

import app "../app"
import ui "../ui"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "egl"
import "gbm"
import gl "vendor:OpenGL"
import wayl "../../"
import wl "../../wl"
import wp "../../wp"
import xdg "../../xdg"
import zwp "../../zwp"

Dmabuf_Format_Modifier :: struct {
	format:   u32,
	modifier: u64,
}

Dmabuf_Tranche :: struct {
	target_device: [8]u8,
	flags:         zwp.Linux_Dmabuf_Feedback_V1_Tranche_Flags,
	formats:       [dynamic]Dmabuf_Format_Modifier,
}

Dmabuf_Feedback :: struct {
	main_device:  [8]u8,
	format_table: [dynamic]Dmabuf_Format_Modifier,
	tranches:     [dynamic]Dmabuf_Tranche,
	current:      Dmabuf_Tranche,
}

MAX_POOL_SIZE :: app.BUF_WIDTH * app.BUF_HEIGHT * 4 * 4
BUF_LEN :: 4
State :: struct {
	buffer_size, stride, w, h:           u32,
	tick:                                u32,
	keymap, use_software, should_redraw: bool,
	status:                              Status,

	// WL
	wl_registry:                         wl.Registry,
	wl_buffer:                           [BUF_LEN]wl.Buffer,
	xdg_wm_base:                         xdg.Wm_Base,
	xdg_surface:                         xdg.Surface,
	wl_surface:                          wl.Surface,
	surface_callback:                    wl.Callback,
	wl_compositor:                       wl.Compositor,
	xdg_toplevel:                        xdg.Toplevel,
	wl_seat:                             wl.Seat,
	wl_pointer:                          wl.Pointer,
	wl_keyboard:                         wl.Keyboard,
	data_device_manager:                 wl.Data_Device_Manager,
	data_source:                         wl.Data_Source,
	cursor_shape_manager:                wp.Cursor_Shape_Manager_V1,

	// EGL
	egl_display:                         egl.Display,
	egl_surface:                         egl.Surface,
	egl_context:                         egl.Context,

	// GBM
	drm_fd:                              linux.Fd,
	gbm_device:                          gbm.Device,
	gbm_surface:                         gbm.Surface,
	zwp_linux_dmabuf:                    zwp.Linux_Dmabuf_V1,
	prog2d:                              Program2D,

	// SHM
	shm_fd:                              linux.Fd,
	wl_shm:                              wl.Shm,
	wl_shm_pool:                         wl.Shm_Pool,
	shm_pool_data:                       []u8,
	dmabuf_feedback:                     Dmabuf_Feedback,
	app:                                 app.State,
}

BufferStatus :: enum {
	Initialized,
	Failed,
	Busy,
	Ready,
}
Gbo :: struct {
	bo:         gbm.BufferObject,
	status:     BufferStatus,
	buffer:     wl.Buffer,
	egl_image:  egl.Image,
	gl_texture: u32,
	gl_fbo:     u32,
	plane_fds:  [4]linux.Fd,
	zwp_params: zwp.Linux_Buffer_Params_V1,
}
gbo: #soa[BUF_LEN]Gbo

Error :: enum {
	None,
	Crash,
	NoWayland,
}
Status :: enum {
	None,
	SurfaceAckedConfigure,
	SurfaceAttached,
}
GL :: #config(GL, true)
WL_DBG :: #config(WL_DBG, false)



n: int = 0
draw :: proc(conn: ^wl.Connection, st: ^State, i: u32) {
	fmt.println(n, "====================DRAW====================")
	n = 1 + n
	if st.use_software {
		if !st.should_redraw do return
		i := i % len(st.wl_buffer)
		wl.surface_frame(conn, st.wl_surface)
		app.update_render(st.shm_pool_data[((i)) * st.buffer_size:][:st.buffer_size], st.w, st.h)
		wl.surface_attach(conn, st.wl_surface, st.wl_buffer[i], 0, 0)
		wl.surface_damage_buffer(conn, st.wl_surface, 0, 0, i32(st.w), i32(st.h))
		st.keymap
		wl.surface_commit(conn, st.wl_surface)
		st.should_redraw = false
		return
	}

	slot, ok := window_next_buffer()
	if !ok {
		log.warn("all buffers busy, skipping frame")
		return
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, gbo[slot].gl_fbo)
	gl.Viewport(0, 0, i32(st.w), i32(st.h))

	utx: ui.Context
	size: [2]f32 = {f32(st.w), f32(st.h)}
	if ui.start(&utx, size) {
		app.make_ui(&utx, &st.app)
	}
	rr_frame(&utx, &st.prog2d, size)
	gl.Flush()


	fmt.println(n, "====================PRESENT====================")

	wl.surface_frame(conn, st.wl_surface)
	wl.surface_attach(conn, st.wl_surface, gbo[slot].buffer, 0, 0)
	wl.surface_damage_buffer(conn, st.wl_surface, 0, 0, i32(st.w), i32(st.h))
	wl.surface_commit(conn, st.wl_surface)

	gbo[slot].status = .Busy
	st.should_redraw = false
	fmt.println(n, "====================END DRAW====================")

}
window_next_buffer :: proc() -> (slot: int, ok: bool) {
	for &g, i in gbo {
		if g.status == .Ready do return i, true
	}
	return -1, false
}

create_objects :: proc(conn: ^wl.Connection, st: ^State) -> linux.Errno {
	wayl.connection_flush(conn) or_return
	wayl.connection_poll(conn)
	if exit := receive_events(conn, st); exit do return .NONE

	assert(st.wl_compositor != 0)
	assert(st.xdg_wm_base != 0)
	assert(st.wl_seat != 0)

	st.wl_surface = wl.compositor_create_surface(conn, st.wl_compositor)
	st.xdg_surface = xdg.wm_base_get_xdg_surface(conn, st.xdg_wm_base, st.wl_surface)
	st.xdg_toplevel = xdg.surface_get_toplevel(conn, st.xdg_surface)
	st.wl_keyboard = wl.seat_get_keyboard(conn, st.wl_seat)
	st.wl_pointer = wl.seat_get_pointer(conn, st.wl_seat)

	xdg.toplevel_set_title(conn, st.xdg_toplevel, app.TITLE)
	xdg.toplevel_set_app_id(conn, st.xdg_toplevel, app.APP_ID)
	wl.surface_commit(conn, st.wl_surface)
	if st.zwp_linux_dmabuf != 0 {
		zwp.linux_dmabuf_v1_get_surface_feedback(conn, st.zwp_linux_dmabuf, st.wl_surface)
	}

	wayl.connection_flush(conn) or_return
	wayl.connection_poll(conn)
	if exit := receive_events(conn, st); exit do return .NONE

	if st.use_software {
		using st
		if wl_shm != 0 && wl_shm_pool == 0 && wl_buffer == 0 {
			wl_shm_pool = wl.shm_create_pool(conn, wl_shm, auto_cast shm_fd, i32(MAX_POOL_SIZE))
			for &b, i in wl_buffer {
				b = wl.shm_pool_create_buffer(
					conn,
					wl_shm_pool,
					i32(u32(i) * buffer_size),
					i32(w),
					i32(h),
					i32(stride),
					.Argb8888,
				)
			}
			assert(len(shm_pool_data) != 0)
			assert(buffer_size != 0)
		}
	} else {
		if !create_display_hw(conn, st) {
			log.error("Error in GL creation")
			return .EADV
		}
		create_err := create_window(conn, st)
		if !create_err do return .EIO
	}
	return .NONE
}

connect_display :: proc() -> (conn: wl.Connection, display: wl.Display, ok: bool) {
	socket := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, {}) or_else panic("")
	addr: linux.Sock_Addr_Un = {
		sun_family = .UNIX,
	}
	fmt.bprintf(
		addr.sun_path[:],
		"%v/%v",
		os.get_env("XDG_RUNTIME_DIR", context.temp_allocator),
		os.get_env("WAYLAND_DISPLAY", context.temp_allocator),
	)

	if err := linux.connect(socket, &addr); err != .NONE {
		log.error("Wayland connection failed:", err)
		return
	}

	conn, display = wayl.display_connect(
		socket,
		log_fn = proc(message: string, user_pointer: rawptr) {
			if os.get_env("WAYLAND_DEBUG", context.temp_allocator) == "1" || WL_DBG {
				fmt.println("WL EV: ", message)
			}
		},
	)
	// conn.object_types = make([dynamic]wl.Object_Type, 2)
	// conn.object_types[1] = .Display

	return conn, display, true
}

create_shm_file :: proc(fb: ^[]u8, size: u32) -> (shm_fd: linux.Fd, err: linux.Errno) {
	shm_fd = linux.Fd(
		linux.syscall(linux.SYS_memfd_create, transmute(^u8)(cstring("wayland-shm")), 1),
	)
	// shm_fd = memfd_create("wayland-shm") or_return
	linux.ftruncate(shm_fd, i64(size)) or_return
	shm_ptr, mmap_err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, shm_fd)
	if mmap_err != .NONE {
		linux.close(shm_fd)
		return 0, mmap_err
	}
	fb^ = mem.slice_ptr(cast(^byte)shm_ptr, int(size))
	return shm_fd, .NONE
}


@(private)
receive_events :: proc(conn: ^wl.Connection, st: ^State) -> (exit: bool) {
	for ev in wayl.peek_event(conn) {
		#partial switch e in ev {
		case wl.Registry_Global_Event:
			switch e.interface {
			case wl.SHM_INTERFACE:
				if st.use_software {
					st.wl_shm = wl.registry_bind(
						conn,
						st.wl_registry,
						e.name,
						e.interface,
						e.version,
						wl.Shm,
					)
				}
			case xdg.WM_BASE_INTERFACE:
				st.xdg_wm_base = wl.registry_bind(
					conn,
					st.wl_registry,
					e.name,
					e.interface,
					e.version,
					xdg.Wm_Base,
				)
			case wl.COMPOSITOR_INTERFACE:
				st.wl_compositor = wl.registry_bind(
					conn,
					st.wl_registry,
					e.name,
					e.interface,
					e.version,
					wl.Compositor,
				)
			case wl.SEAT_INTERFACE:
				st.wl_seat = wl.registry_bind(
					conn,
					st.wl_registry,
					e.name,
					e.interface,
					e.version,
					wl.Seat,
				)
			case zwp.LINUX_DMABUF_V1_INTERFACE:
				st.zwp_linux_dmabuf = wl.registry_bind(
					conn,
					st.wl_registry,
					e.name,
					e.interface,
					e.version,
					zwp.Linux_Dmabuf_V1,
				)
			// zwp_linux_dmabuf_v1_get_default_feedback(conn, st.zwp_linux_dmabuf)
			}
		case wl.Display_Error_Event:
			log.error("[ERROR] code:", e.code, "::", e.object_id, e.message)
		case wl.Shell_Surface_Ping_Event:
			xdg.wm_base_pong(conn, xdg.Wm_Base(e.object), e.serial)
		case xdg.Surface_Configure_Event:
			xdg.surface_ack_configure(conn, st.xdg_surface, e.serial)
			st.status = .SurfaceAckedConfigure
		case wl.Shm_Format_Event:
			if e.format == .Argb8888 {
				fmt.println("ARGB8888 supported by compositor!")
			}
		case xdg.Toplevel_Configure_Event:
			if st.use_software {
				if e.height == 0 || e.width == 0 do break
				if st.wl_buffer != 0 && i32(st.buffer_size) != e.height * e.width * 4 {
					resize_pool(st, e.width, e.height)
					for &b, i in st.wl_buffer {
						if b != 0 do wl.buffer_destroy(conn, b)
						b = wl.shm_pool_create_buffer(
							conn,
							st.wl_shm_pool,
							i32(i) * i32(st.buffer_size),
							i32(st.w),
							i32(st.h),
							i32(st.stride),
							.Argb8888,
						)
					}
					st.status = .None
				}
				if (st.wl_shm_pool != 0 && st.buffer_size * 2 > MAX_POOL_SIZE) {
					wl.shm_pool_resize(conn, st.wl_shm_pool, i32(st.buffer_size))
				}
			}
		case xdg.Toplevel_Close_Event:
			return true
		case wl.Callback_Done_Event:
			log.info("wl.Callback_Done_Event")
			when ODIN_DEBUG do log.infof("%ims", e.callback_data - st.tick)
			st.tick = e.callback_data
			st.should_redraw = true
		case xdg.Toplevel_Configure_Bounds_Event:
		case xdg.Toplevel_Wm_Capabilities_Event:
		case wl.Buffer_Release_Event:
			released_buffer := e.object
			for &e in gbo {
				if e.buffer == released_buffer {
					e.status = .Ready
					break
				}
			}

		case zwp.Linux_Dmabuf_Feedback_V1_Main_Device_Event:
			clear(&st.dmabuf_feedback.tranches)
			copy(st.dmabuf_feedback.main_device[:], e.device[:])
			log.debug("main_device", e.device)
		case zwp.Linux_Dmabuf_Feedback_V1_Format_Table_Event:
			size := uint(e.size)
			ptr, mmap_err := linux.mmap(0, size, {.READ}, {.PRIVATE}, e.fd)
			linux.close(e.fd)
			if mmap_err != .NONE {
				log.error("Failed to mmap format table", mmap_err)
				break
			}
			clear(&st.dmabuf_feedback.format_table)
			count := size / 16
			raw := mem.slice_ptr(cast(^u8)ptr, int(e.size))
			for i in 0 ..< count {
				base := i * 16
				format := (^u32)(&raw[base])^
				modifier := (^u64)(&raw[base + 8])^
				append(&st.dmabuf_feedback.format_table, Dmabuf_Format_Modifier{format, modifier})
			}
			linux.munmap(ptr, size)
		case zwp.Linux_Dmabuf_Feedback_V1_Tranche_Target_Device_Event:
			copy(st.dmabuf_feedback.current.target_device[:], e.device[:])
		case zwp.Linux_Dmabuf_Feedback_V1_Tranche_Flags_Event:
			st.dmabuf_feedback.current.flags = e.flags

		case zwp.Linux_Dmabuf_Feedback_V1_Tranche_Formats_Event:
			// e.indices indexes into the mmap'd format_table, NOT a direct
			// (format, modifier) pair itself
			for idx in e.indices {
				if int(idx) < len(st.dmabuf_feedback.format_table) {
					append(
						&st.dmabuf_feedback.current.formats,
						st.dmabuf_feedback.format_table[idx],
					)
				}
			}
		case zwp.Linux_Dmabuf_Feedback_V1_Tranche_Done_Event:
			append(&st.dmabuf_feedback.tranches, st.dmabuf_feedback.current)
			log.debug(st.dmabuf_feedback.current.target_device, st.dmabuf_feedback.current.flags)
			// reset scratch state for next tranche
			st.dmabuf_feedback.current = {}
		case zwp.Linux_Dmabuf_Feedback_V1_Done_Event:
			log.info(
				"=== dmabuf feedback complete:",
				len(st.dmabuf_feedback.tranches),
				"tranches ===",
			)

		case wl.Seat_Capabilities_Event:
			capabilities := e.capabilities
		case wl.Seat_Name_Event:
		case wl.Keyboard_Keymap_Event:
			assert(e.format == .Xkb_V1)
			fd: linux.Fd = auto_cast e.fd
			if (!st.keymap) {
				if ptr, err := linux.mmap(0, uint(e.size), {.READ}, {.PRIVATE}, fd); err != .NONE {
					log.error("mmap failed, ", err)
					linux.close(fd)
					return false
				} else {
					st.keymap = true
					linux.munmap(ptr, uint(e.size))
				}
				linux.close(fd)
			}
		case zwp.Linux_Buffer_Params_V1_Created_Event:
			found := false
			for &b in gbo {
				if b.zwp_params == e.object {
					found = true
					b.status = .Ready
					b.buffer = e.buffer
					b.zwp_params = 0
					zwp.linux_buffer_params_v1_destroy(conn, e.object)
				}
			}
			if !found {
				log.error("Could not locate Gbo to associate with wl_buffer")
				return false
			}
		case zwp.Linux_Buffer_Params_V1_Failed_Event:
			found := false
			for &b, slot in gbo {
				if b.zwp_params == e.object {
					log.error("Buffer creation failed for slot", slot)
					found = true
					b.status = .Failed
					b.zwp_params = 0
					zwp.linux_buffer_params_v1_destroy(conn, e.object)
				}
			}
			if !found {
				log.error("Could not locate Gbo to associate with wl_buffer")
				return false
			}
		}
	}
	return false
}

resize_pool :: proc(state: ^State, w, h: i32) {
	state.w = auto_cast w
	state.h = auto_cast h
	state.stride = state.w * 4
	state.buffer_size = state.stride * state.h
}

quit :: proc(conn: ^wl.Connection, state: State) {
	// TODO: Single destroy command for any wl.object
	for b in state.wl_buffer {
		if b != 0 do wl.buffer_destroy(conn, b)
	}
	if state.wl_shm_pool != 0 do wl.shm_pool_destroy(conn, state.wl_shm_pool)
	if state.xdg_toplevel != 0 do xdg.toplevel_destroy(conn, state.xdg_toplevel)
	if state.xdg_surface != 0 do xdg.surface_destroy(conn, state.xdg_surface)
	if state.wl_surface != 0 do wl.surface_destroy(conn, state.wl_surface)
	if state.wl_seat != 0 do wl.seat_release(conn, state.wl_seat)
	if state.wl_keyboard != 0 do wl.keyboard_release(conn, state.wl_keyboard)
	if state.wl_pointer != 0 do wl.pointer_release(conn, state.wl_pointer)
	wayl.connection_flush(conn)
	if len(state.shm_pool_data) > 0 {
		linux.munmap(raw_data(state.shm_pool_data), len(state.shm_pool_data))
	}
	linux.close(state.shm_fd)
	linux.close(conn.socket)
	// delete(conn.object_types)
	delete(conn.fds_in)
	delete(conn.fds_out)
	delete(conn.free_ids)
	log.info("closed safely")
	// bytes.buffer_destroy(&conn.buffer)
}

open_drm_device :: proc() -> (fd: linux.Fd, ok: bool) {
	render_nodes := []cstring {
		"/dev/dri/renderD128",
		"/dev/dri/renderD129",
		"/dev/dri/card1",
		"/dev/dri/card2",
	}

	for node in render_nodes {
		fd_int, err := linux.open(node, {.RDWR}, {})
		if err == .NONE {
			log.debugf("Opened DRM device: %s", node)
			return linux.Fd(fd_int), true
		}
	}

	log.debug("Failed to open any DRM device")
	return 0, false
}

/* 
  Info may be found in Mesa's implementation at src/egl/drivers/dri2/platform_wayland.c"
 * https://ziggit.dev/t/drawing-with-opengl-without-glfw-or-sdl-on-linux/3175/12
 * https://blaztinn.gitlab.io/post/dmabuf-texture-sharing/
 */

// https://registry.khronos.org/EGL/sdk/docs/man/html/eglIntro.xhtml
create_display_hw :: proc(conn: ^wayl.Connection, st: ^State) -> bool {
	st.drm_fd = open_drm_device() or_return
	st.gbm_device = gbm.create_device(st.drm_fd)
	if st.gbm_device == {} {
		log.error("gbm_create_device failed")
		return false
	}

	assert(st.wl_surface != 0)
	egl.BindAPI(egl.OPENGL_API)

	st.egl_display = egl.GetPlatformDisplay(.GBM_KHR, st.gbm_device, nil)
	if st.egl_display == egl.NO_DISPLAY {
		log.error("Failed to create egl display")
		return false
	}

	major, minor: i32
	if !egl.Initialize(st.egl_display, &major, &minor) {
		log.error("Failed to initialize egl")
		return false
	}
	log.infof("EGLv%i.%i Initialized", major, minor)

	extensions := string(egl.QueryString(st.egl_display, 0x3055))

	if extensions == "" {
		log.error("eglQueryString(EGL_EXTENSIONS) returned empty")
		return false
	}
	if !egl.has_egl_extension(extensions, "EGL_EXT_image_dma_buf_import") {
		log.error("EGL_EXT_image_dma_buf_import not supported")
		return false
	}
	if !egl.has_egl_extension(extensions, "EGL_KHR_surfaceless_context") {
		log.error("EGL_KHR_surfaceless_context not supported")
		return false
	}

	has_no_config := egl.has_egl_extension(extensions, "EGL_KHR_no_config_context")
	egl_config := egl.NO_CONFIG_KHR
	if !has_no_config {
		log.warn("EGL_KHR_no_config_context not supported")
		config_attribs := []i32 {
			egl.SURFACE_TYPE,
			egl.WINDOW_BIT,
			egl.RENDERABLE_TYPE,
			egl.OPENGL_BIT,
			egl.RED_SIZE,
			8,
			egl.GREEN_SIZE,
			8,
			egl.BLUE_SIZE,
			8,
			egl.NONE,
		}
		MAX_CONFIGS :: 256
		configs: [MAX_CONFIGS]egl.Config
		num_configs: i32

		if !egl.ChooseConfig(
			st.egl_display,
			&config_attribs[0],
			&configs[0],
			MAX_CONFIGS,
			&num_configs,
		) {
			log.error("Failed to choose egl config")
			return false
		}
		log.debug("configs matched: ", num_configs)

		egl_config: egl.Config
		found := false
		for i in 0 ..< num_configs {
			visual_id: i32
			egl.GetConfigAttrib(st.egl_display, configs[i], egl.NATIVE_VISUAL_ID, &visual_id)
			if u32(visual_id) == u32(gbm.Formats.XRGB8888) {
				egl_config = configs[i]
				found = true
				break
			}
		}
		if !found {
			log.error("unable to find matching egl config")
			return false
		}
	}

	if !egl.BindAPI(egl.OPENGL_API) {
		log.error("Bind API failed")
		return false
	}

	context_attribs := []i32 {
		egl.CONTEXT_MAJOR_VERSION,
		GL_MAJOR,
		egl.CONTEXT_MINOR_VERSION,
		GL_MINOR,
		egl.NONE,
	}

	st.egl_context = egl.CreateContext(
		st.egl_display,
		egl_config,
		egl.NO_CONTEXT,
		&context_attribs[0],
	)
	if (st.egl_context == egl.NO_CONTEXT) {
		log.error("egl_context creation failed:", egl.get_error())
		return false
	}
	log.debug(st.egl_context, "egl_context created")

	if !egl.MakeCurrent(st.egl_display, egl.NO_SURFACE, egl.NO_SURFACE, st.egl_context) {
		log.error("eglMakeCurrent (surfaceless) failed", egl.get_error())
		return false
	}

	egl.load_extensions()
	if egl.CreateImageKHR == nil || egl.DestroyImageKHR == nil {
		log.error("eglCreateImageKHR/eglDestroyImageKHR not available")
		return false
	}
	if egl.EGLImageTargetTexture2DOES == nil {
		log.error("glEGLImageTargetTexture2DOES not available")
		return false
	}

	if egl.has_egl_extension(extensions, "EGL_EXT_image_dma_buf_import_modifiers") &&
	   egl.QueryDmaBufModifiersEXT == nil {
		log.warn("EGL_EXT_image_dma_buf_import_modifiers advertised but proc load failed")
	}


	// st.egl_surface = egl.CreatePlatformWindowSurface(st.egl_display, egl_config, gbm_surface, {})
	// if (st.egl_surface == egl.NO_SURFACE) {
	// 	log.error("egl_surface creation failed:", egl.get_error())
	// 	return false
	// }

	// if !egl.MakeCurrent(st.egl_display, st.egl_surface, st.egl_surface, st.egl_context) {
	// 	log.error("Failed to make egl context current:", egl.get_error())
	// 	return false
	// }
	// w, h: i32
	// egl.QuerySurface(st.egl_display, st.egl_surface, egl.WIDTH, &w)
	// egl.QuerySurface(st.egl_display, st.egl_surface, egl.HEIGHT, &h)
	// assert(u32(w) == st.w)
	// log.debugf("EGL Context Current. size:%ix%i:", w, h)

	// st.gbm_device = gbm_device
	// st.gbm_surface = gbm_surface

	gl.load_up_to(GL_MAJOR, GL_MINOR, egl.set_proc_address)
	log.infof("OpenGL %s", gl.GetString(gl.VERSION))
	log.infof("Renderer: %s", gl.GetString(gl.RENDERER))

	// gl.Viewport(0, 0, i32(st.w), i32(st.h))
	if prog2d, ok := rr_make_program(); ok {
		st.prog2d = prog2d
	} else {
		log.error("failed to initialize shader program")
		return false
	}
	gl.Disable(gl.BLEND)

	log.info("\n========= OPENGL READY ============\n")
	return true
}

create_window :: proc(conn: ^wl.Connection, st: ^State) -> bool {
	for slot in 0 ..< BUF_LEN {
		if !create_dmabuf_buffer(conn, st, slot) {
			log.error("create_window: failed to create buffer at slot", slot)
			return false
		}
	}
	return true
}

is_ccs_modifier :: proc(mod: u64) -> bool {
	// Intel CCS modifiers
	I915_FORMAT_MOD_Y_TILED_CCS :: 0x0100000000000002
	I915_FORMAT_MOD_Y_TILED_GEN12_RC_CCS :: 0x0100000000000004
	I915_FORMAT_MOD_Y_TILED_GEN12_MC_CCS :: 0x0100000000000005
	I915_FORMAT_MOD_Y_TILED_GEN12_RC_CCS_CC :: 0x0100000000000006

	return(
		mod == I915_FORMAT_MOD_Y_TILED_CCS ||
		mod == I915_FORMAT_MOD_Y_TILED_GEN12_RC_CCS ||
		mod == I915_FORMAT_MOD_Y_TILED_GEN12_MC_CCS ||
		mod == I915_FORMAT_MOD_Y_TILED_GEN12_RC_CCS_CC \
	)
}

create_dmabuf_buffer :: proc(conn: ^wl.Connection, st: ^State, slot: int) -> bool {
	format := gbm.Formats.XRGB8888

	// Gather tranche-advertised modifiers for this format .
	mods: [dynamic]u64
	defer delete(mods)
	for tranche in st.dmabuf_feedback.tranches {
		for fm in tranche.formats {
			if fm.format == u32(format) {
				append(&mods, fm.modifier)
			}
		}
	}

	// egl intersection
	egl_mods: [dynamic]u64
	defer delete(egl_mods)
	if egl.QueryDmaBufModifiersEXT != nil {
		max_mods: i32 = 64
		egl_mod_array: [64]u64
		num_egl_mods: i32
		egl.QueryDmaBufModifiersEXT(
			st.egl_display,
			i32(format),
			max_mods,
			&egl_mod_array[0],
			nil,
			&num_egl_mods,
		)

		for comp_mod in mods {
			for egl_mod in egl_mod_array[:num_egl_mods] {
				if comp_mod == egl_mod {
					append(&egl_mods, comp_mod)
					break
				}
			}
		}
	} else {
		assert(false)
		// append(&egl_mods, gbm.XDG_RUNTIME_DIR)
	}

	bo: gbm.BufferObject
	if len(egl_mods) > 0 {
		bo = gbm.bo_create_with_modifiers2(
			st.gbm_device,
			st.w,
			st.h,
			format,
			raw_data(egl_mods),
			u32(len(egl_mods)),
			{.USE_RENDERING},
		)
	}
	if bo == {} {
		bo = gbm.bo_create(st.gbm_device, st.w, st.h, format, {.USE_RENDERING})
	}
	if bo == {} {
		log.error("gbm_bo_create failed for slot", slot)
		return false
	}

	modifier := gbm.bo_get_modifier(bo)
	plane_count := gbm.bo_get_plane_count(bo)
	if plane_count > 4 {
		log.error("plane_count", plane_count, "exceeds MAX_BUFFER_PLANES (4)")
		return false
	}

	fds_to_close_on_failure: [dynamic]i32
	defer {
		for fd in fds_to_close_on_failure {
			linux.close(linux.Fd(fd))
		}
		delete(fds_to_close_on_failure)
	}

	zwp_params := zwp.linux_dmabuf_v1_create_params(conn, st.zwp_linux_dmabuf)
	plane_fds: [4]linux.Fd
	offsets, strides: [4]u32
	for plane in 0 ..< plane_count {
		offset := gbm.bo_get_offset(bo, plane)
		stride := gbm.bo_get_stride_for_plane(bo, plane)
		plane_fd := gbm.bo_get_fd_for_plane(bo, plane)
		if plane_fd <= 0 {
			log.error("bo_get_fd_for_plane failed for plane", plane)
			return false
		}
		append(&fds_to_close_on_failure, plane_fd)
		plane_fds[plane] = linux.Fd(plane_fd)
		offsets[plane] = offset
		strides[plane] = stride

		zwp.linux_buffer_params_v1_add(
			conn,
			zwp_params,
			auto_cast plane_fd,
			u32(plane),
			offset,
			stride,
			u32(modifier >> 32),
			u32(modifier & 0xFFFFFFFF),
		)
	}

	zwp.linux_buffer_params_v1_create(conn, zwp_params, i32(st.w), i32(st.h), u32(format), {})

	// --- EGLImage import, using the SAME fds just sent to the compositor ---
	attribs: [6 + 4 * 10 + 1]i32
	i := 0
	attribs[i] = egl.WIDTH; i += 1; attribs[i] = i32(st.w); i += 1
	attribs[i] = egl.HEIGHT; i += 1; attribs[i] = i32(st.h); i += 1
	attribs[i] = egl.LINUX_DRM_FOURCC_EXT; i += 1; attribs[i] = i32(format); i += 1

	plane_fd_attrs := [4]i32 {
		egl.DMA_BUF_PLANE0_FD_EXT,
		egl.DMA_BUF_PLANE1_FD_EXT,
		egl.DMA_BUF_PLANE2_FD_EXT,
		egl.DMA_BUF_PLANE3_FD_EXT,
	}
	plane_offset_attrs := [4]i32 {
		egl.DMA_BUF_PLANE0_OFFSET_EXT,
		egl.DMA_BUF_PLANE1_OFFSET_EXT,
		egl.DMA_BUF_PLANE2_OFFSET_EXT,
		egl.DMA_BUF_PLANE3_OFFSET_EXT,
	}
	plane_pitch_attrs := [4]i32 {
		egl.DMA_BUF_PLANE0_PITCH_EXT,
		egl.DMA_BUF_PLANE1_PITCH_EXT,
		egl.DMA_BUF_PLANE2_PITCH_EXT,
		egl.DMA_BUF_PLANE3_PITCH_EXT,
	}
	plane_mod_lo_attrs := [4]i32 {
		egl.DMA_BUF_PLANE0_MODIFIER_LO_EXT,
		egl.DMA_BUF_PLANE1_MODIFIER_LO_EXT,
		egl.DMA_BUF_PLANE2_MODIFIER_LO_EXT,
		egl.DMA_BUF_PLANE3_MODIFIER_LO_EXT,
	}
	plane_mod_hi_attrs := [4]i32 {
		egl.DMA_BUF_PLANE0_MODIFIER_HI_EXT,
		egl.DMA_BUF_PLANE1_MODIFIER_HI_EXT,
		egl.DMA_BUF_PLANE2_MODIFIER_HI_EXT,
		egl.DMA_BUF_PLANE3_MODIFIER_HI_EXT,
	}

	for plane in 0 ..< plane_count {
		attribs[i] = plane_fd_attrs[plane]; i += 1; attribs[i] = i32(plane_fds[plane]); i += 1
		attribs[i] = plane_offset_attrs[plane]; i += 1; attribs[i] = i32(offsets[plane]); i += 1
		attribs[i] = plane_pitch_attrs[plane]; i += 1; attribs[i] = i32(strides[plane]); i += 1
		if egl.QueryDmaBufModifiersEXT != nil {
			attribs[i] =
				plane_mod_lo_attrs[plane]; i += 1; attribs[i] = i32(modifier & 0xFFFFFFFF); i += 1
			attribs[i] =
				plane_mod_hi_attrs[plane]; i += 1; attribs[i] = i32(modifier >> 32); i += 1
		}
	}
	attribs[i] = egl.NONE

	image := egl.CreateImageKHR(
		st.egl_display,
		egl.NO_CONTEXT,
		egl.LINUX_DMA_BUF_EXT,
		nil,
		&attribs[0],
	)
	if image == egl.NO_IMAGE_KHR {
		log.error("eglCreateImageKHR failed for slot", slot, ":", egl.get_error())
		return false
	}

	tex, fbo: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE)
	egl.EGLImageTargetTexture2DOES(gl.TEXTURE_2D, image)

	gl.GenFramebuffers(1, &fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0)
	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
		log.error("FBO incomplete for slot", slot)
		egl.DestroyImageKHR(st.egl_display, image)
		return false
	}

	// success — ownership moves to gbo[slot].
	clear(&fds_to_close_on_failure)
	gbo[slot] = Gbo {
		bo         = bo,
		buffer     = 0,
		egl_image  = image,
		gl_texture = tex,
		gl_fbo     = fbo,
		plane_fds  = plane_fds,
		status     = .Initialized,
		zwp_params = zwp_params,
	}
	return true
}

main :: proc() -> Error {
  conn, display, ok := connect_display()
	if !ok do return .NoWayland
	st := State {
		wl_registry   = wl.display_get_registry(&conn, display),
		w             = 500,
		h             = 500,
		use_software  = !GL,
		should_redraw = true,
	}

	st.stride = st.w * 4
	if st.use_software {
		st.buffer_size = st.stride * st.h

		shm_fd, shm_err := create_shm_file(&st.shm_pool_data, MAX_POOL_SIZE)
		if shm_err != .NONE {
			return .Crash
		}
		st.shm_fd = shm_fd
	}
	defer quit(&conn, st)
	if err := create_objects(&conn, &st); err != .NONE {
		log.error("Initial object creation failed", err)
		return .Crash
	}
	log.info("Initial object creation passed")
	log.info("Entering main loop")

	i: u8 = 0
	m: for {
		if err := wayl.connection_flush(&conn); err != .NONE {
			log.error("FLUSH Error:", err)
			receive_events(&conn, &st)
			return .Crash
		}

		{
			result, _ := linux.poll({linux.Poll_Fd{fd = conn.socket, events = {.IN}}}, 2)
			if result > 0 {
				wayl.connection_poll(&conn)
				if exit := receive_events(&conn, &st); exit do return .None
				// conn.data_cursor = 0
				// conn.data = {}
			}
		}
		if st.status == .None do continue
		if st.should_redraw do draw(&conn, &st, u32(i))
		i += 1
	}
	return .None
}
