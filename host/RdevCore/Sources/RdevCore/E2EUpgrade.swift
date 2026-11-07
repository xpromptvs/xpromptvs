import Foundation

/// **§10.3's upgrade, as the one rule that decides it.**
///
/// > "A code-enrolled B requesting passkey authorization receives a new **direct** grant. It does not
/// > gain authority merely because the UI showed a passkey prompt. Its new direct chain does not
/// > depend on A."
///
/// A Mac adopted by code holds capability `2` — share only — and §12.1's ceremony is how it becomes
/// a full device. That ceremony is refused on an enrolled Mac for a good reason: starting one would
/// otherwise reserve a second window for a device that already has a chain. This is the exception,
/// and it is narrow on purpose.
///
/// **THE SAME-ROOT GUARD IS NOT HERE, AND MUST NOT BE.** It lives in
/// `E2EIdentityManager.acceptEnrollmentReturn`, which keeps an enrolled device's existing
/// `trustedRootID` and checks the incoming chain against it — so a return under a different root
/// fails verification rather than replacing the anchor (§10.1). Deciding "may this ceremony start"
/// and deciding "may this chain be adopted" are different questions, and putting both in one place
/// is how the second comes to be skipped when the first says yes.
public enum E2EUpgrade {

    /// May a device holding this capability start a fresh §12.1 ceremony?
    ///
    /// **Only one without `enroll`.** A device that already holds `enroll` has everything a direct
    /// grant confers, so a second ceremony would reserve a window and change nothing; a device
    /// without it is exactly §10.3's code-enrolled B. Nil — no chain, or one that cannot be read —
    /// is NOT an upgrade candidate: an unenrolled device enrols through the ordinary path, and an
    /// unreadable chain is the one state that must never be resolved by writing over it.
    public static func mayUpgrade(capabilities: E2EIdentity.Capabilities?) -> Bool {
        guard let capabilities else { return false }
        return !capabilities.canEnroll
    }
}
