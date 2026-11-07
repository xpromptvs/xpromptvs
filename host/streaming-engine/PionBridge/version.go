package main

/*
#include <stddef.h>
#include <stdint.h>
*/
import "C"

import (
	"unsafe"

	_ "github.com/pion/webrtc/v4"
)

const pionWebRTCVersion = "v4.2.15"

func versionString() string {
	return "pion-webrtc/" + pionWebRTCVersion
}

//export llv_pion_copy_version
func llv_pion_copy_version(output *C.char, capacity C.size_t) C.int32_t {
	value := append([]byte(versionString()), 0)
	if output == nil || uint64(capacity) < uint64(len(value)) {
		return -1
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(output)), len(value)), value)
	return 0
}

func main() {}
