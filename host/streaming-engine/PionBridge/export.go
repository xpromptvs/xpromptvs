package main

/*
#include "callback_trampolines.h"
*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"
	"unsafe"
)

func pionUptimeNanoseconds() uint64 {
	return uint64(C.llv_pion_uptime_nanoseconds())
}

const (
	exportStatusOK             = int32(0)
	exportStatusDropped        = int32(1)
	exportErrorInvalidArgument = int32(-1)
	exportErrorUnknownHandle   = int32(-2)
	exportErrorOperation       = int32(-3)
	exportErrorBufferTooSmall  = int32(-4)
	exportErrorPanic           = int32(-5)
)

var errUnknownSessionHandle = errors.New("unknown Pion session handle")

type exportedSession interface {
	SendVideo(OutboundFrame) error
	SendInput([]byte) (SendDisposition, error)
	SendControl([]byte) error
	Stats() SessionStats
	ActivateImpairment() error
	ResetImpairmentMeasurement() error
	DrainImpairment() error
	Close() error
}

type sessionRegistry struct {
	mutex    sync.Mutex
	next     uint64
	sessions map[uint64]exportedSession
	closed   map[uint64][]byte
}

func newSessionRegistry() *sessionRegistry {
	return &sessionRegistry{
		next: 1, sessions: make(map[uint64]exportedSession), closed: make(map[uint64][]byte),
	}
}

func (registry *sessionRegistry) add(session exportedSession) (uint64, error) {
	if session == nil {
		return 0, fmt.Errorf("%w: nil session", errSession)
	}
	registry.mutex.Lock()
	defer registry.mutex.Unlock()
	handle := registry.next
	if handle == 0 {
		return 0, fmt.Errorf("%w: session handle overflow", errSession)
	}
	registry.next++
	registry.sessions[handle] = session
	return handle, nil
}

func (registry *sessionRegistry) get(handle uint64) (exportedSession, error) {
	registry.mutex.Lock()
	defer registry.mutex.Unlock()
	session, exists := registry.sessions[handle]
	if !exists {
		return nil, fmt.Errorf("%w: %d", errUnknownSessionHandle, handle)
	}
	return session, nil
}

func (registry *sessionRegistry) close(handle uint64) error {
	registry.mutex.Lock()
	if _, alreadyClosed := registry.closed[handle]; alreadyClosed {
		registry.mutex.Unlock()
		return nil
	}
	session, exists := registry.sessions[handle]
	if !exists {
		registry.mutex.Unlock()
		return fmt.Errorf("%w: %d", errUnknownSessionHandle, handle)
	}
	delete(registry.sessions, handle)
	registry.closed[handle] = nil
	registry.mutex.Unlock()
	closeErr := session.Close()
	stats, statsErr := json.Marshal(session.Stats())
	registry.mutex.Lock()
	registry.closed[handle] = stats
	registry.mutex.Unlock()
	return errors.Join(closeErr, statsErr)
}

func sendRegistryInput(
	registry *sessionRegistry,
	handle uint64,
	data []byte,
) (SendDisposition, error) {
	session, err := registry.get(handle)
	if err != nil {
		return SendDispositionDropped, err
	}
	return session.SendInput(append([]byte(nil), data...))
}

func copyRegistryStats(registry *sessionRegistry, handle uint64) ([]byte, error) {
	session, err := registry.get(handle)
	if err == nil {
		return json.Marshal(session.Stats())
	}
	registry.mutex.Lock()
	stats, closed := registry.closed[handle]
	registry.mutex.Unlock()
	if !closed || stats == nil {
		return nil, err
	}
	return append([]byte(nil), stats...), nil
}

var processSessions = newSessionRegistry()

type abiCallbacks struct {
	context    C.uint64_t
	state      C.llv_pion_state_callback
	message    C.llv_pion_message_callback
	fatal      C.llv_pion_error_callback
	recovery   C.llv_pion_recovery_keyframe_callback
	impairment C.llv_pion_impairment_nack_callback
	policy     C.llv_pion_recovery_policy_callback
}

//export llv_pion_activate_impairment
func llv_pion_activate_impairment(handle C.uint64_t) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	if handle == 0 {
		return C.int32_t(exportErrorInvalidArgument)
	}
	session, err := processSessions.get(uint64(handle))
	if err != nil {
		return statusForExportError(err)
	}
	if err := session.ActivateImpairment(); err != nil {
		return C.int32_t(exportErrorOperation)
	}
	return C.int32_t(exportStatusOK)
}

//export llv_pion_reset_impairment_measurement
func llv_pion_reset_impairment_measurement(handle C.uint64_t) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	if handle == 0 {
		return C.int32_t(exportErrorInvalidArgument)
	}
	session, err := processSessions.get(uint64(handle))
	if err != nil {
		return statusForExportError(err)
	}
	if err := session.ResetImpairmentMeasurement(); err != nil {
		return C.int32_t(exportErrorOperation)
	}
	return C.int32_t(exportStatusOK)
}

//export llv_pion_drain_impairment
func llv_pion_drain_impairment(handle C.uint64_t) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	if handle == 0 {
		return C.int32_t(exportErrorInvalidArgument)
	}
	session, err := processSessions.get(uint64(handle))
	if err != nil {
		return statusForExportError(err)
	}
	if err := session.DrainImpairment(); err != nil {
		return C.int32_t(exportErrorOperation)
	}
	return C.int32_t(exportStatusOK)
}

//export llv_pion_host_create
func llv_pion_host_create(
	configuration *C.llv_pion_session_configuration,
	output *C.uint64_t,
) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	parsed, callbacks, err := parseABIConfiguration(configuration)
	if err != nil || output == nil {
		return C.int32_t(exportErrorInvalidArgument)
	}
	session, err := newHostSession(parsed, callbacks.sessionCallbacks())
	if err != nil {
		callbacks.callError(err)
		return C.int32_t(exportErrorOperation)
	}
	handle, err := processSessions.add(session)
	if err != nil {
		_ = session.Close()
		callbacks.callError(err)
		return C.int32_t(exportErrorOperation)
	}
	*output = C.uint64_t(handle)
	return C.int32_t(exportStatusOK)
}

//export llv_pion_send_video
func llv_pion_send_video(
	handle C.uint64_t,
	frame *C.llv_pion_outbound_frame,
) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	if frame == nil || frame.bytes == nil || frame.byte_count == 0 ||
		uint64(frame.byte_count) > uint64(maximumGoSliceBytes()) || frame.is_keyframe > 1 {
		return C.int32_t(exportErrorInvalidArgument)
	}
	for _, reserved := range frame.reserved {
		if reserved != 0 {
			return C.int32_t(exportErrorInvalidArgument)
		}
	}
	dependency, err := parseABIFrameDependency(
		uint8(frame.scalability_mode),
		uint8(frame.temporal_id),
		uint8(frame.template_id),
		frame.is_keyframe != 0,
	)
	if err != nil {
		return C.int32_t(exportErrorInvalidArgument)
	}
	session, err := processSessions.get(uint64(handle))
	if err != nil {
		return statusForExportError(err)
	}
	data := append([]byte(nil), unsafe.Slice((*byte)(unsafe.Pointer(frame.bytes)), int(frame.byte_count))...)
	err = session.SendVideo(OutboundFrame{
		StreamID: uint64(frame.stream_id), FrameID: uint64(frame.frame_id),
		InputSequence:       uint64(frame.input_sequence),
		HostProcessingNanos: uint64(frame.host_processing_nanoseconds),
		EncodeNanos:         uint64(frame.encode_nanoseconds),
		Keyframe:            frame.is_keyframe != 0,
		Dependency:          dependency,
		Data:                data,
	})
	if err != nil {
		return C.int32_t(exportErrorOperation)
	}
	return C.int32_t(exportStatusOK)
}

func parseABIFrameDependency(
	mode uint8,
	temporalID uint8,
	templateID uint8,
	keyframe bool,
) (AV1Dependency, error) {
	dependency := AV1Dependency{
		Mode: AV1ScalabilityMode(mode), TemporalID: temporalID, TemplateID: templateID,
	}
	if err := dependency.Validate(keyframe); err != nil {
		return AV1Dependency{}, err
	}
	return dependency, nil
}

//export llv_pion_send_input
func llv_pion_send_input(
	handle C.uint64_t,
	bytes *C.uint8_t,
	byteCount C.size_t,
) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	data, err := copyABIBytes(bytes, byteCount)
	if err != nil {
		return C.int32_t(exportErrorInvalidArgument)
	}
	disposition, err := sendRegistryInput(processSessions, uint64(handle), data)
	if err != nil {
		return statusForExportError(err)
	}
	if disposition == SendDispositionDropped {
		return C.int32_t(exportStatusDropped)
	}
	return C.int32_t(exportStatusOK)
}

//export llv_pion_send_control
func llv_pion_send_control(
	handle C.uint64_t,
	bytes *C.uint8_t,
	byteCount C.size_t,
) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	data, err := copyABIBytes(bytes, byteCount)
	if err != nil {
		return C.int32_t(exportErrorInvalidArgument)
	}
	session, err := processSessions.get(uint64(handle))
	if err != nil {
		return statusForExportError(err)
	}
	if err := session.SendControl(data); err != nil {
		return C.int32_t(exportErrorOperation)
	}
	return C.int32_t(exportStatusOK)
}

//export llv_pion_copy_stats
func llv_pion_copy_stats(
	handle C.uint64_t,
	output *C.char,
	capacity C.size_t,
	required *C.size_t,
) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	if required == nil {
		return C.int32_t(exportErrorInvalidArgument)
	}
	data, err := copyRegistryStats(processSessions, uint64(handle))
	if err != nil {
		return statusForExportError(err)
	}
	*required = C.size_t(len(data))
	if output == nil || uint64(capacity) < uint64(len(data)) {
		return C.int32_t(exportErrorBufferTooSmall)
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(output)), len(data)), data)
	return C.int32_t(exportStatusOK)
}

//export llv_pion_close
func llv_pion_close(handle C.uint64_t) (status C.int32_t) {
	status = C.int32_t(exportErrorOperation)
	defer recoverExport(&status)
	if handle == 0 {
		return C.int32_t(exportErrorInvalidArgument)
	}
	if err := processSessions.close(uint64(handle)); err != nil {
		return statusForExportError(err)
	}
	return C.int32_t(exportStatusOK)
}

func parseABIConfiguration(
	configuration *C.llv_pion_session_configuration,
) (SessionConfiguration, abiCallbacks, error) {
	if configuration == nil || configuration.local_ip == nil {
		return SessionConfiguration{}, abiCallbacks{}, fmt.Errorf("invalid C session configuration")
	}
	recovery, rtxMaxAge, err := parseABIRecovery(
		uint8(configuration.recovery_mode),
		uint16(configuration.rtx_max_age_milliseconds),
	)
	if err != nil {
		return SessionConfiguration{}, abiCallbacks{}, err
	}
	rtxAgePolicy, err := parseABIRTXAgePolicy(
		uint8(configuration.rtx_age_mode),
		uint16(configuration.rtx_max_age_milliseconds),
		uint16(configuration.rtx_age_multiplier_milli),
		uint16(configuration.rtx_age_cap_milliseconds),
	)
	if err != nil {
		return SessionConfiguration{}, abiCallbacks{}, err
	}
	flexFECPolicy := FlexFECPolicyOff
	var scalabilityMode AV1ScalabilityMode
	var totalRTPBudgetBitsPerSecond uint32
	var framesPerSecond uint32
	var controllerPolicyData []byte
	if recovery == RecoveryNACKRTXFlexFEC {
		flexFECPolicy, err = parseABIFlexFECPolicy(uint8(configuration.flexfec_policy))
		if err != nil {
			return SessionConfiguration{}, abiCallbacks{}, err
		}
		scalabilityMode = AV1ScalabilityMode(configuration.scalability_mode)
		if scalabilityMode < AV1ScalabilityL1T1 || scalabilityMode > AV1ScalabilityL1T3 {
			return SessionConfiguration{}, abiCallbacks{}, fmt.Errorf("invalid C FlexFEC scalability mode")
		}
		totalRTPBudgetBitsPerSecond = uint32(configuration.total_rtp_budget_bits_per_second)
		framesPerSecond = uint32(configuration.frames_per_second)
		if totalRTPBudgetBitsPerSecond == 0 || framesPerSecond == 0 || framesPerSecond > 1_000 ||
			configuration.recovery_policy_callback == nil {
			return SessionConfiguration{}, abiCallbacks{}, fmt.Errorf("incomplete C FlexFEC configuration")
		}
		controllerPolicyData, err = copyABIOptionalBytes(
			configuration.flexfec_controller_policy_json,
			configuration.flexfec_controller_policy_json_byte_count,
		)
		if err != nil {
			return SessionConfiguration{}, abiCallbacks{}, err
		}
		if len(controllerPolicyData) > 0 && flexFECPolicy != FlexFECPolicyAdaptive {
			return SessionConfiguration{}, abiCallbacks{}, fmt.Errorf(
				"FlexFEC controller policy override requires adaptive policy",
			)
		}
	} else if configuration.flexfec_policy != 0 || configuration.scalability_mode != 0 ||
		configuration.frames_per_second != 0 ||
		configuration.total_rtp_budget_bits_per_second != 0 ||
		configuration.recovery_policy_callback != nil ||
		configuration.flexfec_controller_policy_json != nil ||
		configuration.flexfec_controller_policy_json_byte_count != 0 {
		return SessionConfiguration{}, abiCallbacks{}, fmt.Errorf(
			"FlexFEC fields require NACK/RTX/FlexFEC recovery",
		)
	}
	diagnosticRecoveryTrace, err := parseABIDiagnosticRecoveryTrace(
		uint8(configuration.diagnostic_recovery_trace),
	)
	if err != nil {
		return SessionConfiguration{}, abiCallbacks{}, err
	}
	localIP := net.ParseIP(C.GoString(configuration.local_ip))
	profileData, err := copyABIOptionalBytes(
		configuration.impairment_profile_json,
		configuration.impairment_profile_json_byte_count,
	)
	if err != nil {
		return SessionConfiguration{}, abiCallbacks{}, err
	}
	var impairment *RecoveryImpairmentConfiguration
	if len(profileData) > 0 {
		impairment, err = parseRecoveryImpairment(
			profileData, int64(configuration.impairment_seed),
		)
		if err != nil {
			return SessionConfiguration{}, abiCallbacks{}, err
		}
	} else if configuration.impairment_seed != 0 {
		return SessionConfiguration{}, abiCallbacks{}, fmt.Errorf("impairment seed has no profile")
	}
	var remoteIP net.IP
	if configuration.remote_ip != nil {
		remoteIP = net.ParseIP(C.GoString(configuration.remote_ip))
	}
	parsed := SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   localIP, RemoteIP: remoteIP,
		SignalPort: uint16(configuration.signal_port), ICEPort: uint16(configuration.ice_port),
		Recovery: recovery, RTXMaxAge: rtxMaxAge,
		RTXAgeMode:            rtxAgePolicy.Mode,
		RTXAgeMultiplierMilli: rtxAgePolicy.MultiplierMilli,
		RTXAgeCap:             rtxAgePolicy.Cap,
		FlexFECPolicy:         flexFECPolicy, ScalabilityMode: scalabilityMode,
		TotalRTPBudgetBitsPerSecond: totalRTPBudgetBitsPerSecond,
		FramesPerSecond:             framesPerSecond,
		FlexFECControllerPolicyJSON: append([]byte(nil), controllerPolicyData...),
		Impairment:                  impairment, DiagnosticRecoveryTrace: diagnosticRecoveryTrace,
	}
	if err := validateSessionConfiguration(parsed); err != nil {
		return SessionConfiguration{}, abiCallbacks{}, err
	}
	callbacks := abiCallbacks{
		context: configuration.callback_context,
		state:   configuration.state_callback,
		message: configuration.message_callback, fatal: configuration.error_callback,
		recovery:   configuration.recovery_keyframe_callback,
		impairment: configuration.impairment_nack_callback,
		policy:     configuration.recovery_policy_callback,
	}
	return parsed, callbacks, nil
}

func parseRecoveryImpairment(
	data []byte,
	seed int64,
) (*RecoveryImpairmentConfiguration, error) {
	profile, err := parseRecoveryMatrixProfileWithSeed(data, &seed)
	if err != nil {
		return nil, err
	}
	return &RecoveryImpairmentConfiguration{Profile: profile, Seed: seed}, nil
}

func parseABIRecovery(
	mode uint8,
	ageMilliseconds uint16,
) (RecoveryMode, time.Duration, error) {
	recovery := RecoveryMode(mode)
	if (recovery != RecoveryNACKRTX && recovery != RecoveryOff &&
		recovery != RecoveryNACKRTXFlexFEC) ||
		ageMilliseconds < 1 || ageMilliseconds > 1_000 {
		return 0, 0, fmt.Errorf("invalid C recovery configuration")
	}
	return recovery, time.Duration(ageMilliseconds) * time.Millisecond, nil
}

func parseABIRTXAgePolicy(
	mode uint8,
	floorMilliseconds uint16,
	multiplierMilli uint16,
	capMilliseconds uint16,
) (RTXAgePolicyConfig, error) {
	if mode == 0 && multiplierMilli == 0 && capMilliseconds == 0 {
		mode = uint8(RTXAgeFixed)
	}
	config := RTXAgePolicyConfig{
		Mode:            RTXAgeMode(mode),
		Floor:           time.Duration(floorMilliseconds) * time.Millisecond,
		Cap:             time.Duration(capMilliseconds) * time.Millisecond,
		MultiplierMilli: uint32(multiplierMilli),
	}
	if config.Mode == RTXAgeFixed {
		if multiplierMilli != 0 || capMilliseconds != 0 {
			return RTXAgePolicyConfig{}, fmt.Errorf("fixed RTX age has RTT fields")
		}
		config.Cap = config.Floor
		config.MultiplierMilli = 1_000
	}
	mediaRTT := (*mediaRTTEstimator)(nil)
	if config.Mode == RTXAgeRTT {
		mediaRTT = &mediaRTTEstimator{}
	}
	if _, err := NewRTXAgePolicy(config, mediaRTT); err != nil {
		return RTXAgePolicyConfig{}, fmt.Errorf("invalid C RTX age policy: %w", err)
	}
	return config, nil
}

func parseABIFlexFECPolicy(value uint8) (FlexFECPolicy, error) {
	policy := FlexFECPolicy(value)
	if policy < FlexFECPolicyAdaptive || policy > FlexFECPolicyHigh {
		return 0, fmt.Errorf("invalid C FlexFEC policy")
	}
	return policy, nil
}

func parseABIDiagnosticRecoveryTrace(value uint8) (bool, error) {
	switch value {
	case 0:
		return false, nil
	case 1:
		return true, nil
	default:
		return false, fmt.Errorf("invalid C diagnostic recovery trace configuration")
	}
}

func (callbacks abiCallbacks) sessionCallbacks() SessionCallbacks {
	return SessionCallbacks{
		OnState:            callbacks.callState,
		OnMessage:          callbacks.callMessage,
		OnError:            callbacks.callError,
		OnRecoveryKeyframe: callbacks.callRecoveryKeyframe,
		OnImpairmentNACK:   callbacks.callImpairmentNACK,
		OnRecoveryPolicy:   callbacks.callRecoveryPolicy,
	}
}

func (callbacks abiCallbacks) callState(data []byte) {
	C.llv_pion_call_state(callbacks.state, callbacks.context, abiDataPointer(data), C.size_t(len(data)))
}

func (callbacks abiCallbacks) callMessage(channel ChannelKind, data []byte) {
	C.llv_pion_call_message(
		callbacks.message, callbacks.context, C.uint8_t(channel),
		abiDataPointer(data), C.size_t(len(data)),
	)
}

func (callbacks abiCallbacks) callError(err error) {
	if err == nil {
		return
	}
	data := []byte(err.Error())
	C.llv_pion_call_error(callbacks.fatal, callbacks.context, abiDataPointer(data), C.size_t(len(data)))
}

func (callbacks abiCallbacks) callRecoveryKeyframe(streamID uint64) {
	C.llv_pion_call_recovery_keyframe(
		callbacks.recovery, callbacks.context, C.uint64_t(streamID),
	)
}

func (callbacks abiCallbacks) callImpairmentNACK() {
	C.llv_pion_call_impairment_nack(
		callbacks.impairment, callbacks.context,
	)
}

func (callbacks abiCallbacks) callRecoveryPolicy(update RecoveryPolicyUpdate) error {
	if update.Sequence == 0 || update.Tier > FlexFECTierHigh ||
		update.MediaBitrateBitsPerSecond == 0 {
		return fmt.Errorf("invalid recovery policy update")
	}
	status := C.llv_pion_call_recovery_policy(
		callbacks.policy, callbacks.context, C.uint64_t(update.Sequence),
		C.uint8_t(update.Tier), C.uint32_t(update.MediaBitrateBitsPerSecond),
	)
	if status != 0 {
		return fmt.Errorf("recovery policy callback failed: %d", int32(status))
	}
	return nil
}

func abiDataPointer(data []byte) *C.uint8_t {
	if len(data) == 0 {
		return nil
	}
	return (*C.uint8_t)(unsafe.Pointer(&data[0]))
}

func copyABIBytes(bytes *C.uint8_t, byteCount C.size_t) ([]byte, error) {
	if bytes == nil || byteCount == 0 || uint64(byteCount) > uint64(maximumGoSliceBytes()) {
		return nil, fmt.Errorf("invalid C byte buffer")
	}
	return append([]byte(nil), unsafe.Slice((*byte)(unsafe.Pointer(bytes)), int(byteCount))...), nil
}

func copyABIOptionalBytes(bytes *C.uint8_t, byteCount C.size_t) ([]byte, error) {
	if bytes == nil && byteCount == 0 {
		return nil, nil
	}
	return copyABIBytes(bytes, byteCount)
}

func maximumGoSliceBytes() int {
	return int(^uint(0) >> 1)
}

func statusForExportError(err error) C.int32_t {
	if errors.Is(err, errUnknownSessionHandle) {
		return C.int32_t(exportErrorUnknownHandle)
	}
	return C.int32_t(exportErrorOperation)
}

func recoverExport(status *C.int32_t) {
	if recover() != nil {
		*status = C.int32_t(exportErrorPanic)
	}
}
