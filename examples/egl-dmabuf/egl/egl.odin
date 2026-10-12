#+build linux
/*
	Bindings for [[ EGL ; https://registry.khronos.org/EGL/sdk/docs/man/html/eglIntro.xhtml ]].
	Copied from the odin vendor:egl
	Zlib License
*/
package egl

NativeDisplayType :: distinct rawptr
NativeWindowType :: distinct rawptr
Display :: distinct rawptr
Surface :: distinct rawptr
Config :: distinct rawptr
Context :: distinct rawptr
Image :: distinct rawptr

Boolean :: b32

FALSE :: false
TRUE :: true

NO_DISPLAY    :: Display(uintptr(0))
NO_CONTEXT    :: Context(uintptr(0))
NO_CONFIG_KHR :: Config(uintptr(0))
NO_SURFACE    :: Surface(uintptr(0))
NO_IMAGE_KHR  :: Image(uintptr(0))

DEFAULT_DISPLAY :: NativeDisplayType(uintptr(0))

DISPLAY_SCALING                 :: 10000

CONTEXT_OPENGL_CORE_PROFILE_BIT :: 0x00000001
OPENGL_ES_BIT                   :: 0x0001
OPENVG_BIT                      :: 0x0002
WINDOW_BIT                      :: 0x0004
OPENGL_BIT                      :: 0x0008
OPENGL_ES2_BIT                  :: 0x0004
OPENGL_ES3_BIT                  :: 0x00000040

EGL_Error :: enum i32 {
	SUCCESS             = 0x3000,
	NOT_INITIALIZED     = 0x3001,
	BAD_ACCESS          = 0x3002,
	BAD_ALLOC           = 0x3003,
	BAD_ATTRIBUTE       = 0x3004,
	BAD_CONFIG          = 0x3005,
	BAD_CONTEXT         = 0x3006,
	BAD_CURRENT_SURFACE = 0x3007,
	BAD_DISPLAY         = 0x3008,
	BAD_MATCH           = 0x3009,
	BAD_NATIVE_PIXMAP   = 0x300A,
	BAD_NATIVE_WINDOW   = 0x300B,
	BAD_PARAMETER       = 0x300C,
	BAD_SURFACE         = 0x300D,
	CONTEXT_LOST        = 0x300E,
}

BUFFER_SIZE                     :: 0x3020
ALPHA_SIZE                      :: 0x3021
BLUE_SIZE                       :: 0x3022
GREEN_SIZE                      :: 0x3023
RED_SIZE                        :: 0x3024
DEPTH_SIZE                      :: 0x3025
STENCIL_SIZE                    :: 0x3026
NATIVE_VISUAL_ID                :: 0x302E
SURFACE_TYPE                    :: 0x3033
NONE                            :: 0x3038
LUMINANCE_SIZE                  :: 0x303D
ALPHA_MASK_SIZE                 :: 0x303E
COLOR_BUFFER_TYPE               :: 0x303F
RENDERABLE_TYPE                 :: 0x3040
CONFORMANT                      :: 0x3042
VENDOR                          :: 0x3053
VERSION                         :: 0x3054
EXTENSTIONS                     :: 0x3055
HEIGHT                          :: 0x3056
WIDTH                           :: 0x3057
DRAW                            :: 0x3059
READ                            :: 0x305A
BACK_BUFFER                     :: 0x3084
SINGLE_BUFFER                   :: 0x3085
RENDER_BUFFER                   :: 0x3086
COLORSPACE                      :: 0x3087
ALPHA_FORMAT                    :: 0x3088
GL_COLORSPACE_SRGB              :: 0x3089
GL_COLORSPACE_LINEAR            :: 0x308A
COLORSPACE_LINEAR               :: 0x308A
ALPHA_FORMAT_NONPRE             :: 0x308B
ALPHA_FORMAT_PRE                :: 0x308C
CLIENT_APIS                     :: 0x308D
RGB_BUFFER                      :: 0x308E
LUMINANCE_BUFFER                :: 0x308F
HORIZONTAL_RESOLUTION           :: 0x3090
PIXEL_ASPECT_RATIO              :: 0x3092
SWAP_BEHAVIOR                   :: 0x3093
BUFFER_PRESERVED                :: 0x3094
BUFFER_DESTROYED                :: 0x3095
OPENVG_IMAGE                    :: 0x3096
CONTEXT_CLIENT_TYPE             :: 0x3097
GL_COLORSPACE                   :: 0x309D
CONTEXT_CLIENT_VERSION          :: 0x3098
CONTEXT_MAJOR_VERSION           :: 0x3098
OPENGL_ES_API                   :: 0x30A0
OPENVG_API                      :: 0x30A1
OPENGL_API                      :: 0x30A2
CONTEXT_MINOR_VERSION           :: 0x30FB
CONTEXT_OPENGL_PROFILE_MASK     :: 0x30FD

