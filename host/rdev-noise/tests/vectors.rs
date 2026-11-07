//! `snow` against the published Cacophony vectors, through OUR C ABI rather than snow's Rust API.
//!
//! Testing the ABI is the point: the Swift host never calls snow directly, so a boundary that
//! transposed a length or dropped the transport transition would pass a test written against
//! `HandshakeState` and fail in production.
use rdev_noise::*;
use std::ffi::c_void;

fn hex(s: &str) -> Vec<u8> { hex::decode(s).unwrap() }

struct Session(*mut RdevNoiseSession);
impl Drop for Session { fn drop(&mut self) { unsafe { rdev_noise_free(self.0) } } }

impl Session {
    fn new(mode: i32, initiator: bool, prologue: &[u8], sk: &[u8], psk: Option<&[u8]>) -> Session {
        let p = unsafe {
            rdev_noise_new(mode, initiator, prologue.as_ptr(), prologue.len(), sk.as_ptr(),
                           psk.map_or(std::ptr::null(), |p| p.as_ptr()))
        };
        assert!(!p.is_null(), "rdev_noise_new returned null");
        Session(p)
    }
    fn write(&self, payload: &[u8]) -> Option<Vec<u8>> {
        let mut out = vec![0u8; 65535];
        let mut n = 0usize;
        let rc = unsafe { rdev_noise_write(self.0, payload.as_ptr(), payload.len(),
                                           out.as_mut_ptr(), out.len(), &mut n) };
        (rc == RDEV_NOISE_OK).then(|| { out.truncate(n); out })
    }
    fn read(&self, msg: &[u8]) -> Option<Vec<u8>> {
        let mut out = vec![0u8; 65535];
        let mut n = 0usize;
        let rc = unsafe { rdev_noise_read(self.0, msg.as_ptr(), msg.len(),
                                          out.as_mut_ptr(), out.len(), &mut n) };
        (rc == RDEV_NOISE_OK).then(|| { out.truncate(n); out })
    }
    fn handshake_hash(&self) -> Option<[u8; 32]> {
        let mut h = [0u8; 32];
        (unsafe { rdev_noise_handshake_hash(self.0, h.as_mut_ptr()) } == RDEV_NOISE_OK).then_some(h)
    }
    fn is_transport(&self) -> bool { unsafe { rdev_noise_is_transport(self.0) } }
}

/// TWO PATHS, because this suite runs under both. Bazel places a declared `data` dependency in the
/// runfiles tree relative to the working directory; cargo runs from the package and has to walk up.
/// Trying the runfiles path FIRST keeps the Bazel run — the one that gates `test-all.sh` — from
/// depending on an environment variable Bazel has no reason to set.
fn fixture() -> serde_json::Value {
    const RUNFILES: &str = "protocol/fixtures/noise-vectors.json";
    const CARGO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/fixtures/noise-vectors.json");
    let raw = std::fs::read_to_string(RUNFILES)
        .or_else(|_| std::fs::read_to_string(CARGO))
        .expect("noise-vectors.json: not in runfiles and not at the cargo-relative path");
    serde_json::from_str(&raw).unwrap()
}

/// THE ABI IS NOT GIVEN THE EPHEMERAL. snow can pin one, but our ABI deliberately does not expose
/// that — a production seam for injecting handshake randomness is a liability, and §7 requires all
/// randomness to come from a CSPRNG. So the vector's CIPHERTEXTS cannot be reproduced through the
/// ABI; what is asserted here is the protocol's observable behaviour, and the byte-exactness of the
/// two named protocols is asserted against snow directly in `snow_matches_the_published_vectors`.
#[test]
fn a_full_handshake_runs_through_the_abi_in_both_modes() {
    for (mode, psk) in [(RDEV_NOISE_XX, None), (RDEV_NOISE_PAIR, Some([0xABu8; 32]))] {
        let prologue = b"rdev-e2e/v3";
        let i = Session::new(mode, true, prologue, &[0x11; 32], psk.as_ref().map(|p| &p[..]));
        let r = Session::new(mode, false, prologue, &[0x22; 32], psk.as_ref().map(|p| &p[..]));

        let m1 = i.write(b"").expect("message 1");
        r.read(&m1).expect("read 1");
        let m2 = r.write(b"issuer-route").expect("message 2");
        assert_eq!(i.read(&m2).unwrap(), b"issuer-route", "message 2 payload");
        let m3 = i.write(b"device+op").expect("message 3");
        assert_eq!(r.read(&m3).unwrap(), b"device+op", "message 3 payload");

        assert!(i.is_transport() && r.is_transport(), "mode {mode}: both sides settle to transport");
        assert_eq!(i.handshake_hash(), r.handshake_hash(), "mode {mode}: handshake hashes agree");
        assert!(i.handshake_hash().is_some(), "mode {mode}: the hash survives the transition");

        // Transport, both directions — the transition is invisible to the caller, which is the
        // property the wrapper exists to provide.
        let t = i.write(b"client-confirm").expect("transport i->r");
        assert_eq!(r.read(&t).unwrap(), b"client-confirm");
        let t = r.write(b"session-start").expect("transport r->i");
        assert_eq!(i.read(&t).unwrap(), b"session-start");
    }
}

