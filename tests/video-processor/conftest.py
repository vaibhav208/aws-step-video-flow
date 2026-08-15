import importlib.util
import os
import sys

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.fixture(autouse=True)
def aws_credentials():
    os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
    os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
    os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
    os.environ.setdefault("AWS_SESSION_TOKEN", "testing")
    os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")


@pytest.fixture
def main_module():
    """Load app/main.py fresh for each test so module-level state (none
    currently, but defensive) and RESOLUTION_PRESETS edits in a test don't
    leak between tests."""
    path = os.path.join(REPO_ROOT, "src", "video-processor", "app", "main.py")
    spec = importlib.util.spec_from_file_location("video_processor_main", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["video_processor_main"] = module
    spec.loader.exec_module(module)
    return module