CONTEXT_OPENGL_DEBUG            :: 0x31B0

Platform :: enum u32 {
	ANDROID_KHR      = 0x3141,
	GBM_KHR          = 0x31D7,
	WAYLAND_KHR      = 0x31D8,
	X11_KHR          = 0x31D5,
	X11_SCREEN_KHR   = 0x31D6,
	DEVICE_EXT       = 0x313F,
	WAYLAND_EXT      = 0x31D8,
	X11_EXT          = 0x31D5,
	X11_SCREEN_EXT   = 0x31D6,
	XCB_EXT          = 0x31DC,
	XCB_SCREEN_EXT   = 0x31DE,
	GBM_MESA         = 0x31D7,
	SURFACELESS_MESA = 0x31DD,
}

// EGL_EXT_image_dma_buf_import
LINUX_DMA_BUF_EXT              :: 0x3270
LINUX_DRM_FOURCC_EXT           :: 0x3271
DMA_BUF_PLANE0_FD_EXT          :: 0x3272
DMA_BUF_PLANE0_OFFSET_EXT      :: 0x3273
DMA_BUF_PLANE0_PITCH_EXT       :: 0x3274
DMA_BUF_PLANE1_FD_EXT          :: 0x3275
DMA_BUF_PLANE1_OFFSET_EXT      :: 0x3276
DMA_BUF_PLANE1_PITCH_EXT       :: 0x3277
DMA_BUF_PLANE2_FD_EXT          :: 0x3278
DMA_BUF_PLANE2_OFFSET_EXT      :: 0x3279
DMA_BUF_PLANE2_PITCH_EXT       :: 0x327A

// EGL_EXT_image_dma_buf_import_modifiers
DMA_BUF_PLANE3_FD_EXT          :: 0x3440
DMA_BUF_PLANE3_OFFSET_EXT      :: 0x3441
DMA_BUF_PLANE3_PITCH_EXT       :: 0x3442
DMA_BUF_PLANE0_MODIFIER_LO_EXT :: 0x3443
DMA_BUF_PLANE0_MODIFIER_HI_EXT :: 0x3444
DMA_BUF_PLANE1_MODIFIER_LO_EXT :: 0x3445
DMA_BUF_PLANE1_MODIFIER_HI_EXT :: 0x3446
DMA_BUF_PLANE2_MODIFIER_LO_EXT :: 0x3447
DMA_BUF_PLANE2_MODIFIER_HI_EXT :: 0x3448
DMA_BUF_PLANE3_MODIFIER_LO_EXT :: 0x3449
DMA_BUF_PLANE3_MODIFIER_HI_EXT :: 0x344A



