# solo-decisions

The decisions cell: decision records, their event history, and scheduled
reviews. It keeps its own Neon database and reuses
[empire-platform](https://github.com/bookchaowalit/empire-platform) for
identity, authorization, execution and audit records, and the graph, all over
HTTP with the caller's own token.

| | |
|---|---|
| API | Railway project `solo-decisions`, service `decisions-api` (Serverless: sleeps when idle) |
| Outbox sweep | service `decisions-publisher`, cron `*/15 * * * *` |
| Data | Neon project `solo-decisions`, database `decisions` |
| Registry | solo-empire `repository-catalog/registries/online-systems.yaml` (`decisions`) |

## How a request works

- **Read:** verify the token (`decisions-api` audience), ask the platform
  `POST /v1/authz/decide`, then read under row-level security bound to the
  token's workspace.
- **Write:** `POST /v1/executions` on the platform (decision with locks plus an
  execution record), then one local transaction that changes the row, appends
  the event history and the outbox, then `POST /v1/executions/{id}/finish`
  with row hashes for the audit trail.
- **Graph:** outbox rows go to the platform `POST /v1/graph/events` right
  after the write (best effort) and from the cron sweep (retries with backoff).

Fails closed: if the platform cannot answer, reads and writes return 503.

Permissions: `decisions.decision:read|write|approve|delete`,
`decisions.review:write`; changing `approval_status` needs `approve`. The
publisher identity needs `graph.decisions:write`.

## API

| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/decisions` | list (status, domain, approval, source, review due, updated since) |
| GET | `/v1/decisions/stats` | counts by status, domain, approval or action status |
| GET | `/v1/decisions/{id}` · `/dedupe/{key}` · `/legacy/{id}` | one record |
| POST | `/v1/decisions` | create (`Idempotency-Key` header supported) |
| PUT | `/v1/decisions/dedupe/{key}` | create or refresh by dedupe key |
| PATCH | `/v1/decisions/{id}` | change fields, optional `event` and `expected_version` |
| DELETE | `/v1/decisions/{id}` | delete |
| POST/GET | `/v1/decisions/{id}/events` | append or read history |
| GET | `/v1/decision-events` | history across records |
| GET | `/v1/decision-reviews` | reviews (status, decision, due) |
| PUT | `/v1/decisions/{id}/reviews/{due_date}` | create or update a review |
| PATCH | `/v1/decision-reviews/{id}` | update a review |

## Develop

```bash
uv venv .venv && uv pip install --python .venv/bin/python -e ".[dev]"
.venv/bin/pytest -q
```

## Operate

```bash
NEON_API_KEY=... .venv/bin/decisions-db provision    # project, roles, migrations; URLs owner-only
DECISIONS_DB_MODE=hosted .venv/bin/decisions-db migrate
npm install && railway up --ci                       # from a linked checkout
```

Railway variables (never in the repository): `DECISIONS_DB_MODE=hosted`,
`DECISIONS_DB_URL_API`, `DECISIONS_DB_URL_PUBLISHER`,
`DECISIONS_JWT_PUBLIC_KEY_PEM`, `DECISIONS_JWT_ISSUER`, `EMPIRE_PLATFORM_URL`,
`DECISIONS_PUBLISHER_TOKEN`.
