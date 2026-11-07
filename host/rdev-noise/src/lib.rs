//! The C ABI the Swift host drives Noise through — `snow` behind a boundary of our own.
//!
//! WHY A BOUNDARY AT ALL. Two things. `snow` splits a session into a `HandshakeState` and a
//! `TransportState`, with a consuming transition between them; callers should not have to model that
//! across an FFI line. And the implementation is replaceable: the decision record
//! (`docs/superpowers/specs/2026-09-12-noise-implementation-choice.md`) exists because three
//! candidates were eliminated on facts, and if a fourth ever displaces `snow`, only this file moves.
//!
//! PATTERNS ARE FIXED HERE, not passed as strings. A caller cannot ask for a protocol the
//! specification does not name, which keeps §11.1's table the single source of truth for what modes
//! exist — and keeps a typo from silently negotiating something else.

use snow::{Builder, HandshakeState, TransportState};

/// `pair` (§11.1). The PSK is the pairing seed's derived `psk`; `psk3` mixes it at the end of
/// message 3.
pub const RDEV_NOISE_PAIR: i32 = 1;
/// `enroll`, `auth` and `resume` — all plain `XX`, distinguished by the prologue's mode field
/// rather than by the pattern.
pub const RDEV_NOISE_XX: i32 = 0;

pub const RDEV_NOISE_OK: i32 = 0;
pub const RDEV_NOISE_ERR_ARGS: i32 = -1;
/// `out_len` is set to the size required; nothing was consumed.
pub const RDEV_NOISE_ERR_BUFFER: i32 = -2;
/// Decryption or handshake failure. §11.3: a decryption failure TERMINATES the signalling session,
/// so a caller must not retry a message that returns this.
pub const RDEV_NOISE_ERR_NOISE: i32 = -3;

const PARAMS_XX: &str = "Noise_XX_25519_ChaChaPoly_SHA256";
const PARAMS_PAIR: &str = "Noise_XXpsk3_25519_ChaChaPoly_SHA256";

enum State {
    Handshake(Box<HandshakeState>),
    Transport(Box<TransportState>),
    /// Reached only if a transition panicked; every operation refuses.
    Poisoned,
}

pub struct RdevNoiseSession {
    state: State,
    /// CAPTURED AT THE TRANSITION, because `TransportState` does not carry it — and §11.2 needs it
    /// AFTER Split, to bind `client-confirm` and the device proof. Reading it only during the
    /// handshake would make the one moment it is required the one moment it is gone.
    handshake_hash: Option<[u8; 32]>,
}

impl RdevNoiseSession {
    /// Move to transport the moment the pattern completes.
    ///
    /// THE CALLER NEVER SEES THE SEAM. `snow` models the two phases as different types with a
    /// consuming transition; exposing that across the ABI would put a state machine in Swift and
    /// another in TypeScript, both of which could disagree with this one.
    fn settle(&mut self) {
        if let State::Handshake(h) = &self.state {
            if h.is_handshake_finished() {
                let hh = h.get_handshake_hash();
                if hh.len() >= 32 {
                    let mut a = [0u8; 32];
                    a.copy_from_slice(&hh[..32]);
                    self.handshake_hash = Some(a);
                }
                let old = std::mem::replace(&mut self.state, State::Poisoned);
                if let State::Handshake(h) = old {
                    self.state = match h.into_transport_mode() {
                        Ok(t) => State::Transport(Box::new(t)),
                        Err(_) => State::Poisoned,
                    };
                }
            }
        }
    }
}

unsafe fn slice<'a>(p: *const u8, n: usize) -> Option<&'a [u8]> {
    if n == 0 { Some(&[]) } else if p.is_null() { None } else { Some(std::slice::from_raw_parts(p, n)) }
}

