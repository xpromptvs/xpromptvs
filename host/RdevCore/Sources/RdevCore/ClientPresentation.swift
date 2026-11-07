/// What a trusted transport can present; independent of whether it owns a WebRTC peer.
public enum ClientPresentation: Sendable {
    case terminalOnly, nativeSimulators, streamedSources
}
