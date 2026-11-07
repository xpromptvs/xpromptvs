package main

import (
	"errors"
	"strings"
	"sync/atomic"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

var (
	errTWCCExtensionNotNegotiated = errors.New("TWCC RTP header extension was not negotiated")
	errNilTWCCHeader              = errors.New("nil RTP header for TWCC injection")
)

// TransportSequenceAllocator owns the single transport-wide packet sequence
// used by media, RTX, and FlexFEC packets in one PeerConnection.
type TransportSequenceAllocator struct {
	next atomic.Uint32
}

func NewTransportSequenceAllocator() *TransportSequenceAllocator {
	return newTransportSequenceAllocator(0)
}

func newTransportSequenceAllocator(seed uint16) *TransportSequenceAllocator {
	allocator := &TransportSequenceAllocator{}
	allocator.next.Store(uint32(seed))
	return allocator
}

func (allocator *TransportSequenceAllocator) Next() uint16 {
	return uint16(allocator.next.Add(1) - 1) //nolint:gosec // The wire counter intentionally wraps at 16 bits.
}

type twccHeaderInjectorFactory struct {
	allocator *TransportSequenceAllocator
	history   *TWCCPacketHistory
	budget    *RecoveryFrameClockBudget
}

func NewTWCCHeaderInjector(
	allocator *TransportSequenceAllocator,
	history *TWCCPacketHistory,
	budgets ...*RecoveryFrameClockBudget,
) interceptor.Factory {
	var budget *RecoveryFrameClockBudget
	if len(budgets) == 1 {
		budget = budgets[0]
	}
	return &twccHeaderInjectorFactory{
		allocator: allocator, history: history, budget: budget,
	}
}

func (factory *twccHeaderInjectorFactory) NewInterceptor(_ string) (interceptor.Interceptor, error) {
	if factory.allocator == nil || factory.history == nil {
		return nil, errors.New("TWCC injector requires allocator and history")
	}
	return &twccHeaderInjector{
		allocator: factory.allocator, history: factory.history, budget: factory.budget,
	}, nil
}

type twccHeaderInjector struct {
	interceptor.NoOp
	allocator *TransportSequenceAllocator
	history   *TWCCPacketHistory
	budget    *RecoveryFrameClockBudget
}

func (injector *twccHeaderInjector) BindLocalStream(
	info *interceptor.StreamInfo,
	writer interceptor.RTPWriter,
) interceptor.RTPWriter {
	if info == nil || writer == nil {
		return interceptor.RTPWriterFunc(func(*rtp.Header, []byte, interceptor.Attributes) (int, error) {
			return 0, errTWCCExtensionNotNegotiated
		})
	}
	// AN AUDIO STREAM PASSES THROUGH UNTOUCHED. rdev registers the TWCC header extension for VIDEO
	// ONLY, so an Opus stream carries none and the check below refused EVERY audio write with
	// "TWCC RTP header extension was not negotiated" — silently, because the encoder's own counter
	// reports encodes rather than wire packets and went on printing 96.8 kbps.
	//
	// TWCC HERE IS rdev's VIDEO RECOVERY BOOKKEEPING — the transport-sequence allocator, the packet
	// history and the frame-clock budget are all video-shaped — so audio is not a participant rather
	// than an unconfigured one. Enrolling it would mean giving audio a frame clock it does not have.
	//
	// EXPLICIT AUDIO ONLY, never "not video": an empty or unfamiliar MimeType still falls through and
	// still fails, because a VIDEO stream without the extension is a real misconfiguration and is
	// what this refusal exists to catch. Same rule, and the same reasoning, as frameAwareFlexFEC's.
	if strings.HasPrefix(strings.ToLower(info.MimeType), "audio/") {
		return writer
	}
	extensionID := uint8(0)
	for _, extension := range info.RTPHeaderExtensions {
		if extension.URI == twccURI && extension.ID > 0 && extension.ID <= 255 {
			extensionID = uint8(extension.ID)
			break
		}
	}
	if extensionID == 0 {
		return interceptor.RTPWriterFunc(func(*rtp.Header, []byte, interceptor.Attributes) (int, error) {
			return 0, errTWCCExtensionNotNegotiated
		})
	}
	mediaSSRC := info.SSRC
	rtxSSRC := info.SSRCRetransmission
	fecSSRC := info.SSRCForwardErrorCorrection
	return interceptor.RTPWriterFunc(func(
		header *rtp.Header,
		payload []byte,
		attributes interceptor.Attributes,
	) (int, error) {
		if header == nil {
			return 0, errNilTWCCHeader
		}
		packetClass := TWCCMedia
		switch header.SSRC {
		case rtxSSRC:
			if rtxSSRC != 0 {
				packetClass = TWCCRTX
			}
		case fecSSRC:
			if fecSSRC != 0 {
				packetClass = TWCCFEC
			}
		case mediaSSRC:
			packetClass = TWCCMedia
		}
		if err := header.SetExtension(extensionID, []byte{0, 0}); err != nil {
			return 0, err
		}
		packetBytes := header.MarshalSize() + len(payload) + int(header.PaddingSize)
		if injector.budget != nil {
			if packetClass == TWCCMedia {
				if err := injector.budget.ObserveMedia(packetBytes); err != nil {
					return 0, err
				}
			} else {
				admitted, err := injector.budget.TryAdmitRecovery(packetClass, packetBytes)
				if err != nil {
					return 0, err
				}
				if !admitted {
					return 0, errRecoveryFrameClockSuppressed
				}
			}
		}
		sequence := injector.allocator.Next()
		extension, err := (&rtp.TransportCCExtension{TransportSequence: sequence}).Marshal()
		if err != nil {
			return 0, err
		}
		if err := header.SetExtension(extensionID, extension); err != nil {
			return 0, err
		}
		injector.history.RecordSent(TWCCSentPacket{
			SSRC: header.SSRC, RTPSequence: header.SequenceNumber,
			TransportSequence: sequence, Class: packetClass,
			Bytes: packetBytes, Departure: injector.history.now(),
		})
		return writer.Write(header, payload, attributes)
	})
}

func (injector *twccHeaderInjector) BindRTCPReader(reader interceptor.RTCPReader) interceptor.RTCPReader {
	if reader == nil {
		return reader
	}
	return interceptor.RTCPReaderFunc(func(
		buffer []byte,
		attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		count, returnedAttributes, err := reader.Read(buffer, attributes)
		if err != nil || count <= 0 {
			return count, returnedAttributes, err
		}
		packets, unmarshalErr := rtcp.Unmarshal(buffer[:count])
		if unmarshalErr != nil {
			injector.history.recordMalformedFeedback()
			return count, returnedAttributes, nil
		}
		for _, packet := range packets {
			feedback, ok := packet.(*rtcp.TransportLayerCC)
			if !ok {
				continue
			}
			_ = injector.history.ApplyFeedback(feedback)
		}
		return count, returnedAttributes, nil
	})
}
