package main

import "sort"

// THE LANE'S FEC HALVES ON THE MAC (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §3, "Decisions" 5): the
// same code as the DataChannel video path (rdev_dc_rlc.go — the field, the generator), over a window of any size,
// and a DECODER, which the video path never needed on this side. The decoder is a port of web/src/lib/rlc.ts's
// RlcDecoder — the same elimination, the same normalisation rule — with 64-bit ESIs and a caller-set history.

// rlcRepair is one repair symbol over `symbols` — consecutive ESIs, the first being the window's: Σ cᵢ·Sᵢ with the
// coefficients `seed` draws, sized to the LONGEST symbol (the others count as zero-extended), as
// rlcEncoder.buildRepair does over its ring.
func rlcRepair(symbols [][]byte, seed uint32) []byte {
	coefficients := make([]byte, len(symbols))
	rlcCoefficients(seed, coefficients)
	width := 0
	for _, symbol := range symbols {
		if len(symbol) > width {
			width = len(symbol)
		}
	}
	out := make([]byte, width)
	for i, symbol := range symbols {
		gfMulAddInto(out[:len(symbol)], symbol, coefficients[i])
	}
	return out
}

// rlcNextSeed is the seed after `seed`: one step of the coefficient generator, as rlcEncoder advances its own.
func rlcNextSeed(seed uint32) uint32 { return newXorshift32(seed).next() }

// A hard ceiling on one reduction, so no arithmetic error can spin a goroutine forever. Each pass removes a term.
const rlcMaxEliminationPasses = 4096

// rlcEquation is one repair equation, reduced as far as current knowledge allows: ESI → coefficient for the
// unknowns still in play.
type rlcEquation struct {
	terms   map[uint64]byte
	payload []byte
}

// rlcDecoder solves the page's repairs. EVERY PAYLOAD MUST BE ONE WIDTH (the first seen): the lane pads to
// laneSymbolMax; a payload of another width is refused rather than mis-solved.
type rlcDecoder struct {
	history          uint64
	width            int
	symbols          map[uint64][]byte
	pivots           map[uint64]*rlcEquation // keyed by the LEADING unknown, normalised to coefficient 1
	newest           uint64
	hasNewest        bool
	recovered        int
	redundant        int
	duplicateSymbols int
}

func newRLCDecoder(history uint64) *rlcDecoder {
	return &rlcDecoder{history: history, symbols: map[uint64][]byte{}, pivots: map[uint64]*rlcEquation{}}
}

func (d *rlcDecoder) has(esi uint64) bool   { _, ok := d.symbols[esi]; return ok }
func (d *rlcDecoder) get(esi uint64) []byte { return d.symbols[esi] }

// TEST-ONLY. The leading coefficient of every stored pivot — the invariant (each is 1) cannot be seen through
// behaviour, since rlcMaxEliminationPasses turns a violation into a quiet early exit, not a visible hang.
func (d *rlcDecoder) debugPivotLeadingCoefficients() []byte {
	out := make([]byte, 0, len(d.pivots))
	for leading, equation := range d.pivots {
		out = append(out, equation.terms[leading])
	}
	return out
}

// inHistory: an ESI the decoder may still hold — newer than newest − history.
func (d *rlcDecoder) inHistory(esi uint64) bool { return !d.hasNewest || esi+d.history > d.newest }

func (d *rlcDecoder) noteNewest(esi uint64) {
	if !d.hasNewest || esi > d.newest {
		d.newest, d.hasNewest = esi, true
	}
}

func (d *rlcDecoder) widthOK(payload []byte) bool {
	if len(payload) == 0 {
		return false // width 0 is "not yet set": an empty first payload would leave every later one unchecked
	}
	if d.width == 0 {
		d.width = len(payload)
	}
	return len(payload) == d.width
}

// belowFloor: an ESI prune deletes — older than newest − history.
func (d *rlcDecoder) belowFloor(esi uint64) bool {
	return d.hasNewest && d.newest >= d.history && esi < d.newest-d.history
}

// addSource: a source symbol arrived intact. Returns the ESIs this made newly known (itself, and what it unlocked).
// One below the floor is refused: prune would delete it at once, and the ESI returned would name a symbol get cannot
// give.
func (d *rlcDecoder) addSource(esi uint64, payload []byte) []uint64 {
	if !d.widthOK(payload) || d.belowFloor(esi) {
		return nil
	}
	if _, ok := d.symbols[esi]; ok {
		d.duplicateSymbols++
		return nil
	}
	d.symbols[esi] = payload
	d.noteNewest(esi)
	unlocked := d.substitute(esi)
	d.prune()
	return append([]uint64{esi}, unlocked...)
}

