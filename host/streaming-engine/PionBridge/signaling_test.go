package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"strconv"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func TestSignalingUsesLengthPrefixedStrictJSONAndDeadlines(t *testing.T) {
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	tracked := &deadlineTrackingConn{Conn: left}
	written := make(chan error, 1)
	go func() {
		written <- writeSignal(tracked, signalMessage{Type: "offer", SDP: "v=0\r\n"})
	}()

	var prefix [4]byte
	if _, err := io.ReadFull(right, prefix[:]); err != nil {
		t.Fatal(err)
	}
	length := binary.BigEndian.Uint32(prefix[:])
	body := make([]byte, length)
	if _, err := io.ReadFull(right, body); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(body, []byte(`{"type":"offer","sdp":"v=0\r\n"}`)) {
		t.Fatalf("signal body = %q", body)
	}
	if err := <-written; err != nil {
		t.Fatal(err)
	}
	if !tracked.writeDeadlineSet {
		t.Fatal("write deadline was not set")
	}
}

func TestSignalingAcceptWindowCoversSlowGUIStartup(t *testing.T) {
	if signalAcceptTimeout < 30*time.Second {
		t.Fatalf("signal accept timeout = %s", signalAcceptTimeout)
	}
	if signalIOTimeout > 10*time.Second {
		t.Fatalf("signal I/O timeout = %s", signalIOTimeout)
	}
}

func TestSignalingExchangeEnforcesOfferThenAnswer(t *testing.T) {
	viewer, host := net.Pipe()
	defer viewer.Close()
	defer host.Close()
	hostResult := make(chan error, 1)
	go func() {
		hostResult <- serveAnswer(host, func(offer webrtc.SessionDescription) (webrtc.SessionDescription, error) {
			if offer.Type != webrtc.SDPTypeOffer || offer.SDP != "offer-sdp" {
				t.Errorf("host received %#v", offer)
			}
			return webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: "answer-sdp"}, nil
		})
	}()
	answer, err := exchangeOffer(viewer, webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer, SDP: "offer-sdp",
	})
	if err != nil {
		t.Fatal(err)
	}
	if answer.Type != webrtc.SDPTypeAnswer || answer.SDP != "answer-sdp" {
		t.Fatalf("viewer received %#v", answer)
	}
	if err := <-hostResult; err != nil {
		t.Fatal(err)
	}
}

func TestSignalingRejectsOversizeMalformedTrailingAndWrongOrder(t *testing.T) {
	tests := []struct {
		name string
		body []byte
	}{
		{"malformed JSON", []byte(`{"type":`)},
		{"trailing JSON", []byte(`{"type":"offer","sdp":"x"}{}`)},
		{"unknown field", []byte(`{"type":"offer","sdp":"x","extra":1}`)},
		{"unknown type", []byte(`{"type":"pranswer","sdp":"x"}`)},
		{"empty SDP", []byte(`{"type":"offer","sdp":""}`)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			left, right := net.Pipe()
			defer left.Close()
			defer right.Close()
			go writeRawSignalFrame(right, uint32(len(test.body)), test.body)
			if _, err := readSignal(left); err == nil {
				t.Fatal("invalid signal unexpectedly parsed")
			}
		})
	}

	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	go writeRawSignalFrame(right, maxSignalBytes+1, nil)
	if _, err := readSignal(left); err == nil {
		t.Fatal("oversize signal unexpectedly parsed")
	}

	viewer, host := net.Pipe()
	defer viewer.Close()
	defer host.Close()
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- serveAnswer(host, func(webrtc.SessionDescription) (webrtc.SessionDescription, error) {
			t.Fatal("answer callback should not run")
			return webrtc.SessionDescription{}, nil
		})
	}()
	if err := writeSignal(viewer, signalMessage{Type: "answer", SDP: "wrong"}); err != nil {
		t.Fatal(err)
	}
	if err := <-serverDone; err == nil {
		t.Fatal("answer-first exchange unexpectedly succeeded")
	}
}

func TestSignalingTCPRetriesThenAcceptsExactlyOneConfiguredIPv4Peer(t *testing.T) {
	port := reserveTCPPort(t)
	type acceptedResult struct {
		connection net.Conn
		remoteIP   net.IP
		err        error
	}
	viewerResult := make(chan struct {
		connection net.Conn
		err        error
	}, 1)
	go func() {
		connection, err := connectSignalTCP(
			net.ParseIP("127.0.0.1"), net.ParseIP("127.0.0.1"), port,
		)
		viewerResult <- struct {
			connection net.Conn
			err        error
		}{connection, err}
	}()
	time.Sleep(40 * time.Millisecond)
	hostResult := make(chan acceptedResult, 1)
	go func() {
		connection, remoteIP, err := acceptSignalTCP(net.ParseIP("127.0.0.1"), port)
		hostResult <- acceptedResult{connection, remoteIP, err}
	}()

	viewer := <-viewerResult
	if viewer.err != nil {
		t.Fatal(viewer.err)
	}
	defer viewer.connection.Close()
	host := <-hostResult
	if host.err != nil {
		t.Fatal(host.err)
	}
	defer host.connection.Close()
	if !host.remoteIP.Equal(net.ParseIP("127.0.0.1")) {
		t.Fatalf("accepted remote IP = %s", host.remoteIP)
	}
	if _, err := net.DialTimeout(
		"tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(int(port))), 50*time.Millisecond,
	); err == nil {
		t.Fatal("one-shot signaling listener accepted a second connection")
	}
}

func writeRawSignalFrame(connection net.Conn, length uint32, body []byte) {
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], length)
	_, _ = connection.Write(prefix[:])
	if len(body) != 0 {
		_, _ = connection.Write(body)
	}
}

type deadlineTrackingConn struct {
	net.Conn
	readDeadlineSet  bool
	writeDeadlineSet bool
}

func reserveTCPPort(t *testing.T) uint16 {
	t.Helper()
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return uint16(port)
}

func (connection *deadlineTrackingConn) SetReadDeadline(deadline time.Time) error {
	connection.readDeadlineSet = true
	return connection.Conn.SetReadDeadline(deadline)
}

func (connection *deadlineTrackingConn) SetWriteDeadline(deadline time.Time) error {
	connection.writeDeadlineSet = true
	return connection.Conn.SetWriteDeadline(deadline)
}