foreign import egl "system:EGL"
@(default_calling_convention = "c", link_prefix = "egl")
foreign egl {
	GetDisplay :: proc(display: NativeDisplayType) -> Display ---
	GetPlatformDisplay :: proc(platform: Platform, native_display: rawptr, attrib_list: ^int) -> Display ---
	Initialize :: proc(display: Display, major: ^i32, minor: ^i32) -> Boolean ---
	BindAPI :: proc(api: u32) -> Boolean ---
	GetConfigs :: proc(display: Display, config: [^]Config, config_size: i32, num_configs: ^i32) -> Boolean ---
	ChooseConfig :: proc(display: Display, attrib_list: ^i32, configs: [^]Config, config_size: i32, num_config: ^i32) -> Boolean ---
	CreateWindowSurface :: proc(display: Display, config: Config, native_window: NativeWindowType, attrib_list: ^i32) -> Surface ---
	CreatePlatformWindowSurface :: proc(display: Display, config: Config, native_window: rawptr, attrib_list: ^int) -> Surface ---
	CreateContext :: proc(display: Display, config: Config, share_context: Context, attrib_list: ^i32) -> Context ---
	MakeCurrent :: proc(display: Display, draw: Surface, read: Surface, ctx: Context) -> Boolean ---
	QuerySurface :: proc(display: Display, surface: Surface, attribute: i32, value: ^i32) -> Boolean ---
	QueryString :: proc(display: Display, name: i32) -> cstring ---
	SwapInterval :: proc(display: Display, interval: i32) -> Boolean ---
	SwapBuffers :: proc(display: Display, surface: Surface) -> Boolean ---
	GetProcAddress :: proc(name: cstring) -> rawptr ---
	GetConfigAttrib :: proc(display: Display, config: Config, attribute: i32, value: ^i32) -> Boolean ---
	GetError :: proc() -> i32 ---
	DestroyContext :: proc(display: Display, ctx: Context) -> Boolean ---
	DestroySurface :: proc(display: Display, surface: Surface) -> Boolean ---
	GetCurrentDisplay :: proc() -> Display ---
	GetCurrentSurface :: proc(readdraw: i32) -> Surface ---
	GetCurrentContext :: proc() -> Context ---
	Terminate :: proc(display: Display) -> Boolean ---
}

get_error :: proc() -> EGL_Error {
	return EGL_Error(GetError())
}

set_proc_address :: proc(p: rawptr, name: cstring) {
	(^rawptr)(p)^ = GetProcAddress(name)
}

EGLImageTargetTexture2DOES: proc "c" (target: u32, image: Image)

// Extension functions loaded dynamically
load_extensions :: proc() {
  set_proc_address(&GetPlatformDisplayEXT, "eglGetPlatformDisplayEXT")
  set_proc_address(&EGLImageTargetTexture2DOES, "glEGLImageTargetTexture2DOES")
	set_proc_address(&GetPlatformDisplayEXT,"eglGetPlatformDisplayEXT")
	set_proc_address(&CreatePlatformWindowSurfaceEXT,"eglCreatePlatformWindowSurfaceEXT")
	set_proc_address(&CreateImageKHR,"eglCreateImageKHR")
	set_proc_address(&DestroyImageKHR,"eglDestroyImageKHR")
	set_proc_address(&QueryDmaBufModifiersEXT,"eglQueryDmaBufModifiersEXT")
	set_proc_address(&EGLImageTargetTexture2DOES,"glEGLImageTargetTexture2DOES")
}

GetPlatformDisplayEXT: proc "c" (
	platform: Platform,
	native_display: rawptr,
	attrib_list: ^i32,
) -> Display

CreatePlatformWindowSurfaceEXT: proc "c" (
	display: Display,
	config: Config,
	native_window: rawptr,
	attrib_list: ^i32,
) -> Surface

CreateImageKHR: proc "c" (
	dpy:          Display,
	ctx:          Context,
	target:       u32,
	buffer:       rawptr,
	attrib_list:  ^i32,
) -> Image

DestroyImageKHR: proc "c" (dpy: Display, image: Image) -> Boolean

QueryDmaBufModifiersEXT: proc "c" (
	dpy:            Display,
	format:         i32,
	max_modifiers:  i32,
	modifiers:      ^u64,
	external_only:  ^Boolean,
	num_modifiers:  ^i32,
) -> Boolean

// checks name appears as a whole token, not a substring of a longer name
has_egl_extension :: proc(extensions: string, name: string) -> bool {
	ext := extensions
	for len(ext) > 0 {
		i := 0
		for i < len(ext) && ext[i] != ' ' do i += 1
		if ext[:i] == name do return true
		if i >= len(ext) do break
		ext = ext[i + 1:]
	}
	return false
}
