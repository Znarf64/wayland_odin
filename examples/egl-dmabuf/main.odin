package egl_dmabuf

import wayl "../../"
import wl "../../wl"
import xdg "../../xdg"
import zwp "../../zwp"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "egl"
import "gbm"
import gl "vendor:OpenGL"


WL_DBG :: #config(WL_DBG, false)

GL_MAJOR :: 3
GL_MINOR :: 3
FRAME_CACHE_LEN :: 8
MAX_LOCKED_BUFFERS :: 3

State :: struct {
	w, h:           u32,
	should_redraw: bool,
	status:                              Status,

	// WL
	wl_registry:                         wl.Registry,
	xdg_wm_base:                         xdg.Wm_Base,
	xdg_surface:                         xdg.Surface,
	wl_surface:                          wl.Surface,
	wl_compositor:                       wl.Compositor,
	xdg_toplevel:                        xdg.Toplevel,

	// EGL
	egl_display:                         egl.Display,
	egl_context:                         egl.Context,
	egl_surface:                         egl.Surface,

	// GBM
	drm_fd:                              linux.Fd,
	gbm_device:                          gbm.Device,
	gbm_surface:                         gbm.Surface,
	zwp_linux_dmabuf:                    zwp.Linux_Dmabuf_V1,
	frame_buffers:                       [FRAME_CACHE_LEN]Frame_Buffer
}

Frame_Buffer :: struct {
  bo:     gbm.BufferObject,
  buffer: wl.Buffer,
  locked: bool
}

BufferStatus :: enum {
	Initialized,
	Failed,
	Busy,
	Ready,
}

Status :: enum {
	None,
	SurfaceAckedConfigure,
}


create_objects :: proc(conn: ^wl.Connection, st: ^State) -> (ok: bool) {
	wayl.connection_flush(conn)
	wayl.connection_poll(conn)
	if exit := receive_events(conn, st); exit do return true

	assert(st.xdg_wm_base != 0)

	st.wl_surface = wl.compositor_create_surface(conn, st.wl_compositor)
	st.xdg_surface = xdg.wm_base_get_xdg_surface(conn, st.xdg_wm_base, st.wl_surface)
	st.xdg_toplevel = xdg.surface_get_toplevel(conn, st.xdg_surface)

	xdg.toplevel_set_title(conn, st.xdg_toplevel, "egl-dmabuf")
	xdg.toplevel_set_app_id(conn, st.xdg_toplevel, "egl-dmabuf")
	wl.surface_commit(conn, st.wl_surface)
	if st.zwp_linux_dmabuf != 0 {
		zwp.linux_dmabuf_v1_get_surface_feedback(conn, st.zwp_linux_dmabuf, st.wl_surface)
	}

	wayl.connection_flush(conn)
	wayl.connection_poll(conn)
	if exit := receive_events(conn, st); exit do return true

	if !create_display(conn, st) {
		log.error("Error in GL creation")
		return false
	}
	return true
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

	return conn, display, true
}

@(private)
receive_events :: proc(conn: ^wl.Connection, st: ^State) -> (exit: bool) {
	for ev in wayl.peek_event(conn) {
		#partial switch e in ev {
		case wl.Registry_Global_Event:
			switch e.interface {
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
			case zwp.LINUX_DMABUF_V1_INTERFACE:
				st.zwp_linux_dmabuf = wl.registry_bind(
					conn,
					st.wl_registry,
					e.name,
					e.interface,
					e.version,
					zwp.Linux_Dmabuf_V1,
				)
			}
		case wl.Display_Error_Event:
			log.error("[ERROR] code:", e.code, "::", e.object_id, e.message)
		case wl.Shell_Surface_Ping_Event:
			xdg.wm_base_pong(conn, xdg.Wm_Base(e.object), e.serial)
		case xdg.Surface_Configure_Event:
			xdg.surface_ack_configure(conn, st.xdg_surface, e.serial)
			st.status = .SurfaceAckedConfigure
		case xdg.Toplevel_Close_Event:
			return true
		case wl.Callback_Done_Event:
			st.should_redraw = true
		case xdg.Toplevel_Configure_Bounds_Event:
		case xdg.Toplevel_Wm_Capabilities_Event:
		case wl.Buffer_Release_Event:
			released_buffer := e.object
			for &f in st.frame_buffers {
				if f.buffer == released_buffer && f.locked {
					gbm.surface_release_buffer(st.gbm_surface, f.bo)
					f.locked = false
					break
				}
			}
		}
	}
	return false
}

