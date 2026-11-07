package main

// The rdev OFFER path's recovery-impairment knob: the environment it reads, every way it refuses,
// and the one arithmetic boundary in arming it.
//
// WHY THESE TESTS AND NOT A LIVE SESSION. Everything downstream of `SessionConfiguration.Impairment`
// is `createSession`'s and is SHARED with the answering path stock `llv capture-host` drives — the
// controller construction, `wrapHostPacketConn`, `ResolveRecovery` — and that path already has its
// own suites. What is NEW here is exactly two things: turning an environment into that field, and
// deciding which video write arms the controller. Both are covered below; neither needs a peer
// connection, and asserting them through one would test the shared half over again while leaving the
// new half's boundaries untested.
//
// THE REFUSALS MATTER MORE THAN THE HAPPY PATH, which is why there are more of them. A profile that
// was asked for and silently not applied produces a run that streams, decodes and reports a complete
// latency distribution — of an unimpaired network, under an impaired name. That is not a
// hypothetical shape in this repo; it is the most-repeated one.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// rdevImpairmentEnvironment sets the two variables for one test and restores them afterwards.
//
// `t.Setenv` REFUSES TO RUN IN A PARALLEL TEST, which is what makes it the right tool here rather
// than a hazard: `rdevConfiguredImpairment` reads process-global state, so a parallel test that set
// it would be racing every other test in the package that constructs a session.
func rdevImpairmentEnvironment(t *testing.T, profile string, seed string) {
	t.Helper()
	t.Setenv(rdevImpairmentProfileVariable, profile)
	t.Setenv(rdevImpairmentSeedVariable, seed)
}

// rdevWriteOneProfile extracts ONE named profile from the catalogue and writes it to a temporary
// file, which is exactly what scripts/gate-input-to-decode.sh hands the host.
func rdevWriteOneProfile(t *testing.T, name string, mutate func(map[string]any)) string {
	t.Helper()
	data, err := os.ReadFile("testdata/recovery_impairment_profiles.json")
	if err != nil {
		t.Fatalf("reading the catalogue: %v", err)
	}
	var catalogue struct {
		Profiles []map[string]any `json:"profiles"`
	}
	if err := json.Unmarshal(data, &catalogue); err != nil {
		t.Fatalf("parsing the catalogue: %v", err)
	}
	for _, profile := range catalogue.Profiles {
		if profile["name"] != name {
			continue
		}
		if mutate != nil {
			mutate(profile)
		}
		encoded, err := json.Marshal(profile)
		if err != nil {
			t.Fatalf("re-encoding %q: %v", name, err)
		}
		path := filepath.Join(t.TempDir(), name+".json")
		if err := os.WriteFile(path, encoded, 0o600); err != nil {
			t.Fatalf("writing %q: %v", path, err)
		}
		return path
	}
	t.Fatalf("no profile named %q in the catalogue", name)
	return ""
}

func TestRdevImpairmentUnsetConfiguresNothing(t *testing.T) {
	rdevImpairmentEnvironment(t, "", "")
	configuration, err := rdevConfiguredImpairment()
	if err != nil {
		t.Fatalf("an unset environment must not be an error, got %v", err)
	}
	if configuration != nil {
		t.Fatalf("an unset environment configured an impairment: %+v", configuration)
	}
}

// THE PRODUCT PATH, ASSERTED AS SUCH. Every rdev host that is not this gate runs with both variables
// unset, so `Impairment` staying nil is the claim that this change is inert outside the measurement.
func TestRdevSessionConfigurationLeavesImpairmentNilWhenUnset(t *testing.T) {
	rdevImpairmentEnvironment(t, "", "")
	t.Setenv("RDEV_LLV_LOCAL_IP", "192.0.2.10")
	t.Setenv("RDEV_LLV_REMOTE_IP", "192.0.2.11")
	configuration, err := rdevSessionConfiguration("", 20_000_000)
	if err != nil {
		t.Fatalf("rdevSessionConfiguration: %v", err)
	}
	if configuration.Impairment != nil {
		t.Fatalf("expected no impairment, got %+v", configuration.Impairment)
	}
}

