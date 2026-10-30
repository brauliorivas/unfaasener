# UnFaaSener
[![Build Status](https://github.com/ubc-cirrus-lab/unfaasener/actions/workflows/python-app.yml/badge.svg)](https://github.com/ubc-cirrus-lab/unfaasener/actions/workflows/python-app.yml) [![GitHub license](https://img.shields.io/badge/license-Apache%202-blue.svg)](https://github.com/ubc-cirrus-lab/unfaasener/blob/main/LICENSE)

UnFaaSener is a lightweight framework designed to empower serverless developers to decrease their expenses by harnessing non-serverless compute resources.
Whether it's your VMs, on-premise servers, or personal computers, UnFaaSener allows you to make the most of these underutilized resources.

UnFaaSener is not a new serverless platform.
It uses pub/sub services to glue serverless applications and offloading hosts.
UnFaaSener has been thoroughly tested and evaluated on [Google Cloud Functions](https://cloud.google.com/functions).

Our 2023 USENIX ATC paper provides in-depth insights into the design and evaluation of UnFaaSener: 
* [Paper PDF](https://www.usenix.org/system/files/atc23-sadeghian.pdf)
* [Presentation](https://www.youtube.com/watch?v=Yk9N5Ui6oaI)

## Setting Up and Building the Tool

**Before running the setup scripts, review the following notes:**

1. UnFaaSener uses [gcloud CLI](https://cloud.google.com/sdk/docs/install) for collecting serverless logs. 
Make sure you have it installed in your leader host.

2. Ensure that you have [Julia](https://julialang.org/downloads/platform/) installed before running the setup script, as the default solver is implemented in Julia (Our solver has been tested with `julia version 1.9.3`). 
Julia's solver offers superior performance, particularly for larger workflows or a higher number of offloading hosts. 
Nonetheless, you retain the flexibility to switch to the Gekko solver by modifying the value of the `solver` field within the [rankerConfig.ini](https://github.com/ubc-cirrus-lab/unfaasener/blob/main/scheduler/rankerConfig.ini) (set `solver = gekko` to use the Gekko solver and `solver = julia` to use the Julia solver).

3. In case of leader failure, the leaderFailure variable in the setup.sh needs to be set to 1 (```leaderFailure=1```) in order to retrieve host logs from the datastore.

Now, you are ready to set up the dependencies for the tool by simply running the following script:

```
./setup.sh 
```
Then, run the following script to build those components that need to be compiled:
```
./build.sh
```

## Deploying the System

To deploy the system, follow these steps:
1. **Giving the required credentials:** To create the necessary credentials for using UnFaaSener, follow the instructions [here](./scheduler/key/).
2. **Adding a new host:** To register a new host to UnFaaSener, you must assign a new Pub/Sub topic to the host and ensure that the host subscribes to this topic. To do this in Google Cloud Functions, follow these steps:
    1. **Create a Pub/Sub Topic:** 
        * Access the Pub/Sub service page on the Google Cloud Console.
        * Navigate to the *Topics* section and click on *CREATE TOPIC*. This topic will serve as the communication channel for the host.
        * The host topics follow the naming pattern `vmTopic+n`, where `n` represents the host number. For example, if you want to add the third host, name the topic as `vmTopic3`.
    2. **Configure the Host Subscription:**
        * To receive messages published to the topic, create a subscription for the host.
        * Go to the *Subscriptions* section and click on *CREATE SUBSCRIPTION*.
        * Provide a unique subscription ID for the host execution agent to use.
        * Select **never expire** for the expiration period if you want the host to be available indefinitely.
            <img src="./scheduler/key/Images/expire.png" alt="expireSubsciption"/>
        * For providing a level of fault tolerance, enable dead lettering while creating the subscription. You need to choose the dead-letter topic for your host subscription, which is assigned to another host. We suggest using a round-robin approach to assign the dead-letter topic for host<sub>i</sub> to the topic of host<sub>(i + 1)%numhosts</sub>.
            <img src="./scheduler/key/Images/deadLetter.png" alt="deadLetterTopic"/>
3. **Deployment Script:**
    * To ensure that all functions initially run as serverless functions by default, run [this](./scheduler/resetRoutingDecisions.py) script before running the system. 
    This script resets the routing decisions.
        ```
        python3 ./scheduler/resetRoutingDecisions.py [benchmark name] [number of offloading hosts]
        ``` 
    * Start the system using the [deployment script](./initialDeploy.sh). 
    This script launches the system, prepares the initial state, and starts the host agents.
    To run the script, simply use the following arguments:
        ```
        ./initialDeploy.sh [benchmark name] [number of offloading hosts] [optimization mode (latency/cost)]
        ``` 

## Acknowledgments

This work was supported by the Natural Sciences and Engineering Research Council of Canada (NSERC) and The University of British Columbia (UBC).
We are also thankful for cloud resources made available to us by the Digital Research Alliance of Canada, the Google Cloud Research Credits program, and the AWS Cloud Credit for Research program.

In addition to authors of our paper (Ghazal Sadeghian, Mohamed Elsakhawy, Mohanna Shahrad, Joe Hattori, and Mohammad Shahrad), we acknowledge Parshan Javanrood who played an important role in optimizing UnFaaSener's solver.

## DiSel Serverless Research code changes

We are researching the **average time UnFaaSener takes to start an offloaded function's Docker container** on a CloudLab host. The agents run natively; GCP runs the serverless baseline.

Changes so far:

- Added `profile.py` to create a configurable CloudLab node.
- Fixed Julia JSON parser compatibility and adjusted the existing CI test launcher.
- Updated Image Processing's bucket names and pinned `Werkzeug==2.3.8` for Flask 2.1 compatibility.
- Raised `ImageProcessing_GetInput` to 256 MiB and matched its workflow memory metadata.
- Added `full_setup.sh`, `start.sh` and `stop.sh` for the host lifecycle. `setup.sh` keeps an existing Docker installation.
- Offloaded images use Python 3.12, `setuptools<81` for the old Datastore SDK, and files owned by the original `bin` runtime user.

## GCP and offload host setup

Steps followed for `serverless-research-espol`, using `northamerica-northeast1`:

1. Enabled billing and the Cloud Functions, Cloud Build, Artifact Registry, IAM, Storage, Pub/Sub, Datastore/Firestore, Logging and Monitoring APIs.
2. Created service accounts: `unfaasener-monitoring` (Monitoring Admin/Viewer), `unfaas-scheduler` (Cloud Datastore Owner), and `unfaas-host` (Cloud Functions Admin, Cloud Datastore Owner, Pub/Sub Publisher/Subscriber, Storage Object User, Logs Viewer). Downloaded their JSON keys to the [documented locations](./scheduler/key/).
3. Created the default database in **Datastore mode**, in the same region.
4. Created private Standard buckets `serverless-research-espol-imageprocessingsamples` and `serverless-research-espol-imageprocessingworkflowstorage`, with uniform bucket-level access. Uploaded the repository's `benchmarks/aws_step_functions/powerTuning/ImageProcessingBenchmark/sample_1/test.png` to the input bucket as `test.png`.
5. Created topics `ImageProcessing_Flip`, `ImageProcessing_Rotate`, `ImageProcessing_Filter`, `ImageProcessing_Greyscale`, `ImageProcessing_Resize`, and `vmTopic1`. Created pull subscription `vmSubscriber1` for `vmTopic1`; no dead-letter topic for this single-host setup.
6. Set `projectid` in `project-config.ini` and `PROJECT_ID` in all six Image Processing functions to the project ID. Set the functions' input/output bucket names to the names above.
7. Created Datastore kind `routingDecision`, entity `ImageProcessingWorkflow`: string `active = "50"`; strings `routing_25`, `routing_50`, `routing_75`, `routing_95` all set to `[[0], [0], [0], [0], [0], [0]]` (all stages on serverless).
8. Deployed all six functions as **Gen 1**, **Python 3.12**, **256 MiB**, with runtime service account `unfaas-host@serverless-research-espol.iam.gserviceaccount.com`. GetInput uses an authenticated HTTP trigger; the workers use their matching Pub/Sub topics. Entry points: `get`, `flip`, `rotate`, `filterr`, `greyscale`, `resize`.
9. Called GetInput with `{"message":"test.png"}` and checked all stages, logs and the resized output in Storage.

For an Ubuntu CloudLab host with SSH and passwordless sudo, run from your computer:

```bash
# Install dependencies, configure credentials/project, and build. Does not start agents.
./full_setup.sh user@host \
  --host-key /path/to/vmExeModule.json \
  --monitor-key /path/to/monitoringKey.json \
  --scheduler-key /path/to/schedulerKey.json \
  --project serverless-research-espol

# Start without resetting state.
./start.sh user@host --mode latency

# Stop the processes started by start.sh.
./stop.sh user@host

# Explicitly reset workflow history, stop its containers and drain the subscription.
./start.sh user@host --initialize --mode cost
```

These scripts replace `offload-host.sh` and use `~/unfaasener` on the remote host. Setup installs dependencies, copies missing keys, configures the project and runs the existing setup/build scripts. Existing checkouts are kept without pulling.

`start.sh` mirrors the startup commands in `initialDeploy.sh`, adding `nohup` and saving agent PIDs in `~/.unfaasener.pids` for `stop.sh`. `--mode` is optional; omission keeps the configured mode. `initialDeploy.sh` is unchanged.

Only `--initialize` runs the reset steps copied from `initialDeploy.sh`. No automatic warm-up requests are sent. The original log collector still needs completed cloud executions as input; prepare those before starting a fresh experiment. Normal scheduling can update routing after startup.

Wait for workflow requests and scheduling work to finish before stopping. Stop sends termination signals to the saved agents and retains containers, images and experiment data. Logs append to `~/unfaasener/scheduler/logs/initialDeploy.log`; view them with SSH/tail when needed.

For request verification, see [Manual request verification](docs/manual-request-verification.md).
