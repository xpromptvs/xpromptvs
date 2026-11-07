#!/usr/bin/env sh
# The submodule must sit on the reviewed commit. Bazel cannot read a submodule's HEAD
# from the sandbox, so libaom_pin.txt records it and Task 4 Step 3 regenerates it from
# `git -C third_party/libaom rev-parse HEAD`.
#
# THIS TEST ONLY GUARDS THE CHECKED-IN RECORD, NOT THE REAL SUBMODULE. It compares this
# script's hardcoded `expected=` against libaom_pin.txt — both static text written by
# the same commit — so it can only fail if one is edited without the other. It never
# reads the actual submodule gitlink that @libaom_src builds from (Bazel's sandbox has
# no `git`, so it can't). scripts/gate-submodule-pins.sh is what checks THAT, via
# `git ls-tree HEAD third_party/libaom`; run it (wired into scripts/test-all.sh) to
# catch a gitlink bump that forgot to regenerate this file's pin.
set -eu
expected=03087864cf4bea6abb0d28f95cf7843511413d8f
actual=$(cat "$(dirname -- "$0")/libaom_pin.txt" 2>/dev/null || echo missing)
if [ "$actual" != "$expected" ]; then
    echo "libaom pin drifted: expected=$expected actual=$actual" >&2
    exit 1
fi
echo "PASS: libaom pinned at $expected"
