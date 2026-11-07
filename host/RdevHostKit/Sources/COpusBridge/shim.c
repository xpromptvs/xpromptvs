/* The module's only translation unit. The ctl wrappers in copus_bridge.h are `static inline`, so
 * this file exists for the same reason CPionBridge/shim.c does: a cc_library needs a source, and
 * every real symbol comes from libopus.a at link time. */
#include "copus_bridge.h"