func TestRdevSessionConfigurationCarriesTheProfileAndSeed(t *testing.T) {
	path := rdevWriteOneProfile(t, "congested-wifi-seed-1741", nil)
	rdevImpairmentEnvironment(t, path, "8191")
	t.Setenv("RDEV_LLV_LOCAL_IP", "192.0.2.10")
	t.Setenv("RDEV_LLV_REMOTE_IP", "192.0.2.11")
	configuration, err := rdevSessionConfiguration("", 20_000_000)
	if err != nil {
		t.Fatalf("rdevSessionConfiguration: %v", err)
	}
	if configuration.Impairment == nil {
		t.Fatal("the profile did not reach SessionConfiguration.Impairment")
	}
	if got := configuration.Impairment.Profile.Name; got != "congested-wifi-seed-1741" {
		t.Fatalf("profile name %q", got)
	}
	// THE SEED OVERRIDE IS THE POINT OF ASSERTING IT. The catalogue member carries seed 1741 in its
	// own JSON; the environment asked for 8191, and the seeded profiles differ in nothing else — so
	// a seed that was read and discarded would run a different loss pattern under an unchanged name.
	if got := configuration.Impairment.Seed; got != 8191 {
		t.Fatalf("seed %d, want the environment's 8191 rather than the profile's own", got)
	}
	// Carried so that newRdevPeer can wait the profile's own warm-up rather than a constant.
	if got := configuration.Impairment.Profile.WarmupFrames; got != 30 {
		t.Fatalf("warmupFrames %d, want the catalogue's 30", got)
	}
}

func TestRdevImpairmentRefusesASeedWithNoProfile(t *testing.T) {
	rdevImpairmentEnvironment(t, "", "1741")
	_, err := rdevConfiguredImpairment()
	if err == nil {
		t.Fatal("a seed with no profile must be refused")
	}
	if !strings.Contains(err.Error(), rdevImpairmentProfileVariable) {
		t.Fatalf("the error must name the missing variable, got %v", err)
	}
}

// THE MIRROR-IMAGE REFUSAL, AND THE ONE WITH THE QUIETEST FAILURE. A missing seed would otherwise
// default, and a defaulted seed runs a DIFFERENT loss pattern from the comparison arm's while both
// runs are labelled with the same profile name — a difference between the arms that is entirely the
// harness's.
func TestRdevImpairmentRefusesAProfileWithNoSeed(t *testing.T) {
	path := rdevWriteOneProfile(t, "clean", nil)
	rdevImpairmentEnvironment(t, path, "")
	_, err := rdevConfiguredImpairment()
	if err == nil {
		t.Fatal("a profile with no seed must be refused")
	}
	if !strings.Contains(err.Error(), rdevImpairmentSeedVariable) {
		t.Fatalf("the error must name the missing variable, got %v", err)
	}
}

func TestRdevImpairmentRefusesANonIntegerSeed(t *testing.T) {
	path := rdevWriteOneProfile(t, "clean", nil)
	rdevImpairmentEnvironment(t, path, "seventeen")
	if _, err := rdevConfiguredImpairment(); err == nil {
		t.Fatal("a non-integer seed must be refused")
	}
}

func TestRdevImpairmentRefusesAnUnreadableProfile(t *testing.T) {
	rdevImpairmentEnvironment(t, filepath.Join(t.TempDir(), "absent.json"), "1741")
	if _, err := rdevConfiguredImpairment(); err == nil {
		t.Fatal("an unreadable profile path must be refused")
	}
}

// THE CATALOGUE IS NOT ONE PROFILE, and handing it over whole is the likeliest operator mistake:
// `--impairment-profile` on the stock arm takes a single object too, and the file that holds all 101
// is the one whose path is easiest to reach for.
func TestRdevImpairmentRefusesTheWholeCatalogue(t *testing.T) {
	rdevImpairmentEnvironment(t, "testdata/recovery_impairment_profiles.json", "1741")
	if _, err := rdevConfiguredImpairment(); err == nil {
		t.Fatal("the whole catalogue must be refused: it is not one profile object")
	}
}

// warmupFrames = 0 IS ACCEPTED BY validateRecoveryMatrixProfile AND IS A SILENTLY DEAD IMPAIRMENT.
// The controller learns which stream carries the original media from a passthrough packet seen while
// inactive; with no warm-up there is no such packet, every datagram is then classified `other`, and
// the run reports a live controller with thousands of decisions and zero drops.
func TestRdevImpairmentRefusesAZeroWarmup(t *testing.T) {
	path := rdevWriteOneProfile(t, "clean", func(profile map[string]any) {
		profile["warmupFrames"] = 0
	})
	rdevImpairmentEnvironment(t, path, "1741")
	_, err := rdevConfiguredImpairment()
	if err == nil {
		t.Fatal("warmupFrames=0 must be refused")
	}
	if !strings.Contains(err.Error(), "warmupFrames") {
		t.Fatalf("the error must name warmupFrames, got %v", err)
	}
}

