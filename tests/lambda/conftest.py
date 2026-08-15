import importlib.util
import os
import sys

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.fixture(autouse=True)
def aws_credentials():
    """Fake credentials so boto3 never tries a real network call, and a
    region so client construction doesn't fail — moto intercepts the actual
    API calls regardless of what's "configured" here."""
    os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
    os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
    os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
    os.environ.setdefault("AWS_SESSION_TOKEN", "testing")
    os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")


def _load_handler_module(unique_name: str, function_dir: str):
    """Load a Lambda function's handler.py under a unique module name.

    Every function in src/lambda/*/ names its file `handler.py`, which is
    correct and expected for independent Lambda deployment packages — but
    it means a plain `import handler` from two different test files would
    collide in sys.modules and silently return the wrong function's module.
    Loading each one under a distinct name (e.g. "validate_handler_module")
    sidesteps that without renaming the actual Lambda source files.
    """
    handler_path = os.path.join(REPO_ROOT, "src", "lambda", function_dir, "handler.py")
    spec = importlib.util.spec_from_file_location(unique_name, handler_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[unique_name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def validate_handler():
    return _load_handler_module("validate_handler_module", "validate")


@pytest.fixture
def database_handler(monkeypatch):
    monkeypatch.setenv("TABLE_NAME", "test-jobs-table")
    return _load_handler_module("database_handler_module", "database")


TEST_STATE_MACHINE_ARN = "arn:aws:states:us-east-1:123456789012:stateMachine:test-pipeline"


@pytest.fixture
def trigger_handler(monkeypatch):
    # 123456789012 is moto's default fake account ID -- a real state machine
    # created inside a test's own `with mock_aws():` block (see
    # tests/lambda/test_trigger.py) using this same name/region gets this
    # exact ARN, so the module-level STATE_MACHINE_ARN this fixture sets at
    # import time lines up with what moto actually creates.
    monkeypatch.setenv("STATE_MACHINE_ARN", TEST_STATE_MACHINE_ARN)
    return _load_handler_module("trigger_handler_module", "trigger")


@pytest.fixture
def web_api_handler(monkeypatch):
    monkeypatch.setenv("MEDIA_BUCKET", "test-media-bucket")
    monkeypatch.setenv("STATE_MACHINE_ARN", TEST_STATE_MACHINE_ARN)
    return _load_handler_module("web_api_handler_module", "web_api")
