"""Tests for app.py. No test calls an external API."""

import json

import pytest

import app

C1_GOOD = {
    "draft_reply": "We have referred your jacket for a return review.",
    "evidence_refs": ["P1"],
    "missing_information": [],
    "review_status": "READY_FOR_HUMAN_REVIEW",
}


def fake_model(payload):
    calls = []

    def model_fn(system, user):
        calls.append((system, user))
        return payload if isinstance(payload, str) else json.dumps(payload)

    model_fn.calls = calls
    return model_fn


@pytest.fixture
def no_real_client(monkeypatch):
    """Fail loudly (and record) if anything tries to build a real client."""
    built = []

    def forbidden(*args, **kwargs):
        built.append((args, kwargs))
        raise AssertionError("real Anthropic client must not be created")

    monkeypatch.setattr(app, "make_anthropic_model_fn", forbidden)
    return built


# ------------------------------------------------------------ success

def test_c1_success_prints_sections_and_draft(capsys):
    model_fn = fake_model(C1_GOOD)
    result = app.run("C1", model_fn=model_fn)
    out = capsys.readouterr().out

    assert result == C1_GOOD
    for section in ("SUPPLIED FACTS", "SUPPLIED POLICY", "DRAFT RESULT FOR HUMAN REVIEW"):
        assert section in out
    assert C1_GOOD["draft_reply"] in out
    assert "READY_FOR_HUMAN_REVIEW" in out
    assert "content was NOT" in out
    assert app.SAFETY_FOOTER in out


def test_prompt_contains_only_supplied_facts_and_policy():
    model_fn = fake_model(C1_GOOD)
    app.run("C1", model_fn=model_fn)
    system, user = model_fn.calls[0]
    assert "ONLY the supplied case facts" in system
    assert "MR-1042" in user and "P4." in user


def test_code_fenced_json_is_accepted(capsys):
    fenced = "```json\n" + json.dumps(C1_GOOD) + "\n```"
    assert app.run("C1", model_fn=fake_model(fenced)) == C1_GOOD


# ------------------------------------------------------------ invalid output

INVALID_OUTPUTS = {
    "not json": "Sure! Here is your draft.",
    "json list": [C1_GOOD],
    "missing key": {k: v for k, v in C1_GOOD.items() if k != "review_status"},
    "extra key": {**C1_GOOD, "refund_approved": True},
    "draft not string": {**C1_GOOD, "draft_reply": 42},
    "refs not list": {**C1_GOOD, "evidence_refs": "P1"},
    "unknown policy id": {**C1_GOOD, "evidence_refs": ["P9"]},
    "missing info not list": {**C1_GOOD, "missing_information": None},
    "unknown field name": {**C1_GOOD, "missing_information": ["credit_card"]},
    "bad status": {**C1_GOOD, "review_status": "REFUND_APPROVED"},
}


@pytest.mark.parametrize("label", INVALID_OUTPUTS)
def test_invalid_model_output_gives_unavailable(label, capsys):
    payload = INVALID_OUTPUTS[label]
    if isinstance(payload, list):
        payload = json.dumps(payload)
    result = app.run("C1", model_fn=fake_model(payload))
    out = capsys.readouterr().out

    assert result["review_status"] == app.UNAVAILABLE
    assert result["draft_reply"] == ""
    assert app.FALLBACK_MESSAGE in out
    assert "Traceback" not in out


def test_provider_error_gives_unavailable_without_traceback(capsys):
    def broken(system, user):
        raise ConnectionError("provider down")

    result = app.run("C1", model_fn=broken)
    out = capsys.readouterr().out
    assert result["review_status"] == app.UNAVAILABLE
    assert result["draft_reply"] == ""
    assert app.FALLBACK_MESSAGE in out
    assert "Traceback" not in out and "provider down" not in out


def test_missing_key_gives_unavailable_without_client(monkeypatch, no_real_client, capsys):
    monkeypatch.setattr(app, "get_config", lambda: ("", app.DEFAULT_MODEL))
    result = app.run("C1")
    assert result["review_status"] == app.UNAVAILABLE
    assert "setup_env.py" in capsys.readouterr().out
    assert no_real_client == []


# ------------------------------------------------------------ timeout

def test_simulate_timeout_makes_no_call(no_real_client, capsys):
    assert app.main(["--case", "C1", "--simulate-timeout"]) == 0
    out = capsys.readouterr().out
    assert no_real_client == []
    assert "review_status: UNAVAILABLE" in out
    assert "draft_reply: (cleared)" in out
    assert app.FALLBACK_MESSAGE in out


def test_simulate_timeout_ignores_model_fn(capsys):
    model_fn = fake_model(C1_GOOD)
    result = app.run("C1", simulate_timeout=True, model_fn=model_fn)
    assert model_fn.calls == []
    assert result["draft_reply"] == ""
    assert C1_GOOD["draft_reply"] not in capsys.readouterr().out


