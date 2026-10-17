"""Tests for the guestbook API: runs the real HTTP server against moto's fake DynamoDB.

Run:  pip install -r requirements-dev.txt && pytest -v
"""
import importlib.util
import json
import os
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import boto3
import pytest
from moto import mock_aws

os.environ.update(AWS_DEFAULT_REGION="us-east-1", AWS_ACCESS_KEY_ID="testing",
                  AWS_SECRET_ACCESS_KEY="testing", TABLE_NAME="guestbook-test", PAGE_SIZE="3")

spec = importlib.util.spec_from_file_location(
    "guestbook_app", os.path.join(os.path.dirname(__file__), "..", "services", "api", "app.py"))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


@pytest.fixture
def base_url():
    with mock_aws():
        boto3.client("dynamodb").create_table(
            TableName="guestbook-test",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"},
                       {"AttributeName": "created", "KeyType": "RANGE"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"},
                                  {"AttributeName": "created", "AttributeType": "N"}],
            BillingMode="PAY_PER_REQUEST",
        )
        app._clients.clear()
        app._identity = None
        server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        yield f"http://127.0.0.1:{server.server_port}"
        server.shutdown()


def request(url, method="GET", body=None):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as res:
            return res.status, json.loads(res.read())
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read())


def test_health(base_url):
    assert request(f"{base_url}/api/health") == (200, {"status": "ok"})


def test_post_then_list_newest_first(base_url):
    for i in range(4):
        status, msg = request(f"{base_url}/api/messages", "POST", {"name": f"user{i}", "message": f"hi {i}"})
        assert status == 201 and msg["name"] == f"user{i}" and "pk" not in msg
        app.time.sleep(0.002)
    status, messages = request(f"{base_url}/api/messages")
    assert status == 200
    assert [m["name"] for m in messages] == ["user3", "user2", "user1"]   # PAGE_SIZE=3


def test_input_is_trimmed(base_url):
    _, msg = request(f"{base_url}/api/messages", "POST", {"name": "  Ama ", "message": " hello  "})
    assert (msg["name"], msg["message"]) == ("Ama", "hello")


@pytest.mark.parametrize("body", [{}, {"name": "x"}, {"name": " ", "message": "x"},
                                  {"name": "x" * 41, "message": "x"}, {"name": "x", "message": "y" * 281},
                                  [1, 2], b"not json"])
def test_validation(base_url, body):
    status, err = request(f"{base_url}/api/messages", "POST", body)
    assert status == 400 and "message" in err


def test_info_reports_identity(base_url):
    status, info = request(f"{base_url}/api/info")
    assert status == 200
    assert info["awsIdentity"].startswith("arn:aws:sts::")    # moto's fake caller identity
    assert info["table"] == "guestbook-test"


def test_unknown_routes(base_url):
    assert request(f"{base_url}/api/nope")[0] == 404
    assert request(f"{base_url}/api/health", "POST", {})[0] == 404
