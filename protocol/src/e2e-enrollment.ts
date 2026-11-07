/// §12.3's commit order, as a pure reducer over the Issuer's durable journal.
///
/// Mirror of `RdevCore.E2EEnrollment` (Swift).
///
/// > "The Issuer's reservation, grant, and registration **job** are one atomic local transaction,
/// > and **that transaction — not a Worker round trip — is what gates the acknowledgement.**"
///
/// **THE ORDERING IS THE FEATURE**, and it is: durable local commit → publication attempt → outcome
/// → acknowledgement → background retries. An Issuer that acknowledged first and committed after
/// would hand a device a grant it might not hold on restart; one that waited for the Worker would
/// let a silent Control Plane hold enrollment open forever, which §12.2 refuses in as many words.
///
/// **A REDUCER, so a crash is a test rather than a scenario.** §17.2 asks for exactly this: "Use
/// injectable delivery, clocks, and crashes; restart from serialized durable state only." A crash
/// here is dropping the returned value on the floor; a restart is calling `apply` against the last
/// journal that was actually written.
import { classifyPublication, type DirectoryResponse } from "./e2e-directory";
import { PublicationStatus } from "./e2e-wire";

const equal = (a: Uint8Array, b: Uint8Array): boolean =>
  a.length === b.length && a.every((v, i) => v === b[i]);
const key = (b: Uint8Array): string => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

/// §12.3's pairing window, from the Issuer's side.
export type WindowState =
  /** Open and waiting; the pairing secret is live. */
  | { state: "open" }
  /**
   * **Reserved to exactly one device and operation.** §12.3: "Only one request wins a window; all
   * other handshakes are aborted." Reservation is durable and happens INSIDE the transaction, so
   * two handshakes racing cannot both believe they won.
   */
  | { state: "reserved"; deviceId: Uint8Array; operationId: Uint8Array }
  /** The transaction committed: the grant exists, the job is recorded, the secret is gone. */
  | { state: "committed"; deviceId: Uint8Array; operationId: Uint8Array }
  /** Expired, or closed without a commit. */
  | { state: "closed" };

/// §12.3: the secret is destroyed as part of the committing transaction, and §14 erases it on
/// expiry. A window still holding a live secret after either is one an attacker can pair against.
export const secretIsLive = (w: WindowState): boolean =>
  w.state === "open" || w.state === "reserved";

/// A registration job. §12.2: "a retry obtains another challenge but preserves the operation ID and
/// payload", so BOTH are stored — a job that re-serialized its payload could produce different bytes
/// and turn an idempotent retry into a `409`.
export interface Job {
  operationId: Uint8Array;
  grantId: Uint8Array;
  deviceId: Uint8Array;
  bundle: Uint8Array;
  status: PublicationStatus;
  attempts: number;
  /** §12.2: a terminal rejection is "paused, pending corrective action" — not looped, not abandoned. */
  paused: boolean;
  /** §12.2: "stop pending jobs whose subject or ancestor has been revoked." A paused job resumes on
   *  user action; a stopped one never does. */
  stopped: boolean;
}

export const retriesNow = (job: Job): boolean =>
  !job.paused && !job.stopped && job.status === PublicationStatus.Unconfirmed;

export interface Journal {
  window: WindowState;
  jobs: Job[];
  /** §10.5's tombstones, applied to jobs as they arrive. */
  revokedDeviceIds: string[];
}

export const emptyJournal = (): Journal =>
  ({ window: { state: "open" }, jobs: [], revokedDeviceIds: [] });

/// §12.3: "that transaction — not a Worker round trip — is what gates the acknowledgement."
///
/// **The publication status is NOT consulted.** An unconfirmed or rejected job is still an enrolled
/// device, and §12.2 is explicit that publication "is not a hard precondition" for access.
export function mayAcknowledge (journal: Journal, operationId: Uint8Array): boolean {
  return journal.window.state === "committed" && equal(journal.window.operationId, operationId);
}

export const pendingJobs = (journal: Journal): Job[] => journal.jobs.filter(retriesNow);

export const findJob = (journal: Journal, operationId: Uint8Array): Job | undefined =>
  journal.jobs.find((j) => equal(j.operationId, operationId));

export type EnrollmentFailure =
  /** Another device already won this window. */
  | "window-taken"
  /** The window is closed or already committed. */
  | "window-unavailable"
  /** A commit arrived with no reservation behind it. */
  | "not-reserved"
  /** A commit for a device or operation other than the reserved one. */
  | "wrong-reservation"
  | "unknown-operation";

