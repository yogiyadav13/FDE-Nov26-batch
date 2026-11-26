# Meridian Retail support-draft review tool

A small classroom demo with fictional data. For one support case it shows:

1. **SUPPLIED FACTS**: the case record from `cases.json`
2. **SUPPLIED POLICY**: the rules from `policy.md`
3. **DRAFT RESULT FOR HUMAN REVIEW**: a draft reply from Claude, checked for structure

The tool only drafts. It **never sends a message, approves a refund, or changes a record**. A human reviews every draft.

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python setup_env.py      # asks for the key with hidden input, writes .env
```

`setup_env.py` writes a project-only `.env` (permissions 600, git-ignored) containing:

- `APP_ANTHROPIC_API_KEY`: the key this app uses. The global `ANTHROPIC_API_KEY` is never read or set.
- `APP_ANTHROPIC_MODEL`: defaults to `claude-haiku-4-5-20251001`.

See `.env.example` for the format. Values set in the shell environment take priority over `.env`.

## Run

```bash
python app.py --case C1                     # live model call
python app.py --case C2 --simulate-timeout  # no API call; shows the safe unavailable state
python app.py --case C3 --offline-demo      # no API call; prerecorded synthetic result
```

Cases: C1 (damage reported within two days), C2 (delivery date missing), C3 (customer asks to confirm resolution, but the issue is still open).

## What the result means

The model must return JSON with exactly `draft_reply`, `evidence_refs` (policy IDs), `missing_information` (case field names) and `review_status` (`READY_FOR_HUMAN_REVIEW`, `NEEDS_INFORMATION` or `BLOCKED`). The app checks the keys, types and allowed values before showing anything.

**Correct structure does not prove correct content.** A well-formed draft can still be wrong, and the reviewer must check it against the facts and policy.

If the call times out, the provider errors, the key is missing or the response fails validation, the app shows `review_status: UNAVAILABLE` with an empty draft and a manual-fallback message. It never shows a traceback or a stale draft.

`--offline-demo` results come from `demo_outputs.json`. They were written by hand, are labelled synthetic, and no model produced them.

## Tests

```bash
python -m pytest -q
```

The tests use fake model functions and never call an external API.
