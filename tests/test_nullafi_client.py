import pytest
import requests

from src.nullafi_client import NullafiAPIError, NullafiClient, NullafiConfig


class FakeResponse:
    def __init__(self, status_code, body):
        self.status_code = status_code
        self._body = body
        self.text = str(body)

    def json(self):
        if isinstance(self._body, Exception):
            raise self._body
        return self._body


class FakeSession:
    def __init__(self, response=None, exception=None):
        self.response = response
        self.exception = exception
        self.calls = []

    def post(self, *args, **kwargs):
        self.calls.append({"args": args, "kwargs": kwargs})
        if self.exception:
            raise self.exception
        return self.response


def make_config() -> NullafiConfig:
    return NullafiConfig(
        api_key="test-key",
        namespace="dlp test",
        base_url="https://api.example.test",
        username="local-user",
        usergroup="engineering",
    )


def test_scan_sends_expected_auth_params_and_payload() -> None:
    session = FakeSession(response=FakeResponse(200, {"ssn": "***-**-8348"}))
    client = NullafiClient(make_config(), session=session)

    response = client.scan({"ssn": "122-12-8348"})

    assert response == {"ssn": "***-**-8348"}
    call = session.calls[0]
    assert call["args"] == ("https://api.example.test/scan",)
    assert call["kwargs"]["headers"]["Authorization"] == "Bearer test-key"
    assert call["kwargs"]["params"] == {
        "namespace": "dlp test",
        "username": "local-user",
        "usergroup": "engineering",
    }
    assert call["kwargs"]["json"] == {"ssn": "122-12-8348"}


def test_scan_raises_clear_error_for_forbidden_response() -> None:
    session = FakeSession(response=FakeResponse(403, {"message": "missing right"}))
    client = NullafiClient(make_config(), session=session)

    with pytest.raises(NullafiAPIError, match="not authorized for scanning") as exc:
        client.scan({"ssn": "122-12-8348"})

    assert exc.value.status_code == 403
    assert exc.value.response_body == {"message": "missing right"}


def test_scan_raises_for_timeout() -> None:
    session = FakeSession(exception=requests.Timeout("slow"))
    client = NullafiClient(make_config(), session=session)

    with pytest.raises(NullafiAPIError, match="timed out"):
        client.scan({"ssn": "122-12-8348"})


def test_scan_requires_json_object_response() -> None:
    session = FakeSession(response=FakeResponse(200, ["not", "an", "object"]))
    client = NullafiClient(make_config(), session=session)

    with pytest.raises(NullafiAPIError, match="not a JSON object"):
        client.scan({"ssn": "122-12-8348"})
