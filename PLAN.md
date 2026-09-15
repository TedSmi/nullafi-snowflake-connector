Goal:
Over the course of ~1 week, develop something that's up on my github with clear, explicit coding style and lots of comments to help someone understand the code, as well as a good readme.

Product: 
Snowflake-native Nullafi integration that can be dropped into a data pipeline to automatically send data through Nullafi for sensitive-data detection and protection before the data continues through the pipeline.

# Nullafi ↔ Snowflake Drop-In Connector — Detailed Build Plan

A Snowflake-native integration that pushes data through Nullafi for sensitive-data
detection/protection before it continues through a pipeline. This plan covers
Phases 0–6 (Phase 7, a Snowflake Native App, is intentionally out of scope for now —
see the Roadmap note at the end).

**How to use this doc:** work top to bottom. Each phase ends with a "Commit to
GitHub" step — don't skip it, even if it feels like a small increment. Checkboxes
are there so you can track progress as you go.

---

## Cross-cutting practices (apply throughout, not just once)

- [ ] **Never commit secrets.** Set up `.gitignore` *before* your first line of code
  (Phase 0.3). API keys live in Snowflake Secrets or local env vars, never in code
  or sample config files.
- [ ] **Test before you commit.** Every phase has explicit test/validation steps —
  don't push code that hasn't passed them.
- [ ] **Update the README incrementally.** Don't save all documentation for the end;
  each phase has a "what changed" doc step so the README always reflects what
  actually works right now.
- [ ] **Comment for a stranger.** Write comments assuming the reader has never seen
  Nullafi or this codebase — explain *why*, not just *what*.
- [ ] **Small, descriptive commits.** One logical change per commit, with a message
  that explains the change, not just "update."

---

## Phase 0 — Research & Setup

Nothing gets built until you know what you're integrating with and what you're
building toward. Skipping this phase is the most common reason projects like this
get reworked halfway through.

- [x] **0.1 — Research the Nullafi API.** Get API access/credentials. Read whatever
  docs exist. If docs are thin, test manually with `curl` or Postman first. Note:
  auth method, request/response format for `/api/scan`, rate limits, max payload
  size, error response format, and whether batch requests are supported. Write
  these findings down — you'll need them in Phase 3.
- [x] **0.2 — Set up local dev environment.** Python virtual environment, install
  `requests` and the Snowflake connector/Snowpark libraries you'll need. Confirm
  Python version compatibility with Snowflake's Python stored procedure runtime.
- [x] **0.3 — Create the GitHub repo.** Initialize with a `.gitignore` (Python +
  secrets/env files), a `LICENSE`, and a stub `README.md` (project name, one-line
  description, "Status: in progress"). **First commit.**
- [x] **0.4 — Design the data schema.** Before writing pipeline code, decide:
  - What does the **input table** look like (which columns get scanned)?
  - What does the **output table** look like (original data + detected entity
    types + redacted/tokenized values + scan metadata like timestamp and
    confidence)?
  - How do you handle nulls, non-string columns, and oversized fields?
  Write this into a `DESIGN.md`. This prevents reworking Phases 2–5 later.
- [x] **0.5 — Decide the configuration approach up front.** How will table names,
  column lists, and the API key be parameterized so this isn't hardcoded to your
  test setup? (e.g., a config table in Snowflake, session variables, or a setup
  script with parameters.) You don't have to build this yet — just decide the
  pattern now so Phases 2–5 follow it consistently instead of retrofitting in
  Phase 6.
- [x] **0.6 — Commit** `DESIGN.md`, `.gitignore`, and repo skeleton.

---

## Phase 1 — Local Proof-of-Concept Script

Goal: prove the Nullafi API behaves the way you think it does, on your own
machine, before touching Snowflake at all.

**Phase 1 closeout status:** local code, docs, and unit tests are complete. A
live curl request confirmed the endpoint/auth/namespace path and showed activity
in the Nullafi dashboard. The dashboard detected the SSN, but the event showed
`Rule: (None)`, so true obfuscation is blocked by dashboard rule setup rather
than by the local client code. The exact obfuscated response shape, rate limits,
and max payload behavior are carried forward until an active rule is attached.

