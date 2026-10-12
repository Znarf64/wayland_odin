package dmabuf_ui

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

	// GBM
	drm_fd:                              linux.Fd,
	gbm_device:                          gbm.Device,
	zwp_linux_dmabuf:                    zwp.Linux_Dmabuf_V1,
	dmabuf_feedback:                     Dmabuf_Feedback,
  // gbo:                                 #soa[BUF_LEN]Gbo
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

Status :: enum {
	None,
	SurfaceAckedConfigure,
}


BUF_LEN :: 4
GL_MAJOR :: 3
GL_MINOR :: 3
gbo: #soa[BUF_LEN]Gbo


window_next_buffer :: proc() -> (slot: int, ok: bool) {
	for &g, i in gbo {
		if g.status == .Ready do return i, true
	}
	return -1, false
}

create_buffers :: proc(conn: ^wl.Connection, st: ^State) -> bool {
	for slot in 0 ..< BUF_LEN {
		if !create_dmabuf_buffer(conn, st, slot) {
			log.error("failed to create buffer at slot", slot)
			return false
		}
	}
	return true
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
	create_err := create_buffers(conn, st)
	if !create_err do return false

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

/* 
  Info may be found in Mesa's implementation at src/egl/drivers/dri2/platform_wayland.c"
 * https://ziggit.dev/t/drawing-with-opengl-without-glfw-or-sdl-on-linux/3175/12
 * https://blaztinn.gitlab.io/post/dmabuf-texture-sharing/
 */

// https://registry.khronos.org/EGL/sdk/docs/man/html/eglIntro.xhtml

create_display :: proc(conn: ^wayl.Connection, st: ^State) -> bool {
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
			egl.SURFACE_TYPE,    egl.WINDOW_BIT,
			egl.RENDERABLE_TYPE, egl.OPENGL_BIT,
			egl.RED_SIZE,        8,
			egl.GREEN_SIZE,      8,
			egl.BLUE_SIZE,       8,
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
		egl.CONTEXT_MAJOR_VERSION, GL_MAJOR,
		egl.CONTEXT_MINOR_VERSION, GL_MINOR,
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
	gl.load_up_to(GL_MAJOR, GL_MINOR, egl.set_proc_address)
	log.infof("OpenGL %s", gl.GetString(gl.VERSION))
	log.infof("Renderer: %s", gl.GetString(gl.RENDERER))

	gl.Viewport(0, 0, i32(st.w), i32(st.h))

	gl.Disable(gl.BLEND)

	log.info("\n========= OPENGL READY ============\n")
	return true
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
	assert(egl.QueryDmaBufModifiersEXT != nil)
	
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
	attribs[i] = egl.WIDTH;                i += 1; attribs[i] = i32(st.w);   i += 1
	attribs[i] = egl.HEIGHT;               i += 1; attribs[i] = i32(st.h);   i += 1
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
		attribs[i] = plane_fd_attrs[plane];     i += 1; attribs[i] = i32(plane_fds[plane]); i += 1
		attribs[i] = plane_offset_attrs[plane]; i += 1; attribs[i] = i32(offsets[plane]);   i += 1
		attribs[i] = plane_pitch_attrs[plane];  i += 1; attribs[i] = i32(strides[plane]);   i += 1
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
	// inverts y coordinate to top-down. available on opengl > 4.5
	// gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE)
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

quit :: proc(conn: ^wl.Connection, state: State) {
	if state.xdg_toplevel != 0 do xdg.toplevel_destroy(conn, state.xdg_toplevel)
	if state.xdg_surface != 0 do xdg.surface_destroy(conn, state.xdg_surface)
	if state.wl_surface != 0 do wl.surface_destroy(conn, state.wl_surface)

	wayl.connection_flush(conn)
	wayl.connection_destroy(conn^)

	delete(state.dmabuf_feedback.current.formats)
	delete(state.dmabuf_feedback.format_table)
	delete(state.dmabuf_feedback.tranches)

	linux.close(conn.socket)
	log.info("closed safely")
}
elapsed :f32= 0
draw :: proc(conn: ^wl.Connection, st: ^State) {
	slot, ok := window_next_buffer()
	if !ok do return 

	gl.BindFramebuffer(gl.FRAMEBUFFER, gbo[slot].gl_fbo)
	gl.Viewport(0, 0, i32(st.w), i32(st.h))

	gl.ClearColor(0.98, 0.67, 0.17, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.Flush()

	wl.surface_frame(conn, st.wl_surface)
	wl.surface_attach(conn, st.wl_surface, gbo[slot].buffer, 0, 0)
	wl.surface_damage_buffer(conn, st.wl_surface, 0, 0, i32(st.w), i32(st.h))
	wl.surface_commit(conn, st.wl_surface)

	gbo[slot].status = .Busy
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
