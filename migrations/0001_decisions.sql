-- Decisions cell: records, their event history, scheduled reviews, and the
-- outbox for graph events. Every row belongs to a workspace and is visible
-- only while the transaction is bound to it (app.workspace_id).

CREATE SCHEMA decisions;

CREATE FUNCTION decisions.current_workspace() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('app.workspace_id', true), '')::uuid
$$;

CREATE TABLE decisions.records (
    workspace_id       uuid NOT NULL,
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    legacy_id          bigint,
    title              text NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
    domain             text NOT NULL DEFAULT 'general' CHECK (length(domain) BETWEEN 1 AND 80),
    decision           text NOT NULL CHECK (length(decision) BETWEEN 1 AND 4000),
    rationale          text,
    evidence_refs      jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(evidence_refs) = 'array'),
    confidence         real CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    expected_outcome   text,
    actual_outcome     text,
    next_action        text,
    status             text NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('draft', 'proposed', 'approved', 'in_progress', 'completed', 'deferred', 'rejected', 'superseded')),
    approval_required  boolean NOT NULL DEFAULT true,
    approval_status    text NOT NULL DEFAULT 'pending'
        CHECK (approval_status IN ('pending', 'approved', 'rejected', 'not_required')),
    action_type        text NOT NULL DEFAULT 'none'
        CHECK (action_type IN ('none', 'task', 'calendar', 'notification', 'message', 'financial', 'external_change')),
    action_status      text NOT NULL DEFAULT 'none'
        CHECK (action_status IN ('none', 'pending_approval', 'queued', 'executed', 'blocked', 'failed')),
    privacy_class      text NOT NULL DEFAULT 'private' CHECK (privacy_class IN ('private', 'sensitive', 'internal')),
    source_type        text,
    source_ref         text,
    review_date        date,
    decided_at         timestamptz,
    dedupe_key         text,
    execution_lock_key text,
    version            bigint NOT NULL DEFAULT 1,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id)
);
CREATE UNIQUE INDEX records_dedupe ON decisions.records (workspace_id, dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE UNIQUE INDEX records_lock ON decisions.records (workspace_id, execution_lock_key) WHERE execution_lock_key IS NOT NULL;
CREATE UNIQUE INDEX records_legacy ON decisions.records (workspace_id, legacy_id) WHERE legacy_id IS NOT NULL;
CREATE INDEX records_status ON decisions.records (workspace_id, status, created_at DESC);
CREATE INDEX records_approval ON decisions.records (workspace_id, approval_status, approval_required);
CREATE INDEX records_review ON decisions.records (workspace_id, review_date);
CREATE INDEX records_source ON decisions.records (workspace_id, source_type, source_ref);

CREATE TABLE decisions.events (
    workspace_id         uuid NOT NULL,
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    decision_id          bigint NOT NULL,
    event_type           text NOT NULL CHECK (event_type IN (
        'created', 'refreshed', 'approved', 'rejected', 'deferred', 'completed', 'signal_cleared',
        'review_task_created', 'reviewed', 'updated')),
    actor                text NOT NULL DEFAULT 'system' CHECK (length(actor) BETWEEN 1 AND 120),
    from_status          text,
    to_status            text,
    from_approval_status text,
    to_approval_status   text,
    from_action_status   text,
    to_action_status     text,
    reason               text,
    metadata             jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    execution_id         uuid,
    created_at           timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id, decision_id) REFERENCES decisions.records (workspace_id, id) ON DELETE CASCADE
);
CREATE INDEX events_decision ON decisions.events (workspace_id, decision_id, created_at DESC);
CREATE INDEX events_type ON decisions.events (workspace_id, event_type, created_at DESC);

CREATE TABLE decisions.reviews (
    workspace_id uuid NOT NULL,
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    decision_id  bigint NOT NULL,
    task_id      bigint,
    due_date     date NOT NULL,
    status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'skipped')),
    reviewer     text,
    outcome      text,
    notes        text,
    reviewed_at  timestamptz,
    version      bigint NOT NULL DEFAULT 1,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, decision_id, due_date),
    FOREIGN KEY (workspace_id, decision_id) REFERENCES decisions.records (workspace_id, id) ON DELETE CASCADE
);
CREATE INDEX reviews_due ON decisions.reviews (workspace_id, status, due_date);

-- Idempotent creates: a key reserves the record id before the platform execution starts, so a
-- retry after a lost answer reuses the same id (and the same platform binding).
CREATE TABLE decisions.create_keys (
    workspace_id uuid NOT NULL,
    actor        uuid NOT NULL,
    key          text NOT NULL CHECK (length(key) BETWEEN 8 AND 200),
    decision_id  bigint NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, actor, key)
);

-- Graph events, written in the same transaction as the change (at-least-once delivery).
CREATE TABLE decisions.outbox (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    uuid NOT NULL,
    type            text NOT NULL,
    subject         text NOT NULL,
    execution_id    uuid,
    classification  text NOT NULL DEFAULT 'confidential',
    payload         jsonb NOT NULL,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    published_at    timestamptz,
    attempts        integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_error      text,
    correlation_id  text
);
CREATE INDEX outbox_pending ON decisions.outbox (next_attempt_at) WHERE published_at IS NULL;

-- Workspace isolation for the runtime role (the owner role runs migrations only).
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['records', 'events', 'reviews', 'outbox', 'create_keys'] LOOP
        EXECUTE format('ALTER TABLE decisions.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE decisions.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY workspace_isolation ON decisions.%I'
                       ' USING (workspace_id = decisions.current_workspace())'
                       ' WITH CHECK (workspace_id = decisions.current_workspace())', t);
    END LOOP;
END
$$;

GRANT USAGE ON SCHEMA decisions TO decisions_api;
GRANT EXECUTE ON FUNCTION decisions.current_workspace() TO decisions_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON decisions.records, decisions.reviews TO decisions_api;
GRANT SELECT, INSERT ON decisions.create_keys TO decisions_api;
GRANT USAGE ON SEQUENCE decisions.records_id_seq TO decisions_api;
-- Events are append-only; execution_id is set once, inside the writing transaction, when the
-- platform execution exists (rows are tagged with a local marker until then).
GRANT SELECT, INSERT ON decisions.events TO decisions_api;
GRANT UPDATE (execution_id) ON decisions.events TO decisions_api;
GRANT SELECT, INSERT ON decisions.outbox TO decisions_api;
GRANT UPDATE (execution_id, published_at, attempts, next_attempt_at, last_error) ON decisions.outbox TO decisions_api;

-- The publisher sweeps the outbox of every workspace, so it reads past RLS for the outbox only.
CREATE POLICY publisher_sweep ON decisions.outbox TO decisions_publisher USING (true) WITH CHECK (true);
GRANT USAGE ON SCHEMA decisions TO decisions_publisher;
GRANT SELECT ON decisions.outbox TO decisions_publisher;
GRANT UPDATE (published_at, attempts, next_attempt_at, last_error) ON decisions.outbox TO decisions_publisher;
