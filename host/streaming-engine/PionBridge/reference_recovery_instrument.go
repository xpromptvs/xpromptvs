package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
)

// The browser's transform API only requests PLI. This opt-in instrument feeds a
// serialized FIR through the same RTCP reader/parser/dispatcher as network RTCP;
// it never calls the encoder or recovery callback directly.
func (factory *ageAwareNACKResponderFactory) injectReferenceTestRTCP(raw []byte) error {
	factory.mutex.Lock()
	responders := make([]*ageAwareNACKResponder, 0, len(factory.responders))
	for responder := range factory.responders {
		responders = append(responders, responder)
	}
	factory.mutex.Unlock()
	for _, responder := range responders {
		reader := responder.BindRTCPReader(interceptor.RTCPReaderFunc(func(buffer []byte, attributes interceptor.Attributes) (int, interceptor.Attributes, error) {
			return copy(buffer, raw), attributes, nil
		}))
		if _, _, err := reader.Read(make([]byte, len(raw)), nil); err != nil {
			return err
		}
	}
	return nil
}

func (peer *rdevPeer) armReferenceTestFIR(slot int, epoch string) {
	if os.Getenv("RDEV_INSTRUMENTS") != "1" || os.Getenv("RDEV_AV1_REFERENCE_TEST_FIR") != "1" {
		return
	}
	peer.referenceTestFIROnce.Do(func() {
		go func() {
			if path := os.Getenv("RDEV_AV1_REFERENCE_TEST_FIR_FILE"); path != "" {
				deadline := time.Now().Add(20 * time.Second)
				for {
					peer.session.mutex.Lock()
					closing := peer.session.closing
					peer.session.mutex.Unlock()
					if closing || time.Now().After(deadline) {
						return
					}
					if _, err := os.Stat(path); err == nil {
						break
					}
					time.Sleep(10 * time.Millisecond)
				}
			} else {
				time.Sleep(2 * time.Second)
			}
			session := peer.session
			session.mutex.Lock()
			entry, closing := session.videoTracks[slot], session.closing
			session.mutex.Unlock()
			if closing || entry == nil || session.apiResources == nil || session.apiResources.responderFactory == nil {
				return
			}
			track := entry.track
			track.mutex.Lock()
			var ssrc uint32
			// The initial IDR can advance the epoch after this timer is armed.
			epoch = track.referenceLedger.epoch
			if epoch != "" && len(track.bindings) == 1 {
				for _, binding := range track.bindings {
					ssrc = uint32(binding.ssrc)
				}
			}
			track.mutex.Unlock()
			if ssrc == 0 {
				return
			}
			raw, err := (&rtcp.FullIntraRequest{FIR: []rtcp.FIREntry{{SSRC: ssrc, SequenceNumber: 1}}}).Marshal()
			if err != nil {
				return
			}
			triggeredAt := time.Now().UnixMilli()
			if err := session.apiResources.responderFactory.injectReferenceTestRTCP(raw); err != nil {
				return
			}
			data, _ := json.Marshal(map[string]any{"source": entry.sourceID, "epoch": epoch, "feedback": "fir", "unixMs": triggeredAt})
			fmt.Printf("[av1-ref-event] %s\n", data)
		}()
	})
}

// Persist the sender's identity separately from browser receipts so the gate
// cannot manufacture agreement by copying a receipt onto an observed frame.
func (peer *rdevPeer) recordReferenceTestFrame(slot int, metadata referenceFrameMetadata, result referenceSendResult, key bool, payload []byte) {
	path := os.Getenv("RDEV_AV1_REFERENCE_TEST_FRAMES_FILE")
	if os.Getenv("RDEV_INSTRUMENTS") != "1" || path == "" {
		return
	}
	peer.session.mutex.Lock()
	entry := peer.session.videoTracks[slot]
	peer.session.mutex.Unlock()
	if entry == nil {
		return
	}
	data, err := json.Marshal(struct {
		Source   string                 `json:"source"`
		Track    string                 `json:"track"`
		Metadata referenceFrameMetadata `json:"metadata"`
		Result   referenceSendResult    `json:"result"`
		Key      bool                   `json:"key"`
		Payload  []byte                 `json:"payload"`
	}{entry.sourceID, entry.track.ID(), metadata, result, key, payload})
	if err != nil {
		return
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = file.Write(append(data, '\n'))
}

// Align a loss burst with a confirmed browser reference rather than elapsed
// startup time (WebKit may not present the initial candidate immediately).
func referenceTestImpairmentReady() bool {
	if os.Getenv("RDEV_INSTRUMENTS") != "1" {
		return true
	}
	path := os.Getenv("RDEV_AV1_REFERENCE_TEST_IMPAIRMENT_FILE")
	if path == "" {
		return true
	}
	_, err := os.Stat(path)
	return err == nil
}

// Negative control only: lie about an inter response's dependency so the
// browser must refuse it and the normal watchdog must deliver an IDR.
var referenceTestBadDescriptor = os.Getenv("RDEV_INSTRUMENTS") == "1" && os.Getenv("RDEV_AV1_REFERENCE_TEST_BAD_DESCRIPTOR") == "1"
