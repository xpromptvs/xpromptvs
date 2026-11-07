package main

import (
	"io"
	"strings"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/transport/v4/packetio"
)

const (
	receiverRTTRTPBufferBytes = 1_000_000
	receiverRTTCPBufferBytes  = 100_000
)

type ReceiverRTTResponderConfig struct {
	Now         func() time.Time
	ReportError func(error)
	Counters    *RecoveryCounters
	MediaRTT    *mediaRTTEstimator
}

type receiverRTTResponderFactory struct {
	config    ReceiverRTTResponderConfig
	mutex     sync.Mutex
	responder *receiverRTTResponder
}

func NewReceiverRTTResponder(config ReceiverRTTResponderConfig) *receiverRTTResponderFactory {
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.ReportError == nil {
		config.ReportError = func(error) {}
	}
	if config.Counters == nil {
		config.Counters = &RecoveryCounters{}
	}
	return &receiverRTTResponderFactory{config: config}
}

func (factory *receiverRTTResponderFactory) NewInterceptor(
	_ string,
) (interceptor.Interceptor, error) {
	responder := &receiverRTTResponder{config: factory.config}
	factory.mutex.Lock()
	factory.responder = responder
	factory.mutex.Unlock()
	return responder, nil
}

func (factory *receiverRTTResponderFactory) NewPacketBuffer(
	packetType packetio.BufferPacketType,
	ssrc uint32,
) io.ReadWriteCloser {
	buffer := packetio.NewBuffer()
	if packetType == packetio.RTCPBufferPacket {
		buffer.SetLimitSize(receiverRTTCPBufferBytes)
		return &receiverRTTObservedPacketBuffer{
			ReadWriteCloser: buffer,
			observe: func(packet []byte) {
				factory.observeRTCP(ssrc, packet)
			},
		}
	}
	buffer.SetLimitSize(receiverRTTRTPBufferBytes)
	return buffer
}

func (factory *receiverRTTResponderFactory) observeRTCP(ssrc uint32, raw []byte) {
	factory.config.Counters.addRTCPPacketObserved()
	packets, err := rtcp.Unmarshal(raw)
	if err != nil {
		factory.config.ReportError(err)
		return
	}
	factory.mutex.Lock()
	responder := factory.responder
	factory.mutex.Unlock()
	if responder != nil {
		responder.replyToRRTR(packets, ssrc, factory.config.Now())
	}
}

type receiverRTTObservedPacketBuffer struct {
	io.ReadWriteCloser
	observe func([]byte)
}

func (buffer *receiverRTTObservedPacketBuffer) Write(packet []byte) (int, error) {
	buffer.observe(packet)
	return buffer.ReadWriteCloser.Write(packet)
}

type receiverRTTResponder struct {
	interceptor.NoOp
	config ReceiverRTTResponderConfig

	mutex      sync.Mutex
	writer     interceptor.RTCPWriter
	senderSSRC uint32
	closed     bool
}

func (responder *receiverRTTResponder) BindRTCPWriter(
	writer interceptor.RTCPWriter,
) interceptor.RTCPWriter {
	responder.mutex.Lock()
	if !responder.closed {
		responder.writer = writer
	}
	responder.mutex.Unlock()
	return writer
}

func (responder *receiverRTTResponder) BindLocalStream(
	info *interceptor.StreamInfo,
	writer interceptor.RTPWriter,
) interceptor.RTPWriter {
	// AUDIO MUST NOT TAKE THE SSRC OVER. This remembers ONE senderSSRC and reports receiver RTT
	// against it, and audio binds AFTER video — so without this guard the RTT that rdev's video
	// recovery stack depends on would be measured against the Opus stream instead. Nothing would
	// look broken; the number would just be about the wrong thing.
	if strings.HasPrefix(strings.ToLower(info.MimeType), "audio/") {
		return writer
	}
	responder.mutex.Lock()
	if !responder.closed && info.SSRC != 0 {
		responder.senderSSRC = info.SSRC
	}
	responder.mutex.Unlock()
	return writer
}

func (responder *receiverRTTResponder) UnbindLocalStream(info *interceptor.StreamInfo) {
	responder.mutex.Lock()
	if responder.senderSSRC == info.SSRC {
		responder.senderSSRC = 0
	}
	responder.mutex.Unlock()
}

