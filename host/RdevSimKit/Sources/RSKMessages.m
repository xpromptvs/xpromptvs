#import "RSKInternal.h"
#import <math.h>

NSString *const RSKDigitizerService = @"com.apple.coredevice.feature.remote.hid.digitizer";

// dtuhidd decodes these with Codable: numbers are UINT64 and points DOUBLE, never int64 — a wrongly typed field is
// dropped by the guest without a word.
static xpc_object_t envelope(const char *type, xpc_object_t payload, BOOL barrier) {
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "messageType", type);
    xpc_dictionary_set_bool(m, "isBarrier", barrier);
    xpc_dictionary_set_string(m, "featureIdentifier", RSKDigitizerService.UTF8String);
    xpc_dictionary_set_value(m, "payload", payload);
    return m;
}

static xpc_object_t point(CGPoint p) {
    xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_double(d, "x", p.x);
    xpc_dictionary_set_double(d, "y", p.y);
    return d;
}

xpc_object_t RSKDigitizerMessage(RSKTouchPhase phase, CGPoint one, BOOL hasTwo, CGPoint two) {
    xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(p, "pointOne", point(one));
    if (hasTwo) xpc_dictionary_set_value(p, "pointTwo", point(two));   // ABSENT for one contact, never zero
    xpc_dictionary_set_uint64(p, "eventType", phase);
    xpc_dictionary_set_uint64(p, "edge", 0);
    xpc_dictionary_set_uint64(p, "target", 0);
    return envelope("IndigoDigitizerEvent", p, NO);
}

xpc_object_t RSKKeyboardMessage(uint32_t usage, BOOL down, BOOL barrier) {
    xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(p, "usageCode", usage);
    xpc_dictionary_set_uint64(p, "state", down ? 1 : 2);
    return envelope("IndigoKeyboardButtonEvent", p, barrier);
}

xpc_object_t RSKButtonMessage(uint16_t page, uint16_t usage, BOOL down) {
    xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(p, "usagePage", page);
    xpc_dictionary_set_uint64(p, "usageCode", usage);
    xpc_dictionary_set_uint64(p, "state", down ? 1 : 2);
    return envelope("IndigoButtonEvent", p, NO);
}

static xpc_object_t scrollRequest(const char *name, xpc_object_t value) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, name, value);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "messageType", "Request");
    xpc_dictionary_set_bool(message, "isBarrier", NO);
    xpc_dictionary_set_value(message, "payload", payload);
    return message;
}

xpc_object_t RSKScrollReadyMessage(void) {
    return scrollRequest("connectedServices", xpc_dictionary_create(NULL, NULL, 0));
}

BOOL RSKScrollReplySupportsTouchscreen(xpc_object_t reply) {
    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) return NO;
    xpc_object_t services = xpc_dictionary_get_array(reply, "connectedServices");
    if (!services) return NO;
    for (size_t i = 0; i < xpc_array_get_count(services); i++) {
        xpc_object_t d = xpc_array_get_value(services, i);
        if (xpc_get_type(d) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_uint64(d, "_ServiceID") == 0x101 &&
            xpc_dictionary_get_uint64(d, "PrimaryUsagePage") == 13 && xpc_dictionary_get_uint64(d, "PrimaryUsage") == 4) return YES;
    }
    return NO;
}

xpc_object_t RSKScrollDigitizerMessage(RSKScrollTouchPhase phase, CGPoint point) {
    // dtuhidd/CoreDevice 651.13.5, DeviceServicesSupport.DigitizerReport. Full reports clear old flags. The first
    // contact begins at byte 3: index/resting/touch/range bits, then little-endian normalized UInt16 x/y.
    // contactCancel(atIndex:) reads bit 0x1c6 + index. Native UIKit phase=cancelled was measured, not inferred.
    uint8_t report[58] = {0};
    report[0] = 9; report[1] = phase == RSKScrollTouchPhaseClear ? 0 : 1; report[2] = 5;
    report[3] = phase == RSKScrollTouchPhaseContact ? 0xc0 : 0;
    if (phase == RSKScrollTouchPhaseCancel) report[454 / 8] |= 1 << (454 % 8);
    double x = isfinite(point.x) ? fmin(fmax(point.x, 0), 1) : 0;
    double y = isfinite(point.y) ? fmin(fmax(point.y, 0), 1) : 0;
    uint16_t px = (uint16_t)(x * UINT16_MAX), py = (uint16_t)(y * UINT16_MAX);
    report[4] = px & 0xff; report[5] = px >> 8; report[6] = py & 0xff; report[7] = py >> 8;
    xpc_object_t send = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_data(send, "_0", report, sizeof(report));
    xpc_dictionary_set_uint64(send, "_1", 0x101); // CoreDevice HIDServiceID.mainTouchscreen, verified by connectedServices
    return scrollRequest("send", send);
}
