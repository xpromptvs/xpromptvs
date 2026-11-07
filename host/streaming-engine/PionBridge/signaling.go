package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"time"

	"github.com/pion/webrtc/v4"
)

const (
	maxSignalBytes = uint32(1 << 20)
)

var signalAcceptTimeout = 30 * time.Second
var signalIOTimeout = 10 * time.Second

var errInvalidSignal = errors.New("invalid signaling message")

type signalMessage struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
}

func writeSignal(connection net.Conn, message signalMessage) error {
	if err := message.validate(); err != nil {
		return err
	}
	body, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("marshal signal: %w", err)
	}
	if len(body) == 0 || uint64(len(body)) > uint64(maxSignalBytes) {
		return fmt.Errorf("%w: byte count %d", errInvalidSignal, len(body))
	}
	if err := connection.SetWriteDeadline(time.Now().Add(signalIOTimeout)); err != nil {
		return fmt.Errorf("set signal write deadline: %w", err)
	}
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], uint32(len(body)))
	if err := writeAll(connection, prefix[:]); err != nil {
		return fmt.Errorf("write signal length: %w", err)
	}
	if err := writeAll(connection, body); err != nil {
		return fmt.Errorf("write signal body: %w", err)
	}
	return nil
}

func readSignal(connection net.Conn) (signalMessage, error) {
	if err := connection.SetReadDeadline(time.Now().Add(signalIOTimeout)); err != nil {
		return signalMessage{}, fmt.Errorf("set signal read deadline: %w", err)
	}
	var prefix [4]byte
	if _, err := io.ReadFull(connection, prefix[:]); err != nil {
		return signalMessage{}, fmt.Errorf("read signal length: %w", err)
	}
	length := binary.BigEndian.Uint32(prefix[:])
	if length == 0 || length > maxSignalBytes {
		return signalMessage{}, fmt.Errorf("%w: byte count %d", errInvalidSignal, length)
	}
	body := make([]byte, int(length))
	if _, err := io.ReadFull(connection, body); err != nil {
		return signalMessage{}, fmt.Errorf("read signal body: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var message signalMessage
	if err := decoder.Decode(&message); err != nil {
		return signalMessage{}, fmt.Errorf("%w: %v", errInvalidSignal, err)
	}
	if err := requireJSONEOF(decoder); err != nil {
		return signalMessage{}, err
	}
	if err := message.validate(); err != nil {
		return signalMessage{}, err
	}
	return message, nil
}

func exchangeOffer(connection net.Conn, offer webrtc.SessionDescription) (webrtc.SessionDescription, error) {
	if offer.Type != webrtc.SDPTypeOffer || offer.SDP == "" {
		return webrtc.SessionDescription{}, fmt.Errorf("%w: viewer must send one offer", errInvalidSignal)
	}
	if err := writeSignal(connection, signalMessage{Type: "offer", SDP: offer.SDP}); err != nil {
		return webrtc.SessionDescription{}, err
	}
	message, err := readSignal(connection)
	if err != nil {
		return webrtc.SessionDescription{}, err
	}
	if message.Type != "answer" {
		return webrtc.SessionDescription{}, fmt.Errorf("%w: expected answer, got %s", errInvalidSignal, message.Type)
	}
	return webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: message.SDP}, nil
}

func serveAnswer(
	connection net.Conn,
	answerer func(webrtc.SessionDescription) (webrtc.SessionDescription, error),
) error {
	message, err := readSignal(connection)
	if err != nil {
		return err
	}
	if message.Type != "offer" {
		return fmt.Errorf("%w: expected offer, got %s", errInvalidSignal, message.Type)
	}
	answer, err := answerer(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: message.SDP})
	if err != nil {
		return err
	}
	if answer.Type != webrtc.SDPTypeAnswer || answer.SDP == "" {
		return fmt.Errorf("%w: host must return one answer", errInvalidSignal)
	}
	return writeSignal(connection, signalMessage{Type: "answer", SDP: answer.SDP})
}

func acceptSignalTCP(localIP net.IP, port uint16) (net.Conn, net.IP, error) {
	if !validPeerIPv4(localIP) || port == 0 {
		return nil, nil, fmt.Errorf("%w: invalid signaling listen address", errInvalidSignal)
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: localIP.To4(), Port: int(port)})
	if err != nil {
		return nil, nil, fmt.Errorf("listen for signal: %w", err)
	}
	defer listener.Close()
	if err := listener.SetDeadline(time.Now().Add(signalAcceptTimeout)); err != nil {
		return nil, nil, fmt.Errorf("set signal accept deadline: %w", err)
	}
	connection, err := listener.AcceptTCP()
	if err != nil {
		return nil, nil, fmt.Errorf("accept signal: %w", err)
	}
	if err := connection.SetNoDelay(true); err != nil {
		connection.Close()
		return nil, nil, fmt.Errorf("configure signal TCP connection: %w", err)
	}
	remoteAddress, ok := connection.RemoteAddr().(*net.TCPAddr)
	if !ok || !validPeerIPv4(remoteAddress.IP) {
		connection.Close()
		return nil, nil, fmt.Errorf("%w: signal peer is not IPv4", errInvalidSignal)
	}
	return connection, append(net.IP(nil), remoteAddress.IP.To4()...), nil
}

func connectSignalTCP(localIP, remoteIP net.IP, port uint16) (net.Conn, error) {
	if !validPeerIPv4(localIP) || !validPeerIPv4(remoteIP) || port == 0 {
		return nil, fmt.Errorf("%w: invalid signaling dial address", errInvalidSignal)
	}
	address := net.JoinHostPort(remoteIP.To4().String(), fmt.Sprintf("%d", port))
	deadline := time.Now().Add(signalIOTimeout)
	dialer := net.Dialer{
		Timeout:   250 * time.Millisecond,
		LocalAddr: &net.TCPAddr{IP: localIP.To4()},
	}
	var lastError error
	for {
		connection, err := dialer.Dial("tcp4", address)
		if err == nil {
			if tcpConnection, ok := connection.(*net.TCPConn); ok {
				if configureErr := tcpConnection.SetNoDelay(true); configureErr != nil {
					connection.Close()
					return nil, fmt.Errorf("configure signal TCP connection: %w", configureErr)
				}
			}
			return connection, nil
		}
		lastError = err
		if time.Now().Add(25 * time.Millisecond).After(deadline) {
			return nil, fmt.Errorf("connect signal: %w", lastError)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func (message signalMessage) validate() error {
	if message.Type != "offer" && message.Type != "answer" {
		return fmt.Errorf("%w: unknown type %q", errInvalidSignal, message.Type)
	}
	if message.SDP == "" {
		return fmt.Errorf("%w: empty SDP", errInvalidSignal)
	}
	return nil
}

func requireJSONEOF(decoder *json.Decoder) error {
	var trailing any
	err := decoder.Decode(&trailing)
	if !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("%w: trailing JSON value", errInvalidSignal)
		}
		return fmt.Errorf("%w: trailing bytes: %v", errInvalidSignal, err)
	}
	return nil
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		written, err := writer.Write(data)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		data = data[written:]
	}
	return nil
}