func (responder *receiverRTTResponder) replyToRRTR(
	packets []rtcp.Packet,
	receiverSSRC uint32,
	receivedAt time.Time,
) {
	responder.mutex.Lock()
	writer := responder.writer
	senderSSRC := responder.senderSSRC
	active := !responder.closed && writer != nil && senderSSRC != 0
	responder.mutex.Unlock()
	responder.observeMediaRTTForSender(packets, receivedAt, senderSSRC)
	if !active {
		return
	}

	responses := make([]rtcp.Packet, 0, len(packets))
	for _, packet := range packets {
		xr, ok := packet.(*rtcp.ExtendedReport)
		if !ok || xr.SenderSSRC != receiverSSRC {
			continue
		}
		for _, report := range xr.Reports {
			rrtr, ok := report.(*rtcp.ReceiverReferenceTimeReportBlock)
			if !ok || rrtr.NTPTimestamp == 0 || xr.SenderSSRC == 0 {
				continue
			}
			responder.config.Counters.addRRTRReceived()
			responses = append(responses, &rtcp.ExtendedReport{
				SenderSSRC: senderSSRC,
				Reports: []rtcp.ReportBlock{&rtcp.DLRRReportBlock{
					Reports: []rtcp.DLRRReport{{
						SSRC:   xr.SenderSSRC,
						LastRR: uint32(rrtr.NTPTimestamp >> 16),
						DLRR:   receiverRTTDelayTicks(responder.config.Now().Sub(receivedAt)),
					}},
				}},
			})
		}
	}
	if len(responses) == 0 {
		return
	}
	if _, err := writer.Write(responses, make(interceptor.Attributes)); err != nil {
		responder.config.ReportError(err)
		return
	}
	for range responses {
		responder.config.Counters.addDLRRSent()
	}
}

func (responder *receiverRTTResponder) observeMediaRTT(
	packets []rtcp.Packet,
	receivedAt time.Time,
) {
	responder.mutex.Lock()
	senderSSRC := responder.senderSSRC
	responder.mutex.Unlock()
	responder.observeMediaRTTForSender(packets, receivedAt, senderSSRC)
}

func (responder *receiverRTTResponder) observeMediaRTTForSender(
	packets []rtcp.Packet,
	receivedAt time.Time,
	senderSSRC uint32,
) {
	responder.observeMediaRTTAtCompactNTPForSender(packets, compactNTP(receivedAt), senderSSRC)
}

func (responder *receiverRTTResponder) observeMediaRTTAtCompactNTP(
	packets []rtcp.Packet,
	arrival uint32,
) {
	responder.mutex.Lock()
	senderSSRC := responder.senderSSRC
	responder.mutex.Unlock()
	responder.observeMediaRTTAtCompactNTPForSender(packets, arrival, senderSSRC)
}

func (responder *receiverRTTResponder) observeMediaRTTAtCompactNTPForSender(
	packets []rtcp.Packet,
	arrival uint32,
	senderSSRC uint32,
) {
	if senderSSRC == 0 || responder.config.MediaRTT == nil {
		return
	}
	for _, packet := range packets {
		report, ok := packet.(*rtcp.ReceiverReport)
		if !ok {
			continue
		}
		for _, block := range report.Reports {
			if block.SSRC != senderSSRC || block.LastSenderReport == 0 {
				continue
			}
			ticks := arrival - block.LastSenderReport - block.Delay
			responder.config.MediaRTT.Observe(compactNTPTicksToDuration(ticks))
		}
	}
}

func receiverRTTDelayTicks(delay time.Duration) uint32 {
	if delay <= 0 {
		return 0
	}
	ticks := uint64(delay) * 65_536 / uint64(time.Second)
	if ticks > uint64(^uint32(0)) {
		return ^uint32(0)
	}
	return uint32(ticks)
}

func (responder *receiverRTTResponder) Close() error {
	responder.mutex.Lock()
	responder.closed = true
	responder.writer = nil
	responder.senderSSRC = 0
	responder.mutex.Unlock()
	return nil
}
