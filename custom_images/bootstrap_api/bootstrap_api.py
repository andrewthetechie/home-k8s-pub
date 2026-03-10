import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List
from pydantic.networks import IPv4Address
from pydantic_extra_types.mac_address import MacAddress
import yaml
import pykube
from pykube import Job
from copy import deepcopy
import random
import string

app = FastAPI()


# Pydantic model for the bootstrap request
class BootstrapRequest(BaseModel):
    name: str
    roles: List[str]
    mac: MacAddress
    ip: IPv4Address


# Load Kubernetes configuration based on environment
def setup_k8s_client() -> pykube.HTTPClient:
    try:
        if os.getenv("KUBERNETES_SERVICE_HOST"):  # Inside a Kubernetes cluster
            return pykube.HTTPClient(pykube.KubeConfig.from_service_account())
        else:  # Outside the cluster, use ~/.kube/config
            return pykube.HTTPClient(pykube.KubeConfig.from_file("~/.kube/config"))
    except Exception as e:
        raise RuntimeError(f"Failed to setup Kubernetes client: {e}")


# Load Job definition from a YAML file
def load_job_definition() -> dict:
    job_definition_path = os.getenv("JOB_DEFINITION_PATH", "./job_definition.yaml")
    if not job_definition_path:
        raise RuntimeError("Environment variable JOB_DEFINITION_PATH is not set.")
    if not os.path.exists(job_definition_path):
        raise RuntimeError(f"Job definition file not found at {job_definition_path}")

    with open(job_definition_path, "r") as f:
        return yaml.safe_load(f)


K8S_CLIENT = setup_k8s_client()
JOB_DEFINITION = load_job_definition()
JOB_IMAGE = os.environ.get(
    "JOB_IMAGE", "ghcr.io/andrewthetechie/home-k8s-pub/ansible_bootstrapper"
)
JOB_TAG = os.environ.get("JOB_TAG", "latest")
NAMESPACE = os.environ.get("NAMESPACE", "bootstrap-api")
BACKOFF_LIMIT = int(os.environ.get("BACKOFF_LIMIT", "5"))


@app.post("/bootstrap")
async def bootstrap(request: BootstrapRequest):
    # Get Kubernetes client and Job definition from app state
    job_definition = deepcopy(JOB_DEFINITION)

    try:
        request.roles.remove("ubuntu")
    except ValueError:
        pass
    # Customize the Job definition with request data
    job_name = f"{request.name}-bootstrap-job-{''.join(random.choice(string.ascii_uppercase + string.digits) for _ in range(8)).lower()}"
    job_definition["metadata"]["name"] = job_name
    job_definition["metadata"]["namespace"] = NAMESPACE
    job_definition["metadata"]["labels"] = {"role": "bootstrap"}
    job_definition["spec"]["backoffLimit"] = BACKOFF_LIMIT
    job_definition["spec"]["template"]["metadata"] = {"name": job_name}
    job_definition["spec"]["template"]["spec"]["containers"][0]["image"] = (
        f"{JOB_IMAGE}:{JOB_TAG}"
    )
    job_definition["spec"]["template"]["spec"]["containers"][0]["env"] = [
        {"name": "NAME", "value": request.name},
        {"name": "ROLES", "value": ",".join(request.roles)},
        {"name": "MAC", "value": str(request.mac)},
        {"name": "IP", "value": str(request.ip)},
    ]

    # Create the Kubernetes Job
    try:
        from pprint import pprint

        pprint(job_definition)
        job = Job(K8S_CLIENT, job_definition)
        job.create()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to create Job: {e}")

    return {"status": "success", "job_name": job_name}


@app.get("/healthz")
async def health_check():
    return {"status": "healthy"}