// addRepair: a repair symbol over [first, first+count) arrived. Returns the ESIs it made known, if any. An unknown
// past the history ABANDONS the equation: dropping its term would make every recovery from it wrong.
func (d *rlcDecoder) addRepair(first uint64, count int, seed uint32, payload []byte) []uint64 {
	if count <= 0 || !d.widthOK(payload) {
		return nil
	}
	coefficients := make([]byte, count)
	rlcCoefficients(seed, coefficients)
	equation := &rlcEquation{terms: map[uint64]byte{}, payload: append([]byte(nil), payload...)}
	for i := 0; i < count; i++ {
		esi := first + uint64(i)
		if known, ok := d.symbols[esi]; ok {
			gfMulAddInto(equation.payload, known, coefficients[i])
		} else if d.inHistory(esi) {
			equation.terms[esi] = coefficients[i]
		} else {
			return nil
		}
	}
	d.noteNewest(first + uint64(count) - 1)
	unlocked := d.reduceAndStore(equation)
	d.prune()
	return unlocked
}

func (d *rlcDecoder) solve(esi uint64, coefficient byte, payload []byte) []uint64 {
	if _, ok := d.symbols[esi]; ok {
		d.redundant++
		return nil
	}
	solved := make([]byte, len(payload))
	gfMulAddInto(solved, payload, gfDiv(1, coefficient))
	d.symbols[esi] = solved
	d.recovered++
	return append([]uint64{esi}, d.substitute(esi)...)
}

// reduceAndStore reduces an equation against the pivots, then solves it, stores it or discards it.
func (d *rlcDecoder) reduceAndStore(equation *rlcEquation) []uint64 {
	for guard := 0; guard < rlcMaxEliminationPasses; guard++ {
		eliminated := false
		for esi, coefficient := range equation.terms {
			pivot, ok := d.pivots[esi]
			if !ok {
				continue
			}
			// The pivot leads with 1, so scaling it by `coefficient` and adding cancels this term exactly.
			for pesi, pcoefficient := range pivot.terms {
				next := equation.terms[pesi] ^ gfMul(pcoefficient, coefficient)
				if next == 0 {
					delete(equation.terms, pesi)
				} else {
					equation.terms[pesi] = next
				}
			}
			gfMulAddInto(equation.payload, pivot.payload, coefficient)
			eliminated = true
			break // the map changed; scan again
		}
		if !eliminated {
			break
		}
	}
	switch len(equation.terms) {
	case 0:
		d.redundant++
		return nil
	case 1:
		for esi, coefficient := range equation.terms {
			return d.solve(esi, coefficient, equation.payload)
		}
	}
	leading := minESI(equation.terms)
	if c := equation.terms[leading]; c != 1 {
		inverse := gfDiv(1, c)
		scaled := make([]byte, len(equation.payload))
		gfMulAddInto(scaled, equation.payload, inverse)
		equation.payload = scaled
		for esi, coefficient := range equation.terms {
			equation.terms[esi] = gfMul(coefficient, inverse)
		}
	}
	if existing, ok := d.pivots[leading]; ok {
		// Two equations leading on one unknown: their sum leads on a later one.
		for pesi, pcoefficient := range existing.terms {
			next := equation.terms[pesi] ^ pcoefficient
			if next == 0 {
				delete(equation.terms, pesi)
			} else {
				equation.terms[pesi] = next
			}
		}
		gfMulAddInto(equation.payload, existing.payload, 1)
		return d.reduceAndStore(equation)
	}
	d.pivots[leading] = equation
	return nil
}

// substitute: a symbol became known — put it into every equation that mentions it, solving any that collapse to
// one unknown, and re-keying (and re-normalising, through reduceAndStore) one whose LEADING unknown it was.
func (d *rlcDecoder) substitute(esi uint64) []uint64 {
	var unlocked []uint64
	queue := []uint64{esi}
	for len(queue) > 0 {
		known := queue[0]
		queue = queue[1:]
		symbol := d.symbols[known]
		for _, leading := range sortedESIs(d.pivots) {
			equation, ok := d.pivots[leading]
			if !ok {
				continue
			}
			coefficient, ok := equation.terms[known]
			if !ok {
				continue
			}
			gfMulAddInto(equation.payload, symbol, coefficient)
			delete(equation.terms, known)
			switch len(equation.terms) {
			case 0:
				delete(d.pivots, leading)
				d.redundant++
				continue
			case 1:
				delete(d.pivots, leading)
				for rest, restCoefficient := range equation.terms {
					unlocked = append(unlocked, d.solve(rest, restCoefficient, equation.payload)...)
				}
				continue
			}
			if leading == known {
				delete(d.pivots, leading)
				unlocked = append(unlocked, d.reduceAndStore(equation)...)
			}
		}
	}
	return unlocked
}

func (d *rlcDecoder) prune() {
	if !d.hasNewest || d.newest < d.history {
		return
	}
	floor := d.newest - d.history
	for esi := range d.symbols {
		if esi < floor {
			delete(d.symbols, esi)
		}
	}
	for leading, equation := range d.pivots {
		if leading < floor {
			delete(d.pivots, leading)
			continue
		}
		for esi := range equation.terms {
			if esi < floor {
				delete(d.pivots, leading)
				break
			}
		}
	}
}

func minESI(terms map[uint64]byte) uint64 {
	first := true
	var least uint64
	for esi := range terms {
		if first || esi < least {
			least, first = esi, false
		}
	}
	return least
}

func sortedESIs(pivots map[uint64]*rlcEquation) []uint64 {
	out := make([]uint64, 0, len(pivots))
	for esi := range pivots {
		out = append(out, esi)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
