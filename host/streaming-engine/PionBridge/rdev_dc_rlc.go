// Sliding-window Random Linear Coding (RFC 8681 in shape) for the DataChannel video path.
//
// MEASURED, NOT CHOSEN ON PRINCIPLE. At 2% packet loss this held frame loss to 0.33-0.39% at 25%
// overhead, against 7.16% unprotected — and against duplication, which needed FOUR TIMES the
// overhead for the same result. The full sweep is in
// docs/superpowers/specs/2026-09-01-datachannel-video-transport-spike.md.
//
// WHY NOT A BLOCK CODE. Block FEC across frames cannot be used at this latency: parity over K frames
// cannot repair the first of them until the Kth has been sent, so recovery costs K x 16.7 ms against
// a 7-16 ms playout margin. A sliding window emits repair CONTINUOUSLY over the last W symbols, so
// repair for frame i rides with frame i (zero added latency) and MORE repair for frame i keeps
// arriving with i+1, i+2. That turns "how long do I wait" into a per-frame decision the decoder makes
// when it has enough equations, instead of a fixed block delay everybody pays.
//
// WHY NOT RAPTORQ, which is the answer that sounds most modern: its win is linear time at large block
// sizes, and it is only NEAR-MDS — at the ~4-symbol frames rdev produces, its ~2-symbol overhead is
// 50% to do worse than a plain Reed-Solomon. Small blocks are where classical codes are optimal, and
// pooling across frames (this) is what actually lowers the overhead.
//
// GF(256) with the standard erasure-coding field: primitive polynomial 0x11d, generator 2. The
// tables and the coefficient PRNG below are mirrored byte-for-byte in web/src/lib/rlc.ts — a
// disagreement between them decodes to plausible garbage rather than to an error, so both sides
// derive coefficients from the SAME seeded generator rather than shipping them on the wire.
package main

var gfExp [512]byte
var gfLog [256]byte

func init() {
	x := 1
	for i := 0; i < 255; i++ {
		gfExp[i] = byte(x)
		gfLog[x] = byte(i)
		x <<= 1
		if x&0x100 != 0 {
			x ^= 0x11d
		}
	}
	// Doubled so a log sum up to 508 needs no modulo in the multiply hot path.
	for i := 255; i < 512; i++ {
		gfExp[i] = gfExp[i-255]
	}
}

func gfMul(a, b byte) byte {
	if a == 0 || b == 0 {
		return 0
	}
	return gfExp[int(gfLog[a])+int(gfLog[b])]
}

func gfDiv(a, b byte) byte {
	if a == 0 {
		return 0
	}
	// b == 0 is a caller error: every pivot is normalised to a non-zero leading coefficient.
	return gfExp[int(gfLog[a])-int(gfLog[b])+255]
}

// mulAddInto computes dst ^= coefficient * src, the only vector operation either side needs.
func gfMulAddInto(dst, src []byte, coefficient byte) {
	if coefficient == 0 {
		return
	}
	logC := int(gfLog[coefficient])
	for i := range dst {
		if s := src[i]; s != 0 {
			dst[i] ^= gfExp[logC+int(gfLog[s])]
		}
	}
}

// xorshift32 — the coefficient generator, identical in Go and TypeScript.
//
// COEFFICIENTS RIDE AS A SEED, NOT AS BYTES. A window of 32 symbols would otherwise put 32 bytes of
// coefficients on every repair packet; the seed is 4. Both sides must therefore produce the SAME
// sequence, which is why this is a hand-rolled generator with defined 32-bit semantics rather than
// each language's rand.
type xorshift32 struct{ state uint32 }

func newXorshift32(seed uint32) *xorshift32 {
	if seed == 0 {
		seed = 0x9e3779b9 // a zero state is a fixed point for xorshift; never let it start there
	}
	return &xorshift32{state: seed}
}

func (r *xorshift32) next() uint32 {
	r.state ^= r.state << 13
	r.state ^= r.state >> 17
	r.state ^= r.state << 5
	return r.state
}