// ── Arming ───────────────────────────────────────────────────────────────────────────────────

// THE OFF-BY-ONE IS THE WHOLE RISK ON THIS AXIS, and it is invisible in every counter: arming one
// frame early gives the controller one fewer passthrough packet than the profile asked for, and the
// run still reports a live controller with plausible drops.
func TestRdevArmsOnTheWriteAfterTheWarmup(t *testing.T) {
	peer := &rdevPeer{impairmentWarmupFrames: 3}
	var armedOn []uint64
	for i := 1; i <= 6; i++ {
		arm, writes := peer.nextVideoWriteAction()
		if writes != uint64(i) {
			t.Fatalf("write %d counted as %d", i, writes)
		}
		if arm {
			armedOn = append(armedOn, writes)
			// noteVideoWrite only sets this on a SUCCESSFUL ActivateImpairment, which is what makes
			// the retry happen at all; setting it here is standing in for that success.
			peer.impairmentMutex.Lock()
			peer.impairmentArmed = true
			peer.impairmentMutex.Unlock()
		}
	}
	if len(armedOn) != 1 || armedOn[0] != 4 {
		t.Fatalf("armed on writes %v, want exactly [4] — the write AFTER the 3 warm-up frames", armedOn)
	}
}

// A FAILED ARMING MUST BE RETRIED, because `Session.ActivateImpairment` refuses a session that is
// not ready and readiness is not ordered against the first video write. A single attempt would leave
// the run unimpaired on a timing difference.
func TestRdevKeepsAskingToArmUntilItSucceeds(t *testing.T) {
	peer := &rdevPeer{impairmentWarmupFrames: 1}
	attempts := 0
	for i := 1; i <= 5; i++ {
		if arm, _ := peer.nextVideoWriteAction(); arm {
			attempts++
		}
	}
	if attempts != 4 {
		t.Fatalf("asked to arm %d times over 5 writes, want 4 — every write after the warm-up, "+
			"since nothing set impairmentArmed", attempts)
	}
}

func TestRdevCountsNothingWithoutAProfile(t *testing.T) {
	peer := &rdevPeer{}
	for i := 0; i < 3; i++ {
		arm, writes := peer.nextVideoWriteAction()
		if arm || writes != 0 {
			t.Fatalf("an unimpaired peer produced arm=%v writes=%d", arm, writes)
		}
	}
}

// THE REPORTER'S LIFECYCLE IS ONE DECISION, AND THIS IS THE MUTATION-SENSITIVE HALF OF IT.
//
// AN EARLIER VERSION OF THIS TEST WAS A TAUTOLOGY AND IS RECORDED AS ONE, because that is exactly the
// failure this branch has produced sixteen times: it asserted `rdevSessionConfiguration("", 20_000_000)` carried no
// impairment when the environment was empty (already covered by
// TestRdevSessionConfigurationLeavesImpairmentNilWhenUnset) and then that a freshly-declared
// `&rdevPeer{}` had nil channels — which is Go's zero value, true of any struct, and breakable by no
// change to this package.
//
// What is asserted instead are two invariants with real failure modes, split apart when the FlexFEC
// report joined the impairment one: `configureImpairment` reads the warm-up from the PROFILE, and
// `configureReporting` creates BOTH reporter channels.
func TestRdevConfigureImpairmentReadsTheWarmupFromTheProfile(t *testing.T) {
	peer := &rdevPeer{}
	peer.configureImpairment(nil)
	if peer.impairmentWarmupFrames != 0 {
		t.Fatalf("an unconfigured peer got warmup=%d", peer.impairmentWarmupFrames)
	}

	// 7, NOT THE CATALOGUE'S 30. Asserting 30 could not distinguish "read from the profile" from
	// "hard-coded to the value every catalogue profile happens to carry" — all 101 specify 30, so
	// the constant and the field are indistinguishable at that value. The helper already takes a
	// mutator; using it is what makes this an assertion about where the number CAME FROM.
	path := rdevWriteOneProfile(t, "clean", func(profile map[string]any) {
		profile["warmupFrames"] = 7
	})
	rdevImpairmentEnvironment(t, path, "1741")
	configuration, err := rdevConfiguredImpairment()
	if err != nil {
		t.Fatalf("rdevConfiguredImpairment: %v", err)
	}
	configured := &rdevPeer{}
	configured.configureImpairment(configuration)
	// The warm-up comes from the PROFILE, not a constant — the same value newRdevPeer prints and
	// nextVideoWriteAction counts against. See the mutator above for why this is 7.
	if configured.impairmentWarmupFrames != 7 {
		t.Fatalf("warmupFrames %d, want the profile's 7", configured.impairmentWarmupFrames)
	}
}

