#!/usr/bin/env python3
"""Meridian Retail support-draft review tool (fictional classroom demo).

Produces a draft reply for HUMAN REVIEW only. This tool never sends a
message, approves a refund, or changes a record.

Usage:
    python app.py --case C1
    python app.py --case C2 --simulate-timeout
    python app.py --case C3 --offline-demo
"""

import argparse
import json
import os
import sys
from pathlib import Path

from dotenv import dotenv_values

APP_DIR = Path(__file__).resolve().parent
CASES_PATH = APP_DIR / "cases.json"
POLICY_PATH = APP_DIR / "policy.md"
DEMO_PATH = APP_DIR / "demo_outputs.json"
ENV_PATH = APP_DIR / ".env"

DEFAULT_MODEL = "claude-haiku-4-5-20251001"
VALID_CASES = ("C1", "C2", "C3")
POLICY_IDS = ("P1", "P2", "P3", "P4")
REVIEW_STATUSES = ("READY_FOR_HUMAN_REVIEW", "NEEDS_INFORMATION", "BLOCKED")
UNAVAILABLE = "UNAVAILABLE"
RESULT_KEYS = {"draft_reply", "evidence_refs", "missing_information", "review_status"}
CASE_FIELDS = (
    "case_id",
    "order_id",
    "product",
    "customer_question",
    "delivery_date",
    "issue_status",
    "issue_details",
)
FALLBACK_MESSAGE = (
    "MANUAL FALLBACK: No model draft is available. A human agent must handle "
    "this case manually using the supplied facts and policy."
)
OFFLINE_NOTICE = (
    "OFFLINE DEMO: No model API was called. The result below is a prerecorded "
    "synthetic example loaded from demo_outputs.json."
)
MISSING_DELIVERY_DATE_REPLY = (
    "Before Meridian Retail can assess whether this case falls within the "
    "two-day damage-reporting rule, please provide the delivery date. A human "
    "support agent will review the request once that information is available."
)
SAFETY_FOOTER = (
    "No message was sent, no refund was approved, and no record was changed."
)

SYSTEM_PROMPT = """\
You draft customer-support replies for Meridian Retail, a fictional company. \
A human agent reviews every draft before anything happens.

Rules:
- Use ONLY the supplied case facts and the supplied policy. Do not invent facts, dates, or policies.
- You cannot approve refunds, send messages, or change records, and the draft must not claim that any of these happened.
- If issue_status is open, the draft must not say the issue is resolved.

Respond with ONLY a JSON object and no other text. It must have exactly these keys:
- "draft_reply": string, the draft reply to the customer.
- "evidence_refs": array of policy IDs (from P1, P2, P3, P4) that the draft relies on.
- "missing_information": array of case field names whose values are needed but missing; empty if none.
- "review_status": one of "READY_FOR_HUMAN_REVIEW", "NEEDS_INFORMATION", "BLOCKED".
Use NEEDS_INFORMATION when required information is missing, and BLOCKED when a reply cannot be drafted within the policy."""


class ModelOutputError(ValueError):
    """The model response could not be used."""


# ---------------------------------------------------------------- inputs

def load_case(case_id, path=CASES_PATH):
    if case_id not in VALID_CASES:
        raise ValueError(f"Unknown case {case_id!r}; expected one of {', '.join(VALID_CASES)}")
    cases = json.loads(Path(path).read_text(encoding="utf-8"))
    return cases[case_id]


def load_policy(path=POLICY_PATH):
    return Path(path).read_text(encoding="utf-8")


def get_config(environ=None, env_path=ENV_PATH):
    """Return (api_key, model) from APP_* variables only.

    The process environment wins over the project .env file. The global
    ANTHROPIC_API_KEY is never read or set.
    """
    environ = os.environ if environ is None else environ
    env_path = Path(env_path)
    file_values = dotenv_values(env_path) if env_path.exists() else {}
    key = environ.get("APP_ANTHROPIC_API_KEY") or file_values.get("APP_ANTHROPIC_API_KEY") or ""
    model = environ.get("APP_ANTHROPIC_MODEL") or file_values.get("APP_ANTHROPIC_MODEL") or DEFAULT_MODEL
    return key.strip(), model.strip()


# ---------------------------------------------------------------- model

def build_prompt(case, policy):
    """Return (system, user) prompt text."""
    user = (
        "SUPPLIED FACTS (JSON):\n"
        f"{json.dumps(case, indent=2)}\n\n"
        "SUPPLIED POLICY:\n"
        f"{policy.strip()}\n\n"
        "Return only the JSON object."
    )
    return SYSTEM_PROMPT, user


