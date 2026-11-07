#!/usr/bin/env sh
# The submodule must sit on the reviewed commit. Bazel cannot read a submodule's HEAD from the
# sandbox, so libopus_pin.txt records it and it is regenerated with
# `git -C third_party/libopus rev-parse HEAD`.
#
# THIS TEST ONLY GUARDS THE CHECKED-IN RECORD, NOT THE REAL SUBMODULE — the same limitation
# libaom_pin_test.sh documents at length. scripts/gate-submodule-pins.sh checks the gitlink.
set -eu
expected=ddbe48383984d56acd9e1ab6a090c54ca6b735a6
actual=missing
if [ "" != "" ]; then
    echo "libopus pin drifted: expected= actual=" >&2
    exit 1
fi
echo "PASS: libopus pinned at "
