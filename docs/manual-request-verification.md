**It uses first-generation Cloud Functions because the current UnFaaSener implementation is built around their APIs and execution model.** Your deployment kept that compatibility.

Specifically, the repository:

- Uses `functions_v1.CloudFunctionsServiceClient()` to fetch function settings and download source code for offloaded Docker images.
- Defines Pub/Sub workers with the legacy `handler(event, context)` interface.
- Parses first-generation execution logs, including their execution IDs and completion messages.

You can see those dependencies in [vmModule.py](/home/brauliorivas/code/unfaasener/host-agents/execution-agent/vmModule.py:301). Your [deployment notes](/home/brauliorivas/code/unfaasener/README.md:99) explicitly record deploying all six functions as Gen 1.

The project accompanies a [2023 research paper](https://www.usenix.org/conference/atc23/presentation/sadeghian). I can verify the compatibility dependencies above; I cannot establish the authors’ original reasoning from the publication date alone. **Gen 1 is not a requirement of offloading as a concept. Moving this implementation to Gen 2 would require adapting and validating those integrations.**

Now, to trace one request yourself:

**1. Understand what you’re identifying**

Every request starts with `GetInput` in GCP. The five processing stages can run in GCP or on your offload host:

```text
HTTP → GetInput → Flip → Rotate → Filter → Greyscale → Resize
         GCP       Each worker: GCP or offload host
```

The useful question is **where each stage actually executed**.

There are two different IDs:

| ID | Purpose |
|---|---|
| `execution_id` | One function invocation in GCP |
| `reqID` | The whole workflow request, carried across stages and hosts |

Your current HTTP handler returns the first ID. You then use its logs to discover the second.

**2. Watch the offload host**

SSH into the machine running UnFaaSener and run:

```bash
cd ~/unfaasener

tail -n 0 -F \
  scheduler/logs/initialDeploy.log \
  host-agents/execution-agent/logs/executionLogs.log
```

Keep this terminal open.

**3. Start one request through HTTP**

In another terminal with your GCP login configured:

```bash
project=serverless-research-espol
region=northamerica-northeast1

url=$(gcloud functions describe ImageProcessing_GetInput \
  --project="$project" \
  --region="$region" \
  --format='value(httpsTrigger.url)')

execution_id=$(curl --fail-with-body --silent --show-error \
  "$url" \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  -H 'Content-Type: application/json' \
  --data '{"message":"test.png"}') &&
printf 'GetInput execution ID: %s\n' "$execution_id"
```

This sends the actual invocation with **HTTP through `curl`**. Here, `gcloud` only discovers the URL and supplies credentials. Your deployment notes say GetInput requires authentication, so the Authorization header is needed. This is Google’s documented [authenticated HTTP invocation pattern](https://codelabs.developers.google.com/how-to-invoke-authenticated-cloud-function).

`test.png` must exist in your input bucket. A successful HTTP response means the workflow started; downstream stages continue asynchronously.

**4. Find the workflow’s `reqID` and selected route**

Open [Logs Explorer for your project](https://console.cloud.google.com/logs/query?project=serverless-research-espol). Select a recent time range and paste:

```text
resource.type="cloud_function"
resource.labels.function_name="ImageProcessing_GetInput"
resource.labels.region="northamerica-northeast1"
labels.execution_id="PASTE_GETINPUT_EXECUTION_ID"
```

In those entries, find:

```text
Routing::::: 0A0000
```

and a standalone **32-character hexadecimal value**, such as:

```text
a14b...32 characters total...
```

That hexadecimal value is the workflow’s `reqID`.

Read the route by position:

| Position | Stage |
|---:|---|
| 0 | GetInput |
| 1 | Flip |
| 2 | Rotate |
| 3 | Filter |
| 4 | Greyscale |
| 5 | Resize |

`0` means GCP; `A` means the first offload host.

Examples:

```text
000000 → all stages selected for GCP
0A0000 → Flip selected for the offload host
0AAAAA → all five workers selected for the offload host
```

**The route records intent. The host can forward a selected stage back to GCP under load.**

**5. Find which stages actually ran in GCP**

Replace the Logs Explorer query with:

```text
resource.type="cloud_function"
resource.labels.region="northamerica-northeast1"
textPayload:"PASTE_WORKFLOW_REQ_ID"
```

The worker handlers log that ID near the end of their work. Expand each matching entry and inspect `resource.labels.function_name`.

For example, these matches:

```text
ImageProcessing_GetInput
ImageProcessing_Rotate
ImageProcessing_Filter
ImageProcessing_Greyscale
ImageProcessing_Resize
```

show cloud execution evidence for those stages. You would then check whether Flip ran on the host.

For an individual cloud invocation, copy its `labels.execution_id` and filter by that ID to inspect its complete logs, including errors and completion status.

**6. Find which stages ran on the offload host**

On the offload host:

```bash
cd ~/unfaasener
req_id='PASTE_WORKFLOW_REQ_ID'

grep -n -F -C 4 -- "$req_id" \
  host-agents/execution-agent/logs/executionLogs.log

grep -n -F -C 4 -- "$req_id" \
  scheduler/logs/initialDeploy.log
```

Interpret the evidence:

| Evidence | Meaning |
|---|---|
| Function name and its `reqID` output in `executionLogs.log` | Function output from a host container |
| `After running:::` / `Total exe time:::` | Host execution attempt finished in a reused container |
| `Exe time after creation:::` | Host execution attempt finished in a new container |
| `has forwarded to the serverless equivalent!` | Agent forwarded that stage to GCP |

Also inspect the host’s recorded stage executions:

```bash
python3 - "$req_id" <<'PY'
import csv
import sys
from pathlib import Path

path = Path("host-agents/execution-agent/data/cachedVMData.csv")
if not path.exists():
    raise SystemExit("No CSV yet; wait for the agent to flush its records.")

with path.open() as stream:
    for row in csv.DictReader(stream):
        if row["reqID"] == sys.argv[1]:
            print({k: row[k] for k in
                   ("function", "host", "start", "finish", "duration")})
PY
```

`host=vm0` identifies the first offload host. Records flush asynchronously.

**7. Confirm the workflow completed**

Open [Cloud Storage](https://console.cloud.google.com/storage/browser?project=serverless-research-espol), then the bucket:

```text
serverless-research-espol-imageprocessingworkflowstorage
```

Find an object whose name **starts with `resized-` and contains your `reqID`**. That is the final output.

Combine the observations:

| Observed evidence | Conclusion |
|---|---|
| All six stages have GCP execution evidence, no matching host execution | Consistent with GCP-only processing |
| At least one worker has host execution evidence, and final output exists | Completed workflow with offloading |
| Host forwarding message followed by matching cloud execution | That stage fell back to GCP |
| Same stage appears in both locations | Inspect retries or duplicate executions; record both |
| Missing stage evidence or no final output | Trace remains incomplete |

**The current logging has limits:** new-container output can appear as numeric bytes, and the agent’s timing/CSV records do not reliably establish function success. Check exceptions and the final output alongside them. Missing logs alone cannot prove that a stage never ran.

So you can reconstruct a request using these steps, but the repository does **not yet provide a fully reliable, automatic distributed trace**. The existing [manual verification guide](/home/brauliorivas/code/unfaasener/docs/manual-request-verification.md) documents the same underlying logs and limitations.