// BOTH CHANNELS OR NEITHER. One without the other is not cosmetic — a nil `reporterDone` panics the
// reporter on its own `defer close(...)`, and a nil `reporterStop` makes its `select` wait on a
// channel nothing can close, so `close()` then waits on the reporter forever. Deleting either
// `make(chan struct{})` fails this test.
//
// UNCONDITIONAL SINCE THE FEC REPORT JOINED THE IMPAIRMENT ONE: these used to be created only when an
// impairment profile was configured, which is every rdev host except the certification arm, and
// `[bridge] fec:` has to run everywhere.
//
// WHAT THIS CANNOT SEE is the CALL: `newRdevPeer` is what invokes configureReporting, and
// constructing a real peer needs a UDP bind. Dropping that one line would silently remove the FEC
// report from every host, and no unit test in this package can catch it.
func TestRdevConfigureReportingCreatesBothChannels(t *testing.T) {
	peer := &rdevPeer{}
	if peer.reporterRunning() {
		t.Fatal("a peer that has not been configured must have no reporter to run")
	}
	peer.configureReporting()
	if peer.reporterStop == nil {
		t.Fatal("no reporterStop: the reporter's select would wait on a channel nothing can close")
	}
	if peer.reporterDone == nil {
		t.Fatal("no reporterDone: the reporter would panic on its own `defer close(nil)`")
	}
	if !peer.reporterRunning() {
		t.Fatal("a configured peer must report")
	}
}

// reporterRunning MUST REJECT A HALF-BUILT LIFECYCLE, which is what makes it safe as the single
// guard at both the goroutine start and the close-time stop. Neither half alone is usable.
func TestRdevReporterRunningRejectsAHalfBuiltLifecycle(t *testing.T) {
	stopOnly := &rdevPeer{reporterStop: make(chan struct{})}
	if stopOnly.reporterRunning() {
		t.Fatal("a peer with only reporterStop must not report — the reporter would panic on " +
			"`defer close(nil)`")
	}
	doneOnly := &rdevPeer{reporterDone: make(chan struct{})}
	if doneOnly.reporterRunning() {
		t.Fatal("a peer with only reporterDone must not report — nothing could ever stop it, and " +
			"close() would wait on it forever")
	}
}

// THE RESIDUAL HOLE, CLOSED — and the failure it prevents is a SILENT LEAK, not a panic.
//
// Making `newRdevPeer`'s `go peer.runPeriodicReporter()` unconditional is a one-line edit that no
// unit test can catch, because constructing a real peer needs a UDP bind. What it would produce was
// reproduced during review and is NOT what an earlier note in this file claimed: with a nil
// `reporterDone`, `defer close(...)` binds nil and is scheduled for a return that never comes,
// because the select waits on a nil `reporterStop` beside a live ticker. No panic, no return — a
// goroutine calling `session.Stats()` every interval forever, INCLUDING AFTER `Session.Close()`,
// which is the one thing close()'s stop-and-wait ordering exists to prevent.
//
// A DEADLINE, NOT A BARE CALL. Without the guard this either hangs (the real failure) or panics on a
// nil session (in this fixture), and the deadline turns both into a failed test rather than a hung
// suite.
func TestRdevPeriodicReporterReturnsOnAPeerWithNoLifecycle(t *testing.T) {
	peer := &rdevPeer{}
	returned := make(chan struct{})
	go func() {
		defer close(returned)
		peer.runPeriodicReporter()
	}()
	select {
	case <-returned:
	case <-time.After(2 * time.Second):
		t.Fatal("runPeriodicReporter did not return on a peer with no lifecycle — it is waiting on " +
			"a nil reporterStop beside a live ticker, i.e. leaking a goroutine that keeps calling " +
			"Stats() after the session is closed")
	}
}
