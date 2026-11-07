// host/RdevHost/Sources/RdevHost/WindowSPI.swift
import ApplicationServices
import CoreGraphics
import Foundation

/// Private/deprecated bindings for window raising, resolved once, lazily.
///
/// Bound with `dlsym` + `@convention(c)` and optional-typed — NEVER `@_silgen_name`, which binds Swift's
/// calling convention and is only safe for register-returned results (a struct-by-value symbol bound that
/// way gave alt-tab-macos an Intel-only crash). Optional-typed so a future macOS that drops a symbol
/// degrades to a logged no-op instead of trapping a long-running host.
///
/// Clean-room from published facts (symbol names + signatures). No code copied from any GPL/AGPL source.
enum WindowSPI {
    /// Front the app but raise only its front window, attributed as user-caused so macOS doesn't suppress it.
    static let kSetFrontProcessFrontWindowOnly: UInt32 = 1
    static let kSetFrontProcessCausedByUser: UInt32 = 2

    private nonisolated(unsafe) static let libSystem = dlopen(nil, RTLD_LAZY)

    /// Deprecated public Carbon; Swift refuses to expose it.
    static let getProcessForPID = unsafeBitCast(
        dlsym(libSystem, "GetProcessForPID"),
        to: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)?.self)

    /// Deprecated public Carbon. Replaces NSRunningApplication.activate, advisory-only since macOS 14.
    static let setFrontProcessWithOptions = unsafeBitCast(
        dlsym(libSystem, "SetFrontProcessWithOptions"),
        to: (@convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32) -> OSStatus)?.self)

    /// Deprecated public Carbon, like the two above: the FRONT process — the one a posted key goes to.
    static let getFrontProcess = unsafeBitCast(
        dlsym(libSystem, "GetFrontProcess"),
        to: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)?.self)

    /// Deprecated public Carbon: a process serial number's pid.
    static let getProcessPID = unsafeBitCast(
        dlsym(libSystem, "GetProcessPID"),
        to: (@convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> OSStatus)?.self)

    /// PRIVATE. element -> CGWindowID. No reverse routine exists, so wid -> element needs enumerate-and-match.
    static let getWindowID = unsafeBitCast(
        dlsym(libSystem, "_AXUIElementGetWindow"),
        to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)?.self)
}
