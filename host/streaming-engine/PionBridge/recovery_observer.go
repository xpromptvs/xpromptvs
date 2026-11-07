package main

import (
	"encoding/binary"
	"fmt"
	"strings"
	"sync"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

type recoveryObserverFactory struct {
	counters       *RecoveryCounters
	markNegotiated func()
	trace          *recoveryTraceRecorder
	impairment     *RecoveryImpairmentController
}

func NewRecoveryObserver(
	counters *RecoveryCounters,
	markNegotiated func(),
	traces ...*recoveryTraceRecorder,
) *recoveryObserverFactory {
	if counters == nil {
		counters = &RecoveryCounters{}
	}
	if markNegotiated == nil {
		markNegotiated = func() {}
	}
	var trace *recoveryTraceRecorder
	if len(traces) != 0 {
		trace = traces[0]
	}
	return &recoveryObserverFactory{
		counters: counters, markNegotiated: markNegotiated,
		trace: trace,
	}
}

func (factory *recoveryObserverFactory) WithImpairment(
	impairment *RecoveryImpairmentController,
) *recoveryObserverFactory {
	factory.impairment = impairment
	if impairment != nil {
		impairment.enableDecryptedRTCPClassification()
	}
	return factory
}

func (factory *recoveryObserverFactory) NewInterceptor(
	_ string,
) (interceptor.Interceptor, error) {
	return &recoveryObserver{
		counters:       factory.counters,
		markNegotiated: factory.markNegotiated,
		trace:          factory.trace,
		impairment:     factory.impairment,
		outstanding:    make(map[uint16]struct{}),
		repaired:       make(map[uint16]struct{}),
		remoteStreams:  make(map[uint32]*recoveryRemoteStream),
	}, nil
}

type recoveryObserver struct {
	interceptor.NoOp
	counters       *RecoveryCounters
	markNegotiated func()
	trace          *recoveryTraceRecorder
	impairment     *RecoveryImpairmentController

	mutex          sync.Mutex
	negotiatedOnce sync.Once
	outstanding    map[uint16]struct{}
	repaired       map[uint16]struct{}
	remoteStreams  map[uint32]*recoveryRemoteStream
	closed         bool
}

func (observer *recoveryObserver) BindLocalStream(
	info *interceptor.StreamInfo,
	writer interceptor.RTPWriter,
) interceptor.RTPWriter {
	if info.SSRC != 0 && info.SSRCRetransmission != 0 &&
		info.PayloadTypeRetransmission != 0 {
		observer.markRTXNegotiated()
	}
	return writer
}

type recoveryRemoteStream struct {
	ssrc uint32
}

func (observer *recoveryObserver) BindRTCPReader(
	reader interceptor.RTCPReader,
) interceptor.RTCPReader {
	return interceptor.RTCPReaderFunc(func(
		buffer []byte,
		attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		for {
			count, returnedAttributes, err := reader.Read(buffer, attributes)
			if err != nil {
				return count, returnedAttributes, err
			}
			packets, parseErr := rtcp.Unmarshal(buffer[:count])
			if parseErr != nil {
				return count, returnedAttributes, nil
			}
			if observer.impairment != nil {
				packets, err = observer.impairment.filterIncomingRTCP(packets)
				if err != nil {
					return 0, returnedAttributes, err
				}
				if len(packets) == 0 {
					attributes = returnedAttributes
					continue
				}
				encoded, marshalErr := rtcp.Marshal(packets)
				if marshalErr != nil {
					return 0, returnedAttributes, fmt.Errorf(
						"marshal impaired RTCP: %w", marshalErr,
					)
				}
				if len(encoded) > len(buffer) {
					return 0, returnedAttributes, fmt.Errorf(
						"impaired RTCP length %d exceeds buffer %d", len(encoded), len(buffer),
					)
				}
				copy(buffer, encoded)
				count = len(encoded)
			}
			observer.mutex.Lock()
			active := !observer.closed
			observer.mutex.Unlock()
			if active {
				for _, packet := range packets {
					if _, ok := packet.(*rtcp.SenderReport); ok {
						observer.counters.addSenderReportReceived()
					}
				}
			}
			return count, returnedAttributes, nil
		}
	})
}

func (observer *recoveryObserver) BindRTCPWriter(
	writer interceptor.RTCPWriter,
) interceptor.RTCPWriter {
	return interceptor.RTCPWriterFunc(func(
		packets []rtcp.Packet,
		attributes interceptor.Attributes,
	) (int, error) {
		packetCount := uint64(0)
		sequenceCount := uint64(0)
		type bufferedNACK struct {
			mediaSSRC uint32
			sequence  uint16
		}
		var buffered []bufferedNACK
		observer.mutex.Lock()
		if !observer.closed {
			for _, packet := range packets {
				nack, ok := packet.(*rtcp.TransportLayerNack)
				if !ok {
					continue
				}
				packetCount++
				for index := range nack.Nacks {
					nack.Nacks[index].Range(func(sequence uint16) bool {
						sequenceCount++
						buffered = append(buffered, bufferedNACK{
							mediaSSRC: nack.MediaSSRC, sequence: sequence,
						})
						if _, alreadyRepaired := observer.repaired[sequence]; !alreadyRepaired {
							observer.outstanding[sequence] = struct{}{}
						}
						return true
					})
				}
			}
		}
		observer.mutex.Unlock()
		for _, nack := range buffered {
			mediaSSRC := nack.mediaSSRC
			requestedSequence := nack.sequence
			observer.trace.Record(recoveryTraceEvent{
				Layer: traceLayerPionReceiver, Kind: traceNACKBuffered,
				MediaSSRC: &mediaSSRC, RTPSequence: &requestedSequence,
			})
		}
		for range packetCount {
			observer.counters.addNACKSent(0)
		}
		if sequenceCount != 0 {
			observer.counters.nackSequencesSent.Add(sequenceCount)
		}
		return writer.Write(packets, attributes)
	})
}

func (observer *recoveryObserver) BindRemoteStream(
	info *interceptor.StreamInfo,
	reader interceptor.RTPReader,
) interceptor.RTPReader {
	if !strings.EqualFold(info.MimeType, "video/rtx") {
		return interceptor.RTPReaderFunc(func(
			buffer []byte,
			attributes interceptor.Attributes,
		) (int, interceptor.Attributes, error) {
			count, returnedAttributes, err := reader.Read(buffer, attributes)
			if err != nil || count < 4 {
				return count, returnedAttributes, err
			}
			sequence := binary.BigEndian.Uint16(buffer[2:4])
			observer.mutex.Lock()
			if !observer.closed {
				delete(observer.repaired, sequence)
			}
			observer.mutex.Unlock()
			return count, returnedAttributes, nil
		})
	}
	state := &recoveryRemoteStream{ssrc: info.SSRC}
	observer.mutex.Lock()
	if observer.closed {
		observer.mutex.Unlock()
		return reader
	}
	observer.remoteStreams[info.SSRC] = state
	observer.mutex.Unlock()
	observer.markRTXNegotiated()

	return interceptor.RTPReaderFunc(func(
		buffer []byte,
		attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		count, returnedAttributes, err := reader.Read(buffer, attributes)
		if err != nil {
			return 0, nil, err
		}
		packet := &rtp.Packet{}
		if err := packet.Unmarshal(buffer[:count]); err != nil || len(packet.Payload) < 2 {
			return count, returnedAttributes, nil
		}
		originalSequence := binary.BigEndian.Uint16(packet.Payload[:2])
		observer.mutex.Lock()
		active := !observer.closed && observer.remoteStreams[state.ssrc] == state
		_, repaired := observer.outstanding[originalSequence]
		if active && repaired {
			delete(observer.outstanding, originalSequence)
			observer.repaired[originalSequence] = struct{}{}
		}
		observer.mutex.Unlock()
		if !active {
			return count, returnedAttributes, nil
		}
		observer.counters.addRTXReceived(uint64(count))
		if repaired {
			observer.counters.addPacketRepaired()
			requestedSequence := originalSequence
			observer.trace.Record(recoveryTraceEvent{
				Layer: traceLayerPionReceiver, Kind: traceRTXArrived,
				RTPSequence: &requestedSequence,
			})
		}
		return count, returnedAttributes, nil
	})
}

func (observer *recoveryObserver) markRTXNegotiated() {
	observer.mutex.Lock()
	active := !observer.closed
	observer.mutex.Unlock()
	if active {
		observer.negotiatedOnce.Do(observer.markNegotiated)
	}
}

func (observer *recoveryObserver) UnbindRemoteStream(info *interceptor.StreamInfo) {
	observer.mutex.Lock()
	delete(observer.remoteStreams, info.SSRC)
	observer.mutex.Unlock()
}

func (observer *recoveryObserver) Close() error {
	observer.mutex.Lock()
	observer.closed = true
	observer.outstanding = nil
	observer.repaired = nil
	observer.remoteStreams = nil
	observer.mutex.Unlock()
	return nil
}
