"""Guestbook API: a small JSON API that runs on EKS and stores messages in DynamoDB.

AWS credentials come from EKS Pod Identity: boto3 finds them automatically through the
AWS_CONTAINER_CREDENTIALS_FULL_URI variable that the Pod Identity agent injects. No access
keys live in the image, the chart or any Kubernetes Secret.

Endpoints
  GET  /api/health     liveness/readiness probe (no AWS calls)
  GET  /api/info       which pod/node answered, app version, and the IAM role it runs as
  GET  /api/messages   latest messages (newest first)
  POST /api/messages   {"name": "...", "message": "..."}  → 201
"""
import json
import os
import socket
import time
import uuid
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from boto3.dynamodb.conditions import Key
from botocore.config import Config

TABLE_NAME = os.environ.get("TABLE_NAME", "guestbook")
APP_VERSION = os.environ.get("APP_VERSION", "dev")
GREETING = os.environ.get("GREETING", "Welcome to the EKS guestbook!")
PAGE_SIZE = int(os.environ.get("PAGE_SIZE", "20"))
PARTITION = "guestbook"   # single partition: fine for a lab, sorted by created time

_clients = {}
_identity = None

# The identity lookup is informational: fail fast instead of retrying for seconds
FAST = Config(connect_timeout=2, read_timeout=2, retries={"max_attempts": 1})


def aws(service, resource=False, config=None):
    """Create boto3 clients lazily and reuse them."""
    key = (service, resource)
    if key not in _clients:
        _clients[key] = (boto3.resource(service, config=config) if resource
                         else boto3.client(service, config=config))
    return _clients[key]


def table():
    return aws("dynamodb", resource=True).Table(TABLE_NAME)


def plain(value):
    if isinstance(value, list):
        return [plain(v) for v in value]
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    if isinstance(value, Decimal):
        return int(value)
    return value


def validate(data):
    if not isinstance(data, dict):
        return "Body must be a JSON object"
    for field, limit in (("name", 40), ("message", 280)):
        value = data.get(field)
        if not isinstance(value, str) or not value.strip():
            return f"'{field}' is required"
        if len(value) > limit:
            return f"'{field}' must be {limit} characters or fewer"
    return None


def list_messages():
    result = table().query(
        KeyConditionExpression=Key("pk").eq(PARTITION),
        ScanIndexForward=False,           # newest first
        Limit=PAGE_SIZE,
    )
    return [{k: v for k, v in item.items() if k != "pk"} for item in plain(result.get("Items", []))]


def add_message(data):
    item = {
        "pk": PARTITION,
        "created": int(time.time() * 1000),
        "id": uuid.uuid4().hex[:8],
        "name": data["name"].strip(),
        "message": data["message"].strip(),
        "pod": socket.gethostname(),
    }
    table().put_item(Item=item)
    return {k: v for k, v in item.items() if k != "pk"}


def aws_identity():
    """The IAM role this pod runs as (cached: it doesn't change for the pod's lifetime)."""
    global _identity
    if _identity is None:
        try:
            _identity = aws("sts", config=FAST).get_caller_identity()["Arn"]
        except Exception as err:  # noqa: BLE001 - show the reason instead of failing the page
            return f"unavailable ({type(err).__name__})"
    return _identity


def info():
    identity = aws_identity()
    return {
        "greeting": GREETING,
        "version": APP_VERSION,
        "pod": socket.gethostname(),
        "node": os.environ.get("NODE_NAME", "local"),
        "namespace": os.environ.get("POD_NAMESPACE", "local"),
        "awsIdentity": identity,
        "table": TABLE_NAME,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "guestbook-api"

    def send_json(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path == "/api/health":
            return self.send_json(200, {"status": "ok"})
        if path == "/api/info":
            return self.send_json(200, info())
        if path == "/api/messages":
            try:
                return self.send_json(200, list_messages())
            except Exception as err:  # noqa: BLE001
                return self.send_json(502, {"message": f"Could not read messages: {type(err).__name__}"})
        return self.send_json(404, {"message": "Not found"})

    def do_POST(self):
        if self.path.split("?")[0].rstrip("/") != "/api/messages":
            return self.send_json(404, {"message": "Not found"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self.send_json(400, {"message": "Body must be valid JSON"})
        error = validate(data)
        if error:
            return self.send_json(400, {"message": error})
        try:
            return self.send_json(201, add_message(data))
        except Exception as err:  # noqa: BLE001
            return self.send_json(502, {"message": f"Could not save message: {type(err).__name__}"})

    def log_message(self, fmt, *args):
        # One JSON line per request → easy to search in CloudWatch / kubectl logs
        print(json.dumps({"method": self.command, "path": self.path, "status": args[1] if len(args) > 1 else None,
                          "pod": socket.gethostname()}), flush=True)


def main():
    port = int(os.environ.get("PORT", "8080"))
    print(json.dumps({"event": "starting", "port": port, "version": APP_VERSION, "table": TABLE_NAME}), flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