wl_buffer_from_bo :: proc(
	conn: ^wl.Connection,
	st: ^State,
	bo: gbm.BufferObject,
) -> (
	buffer: wl.Buffer,
	ok: bool,
) {
	format := gbm.Formats.XRGB8888
	modifier := gbm.bo_get_modifier(bo)
	plane_count := gbm.bo_get_plane_count(bo)

	params := zwp.linux_dmabuf_v1_create_params(conn, st.zwp_linux_dmabuf)
	for plane in 0 ..< plane_count {
		plane_fd := gbm.bo_get_fd_for_plane(bo, plane)
		if plane_fd <= 0 {
			log.error("bo_get_fd_for_plane failed for plane", plane)
			zwp.linux_buffer_params_v1_destroy(conn, params)
			return
		}
		zwp.linux_buffer_params_v1_add(
			conn,
			params,
			auto_cast plane_fd,
			u32(plane),
			gbm.bo_get_offset(bo, plane),
			gbm.bo_get_stride_for_plane(bo, plane),
			u32(modifier >> 32),
			u32(modifier & 0xFFFFFFFF),
		)
	}
	log.debugf("importing bo format=%x modifier=%x planes=%d", u32(format), modifier, plane_count)
	buffer = zwp.linux_buffer_params_v1_create_immed(
		conn,
		params,
		i32(st.w),
		i32(st.h),
		u32(format),
		{},
	)
	zwp.linux_buffer_params_v1_destroy(conn, params)
	return buffer, true
}

find_frame :: proc(conn: ^wl.Connection, st: ^State, bo: gbm.BufferObject) -> ^Frame_Buffer {
	empty: ^Frame_Buffer
	for &frame in st.frame_buffers {
		if frame.bo == bo do return &frame
		if frame.bo == {} && empty == nil do empty = &frame
	}
	if empty == nil do return nil

	buffer, ok := wl_buffer_from_bo(conn, st, bo)
	if !ok do return nil
	empty^ = {
		bo     = bo,
		buffer = buffer,
	}
	return empty
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
			log.debug("Opened DRM device: ", node)
			return linux.Fd(fd_int), true
		}
	}

	log.debug("Failed to open any DRM device")
	return 0, false
}

choose_config :: proc(st: ^State) -> (config: egl.Config, ok: bool) {
	attribs := []i32 {
		egl.SURFACE_TYPE, egl.WINDOW_BIT,
		egl.RENDERABLE_TYPE, egl.OPENGL_BIT,
		egl.RED_SIZE, 8,
		egl.GREEN_SIZE, 8,
		egl.BLUE_SIZE, 8,
		egl.NONE,
	}
	MAX_CONFIGS :: 256
	configs: [MAX_CONFIGS]egl.Config
	config_count: i32
	if !egl.ChooseConfig(st.egl_display, &attribs[0], &configs[0], MAX_CONFIGS, &config_count) {
		return
	}
	for candidate in configs[:config_count] {
		visual_id: i32
		egl.GetConfigAttrib(st.egl_display, candidate, egl.NATIVE_VISUAL_ID, &visual_id)
		if u32(visual_id) == u32(gbm.Formats.XRGB8888) {
			return candidate, true
		}
	}
	return
}