# ------------------------------------------------------------ offline demo

@pytest.mark.parametrize("case_id", app.VALID_CASES)
def test_offline_demo_makes_no_call(case_id, no_real_client, capsys):
    assert app.main(["--case", case_id, "--offline-demo"]) == 0
    out = capsys.readouterr().out
    assert no_real_client == []
    assert "No model API was called" in out
    assert "synthetic" in out
    assert "UNAVAILABLE" not in out


def test_demo_outputs_are_labelled_and_valid():
    demo = json.loads(app.DEMO_PATH.read_text(encoding="utf-8"))
    assert demo["synthetic"] is True
    assert "SYNTHETIC" in demo["_label"]
    assert set(demo["results"]) == set(app.VALID_CASES)
    for case_id in app.VALID_CASES:
        app.validate_result(demo["results"][case_id], app.load_case(case_id))


def test_demo_outputs_follow_policy():
    results = json.loads(app.DEMO_PATH.read_text(encoding="utf-8"))["results"]
    assert results["C2"]["review_status"] == "NEEDS_INFORMATION"
    assert results["C2"]["missing_information"] == ["delivery_date"]
    assert "resolved" not in results["C3"]["draft_reply"].replace("not able to confirm that the issue is resolved", "")


# ------------------------------------------------------------ input files

def test_cases_file():
    cases = json.loads(app.CASES_PATH.read_text(encoding="utf-8"))
    assert set(cases) == {"C1", "C2", "C3"}
    for case_id, case in cases.items():
        assert tuple(case) == app.CASE_FIELDS
        assert case["case_id"] == case_id
        assert case["issue_status"] == "open"
    assert cases["C2"]["delivery_date"] is None


def test_policy_file():
    policy = app.load_policy()
    for policy_id in app.POLICY_IDS:
        assert f"{policy_id}." in policy


def test_unknown_case_rejected():
    with pytest.raises(SystemExit):
        app.main(["--case", "C9"])
    with pytest.raises(ValueError):
        app.load_case("C9")


# ------------------------------------------------------------ config & client

def test_config_uses_app_variables_only(tmp_path):
    missing = tmp_path / "no.env"
    assert app.get_config({"ANTHROPIC_API_KEY": "global"}, missing) == ("", app.DEFAULT_MODEL)
    env = {"APP_ANTHROPIC_API_KEY": "app-key", "APP_ANTHROPIC_MODEL": "m"}
    assert app.get_config(env, missing) == ("app-key", "m")


def test_config_reads_project_env_file(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("APP_ANTHROPIC_API_KEY=file-key\n")
    assert app.get_config({}, env_file) == ("file-key", app.DEFAULT_MODEL)


def test_client_built_with_explicit_key_timeout_and_no_retries(monkeypatch):
    import anthropic

    captured = {}

    class FakeBlock:
        type = "text"
        text = json.dumps(C1_GOOD)

    class FakeResponse:
        stop_reason = "end_turn"
        content = [FakeBlock()]

    class FakeAnthropic:
        def __init__(self, **kwargs):
            captured["init"] = kwargs
            self.messages = self

        def create(self, **kwargs):
            captured["create"] = kwargs
            return FakeResponse()

    monkeypatch.setattr(anthropic, "Anthropic", FakeAnthropic)
    model_fn = app.make_anthropic_model_fn("app-key", "some-model")
    text = model_fn("sys", "user")

    assert captured["init"] == {"api_key": "app-key", "timeout": 20.0, "max_retries": 0}
    assert captured["create"]["model"] == "some-model"
    assert app.validate_result(text) == C1_GOOD


# ------------------------------------------------------------ missing delivery date

C2_EXPECTED = {
    "draft_reply": (
        "Before Meridian Retail can assess whether this case falls within the "
        "two-day damage-reporting rule, please provide the delivery date. A human "
        "support agent will review the request once that information is available."
    ),
    "evidence_refs": ["P2", "P4"],
    "missing_information": ["delivery_date"],
    "review_status": "NEEDS_INFORMATION",
}


def test_c2_missing_delivery_date_never_calls_model(no_real_client, capsys):
    calls = []

    def must_not_be_called(system, user):
        calls.append((system, user))
        raise AssertionError("model must not be called when delivery_date is missing")

    result = app.run("C2", model_fn=must_not_be_called)
    out = capsys.readouterr().out

    assert calls == []
    assert no_real_client == []
    assert result == C2_EXPECTED
    assert C2_EXPECTED["draft_reply"] in out
    assert "review_status: NEEDS_INFORMATION" in out
    assert "UNAVAILABLE" not in out


@pytest.mark.parametrize("value", [None, "", "   "])
def test_empty_delivery_date_detected(value):
    assert not app.has_delivery_date({"delivery_date": value})
    assert not app.has_delivery_date({})
    assert app.has_delivery_date({"delivery_date": "2026-09-12"})