def make_anthropic_model_fn(api_key, model):
    """Return a function (system, user) -> response text that calls Claude."""
    from anthropic import Anthropic

    client = Anthropic(api_key=api_key, timeout=20.0, max_retries=0)

    def call(system, user):
        response = client.messages.create(
            model=model,
            max_tokens=2048,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
        if response.stop_reason != "end_turn":
            raise ModelOutputError(f"unexpected stop_reason {response.stop_reason!r}")
        return "".join(block.text for block in response.content if block.type == "text")

    return call


def _strip_code_fence(text):
    text = text.strip()
    if text.startswith("```") and text.endswith("```"):
        text = text[3:-3].strip()
        if text.lower().startswith("json"):
            text = text[4:].strip()
    return text


def _is_str_list(value):
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def validate_result(raw, case=None):
    """Check structure, types, and allowed values. Raises ModelOutputError.

    Passing validation proves the shape is right, not that the content is.
    """
    if isinstance(raw, str):
        try:
            data = json.loads(_strip_code_fence(raw))
        except json.JSONDecodeError as exc:
            raise ModelOutputError("response is not valid JSON") from exc
    else:
        data = raw
    if not isinstance(data, dict):
        raise ModelOutputError("response is not a JSON object")
    if set(data) != RESULT_KEYS:
        raise ModelOutputError(f"response keys {sorted(data)} != {sorted(RESULT_KEYS)}")
    if not isinstance(data["draft_reply"], str):
        raise ModelOutputError("draft_reply must be a string")
    if not _is_str_list(data["evidence_refs"]):
        raise ModelOutputError("evidence_refs must be a list of strings")
    unknown_refs = [ref for ref in data["evidence_refs"] if ref not in POLICY_IDS]
    if unknown_refs:
        raise ModelOutputError(f"unknown policy IDs: {unknown_refs}")
    if not _is_str_list(data["missing_information"]):
        raise ModelOutputError("missing_information must be a list of strings")
    allowed_fields = tuple(case) if case else CASE_FIELDS
    unknown_fields = [f for f in data["missing_information"] if f not in allowed_fields]
    if unknown_fields:
        raise ModelOutputError(f"unknown field names: {unknown_fields}")
    if data["review_status"] not in REVIEW_STATUSES:
        raise ModelOutputError(f"invalid review_status {data['review_status']!r}")
    return {key: data[key] for key in ("draft_reply", "evidence_refs", "missing_information", "review_status")}


def unavailable_result(reason):
    return {
        "draft_reply": "",
        "evidence_refs": [],
        "missing_information": [],
        "review_status": UNAVAILABLE,
        "reason": reason,
    }


def has_delivery_date(case):
    value = case.get("delivery_date")
    return isinstance(value, str) and value.strip() != ""


def missing_delivery_date_result():
    """Deterministic result used instead of a model call (policy P2, P4)."""
    return {
        "draft_reply": MISSING_DELIVERY_DATE_REPLY,
        "evidence_refs": ["P2", "P4"],
        "missing_information": ["delivery_date"],
        "review_status": "NEEDS_INFORMATION",
    }


def load_demo_result(case_id, case, path=DEMO_PATH):
    demo = json.loads(Path(path).read_text(encoding="utf-8"))
    if demo.get("synthetic") is not True:
        raise ModelOutputError("demo_outputs.json is not labelled synthetic")
    return validate_result(demo["results"][case_id], case)


# ---------------------------------------------------------------- output

def _heading(title):
    print()
    print("=" * 64)
    print(title)
    print("=" * 64)


def print_facts(case):
    _heading("SUPPLIED FACTS")
    for field in CASE_FIELDS:
        value = case.get(field)
        print(f"{field}: {'(missing)' if value is None else value}")


def print_policy(policy):
    _heading("SUPPLIED POLICY")
    print(policy.strip())


def print_result(result):
    _heading("DRAFT RESULT FOR HUMAN REVIEW")
    print(f"review_status: {result['review_status']}")
    if result["review_status"] == UNAVAILABLE:
        print("draft_reply: (cleared)")
        print(f"reason: {result['reason']}")
        print(FALLBACK_MESSAGE)
    else:
        print(f"evidence_refs: {', '.join(result['evidence_refs']) or '(none)'}")
        print(f"missing_information: {', '.join(result['missing_information']) or '(none)'}")
        print("draft_reply:")
        print(f"  {result['draft_reply']}")
        print()
        print("NOTE: Structure was validated; content was NOT. A human must check")
        print("the draft against the supplied facts and policy before using it.")
    print()
    print(SAFETY_FOOTER)


# ---------------------------------------------------------------- main flow

def run(case_id, simulate_timeout=False, offline_demo=False, model_fn=None):
    case = load_case(case_id)
    policy = load_policy()
    print_facts(case)
    print_policy(policy)

    if simulate_timeout:
        result = unavailable_result("Simulated provider timeout. No API call was made.")
    elif offline_demo:
        print()
        print(OFFLINE_NOTICE)
        try:
            result = load_demo_result(case_id, case)
        except Exception as exc:  # any bad demo file -> safe state
            result = unavailable_result(f"Offline demo output unusable ({type(exc).__name__}).")
    elif not has_delivery_date(case):
        # P2: the two-day rule cannot be applied; never call the model.
        result = missing_delivery_date_result()
    else:
        result = None
        try:
            if model_fn is None:
                api_key, model = get_config()
                if not api_key:
                    result = unavailable_result(
                        "APP_ANTHROPIC_API_KEY is not set. Run: python setup_env.py"
                    )
                else:
                    model_fn = make_anthropic_model_fn(api_key, model)
            if result is None:
                system, user = build_prompt(case, policy)
                result = validate_result(model_fn(system, user), case)
        except ModelOutputError as exc:
            result = unavailable_result(f"Model response rejected: {exc}.")
        except Exception as exc:  # provider/network failure -> safe state, no traceback
            result = unavailable_result(f"Model call failed ({type(exc).__name__}).")

    print_result(result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description="Meridian Retail support-draft review tool (demo).")
    parser.add_argument("--case", required=True, choices=VALID_CASES)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--simulate-timeout", action="store_true",
                      help="Show the unavailable state without calling any API.")
    mode.add_argument("--offline-demo", action="store_true",
                      help="Show a prerecorded synthetic result without calling any API.")
    args = parser.parse_args(argv)
    run(args.case, simulate_timeout=args.simulate_timeout, offline_demo=args.offline_demo)
    return 0


if __name__ == "__main__":
    sys.exit(main())