create_display :: proc(conn: ^wayl.Connection, st: ^State) -> bool {
	st.drm_fd = open_drm_device() or_return
	st.gbm_device = gbm.create_device(st.drm_fd)
	if st.gbm_device == {} {
		log.error("gbm_create_device failed")
		return false
	}

	assert(st.wl_surface != 0)

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

	extensions := string(egl.QueryString(st.egl_display, egl.EXTENSTIONS))

	if extensions == "" {
		log.error("eglQueryString(EGL_EXTENSIONS) returned empty")
		return false
	}

	egl_config, config_ok := choose_config(st)
	if !config_ok {
  	log.error("unable to find matching egl config")
  	return false
	}

	if !egl.BindAPI(egl.OPENGL_API) {
  	log.error("Bind API failed")
  	return false
	}

	context_attribs := []i32 {
  	egl.CONTEXT_MAJOR_VERSION, GL_MAJOR,
  	egl.CONTEXT_MINOR_VERSION, GL_MINOR,
  	egl.NONE
	}
	st.egl_context = egl.CreateContext(st.egl_display,
  	egl_config,
  	egl.NO_CONTEXT,
  	&context_attribs[0],
	)

	if st.egl_context == egl.NO_CONTEXT {
		log.error("egl_context creation failed:", egl.get_error())
  	return false
	}

	st.gbm_surface = gbm.surface_create(
  	st.gbm_device,
  	st.w,
  	st.h,
  	gbm.Formats.XRGB8888,
  	{.USE_RENDERING, .USE_SCANOUT},
	)
	if st.gbm_surface == {} {
  	log.error("gbm_surface_create failed")
  	return false
	}

	st.egl_surface = egl.CreatePlatformWindowSurface(
  	st.egl_display,
  	egl_config,
  	st.gbm_surface,
  	{},
	)
	if st.egl_surface == egl.NO_SURFACE {
		log.error("egl_surface creation failed:", egl.get_error())
  	return false
	}

	if !egl.MakeCurrent(st.egl_display, st.egl_surface, st.egl_surface, st.egl_context) {
		log.error("eglMakeCurrent failed:", egl.get_error())
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
	gl.load_up_to(GL_MAJOR, GL_MINOR, egl.set_proc_address)
	log.infof("OpenGL %s", gl.GetString(gl.VERSION))
	log.infof("Renderer: %s", gl.GetString(gl.RENDERER))

	log.info("\n========= OPENGL READY ============\n")
	return true
}

quit :: proc(conn: ^wl.Connection, state: State) {
	if state.xdg_toplevel != 0 do xdg.toplevel_destroy(conn, state.xdg_toplevel)
	if state.xdg_surface != 0 do xdg.surface_destroy(conn, state.xdg_surface)
	if state.wl_surface != 0 do wl.surface_destroy(conn, state.wl_surface)

	wayl.connection_flush(conn)
	wayl.connection_destroy(conn^)

	linux.close(conn.socket)
	log.info("closed safely")
}

tick := 0
draw :: proc(conn: ^wl.Connection, st: ^State) {
  count := 0
	for frame in st.frame_buffers {
		if frame.locked do count += 1
	}
	if count >= MAX_LOCKED_BUFFERS do return

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.Viewport(0, 0, i32(st.w), i32(st.h))

	shade := f32(tick % 120) / 120
	gl.ClearColor(shade, 0.67, 1-shade, 1)
	tick += 1
	gl.Clear(gl.COLOR_BUFFER_BIT)

	if !egl.SwapBuffers(st.egl_display, st.egl_surface) {
		log.error("eglSwapBuffers failed:", egl.get_error())
		return
	}
	bo := gbm.surface_lock_front_buffer(st.gbm_surface)
	if bo == {} {
		log.error("gbm_surface_lock_front_buffer failed")
		return
	}

	frame := find_frame(conn, st, bo)
	if frame == nil {
  	gbm.surface_release_buffer(st.gbm_surface, bo)
  	return
	}

	frame.locked = true

	wl.surface_frame(conn, st.wl_surface)
	wl.surface_attach(conn, st.wl_surface, frame.buffer, 0, 0)
	wl.surface_damage_buffer(conn, st.wl_surface, 0, 0, i32(st.w), i32(st.h))
	wl.surface_commit(conn, st.wl_surface)

	st.should_redraw = false
}

start :: proc() {
	conn, display, ok := connect_display()
	if !ok {
		log.error("Could not connect to wayland socket")
		return
	}

	st := State {
		wl_registry   = wl.display_get_registry(&conn, display),
		w             = 500,
		h             = 500,
		should_redraw = true,
	}
	defer quit(&conn, st)

	if !create_objects(&conn, &st) {
		log.error("Initial object creation failed")
		return
	}

	log.info("Initial object creation complete.\nEntering main loop.")

	m: for {
		wayl.connection_flush(&conn)
	
		if ready, _ := linux.poll({linux.Poll_Fd{fd = conn.socket, events = {.IN}}}, 2); ready > 0 {
			wayl.connection_poll(&conn)
			if receive_events(&conn, &st) do return
		}
	
		if st.status == .None do continue
		if st.should_redraw do draw(&conn, &st)
	}
}

main :: proc() {
  context.logger = log.create_console_logger()
	when ODIN_DEBUG {
  	track: mem.Tracking_Allocator
  	mem.tracking_allocator_init(&track, context.allocator)
  	context.allocator = mem.tracking_allocator(&track)
  	defer {
  		if len(track.allocation_map) > 0 {
  			fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
  			for _, entry in track.allocation_map {
  				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
  			}
  		}
  		if len(track.bad_free_array) > 0 {
  			fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
  			for entry in track.bad_free_array {
  				fmt.eprintf("- %p bytes @ %v\n", entry.memory, entry.location)
  			}
  		}
  		mem.tracking_allocator_destroy(&track)
  	}
	}
	start()
}
