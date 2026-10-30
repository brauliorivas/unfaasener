# UnFaaSener startup benchmark reference

Status: proposed design; no benchmark results yet.

## Goal and scope

Measure how long UnFaaSener takes to prepare an offloaded function and start useful work, then measure completion separately.

- **Image** = stored template; **container** = execution environment created/started from it.
- Missing function image: download source/metadata → build image locally → create/start container → execute Python. Base-image pulling may occur during the build.
- Existing container: restart if stopped, then execute Python. Even a running container starts a new Python process and imports for each invocation.
- Current implementation has no separate pool of generic prewarmed skeleton containers.

## Experiment sequence

1. **Validate instrumentation on Flip.** It is first in the chain and easier to debug; it has no special representative status.
2. **Benchmark all five ImageProcessing workers**, forced onto the host (`0AAAAA`). GetInput remains in GCP. Send authenticated HTTP requests; wait for complete workflow execution before resetting and sending the next request.
3. **Broaden functions/dependencies:** add lightweight and heavier numerical/ML functions if making claims beyond ImageProcessing.
4. **Replay a trace** with natural caching to measure the workload-dependent mixture of startup states. Add concurrency/background load experiments afterward.

One workflow is enough for an ImageProcessing-specific result. Multiple dependency stacks improve startup generality; multiple full workflows become useful for studying DAG structure, fan-out, contention and completion latency.

## Four conditions—measure separately

| Condition | State before each request |
|---|---|
| Running reuse | Function image and idle running container exist |
| Stopped restart | Image and stopped container exist |
| New container | Image exists; container absent |
| Missing image | Function image and container absent; explicit cache policy |

Stopped restart and new-container startup most directly answer the original question. Deleting images every time measures first-use preparation, not typical operation.

For missing-image trials, distinguish final-image absence with cached layers, function build without cache but base image present, and optional fresh-host/base-image-absent trials. **Image deletion alone does not clear build caches.** Keep preparation/reset outside measurement and verify the actual state.

Agent bookkeeping must match Docker state: it caches container references and metadata. Reset that bookkeeping consistently or restart/ready the agent outside timing under a declared policy. Do not rerun full deployment for every sample; it changes state and sends warm-ups.

## Timing and records

Record events at: message receipt → admission → source/metadata preparation → image build → container create → start/restart → Python dispatch → handler entry → handler exit → agent completion. Capture boundaries and success/failure for each applicable phase.

| Metric | Purpose |
|---|---|
| **Host message receipt → handler entry** | **Primary: delay until useful function work starts** |
| Receipt → admission | Acknowledgment/admission waiting |
| Source preparation; image build | First-use preparation costs |
| Container create; start/restart | Container startup costs |
| Python dispatch → handler entry | Dispatch, interpreter startup and imports |
| Handler entry → exit | Function runtime |
| Receipt → agent completion | Complete host-side attempt |
| HTTP send → final output ready | End-to-end workflow latency |

Use monotonic clocks for host-local durations; verify a common clock domain for host/container timestamps. Use UTC for correlation, not unsynchronized cross-machine subtraction. Pub/Sub callback entry defines “received”; StreamingPull does not provide a separate pull-start for every request. Record polling delay if detecting final output by polling.

Each record needs: session/run ID, reqID, function, attempt/message ID, container/image ID, observed starting state, phase timings and outcome. Assess instrumentation overhead. GetInput's HTTP response is **not** workflow completion.

## Per-function and aggregate results

Report each function × condition first: count, mean, 95% confidence interval, median, p95, failures and fallback rate.

Then report, separately:

- **Mean startup per worker invocation:** pooled timings, weighted by invocation counts.
- **Mean accumulated startup per workflow:** sum its five worker startup durations, then average across requests.
- **Mean workflow completion latency:** measured end to end, including execution and communication.

With equal counts and one execution per stage, pooled startup mean equals the mean of the five stage means. Retries/fallbacks break that equivalence; record actual locations and attempts. Define success-only summaries explicitly and retain failure/timeout counts.

100 workflow requests give 100 observations per worker—not 500 independent workflow repetitions. Account for request/session grouping in uncertainty estimates. Never mix startup conditions into an unexplained overall mean.

## Shared caches and ordering

Whole-workflow trials always execute Flip first. Its image build can populate caches used by later stages. This correctly measures the workflow's startup sequence, but not each function independently under identical cache conditions.

For independent function comparisons, reset equivalent cache state before each target measurement and vary function order. Report this as a separate experiment. Do not treat the five related workers as five independent workload families.

## Sample size and controls

- Pilot: **30 workflow requests per condition**, producing 30 observations per worker.
- Initial main-run budget: **100 requests per condition** (400 requests, plus 120 pilot requests). Choose the final count from pilot variability before the main run.
- Approximate planning for a mean with 95% confidence and ±5% relative precision: `n ≈ (1.96 × SD / (0.05 × mean))²`. CV 0.25 suggests ~97; CV 0.50 suggests ~385 independent observations. Dependence/skew can require more or different analysis.
- Spread observations across ≥5 sessions; vary condition order. Report achieved uncertainty. Five sessions and 100 observations are starting budgets, not guarantees; do not claim reliable p99 from 100 samples.
- Fix source/dependencies/base-image digest, input, host CPU/RAM, container limits, Docker version, region/network placement and cache policy. Save commit plus local diff.
- For controlled trials: fixed routing/concurrency, prevent scheduler overwrites, no unrelated load, one workflow in flight. Record unexpected fallback and errors; do not silently remove slow observations.

## Trace replay and later directions

The paper uses uniform traffic and Azure Functions Invocation Trace 2021 through FaaSProfiler. Its trace experiment studies adaptive offloading; its 250-sample count concerns Pub/Sub latency, not startup. It retains function images and stops containers after ten idle minutes.

- Replay arrivals independently of previous completion; record intended/actual send times and delayed arrivals.
- Preserve time gaps initially. Compression changes reuse and cold-start frequency.
- Preserve natural caching; no image deletion between requests. Use gaps long enough to exercise the ten-minute idle policy.
- For operational results, enable normal scheduling/concurrency and report offload fraction, fallback/errors, state frequencies and latency conditional on each state. Forced-offload replay is a separately labeled experiment.
- Repeat declared trace slices; distinguish initial transient from steady operation. A workload average depends on state frequencies, not an equal average of the four controlled means.
- Later: representative dependencies, concurrent requests, background load, different host sizes and genuinely fresh-host startup.

## Fix or validate before trusting measurements

- Existing duration/“Exe time after creation” combines preparation, waiting and execution; add phase timestamps.
- Container-command exit status is not handled reliably; timing/CSV records alone do not prove success.
- New-container output can be logged as numeric bytes.
- Idle timestamp keys differ on creation vs reuse; correct and validate before natural-idle/trace experiments.
- Concurrent image misses lack a per-function build lock; address or explicitly study this before concurrent cold-start trials.

## References

- [Request tracing guide](manual-request-verification.md)
- Implementation: `host-agents/execution-agent/vmModule.py` and `Dockerfile`.
- [UnFaaSener paper](https://www.usenix.org/system/files/atc23-sadeghian.pdf), §§7.3, 9.1, 9.6, 9.8.
- [FaaSProfiler](https://github.com/PrincetonUniversity/faas-profiler), [Azure trace](https://github.com/Azure/AzurePublicDataset/blob/master/AzureFunctionsInvocationTrace2021.md).
- [Docker build cache](https://docs.docker.com/build/cache/), [NIST sample-size planning](https://www.itl.nist.gov/div898/handbook/ppc/section3/ppc333.htm).