/// THE PROPERTY `pair` EXISTS FOR. Without this the test above shows only that the code runs.
#[test]
fn a_one_bit_psk_mismatch_is_rejected() {
    let prologue = b"rdev-e2e/v3";
    let good = [0xABu8; 32];
    let mut bad = good; bad[31] ^= 1;
    let i = Session::new(RDEV_NOISE_PAIR, true, prologue, &[0x11; 32], Some(&good));
    let r = Session::new(RDEV_NOISE_PAIR, false, prologue, &[0x22; 32], Some(&bad));
    let m1 = i.write(b"").expect("message 1");
    r.read(&m1).expect("message 1 predates the psk mix, so it still reads");
    let m2 = r.write(b"").expect("message 2");
    i.read(&m2).expect("message 2 also predates it under psk3");
    let m3 = i.write(b"").expect("message 3");
    assert!(r.read(&m3).is_none(), "message 3 mixes the psk and MUST fail on a mismatch");
}

/// A PSK on a non-PSK pattern is a caller error, and a mode the specification does not name is too.
#[test]
fn the_abi_refuses_incoherent_construction() {
    let pro = b"x";
    let psk = [0u8; 32];
    unsafe {
        assert!(rdev_noise_new(RDEV_NOISE_XX, true, pro.as_ptr(), 1, [0u8;32].as_ptr(), psk.as_ptr()).is_null(),
                "a PSK on plain XX");
        assert!(rdev_noise_new(RDEV_NOISE_PAIR, true, pro.as_ptr(), 1, [0u8;32].as_ptr(), std::ptr::null()).is_null(),
                "pair without a PSK");
        assert!(rdev_noise_new(99, true, pro.as_ptr(), 1, [0u8;32].as_ptr(), std::ptr::null()).is_null(),
                "an unnamed mode");
    }
    let _ = std::ptr::null::<c_void>();
}

/// BYTE-EXACTNESS, against the published corpus, for both protocols §11.1 names. Driven through
/// snow directly because it needs pinned ephemerals, which the ABI deliberately will not take.
#[test]
fn snow_matches_the_published_vectors() {
    let f = fixture();
    let vs = f["vectors"].as_array().unwrap();
    assert_eq!(vs.len(), 2, "an empty or partial fixture would assert nothing");
    for v in vs {
        let name = v["protocol_name"].as_str().unwrap();
        let params: snow::params::NoiseParams = name.parse().unwrap();
        let g = |k: &str| hex(v[k].as_str().unwrap());
        let psk: Option<[u8; 32]> = v.get("init_psks")
            .and_then(|p| p.as_array()).and_then(|a| a.first())
            .map(|s| hex(s.as_str().unwrap()).try_into().unwrap());
        let prologue = g("init_prologue");
        let mk = |initiator: bool, sk: Vec<u8>, eph: Vec<u8>| {
            let mut b = snow::Builder::new(params.clone())
                .prologue(&prologue).unwrap().local_private_key(&sk).unwrap();
            if let Some(p) = psk.as_ref() {
                b = b.psk(3, Box::leak(Box::new(*p))).unwrap();
            }
            let b = b.fixed_ephemeral_key_for_testing_only(&eph);
            if initiator { b.build_initiator().unwrap() } else { b.build_responder().unwrap() }
        };
        let mut i = mk(true, g("init_static"), g("init_ephemeral"));
        let mut r = mk(false, g("resp_static"), g("resp_ephemeral"));
        let messages = v["messages"].as_array().unwrap();
        for (n, m) in messages.iter().take(3).enumerate() {
            let payload = hex(m["payload"].as_str().unwrap());
            let (send, recv) = if n % 2 == 0 { (&mut i, &mut r) } else { (&mut r, &mut i) };
            let mut out = vec![0u8; 4096];
            let len = send.write_message(&payload, &mut out).unwrap();
            assert_eq!(hex::encode(&out[..len]), m["ciphertext"].as_str().unwrap(),
                       "{name} message {}", n + 1);
            let mut back = vec![0u8; 4096];
            let plen = recv.read_message(&out[..len], &mut back).unwrap();
            assert_eq!(&back[..plen], &payload[..], "{name} message {} payload", n + 1);
        }
        assert_eq!(i.get_handshake_hash(), r.get_handshake_hash(), "{name} handshake hashes");

        // TRANSPORT. These pin what the handshake messages cannot: Split's key derivation and the
        // PER-DIRECTION nonce counters. A session that used one cipher state in both directions
        // passes every assertion above and fails here on the second message, once the nonces
        // collide — which is the quiet version of the bug, not the loud one.
        let mut ti = i.into_transport_mode().unwrap();
        let mut tr = r.into_transport_mode().unwrap();
        for (n, m) in messages.iter().enumerate().skip(3) {
            let payload = hex(m["payload"].as_str().unwrap());
            let (send, recv) = if n % 2 == 0 { (&mut ti, &mut tr) } else { (&mut tr, &mut ti) };
            let mut out = vec![0u8; 4096];
            let len = send.write_message(&payload, &mut out).unwrap();
            assert_eq!(hex::encode(&out[..len]), m["ciphertext"].as_str().unwrap(),
                       "{name} transport message {}", n + 1);
            let mut back = vec![0u8; 4096];
            let plen = recv.read_message(&out[..len], &mut back).unwrap();
            assert_eq!(&back[..plen], &payload[..], "{name} transport message {} payload", n + 1);
        }
    }
}
