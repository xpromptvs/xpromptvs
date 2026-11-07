package main

import (
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

const maximumRecoveryReadDatagramBytes = 65_535

type recoveryReadDatagram struct {
	payload []byte
	source  net.Addr
}

type recoveryReadPumpHandler func(
	pump *recoveryImpairmentReadPump,
	readID int64,
	datagram recoveryReadDatagram,
) error

type recoveryImpairmentReadPump struct {
	connection net.PacketConn
	controller *RecoveryImpairmentController
	handle     recoveryReadPumpHandler

	mu            sync.Mutex
	queue         []recoveryReadDatagram
	terminalError error
	closed        bool
	readDeadline  time.Time
	changed       chan struct{}
	done          chan struct{}
	closeOnce     sync.Once
	closeError    error
}

func newRecoveryImpairmentReadPump(
	connection net.PacketConn,
	controller *RecoveryImpairmentController,
	handle recoveryReadPumpHandler,
) *recoveryImpairmentReadPump {
	pump := &recoveryImpairmentReadPump{
		connection: connection,
		controller: controller,
		handle:     handle,
		changed:    make(chan struct{}),
		done:       make(chan struct{}),
	}
	go pump.run()
	return pump
}

func (pump *recoveryImpairmentReadPump) run() {
	defer close(pump.done)
	buffer := make([]byte, maximumRecoveryReadDatagramBytes)
	for {
		readID := int64(0)
		if pump.controller != nil {
			readID = pump.controller.beginPacketConnRead()
		}
		n, source, err := pump.connection.ReadFrom(buffer)
		if n > 0 && pump.controller != nil {
			pump.controller.recordPacketConnReadReturned(readID, buffer[:n])
		}
		if n <= 0 || err != nil {
			if err == nil {
				err = io.ErrNoProgress
			}
			pump.terminate(err)
			return
		}
		datagram := recoveryReadDatagram{
			payload: append([]byte(nil), buffer[:n]...),
			source:  source,
		}
		if pump.handle == nil {
			pump.terminate(errors.New("recovery read pump has no scheduling handler"))
			return
		}
		if err := pump.handle(pump, readID, datagram); err != nil {
			pump.terminate(err)
			return
		}
	}
}

func (pump *recoveryImpairmentReadPump) prepareDelivery(
	datagram recoveryReadDatagram,
) (func(), error) {
	pump.mu.Lock()
	if pump.closed {
		pump.mu.Unlock()
		return nil, net.ErrClosed
	}
	if pump.terminalError != nil {
		err := pump.terminalError
		pump.mu.Unlock()
		return nil, err
	}
	pump.queue = append(pump.queue, datagram)
	return func() {
		pump.notifyLocked()
		pump.mu.Unlock()
	}, nil
}

func (pump *recoveryImpairmentReadPump) ReadFrom(
	payload []byte,
) (int, net.Addr, error) {
	for {
		pump.mu.Lock()
		if len(pump.queue) > 0 {
			datagram := pump.queue[0]
			copy(pump.queue, pump.queue[1:])
			pump.queue[len(pump.queue)-1] = recoveryReadDatagram{}
			pump.queue = pump.queue[:len(pump.queue)-1]
			pump.mu.Unlock()
			return copy(payload, datagram.payload), datagram.source, nil
		}
		if pump.closed {
			pump.mu.Unlock()
			return 0, nil, net.ErrClosed
		}
		if pump.terminalError != nil {
			err := pump.terminalError
			pump.mu.Unlock()
			return 0, nil, err
		}
		changed := pump.changed
		deadline := pump.readDeadline
		pump.mu.Unlock()

		if deadline.IsZero() {
			<-changed
			continue
		}
		wait := time.Until(deadline)
		if wait <= 0 {
			return 0, nil, os.ErrDeadlineExceeded
		}
		timer := time.NewTimer(wait)
		select {
		case <-changed:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		case <-timer.C:
			return 0, nil, os.ErrDeadlineExceeded
		}
	}
}

func (pump *recoveryImpairmentReadPump) SetReadDeadline(deadline time.Time) error {
	pump.mu.Lock()
	pump.readDeadline = deadline
	pump.notifyLocked()
	pump.mu.Unlock()
	return nil
}

func (pump *recoveryImpairmentReadPump) Close() error {
	pump.closeOnce.Do(func() {
		pump.mu.Lock()
		pump.closed = true
		pump.queue = nil
		pump.terminalError = net.ErrClosed
		pump.notifyLocked()
		pump.mu.Unlock()

		err := pump.connection.Close()
		if err != nil && !errors.Is(err, net.ErrClosed) {
			pump.closeError = err
		}
		<-pump.done
	})
	return pump.closeError
}

func (pump *recoveryImpairmentReadPump) terminate(err error) {
	pump.mu.Lock()
	if pump.closed {
		err = net.ErrClosed
	}
	if pump.terminalError == nil {
		pump.terminalError = err
	}
	pump.notifyLocked()
	pump.mu.Unlock()
}

func (pump *recoveryImpairmentReadPump) notifyLocked() {
	close(pump.changed)
	pump.changed = make(chan struct{})
}