export type EnrollmentEvent =
  /** A `client-confirm` passed §11.2's gate and is asking for the window. */
  | { event: "reserve"; deviceId: Uint8Array; operationId: Uint8Array }
  /** **The atomic transaction.** Reservation, grant and job become durable together, and the secret
   *  is destroyed in the same step. */
  | { event: "commit"; deviceId: Uint8Array; operationId: Uint8Array; grantId: Uint8Array;
      bundle: Uint8Array }
  /** A publication attempt resolved, one way or another. */
  | { event: "publication-attempt"; operationId: Uint8Array; response: DirectoryResponse }
  /** A revocation arrived. */
  | { event: "revoked"; deviceId: Uint8Array }
  /** §14: the window expired — erase the secret, abort unreserved handshakes. */
  | { event: "expire" }
  /** §12.2: a paused job resumes "only on explicit operator or user action". */
  | { event: "resume"; operationId: Uint8Array };

export type EnrollmentResult =
  | { ok: true; journal: Journal }
  | { ok: false; failure: EnrollmentFailure };

/// Apply one event. **PURE**: the caller writes the returned journal durably and only then acts on
/// it — which is what makes "the transaction gates the acknowledgement" a property of the code
/// rather than of the specification.
export function apply (journal: Journal, event: EnrollmentEvent): EnrollmentResult {
  const next: Journal = {
    window: journal.window,
    jobs: journal.jobs.map((j) => ({ ...j })),
    revokedDeviceIds: [...journal.revokedDeviceIds],
  };

  switch (event.event) {
    case "reserve": {
      const w = journal.window;
      if (w.state === "open") {
        next.window = { state: "reserved", deviceId: event.deviceId,
                        operationId: event.operationId };
      } else if (w.state === "reserved") {
        // IDEMPOTENT FOR THE SAME REQUEST, and refused for any other. A retry of the same handshake
        // must not lose the window it holds; a different device must not take it.
        if (!equal(w.deviceId, event.deviceId) || !equal(w.operationId, event.operationId)) {
          return { ok: false, failure: "window-taken" };
        }
      } else {
        return { ok: false, failure: "window-unavailable" };
      }
      break;
    }

    case "commit": {
      const w = journal.window;
      if (w.state !== "reserved") {
        // §12.3 puts the reservation INSIDE the transaction, so a commit without one is not a
        // commit — it is a grant nobody reserved a window for.
        if (w.state === "committed" && equal(w.deviceId, event.deviceId)
            && equal(w.operationId, event.operationId)) {
          return { ok: true, journal };      // replay of the same transaction
        }
        return { ok: false, failure: "not-reserved" };
      }
      if (!equal(w.deviceId, event.deviceId) || !equal(w.operationId, event.operationId)) {
        return { ok: false, failure: "wrong-reservation" };
      }
      // ALL THREE, OR NONE. The caller writes this journal in one durable write; there is no
      // intermediate state in which the grant exists and its job does not.
      next.window = { state: "committed", deviceId: event.deviceId,
                      operationId: event.operationId };
      next.jobs.push({
        operationId: event.operationId, grantId: event.grantId, deviceId: event.deviceId,
        bundle: event.bundle, status: PublicationStatus.Unconfirmed, attempts: 0, paused: false,
        // A device already tombstoned at commit time gets a job that never runs, rather than one
        // that runs and is then stopped.
        stopped: journal.revokedDeviceIds.includes(key(event.deviceId)),
      });
      break;
    }

    case "publication-attempt": {
      const index = next.jobs.findIndex((j) => equal(j.operationId, event.operationId));
      if (index < 0) return { ok: false, failure: "unknown-operation" };
      const job = next.jobs[index]!;
      job.attempts += 1;
      const status = classifyPublication(event.response);
      // §12.2: "`confirmed` is terminal. A later `unconfirmed` from any peer MUST NOT reset it."
      // This endpoint HOLDS the job, so it is the one allowed to move the value — and still not
      // backwards out of confirmed.
      if (job.status !== PublicationStatus.Confirmed) job.status = status;
      job.paused = job.status === PublicationStatus.Rejected;
      break;
    }

    case "revoked": {
      const id = key(event.deviceId);
      if (!next.revokedDeviceIds.includes(id)) next.revokedDeviceIds.push(id);
      // Stopping is irreversible here because a tombstone is (§10.5: "no unrevoke operation").
      for (const job of next.jobs) {
        if (equal(job.deviceId, event.deviceId)) job.stopped = true;
      }
      break;
    }

    case "expire":
      // §14: "erase secret and abort unreserved handshakes; PRESERVE ESTABLISHED ROUTES." A
      // committed window is not reopened or torn down by an expiry — the device it enrolled is
      // enrolled, and its job is still owed a publication.
      if (journal.window.state === "open" || journal.window.state === "reserved") {
        next.window = { state: "closed" };
      }
      break;

    case "resume": {
      const index = next.jobs.findIndex((j) => equal(j.operationId, event.operationId));
      if (index < 0) return { ok: false, failure: "unknown-operation" };
      const job = next.jobs[index]!;
      // A STOPPED job does not resume. §10.5 has no unrevoke, so "resume" on a revoked device's job
      // would be the one path that manufactures one.
      if (job.stopped) return { ok: true, journal };
      job.paused = false;
      job.status = PublicationStatus.Unconfirmed;
      break;
    }
  }
  return { ok: true, journal: next };
}
