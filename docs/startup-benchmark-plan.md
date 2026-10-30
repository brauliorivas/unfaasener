# Startup benchmark plan

Start with ImageProcessing, then repeat with the other example workflows. Implementation is pending. Experiment sizes and schedules are configurable; no numerical budgets are fixed yet.

## Measurements

Record three timestamps for each offloaded worker invocation:

| Timestamp | Where |
|---|---|
| T0: received | First operation in `vmModule.callback()` |
| T1: dispatched | Immediately before Docker `exec_run()`, on both execution paths |
| T2: handler entered | First executable statement in the function handler |

- **Startup:** T2 − T0. This is the main result.
- **Preparation:** T1 − T0.
- **Python startup:** T2 − T1.

Use `perf_counter_ns()` and verify compatible host/container clocks. Capture timestamps in memory and export after execution. Function execution time is excluded; still check completion and success. Time waiting before the host callback is outside this measurement.

## Controlled full-offload experiment

Use `0AAAAA`: GetInput stays in GCP; all five workers run on the host. Keep routing and admission settings fixed. **No separate latency/cost runs.**

Prepare all workers in one of these states before each measured workflow:

| State | Preparation | Warm-up execution? |
|---|---|---|
| Running reuse | Image and idle running container exist | Yes; leave running |
| Stopped restart | Image and stopped container exist | Yes; then stop |
| New container | Image exists; containers absent | No |
| Missing image | Function images and containers absent | No |

For running/stopped trials, run `warmup_requests` unmeasured workflows on freshly prepared containers (at least one successful execution per worker). New-container and missing-image trials have no function warm-up. Keep the execution agent ready in every state.

For missing-image trials, keep the pinned base image but reset function build caches before each workflow. Allow shared caches to develop between stages within that workflow. Image deletion alone does not clear build caches.

Trial loop: **prepare and verify state → send one workflow → collect records → wait for all work to finish → repeat**. Reset Docker and agent bookkeeping together. Only one workflow is in flight; GetInput's HTTP response is not completion.

### Pilot and main sample size

1. Run `pilot_requests_per_state` measured workflow requests. Exclude warm-up requests.
2. Calculate each worker/state's startup mean and standard deviation from the pilot.
3. Estimate the main count using the chosen `confidence_level` and `relative_margin`:

   `N = ceil((z × pilot_stddev / (relative_margin × pilot_mean))²)`

   `z` is the normal-distribution multiplier corresponding to `confidence_level`.

4. For each state, use the largest estimated count among its workers. Review dependence between samples before fixing the count; the formula assumes independent observations.
5. Record `main_requests_per_state` before main collection. Keep pilot and main results separate.
6. Spread requests across `sessions` and vary state order. Report the confidence interval actually achieved.

Use the same preparation procedure in pilot and main runs.

## Natural trace replay

- Replay Azure 2021 arrivals as whole workflow requests. Derive start times from `end_timestamp − duration`; these are reconstructed execution starts, not original request-arrival timestamps.
- Configure `trace_segments`: the selected application/function IDs and start/end times. Choose patterns of interest before testing; segment count and duration follow from this list. Preserve original spacing and idle gaps.
- Run each schedule separately in **latency mode and cost mode**. Let the scheduler choose routing.
- Start matched runs with the same images, no containers and the same initial scheduler history. Replay `trace_preroll_seconds` of preceding trace as unmeasured preparation, then measure without resetting.
- Send requests on schedule without waiting for previous workflows. Let caches and the ten-minute idle policy operate naturally.
- Validate replay before main collection. Run each configured segment `trace_repetitions` times per mode. Request count follows from the selected trace.

## Load testing

Keep the same three timestamps. Request rate means **whole workflows per second**.

**Fixed-rate full offload:** retain `0AAAAA`, with no latency/cost split. Use a capacity pilot to choose `load_rates_rps`. At each rate, run `load_preroll_seconds` of preparation followed by `load_duration_seconds` of measurement, repeated `load_repetitions` times. Start each run from the same state, send independently of completion and let containers evolve.

**Four-state startup under load:** prepare a state, then send `batch_requests` using the configured `batch_arrival_schedule`. Repeat the batch `batch_repetitions` times, restoring its initial state each time. Do not reset between overlapping requests; later requests may encounter a different state.

**Scaled trace replay:** run each value in `trace_time_scales` under both scheduling modes, with `trace_repetitions` per segment/scale/mode. Divide arrival gaps by the scale, including the preparation segment. Native timing is the baseline. Keep the idle timeout unchanged; scaling changes both contention and container reuse.

For load/replay, run the sender on a separate machine. Record planned/actual sends, completed requests, outstanding work, failures and fallbacks. Configure `max_sender_lateness_seconds` and `completion_timeout_seconds`.

## Run configuration

Store the parameters named above in a configuration file and save it with each run. Choose pilot counts and precision targets before the pilot; use its results to set main counts, rates, durations and repetitions before main collection. Use matching schedules/settings for latency/cost comparisons. Missing parameters must be supplied explicitly rather than silently assigned example defaults.

## Implementation work

1. Add T0/T1 to [vmModule.py](../host-agents/execution-agent/vmModule.py) and generate the T2 handler hook centrally when preparing downloaded function source.
2. Add a runner for state preparation, warm-up, sequential requests, fixed-rate traffic and trace schedules. Make endpoint, routing, inputs and completion checks configurable per workflow.
3. Fix exit-status/output handling, stale container references and idle tracking. Verify the ten-minute timeout never stops active work. Coordinate concurrent image builds before load tests.
4. Validate instrumentation and the four states on Flip, then run the full-workflow pilot. Check measurement overhead before main collection.

## Records and results

Save run/request/attempt IDs, function, actual placement/state, image/container IDs, T0/T1/T2 and outcome. Keep failed or incomplete attempts; missing timing is not zero.

Save the code/dependency versions, input, host limits, cache policy and experiment settings with each run. Keep them consistent across comparisons. Use a quiet host and standardize initial storage-bucket contents.

Report startup and its two parts per worker/state: count, mean, confidence interval and failures. For trace/load, also report offload fraction, state frequencies and offered/completed throughput. Account for shared sessions/workflows when calculating uncertainty.

Run in this order: **instrumentation validation → controlled pilot → controlled main → native trace replay → load extensions → other workflows**.

References: [Azure trace](https://github.com/Azure/AzurePublicDataset/blob/master/AzureFunctionsInvocationTrace2021.md), [sample-size formula](https://itl.nist.gov/div898/handbook/ppc/section3/ppc333.htm), [request verification](manual-request-verification.md).
