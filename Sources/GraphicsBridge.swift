import UIKit
import QuartzCore
import OpenGLES

final class GoreBoxSurfaceView: UIView {
    override class var layerClass: AnyClass { CAEAGLLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        if let l = layer as? CAEAGLLayer {
            l.isOpaque = true
            l.drawableProperties = [
                kEAGLDrawablePropertyRetainedBacking: false,
                kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
            ]
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

private final class IOSGLESBridge {
    static let shared = IOSGLESBridge()

    private var drawableLayer: CAEAGLLayer?
    private var context: EAGLContext?
    private var framebuffer: GLuint = 0
    private var colorRenderbuffer: GLuint = 0
    private var depthStencilRenderbuffer: GLuint = 0
    private(set) var pixelWidth: GLint = 0
    private(set) var pixelHeight: GLint = 0
    private var requestedWidth: Int32 = 0
    private var requestedHeight: Int32 = 0

    func attach(layer: CAEAGLLayer, width: Int32, height: Int32) {
        drawableLayer = layer
        requestedWidth = width
        requestedHeight = height
        layer.isOpaque = true
        layer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        ]
    }

    func createContext() -> Bool {
        if context != nil { return true }
        context = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)
        guard let context else { return false }
        return EAGLContext.setCurrent(context)
    }

    private func destroyBuffers() {
        guard context != nil else { return }
        _ = EAGLContext.setCurrent(context)
        if depthStencilRenderbuffer != 0 {
            var rb = depthStencilRenderbuffer
            glDeleteRenderbuffers(1, &rb)
            depthStencilRenderbuffer = 0
        }
        if colorRenderbuffer != 0 {
            var rb = colorRenderbuffer
            glDeleteRenderbuffers(1, &rb)
            colorRenderbuffer = 0
        }
        if framebuffer != 0 {
            var fb = framebuffer
            glDeleteFramebuffers(1, &fb)
            framebuffer = 0
        }
    }

    func createWindowSurface() -> Bool {
        guard let layer = drawableLayer else { return false }
        guard createContext(), let context else { return false }
        _ = EAGLContext.setCurrent(context)
        destroyBuffers()

        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)

        glGenRenderbuffers(1, &colorRenderbuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        guard context.renderbufferStorage(Int(GL_RENDERBUFFER), from: layer) else {
            destroyBuffers()
            return false
        }
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorRenderbuffer)

        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &pixelWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &pixelHeight)

        if pixelWidth <= 0 { pixelWidth = GLint(max(requestedWidth, 1)) }
        if pixelHeight <= 0 { pixelHeight = GLint(max(requestedHeight, 1)) }

        glGenRenderbuffers(1, &depthStencilRenderbuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depthStencilRenderbuffer)
        glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH24_STENCIL8), GLsizei(pixelWidth), GLsizei(pixelHeight))
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_ATTACHMENT), GLenum(GL_RENDERBUFFER), depthStencilRenderbuffer)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_STENCIL_ATTACHMENT), GLenum(GL_RENDERBUFFER), depthStencilRenderbuffer)

        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        return glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE)
    }

    func makeCurrent() -> Bool {
        guard let context else { return false }
        guard EAGLContext.setCurrent(context) else { return false }
        if framebuffer != 0 { glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer) }
        return true
    }

    func swapBuffers() -> Bool {
        guard let context, colorRenderbuffer != 0 else { return false }
        _ = EAGLContext.setCurrent(context)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        return context.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }

    func selfTest() -> Bool {
        guard createWindowSurface(), makeCurrent() else { return false }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glViewport(0, 0, GLsizei(max(pixelWidth, 1)), GLsizei(max(pixelHeight, 1)))
        glDisable(GLenum(GL_SCISSOR_TEST))
        glClearColor(0.08, 0.10, 0.13, 1.0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT))
        return swapBuffers()
    }

    func bindDefaultFramebuffer() {
        if framebuffer != 0 {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        }
    }

    func destroy() {
        destroyBuffers()
        if EAGLContext.current() === context { _ = EAGLContext.setCurrent(nil) }
        context = nil
    }
}

@_cdecl("gbr_ios_gles_attach_layer")
func gbr_ios_gles_attach_layer(_ layerPointer: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) {
    guard let layerPointer else { return }
    let layer = Unmanaged<CAEAGLLayer>.fromOpaque(layerPointer).takeUnretainedValue()
    IOSGLESBridge.shared.attach(layer: layer, width: width, height: height)
}

@_cdecl("gbr_ios_gles_create_context")
func gbr_ios_gles_create_context() -> Int32 {
    IOSGLESBridge.shared.createContext() ? 1 : 0
}

@_cdecl("gbr_ios_gles_create_window_surface")
func gbr_ios_gles_create_window_surface() -> Int32 {
    IOSGLESBridge.shared.createWindowSurface() ? 1 : 0
}

@_cdecl("gbr_ios_gles_make_current")
func gbr_ios_gles_make_current() -> Int32 {
    IOSGLESBridge.shared.makeCurrent() ? 1 : 0
}

@_cdecl("gbr_ios_gles_swap_buffers")
func gbr_ios_gles_swap_buffers() -> Int32 {
    IOSGLESBridge.shared.swapBuffers() ? 1 : 0
}

@_cdecl("gbr_ios_gles_width")
func gbr_ios_gles_width() -> Int32 {
    Int32(IOSGLESBridge.shared.pixelWidth)
}

@_cdecl("gbr_ios_gles_height")
func gbr_ios_gles_height() -> Int32 {
    Int32(IOSGLESBridge.shared.pixelHeight)
}

@_cdecl("gbr_ios_gles_self_test")
func gbr_ios_gles_self_test() -> Int32 {
    IOSGLESBridge.shared.selfTest() ? 1 : 0
}

@_cdecl("gbr_ios_gles_destroy")
func gbr_ios_gles_destroy() {
    IOSGLESBridge.shared.destroy()
}

@_cdecl("gbr_ios_gles_bind_default_framebuffer")
func gbr_ios_gles_bind_default_framebuffer() {
    IOSGLESBridge.shared.bindDefaultFramebuffer()
}