/// Build a session. `psk` must be non-null exactly when `mode` is `RDEV_NOISE_PAIR`.
///
/// Returns null rather than an error code: there is no session to carry one, and every failure here
/// is a programming error at the call site rather than a runtime condition.
#[no_mangle]
pub unsafe extern "C" fn rdev_noise_new(mode: i32, initiator: bool,
                                        prologue: *const u8, prologue_len: usize,
                                        static_priv: *const u8, psk: *const u8)
                                        -> *mut RdevNoiseSession {
    let (Some(prologue), Some(sk)) = (slice(prologue, prologue_len), slice(static_priv, 32))
        else { return std::ptr::null_mut() };
    let name = match mode { RDEV_NOISE_XX => PARAMS_XX, RDEV_NOISE_PAIR => PARAMS_PAIR, _ => return std::ptr::null_mut() };
    let Ok(params) = name.parse() else { return std::ptr::null_mut() };

    let mut b = match Builder::new(params).prologue(prologue).and_then(|b| b.local_private_key(sk)) {
        Ok(b) => b,
        Err(_) => return std::ptr::null_mut(),
    };
    if mode == RDEV_NOISE_PAIR {
        let Some(p) = slice(psk, 32) else { return std::ptr::null_mut() };
        let Ok(p32) = <[u8; 32]>::try_from(p) else { return std::ptr::null_mut() };
        // A LEAKED REFERENCE, deliberately: snow's builder borrows the PSK for its own lifetime, and
        // the alternative is threading a lifetime through an FFI type. 32 bytes, once per session.
        let leaked: &'static [u8; 32] = Box::leak(Box::new(p32));
        match b.psk(3, leaked) { Ok(nb) => b = nb, Err(_) => return std::ptr::null_mut() }
    } else if !psk.is_null() {
        return std::ptr::null_mut();   // a PSK on a non-PSK pattern is a caller error, not a no-op
    }
    let built = if initiator { b.build_initiator() } else { b.build_responder() };
    match built {
        Ok(h) => Box::into_raw(Box::new(RdevNoiseSession { state: State::Handshake(Box::new(h)), handshake_hash: None })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdev_noise_free(s: *mut RdevNoiseSession) {
    if !s.is_null() { drop(Box::from_raw(s)); }
}

#[no_mangle]
pub unsafe extern "C" fn rdev_noise_is_transport(s: *const RdevNoiseSession) -> bool {
    matches!(s.as_ref().map(|s| &s.state), Some(State::Transport(_)))
}

/// Write one message. Handshake or transport, whichever the session is in.
#[no_mangle]
pub unsafe extern "C" fn rdev_noise_write(s: *mut RdevNoiseSession,
                                          payload: *const u8, payload_len: usize,
                                          out: *mut u8, out_cap: usize, out_len: *mut usize) -> i32 {
    let (Some(s), Some(payload)) = (s.as_mut(), slice(payload, payload_len)) else { return RDEV_NOISE_ERR_ARGS };
    if out.is_null() || out_len.is_null() { return RDEV_NOISE_ERR_ARGS; }
    let buf = std::slice::from_raw_parts_mut(out, out_cap);
    let r = match &mut s.state {
        State::Handshake(h) => h.write_message(payload, buf),
        State::Transport(t) => t.write_message(payload, buf),
        State::Poisoned => return RDEV_NOISE_ERR_NOISE,
    };
    match r {
        Ok(n) => { *out_len = n; s.settle(); RDEV_NOISE_OK }
        // snow reports a short buffer as an ordinary error, so the caller is told to size up rather
        // than being left to guess which failure it hit.
        Err(snow::Error::Input) => RDEV_NOISE_ERR_BUFFER,
        Err(_) => RDEV_NOISE_ERR_NOISE,
    }
}

/// Read one message, writing the payload to `out`.
#[no_mangle]
pub unsafe extern "C" fn rdev_noise_read(s: *mut RdevNoiseSession,
                                         msg: *const u8, msg_len: usize,
                                         out: *mut u8, out_cap: usize, out_len: *mut usize) -> i32 {
    let (Some(s), Some(msg)) = (s.as_mut(), slice(msg, msg_len)) else { return RDEV_NOISE_ERR_ARGS };
    if out.is_null() || out_len.is_null() { return RDEV_NOISE_ERR_ARGS; }
    let buf = std::slice::from_raw_parts_mut(out, out_cap);
    let r = match &mut s.state {
        State::Handshake(h) => h.read_message(msg, buf),
        State::Transport(t) => t.read_message(msg, buf),
        State::Poisoned => return RDEV_NOISE_ERR_NOISE,
    };
    match r {
        Ok(n) => { *out_len = n; s.settle(); RDEV_NOISE_OK }
        Err(snow::Error::Input) => RDEV_NOISE_ERR_BUFFER,
        Err(_) => RDEV_NOISE_ERR_NOISE,
    }
}

/// The handshake hash `h`. §11.2 binds `client-confirm` and the device proof to it, so it is not a
/// diagnostic — it is protocol input.
#[no_mangle]
pub unsafe extern "C" fn rdev_noise_handshake_hash(s: *const RdevNoiseSession, out: *mut u8) -> i32 {
    let Some(s) = s.as_ref() else { return RDEV_NOISE_ERR_ARGS };
    if out.is_null() { return RDEV_NOISE_ERR_ARGS; }
    match (&s.state, s.handshake_hash) {
        (State::Handshake(h), _) if h.get_handshake_hash().len() >= 32 => {
            std::ptr::copy_nonoverlapping(h.get_handshake_hash().as_ptr(), out, 32);
            RDEV_NOISE_OK
        }
        (_, Some(h)) => { std::ptr::copy_nonoverlapping(h.as_ptr(), out, 32); RDEV_NOISE_OK }
        _ => RDEV_NOISE_ERR_NOISE,
    }
}

/// The peer's static public key, which §11.1 requires be checked against the certified chain before
/// anything is activated.
#[no_mangle]
pub unsafe extern "C" fn rdev_noise_remote_static(s: *const RdevNoiseSession, out: *mut u8) -> i32 {
    let Some(s) = s.as_ref() else { return RDEV_NOISE_ERR_ARGS };
    if out.is_null() { return RDEV_NOISE_ERR_ARGS; }
    let rs = match &s.state {
        State::Handshake(h) => h.get_remote_static(),
        State::Transport(t) => t.get_remote_static(),
        State::Poisoned => None,
    };
    match rs {
        Some(k) if k.len() >= 32 => { std::ptr::copy_nonoverlapping(k.as_ptr(), out, 32); RDEV_NOISE_OK }
        _ => RDEV_NOISE_ERR_NOISE,
    }
}