// coefficient returns a NON-ZERO GF(256) element. Zero is excluded so every symbol in the window
// genuinely participates: a zero coefficient silently shrinks the window and would make the measured
// code rate a lie.
func (r *xorshift32) coefficient() byte { return byte(r.next()%255) + 1 }

// rlcCoefficients fills `out` with the window's coefficients for one repair symbol.
func rlcCoefficients(seed uint32, out []byte) {
	generator := newXorshift32(seed)
	for i := range out {
		out[i] = generator.coefficient()
	}
}

// rlcEncoder keeps the sliding window of source symbols and builds repair symbols over it.
//
// THE WINDOW IS IN SYMBOLS, NOT FRAMES, and its size is the whole latency/pooling trade: a longer
// window pools protection across more frames (better against bursts) but puts more unknowns in every
// equation, so more equations are needed before anything is solvable. Both halves are measured.
type rlcEncoder struct {
	symbolBytes int
	windowLen   int
	symbols     [][]byte // ring of the last windowLen source symbols, oldest first
	// The REAL length of each symbol in `symbols`, before padding. The padding is what the algebra
	// needs; the real length is what the wire needs, and `buildRepair` sizes itself from the longest
	// one still in the window.
	lengths     []int
	firstESI    uint32   // ESI of symbols[0]
	nextSeed    uint32
}

func newRLCEncoder(symbolBytes, windowLen int, seed uint32) *rlcEncoder {
	return &rlcEncoder{
		symbolBytes: symbolBytes,
		windowLen:   windowLen,
		symbols:     make([][]byte, 0, windowLen),
		nextSeed:    seed,
	}
}

// addSource records one source symbol under the ESI the CALLER assigned. The symbol is COPIED: the
// caller's buffer is reused per frame, and the window outlives it by design.
//
// THE ESI COMES FROM THE MIRROR, NOT FROM HERE, and that is a correctness fix rather than a
// refactor. When the encoder owned the counter, the un-coded arm — which has no encoder — stamped
// EVERY symbol with ESI 0, so the client's decoder kept overwriting one slot and could never
// assemble a frame. The baseline arm measured nothing while reporting cleanly, and only the host's
// own symbol counter (941 against a coded arm's 10,491 over the same 30 s) gave it away.
func (encoder *rlcEncoder) addSource(symbol []byte, esi uint32) {
	stored := make([]byte, encoder.symbolBytes)
	copy(stored, symbol)
	if len(encoder.symbols) == 0 {
		encoder.firstESI = esi
	}
	encoder.symbols = append(encoder.symbols, stored)
	encoder.lengths = append(encoder.lengths, len(symbol))
	if len(encoder.symbols) > encoder.windowLen {
		encoder.symbols = encoder.symbols[1:]
		encoder.lengths = encoder.lengths[1:]
		encoder.firstESI++
	}
}

// buildRepair returns one repair symbol over the current window, plus the window it covers.
// Returns nil when the window is empty.
func (encoder *rlcEncoder) buildRepair() (payload []byte, firstESI uint32, windowLen int, seed uint32) {
	count := len(encoder.symbols)
	if count == 0 {
		return nil, 0, 0, 0
	}
	seed = encoder.nextSeed
	encoder.nextSeed = newXorshift32(seed).next()
	coefficients := make([]byte, count)
	rlcCoefficients(seed, coefficients)
	// SIZED TO THE LONGEST SYMBOL IT COVERS, not to the algebraic width. Every byte past that is a
	// combination of zeroes — provably zero, and provably not worth sending. The receiver zero-extends
	// it back before solving, exactly as it does for a short source symbol.
	//
	// Measured on a static window at 95kbps before this: 310 source symbols of ~470 bytes against 286
	// repair symbols of 1240, so repair was 71% OF THE WIRE while the reported overhead — counted in
	// SYMBOLS — read 29%. Cutting the bitrate twentyfold barely moved the wire, because most of it was
	// padding that does not scale with the picture.
	width := 0
	for _, length := range encoder.lengths {
		if length > width {
			width = length
		}
	}
	payload = make([]byte, width)
	for i, symbol := range encoder.symbols {
		gfMulAddInto(payload, symbol[:width], coefficients[i])
	}
	return payload, encoder.firstESI, count, seed
}
