"""
start_server.py — triggered by CloudWatch Logs when a DNS query for the
Minecraft domain is detected. Starts the EC2 instance if it is not already
running.
"""

import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _log(event: str, **kwargs) -> None:
    logger.info(json.dumps({"event": event, **kwargs}))


def handler(event, context):
    # Use os.environ['KEY'] — raises KeyError immediately if missing.
    # Never use os.environ.get('KEY', default): it hides misconfiguration.
    instance_id = os.environ["INSTANCE_ID"]
    region = os.environ["AWS_REGION_TARGET"]

    ec2 = boto3.client("ec2", region_name=region)

    try:
        response = ec2.describe_instances(InstanceIds=[instance_id])
    except ClientError as e:
        _log("describe_instances_failed", instance_id=instance_id, error=str(e))
        raise

    reservations = response.get("Reservations", [])
    if not reservations:
        _log("instance_not_found", instance_id=instance_id)
        raise RuntimeError(f"Instance {instance_id} not found")

    state = reservations[0]["Instances"][0]["State"]["Name"]
    _log("instance_state", instance_id=instance_id, state=state)

    if state in ("running", "pending"):
        _log("already_running", instance_id=instance_id, state=state)
        return {"statusCode": 200, "body": f"Instance already {state}"}

    if state == "stopping":
        # Race condition: instance is mid-stop. Log and return — the next DNS
        # query (Minecraft retries) will trigger us again once it's stopped.
        _log("instance_stopping", instance_id=instance_id)
        return {"statusCode": 200, "body": "Instance stopping, will retry on next query"}

    try:
        ec2.start_instances(InstanceIds=[instance_id])
        _log("instance_started", instance_id=instance_id)
    except ClientError as e:
        _log("start_failed", instance_id=instance_id, error=str(e))
        raise

    return {"statusCode": 200, "body": f"Started {instance_id}"}