- [x] **1.1 — Create fake sensitive test data.** A small CSV/JSON with synthetic
  emails, SSNs, credit card numbers, names, etc. Comment on *why* each field was
  included (what it's meant to test).
- [x] **1.2 — Write a function to read the fake data.**
- [x] **1.3 — Write a function to call Nullafi `/api/scan`.** Include proper auth,
  and explicit handling for timeouts, 4xx, and 5xx responses (don't let it just
  crash on a bad response).
- [x] **1.4 — Write a function to parse the response** into the shape you'll
  actually use downstream (detected entities, redacted value, confidence, etc.).
- [x] **1.5 — Write verification/assertions.** Confirm known-sensitive fields
  (e.g., the SSN you planted) are actually flagged. This is your first real test,
  not just a manual "looks right" check.
- [x] **1.6 — Add structured logging** (not print statements) with clear levels
  (info/warning/error).
- [x] **1.7 — Document API findings.** Add a section to `DESIGN.md` on rate
  limits, batching support, and payload limits discovered here — this directly
  shapes Phase 3's batching logic.
- [x] **1.8 — Test:** run the full script end to end against the fake dataset,
  confirm all planted sensitive fields are detected and nothing throws unhandled
  exceptions.
- [x] **1.9 — Update README** with a "Phase 1: Local POC" section — what it does,
  how to run it, what output to expect.
- [ ] **1.10 — Commit to GitHub.**

Notes on the checked Phase 1 items:
- `1.5`/`1.8`: the local assertion path exists and unit tests pass. The live
  strict run is expected to fail until Nullafi dashboard rule setup changes
  `Rule: (None)` to an active obfuscation rule.
- `1.7`: rate-limit and max-payload results are documented as intentionally
  deferred because meaningful measurements should happen after the rule path is
  configured.
- `1.10`: ready for the user to run the git commands at the end of Phase 1.

---

## Phase 2 — Snowflake Connectivity

Goal: prove Snowflake can reach Nullafi at all, in isolation, before building any
real pipeline logic. This is usually the trickiest part of the whole project —
give it real time.

- [ ] **2.1 — Research the Snowflake concepts you'll need:** Network Rules,
  External Access Integrations, Snowflake Secrets, and Python stored procedures
  (vs. UDFs — stored procs are the right fit here since you're doing I/O with
  side effects). Note the exact SQL DDL syntax for each.
- [ ] **2.2 — Create a Network Rule** allowing egress to Nullafi's API domain.
- [ ] **2.3 — Create a Snowflake Secret** storing the Nullafi API key. Confirm it
  never appears in query history or logs in plaintext.
- [ ] **2.4 — Create an External Access Integration** binding the network rule and
  secret together.
- [ ] **2.5 — Write a minimal Python stored procedure** that calls Nullafi for a
  single hardcoded test value, just to prove the full chain works: Snowflake →
  External Access Integration → Nullafi → response back into Snowflake.
- [ ] **2.6 — Test:** run the procedure via SQL, confirm the expected response,
  confirm the secret is never exposed in output or error messages.
- [ ] **2.7 — Write `SETUP.md`** documenting the exact SQL to create the network
  rule, secret, and integration — this is the part anyone dropping this into
  their own Snowflake account will need most.
- [ ] **2.8 — Commit to GitHub:** SQL setup scripts, the minimal stored proc, and
  `SETUP.md`/README updates.

---

## Phase 3 — Batch Pipeline (Input Table → Nullafi → Output Table)

Goal: the real pipeline logic, correctly handling errors and reruns — not just the
happy path.

- [ ] **3.1 — Create a sample input table** in Snowflake using your Phase 0.4
  schema, loaded with the fake data from Phase 1.
- [ ] **3.2 — Create the output table** per your Phase 0.4 design.
- [ ] **3.3 — Write the core batch stored procedure:** read unprocessed rows from
  the input table.
- [ ] **3.4 — Add batching/chunking logic** sized to respect the rate limits and
  payload limits you found in Phase 1.7 (don't call the API row-by-row if
  Nullafi supports batched requests).
- [ ] **3.5 — Add per-row/per-batch error handling.** A single failed call
  shouldn't crash the whole batch — catch it, log it, and write it to a separate
  error/dead-letter table.
- [ ] **3.6 — Add idempotency.** Use a status column (`PENDING` / `PROCESSED` /
  `FAILED`) or a `MERGE`-based write so re-running the procedure doesn't
  duplicate output rows.
- [ ] **3.7 — Write results to the output table.**
- [ ] **3.8 — Test — happy path:** run against the full fake dataset, verify row
  counts match, no duplicates, and detected entities look correct.
- [ ] **3.9 — Test — failure path:** simulate an API failure (bad key, network
  block, malformed row) and confirm it lands in the error table instead of
  crashing the run.
- [ ] **3.10 — Test — rerun safety:** run the procedure twice in a row and
  confirm the second run doesn't reprocess or duplicate anything.
- [ ] **3.11 — Add basic run metrics** (rows processed, rows failed, duration) —
  a simple run-log table is enough at this stage.
- [ ] **3.12 — Update `DESIGN.md`/README** with Phase 3 usage instructions and
  any schema changes.
- [ ] **3.13 — Commit to GitHub.**

---

## Phase 4 — Incremental Processing with Streams

Goal: only process new rows, instead of re-scanning the whole table every run.

- [ ] **4.1 — Research Snowflake Streams:** how they track inserts/updates/
  deletes, and that the stream offset only advances when consumed inside a DML
  transaction (important — reading a stream in a `SELECT` alone doesn't advance
  it).
- [ ] **4.2 — Create a Stream** on the input table.
- [ ] **4.3 — Modify the batch procedure** to consume from the stream instead of
  scanning the full table.
- [ ] **4.4 — Test — new rows only:** insert new rows, run the procedure, confirm
  only the new rows were processed.
- [ ] **4.5 — Test — idle run:** run the procedure again with no new inserts,
  confirm it processes zero rows and doesn't error.
- [ ] **4.6 — Decide and document update/delete behavior.** Streams also capture
  updates/deletes — explicitly decide whether this connector supports
  re-scanning updated rows, or is insert-only, and document that choice (don't
  leave it as an accidental gap).
- [ ] **4.7 — Update README/DESIGN.md** with streaming behavior and limitations.
- [ ] **4.8 — Commit to GitHub.**

---

## Phase 5 — Automation with Tasks

Goal: run the pipeline unattended, on a schedule, with visibility when it breaks.

- [ ] **5.1 — Research Snowflake Tasks:** scheduling syntax, warehouse sizing for
  the task, task history/error visibility, and how task DAGs work if you need
  multiple chained steps.
- [ ] **5.2 — Create a Task** that runs the stream-consuming procedure on a
  schedule.
- [ ] **5.3 — Add monitoring.** Decide how you'll know if it fails — querying
  `TASK_HISTORY`, an email notification integration, or writing failures to a
  monitored table. Pick one and implement it; don't leave this as a manual "go
  check the UI" step.
- [ ] **5.4 — Test — normal operation:** let the task run unattended for a period,
  confirm new input rows get processed automatically.
- [ ] **5.5 — Test — failure alerting:** deliberately break something (e.g.,
  revoke the secret temporarily) and confirm the failure is surfaced, not
  silent.
- [ ] **5.6 — Document** how to enable/disable/resume the task and how to check
  its health, in the README.
- [ ] **5.7 — Commit to GitHub.**

---

## Phase 6 — Package as a Reusable Drop-In Connector

Goal: someone who has never seen this repo can clone it, run one setup script,
and have it working against their own tables.

- [ ] **6.1 — Parameterize everything.** No hardcoded table/schema/database names
  or column lists anywhere in the code — pull them from the config approach you
  decided in Phase 0.5.
- [ ] **6.2 — Write a single setup script** (SQL) that provisions everything —
  network rule, secret, integration, tables, stream, task — from a new user's
  own parameters.
- [ ] **6.3 — Add input validation and clear error messages** for common
  misconfiguration (missing secret, wrong table schema, bad column mapping).
- [ ] **6.4 — Full comment pass.** Re-read every file as if you're a stranger
  seeing it for the first time; add/clarify comments wherever intent isn't
  obvious.
- [ ] **6.5 — Clean-environment test.** Provision a *fresh* Snowflake schema and
  set the whole thing up using only the setup script and docs — no manual steps
  you forgot to write down. This is the real test of "drop-in."
- [ ] **6.6 — Finalize the README** with:
  - Overview and architecture (a simple diagram or description of the flow)
  - Prerequisites
  - Setup instructions
  - Usage examples
  - Configuration options
  - Troubleshooting / common errors
  - Known limitations
  - A short **Roadmap** section noting a Snowflake Native App as potential
    future work (explicitly out of scope for this release)
- [ ] **6.7 — Tag a release** on GitHub (e.g., `v1.0.0`).
- [ ] **6.8 — Final commit and push.**

---

## Suggested pacing (flexible)

| Day | Focus |
|---|---|
| 1 | Phase 0, start Phase 1 |
| 2 | Finish Phase 1, start Phase 2 |
| 3 | Finish Phase 2 |
| 4 | Phase 3 |
| 5 | Phase 4 |
| 6 | Phase 5 |
| 7 | Phase 6 |

This is tight, especially Phase 3 (error handling + idempotency take real time
to get right) — if something slips a day, that's normal. Better to ship a
correct Phase 3–5 a day late than a rushed one on time.

**Note on Phase 7:** deliberately excluded here per your steer. When you're ready
for it, it's worth treating as its own project (Native App manifest, setup
scripts, application roles, and testing installs from a separate consumer
account) rather than a tail-end addition to this one.
