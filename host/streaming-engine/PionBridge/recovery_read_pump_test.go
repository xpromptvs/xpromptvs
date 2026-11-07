package main

import (
	"errors"
	"net"
	"reflect"
	"testing"
	"time"
)

func publishRecoveryReadImmediately(
	pump *recoveryImpairmentReadPump,
	_ int64,
	datagram recoveryReadDatagram,
) error {
	commit, err := pump.prepareDelivery(datagram)
	if err != nil {
		return err
	}
	commit()
	return nil
}

func TestRecoveryReadPumpPreservesFIFOAddressAndTruncation(t *testing.T) {
	underlying := newMatrixPacketConn()
	pump := newRecoveryImpairmentReadPump(
		underlying, nil, publishRecoveryReadImmediately,
	)
	t.Cleanup(func() { _ = pump.Close() })
	first := matrixPacketRead{
		payload: []byte{1, 2, 3, 4}, source: matrixTestAddr("first"),
	}
	second := matrixPacketRead{
		payload: []byte{5, 6, 7}, source: matrixTestAddr("second"),
	}
	underlying.reads <- first
	underlying.reads <- second

	short := make([]byte, 2)
	n, address, err := pump.ReadFrom(short)
	if err != nil || n != len(short) ||
		!reflect.DeepEqual(short, first.payload[:len(short)]) ||
		address.String() != first.source.String() {
		t.Fatalf("first read = %d, %v, %x, %v", n, err, short, address)
	}
	full := make([]byte, 16)
	n, address, err = pump.ReadFrom(full)
	if err != nil || !reflect.DeepEqual(full[:n], second.payload) ||
		address.String() != second.source.String() {
		t.Fatalf("second read = %d, %v, %x, %v", n, err, full[:n], address)
	}
}

func TestRecoveryReadPumpDeadlineDoesNotStopRawRead(t *testing.T) {
	underlying := newMatrixPacketConn()
	pump := newRecoveryImpairmentReadPump(
		underlying, nil, publishRecoveryReadImmediately,
	)
	t.Cleanup(func() { _ = pump.Close() })
	if err := pump.SetReadDeadline(time.Now().Add(10 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	_, _, err := pump.ReadFrom(make([]byte, 16))
	var networkError net.Error
	if !errors.As(err, &networkError) || !networkError.Timeout() {
		t.Fatalf("deadline error = %T %v; want timeout", err, err)
	}
	if err := pump.SetReadDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}
	want := matrixPacketRead{
		payload: []byte{9, 8, 7}, source: matrixTestAddr("after-timeout"),
	}
	underlying.reads <- want
	buffer := make([]byte, 16)
	n, address, err := pump.ReadFrom(buffer)
	if err != nil || !reflect.DeepEqual(buffer[:n], want.payload) ||
		address.String() != want.source.String() {
		t.Fatalf("post-timeout read = %d, %v, %x, %v", n, err, buffer[:n], address)
	}
}

func TestRecoveryReadPumpCloseUnblocksRawAndConsumerReads(t *testing.T) {
	underlying := newMatrixPacketConn()
	pump := newRecoveryImpairmentReadPump(
		underlying, nil, publishRecoveryReadImmediately,
	)
	readResult := make(chan error, 1)
	go func() {
		_, _, err := pump.ReadFrom(make([]byte, 16))
		readResult <- err
	}()
	if err := pump.Close(); err != nil {
		t.Fatal(err)
	}
	if err := pump.Close(); err != nil {
		t.Fatalf("second close = %v", err)
	}
	select {
	case err := <-readResult:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("blocked consumer error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("close did not unblock consumer read")
	}
	select {
	case <-pump.done:
	default:
		t.Fatal("close returned before raw read pump terminated")
	}
}

func TestRecoveryReadPumpRejectsPublicationAfterClose(t *testing.T) {
	underlying := newMatrixPacketConn()
	pump := newRecoveryImpairmentReadPump(
		underlying, nil, publishRecoveryReadImmediately,
	)
	if err := pump.Close(); err != nil {
		t.Fatal(err)
	}
	_, err := pump.prepareDelivery(recoveryReadDatagram{
		payload: []byte{1}, source: matrixTestAddr("late"),
	})
	if !errors.Is(err, net.ErrClosed) {
		t.Fatalf("late publication error = %v; want net.ErrClosed", err)
	}
}
