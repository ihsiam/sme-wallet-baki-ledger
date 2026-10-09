-- =============================================================================
-- SME WALLET & BAKI (CREDIT) LEDGER
-- Raw PostgreSQL project: normalization, constraints, transactions,
-- row locking, triggers, indexes.  Requires PostgreSQL 11 or newer.
-- =============================================================================
--
-- HOW TO RUN
--   1. Create an empty database and connect to it:
--          CREATE DATABASE ledger;
--          \c ledger
--   2. Run this whole file from top to bottom:
--          psql -d ledger -f ledger.sql
--   3. To start over, run the RESET block below first (it is commented out
--      on purpose, because it deletes everything in the public schema).
--
-- CONTENTS
--   1. Schema      users, accounts, dues, events, audit_log
--   2. Seed data   the System account, 5 users, 5 accounts
--   3. Functions   get_balance, get_due_remaining, cash_in, payment,
--                  create_due, pay_due, write_off, reverse_event
--   4. Triggers    append-only protection and audit logging
--   5. Indexes     one per real query pattern
--   6. Reports     views, account statement, integrity checks
--   7. Tests       every rule, including the errors that must happen
--   8. Demos       the concurrency race (two windows) and an index benchmark
--
-- DESIGN RULES (the whole project follows these)
--   * Money is NUMERIC(12,2): exact decimals, never FLOAT.
--   * There is NO balance column. A balance is always calculated from the
--     events table, so it can never drift away from the history.
--   * events is append-only. A mistake is fixed with a 'reversal' event,
--     never by editing or deleting a row.
--   * Event status decides what counts:
--         success   money really moved       (counted by get_balance)
--         recorded  only a note, no money    (due_created, write_off)
--         pending / failed                   (never counted)
--   * The System account (acc_type = 'system') has no owner. It is where
--     money enters the ledger, so its balance is negative. All balances
--     together always add up to exactly 0.
--   * Flat fee of 5 on every payment and due payment: paid by the sender on
--     top of the amount, received by the System account.
--   * Every function that spends money locks rows in ONE fixed order:
--         1st the due row (if any), 2nd the accounts sorted by acc_no.
--     Same order everywhere means two functions can never deadlock.
--   * Every write function is idempotent: sending the same idempotency key
--     again returns the original event and changes nothing.
--
-- =============================================================================

-- =============================================================================
-- RESET (optional)
-- Uncomment the next two lines to wipe the database and start from scratch.
-- =============================================================================

-- DROP SCHEMA public CASCADE;
-- CREATE SCHEMA public;

-- =============================================================================
-- 1. SCHEMA
-- Tables are created in this order because of the foreign keys.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 users
-- One row per real person or shop owner.
-- -----------------------------------------------------------------------------

CREATE TABLE users (
    -- Auto-numbered identity. ALWAYS means nobody can insert their own value.
    user_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       TEXT        NOT NULL,
    phone      VARCHAR(15) NOT NULL UNIQUE,
    -- Optional: NULL for plain customers.
    shop_name  VARCHAR(50),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- -----------------------------------------------------------------------------
-- 1.2 accounts
-- A wallet. Owned by a user, except the System account which has no owner.
-- -----------------------------------------------------------------------------

-- Enum types: a column using them accepts ONLY the listed values.
CREATE TYPE acc_type   AS ENUM ('system', 'customer', 'merchant');
CREATE TYPE acc_status AS ENUM ('active', 'frozen', 'closed');

CREATE TABLE accounts (
    acc_no     VARCHAR(20) PRIMARY KEY,
    -- NULL is allowed here: the System account has no owner.
    user_id    BIGINT      REFERENCES users (user_id),
    acc_type   acc_type    NOT NULL DEFAULT 'customer',
    acc_status acc_status  NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Ownership rule:
    --   the 'system' account must have NO owner,
    --   every other account MUST have an owner.
    CONSTRAINT accounts_owner_rule CHECK (
        (acc_type =  'system' AND user_id IS NULL)
        OR
        (acc_type <> 'system' AND user_id IS NOT NULL)
    )
);


-- -----------------------------------------------------------------------------
-- 1.3 dues (baki / credit)
-- One row = one credit agreement: the debtor owes the creditor an amount.
-- The remaining balance is NOT stored. It is calculated by get_due_remaining().
-- -----------------------------------------------------------------------------

CREATE TABLE dues (
    due_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- The account that owes the money (a customer).
    debtor_acc_no   VARCHAR(20)   NOT NULL REFERENCES accounts (acc_no),
    -- The account that is owed the money (a merchant).
    creditor_acc_no VARCHAR(20)   NOT NULL REFERENCES accounts (acc_no),
    due_amount      NUMERIC(12,2) NOT NULL CHECK (due_amount > 0),
    -- Payment deadline.
    due_date        DATE          NOT NULL,
    reason          TEXT,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    -- Nobody can owe themselves.
    CONSTRAINT dues_debtor_not_creditor CHECK (debtor_acc_no <> creditor_acc_no)
);


-- -----------------------------------------------------------------------------
-- 1.4 events (the ledger)
-- Every money movement and every due action is one row.
-- Append-only: rows are inserted, never updated or deleted.
-- -----------------------------------------------------------------------------

CREATE TYPE event_type AS ENUM (
    'cash_in',
    'payment',
    'due_created',
    'due_payment',
    'reversal',
    'write_off'
);

CREATE TYPE event_status AS ENUM ('pending', 'success', 'failed', 'recorded');

CREATE TABLE events (
    event_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type          event_type    NOT NULL,
    -- Filled only for reversals: the event that is being cancelled.
    reverses_event_id   BIGINT        REFERENCES events (event_id),
    from_acc_no         VARCHAR(20)   NOT NULL REFERENCES accounts (acc_no),
    to_acc_no           VARCHAR(20)   NOT NULL REFERENCES accounts (acc_no),
    -- Filled only for due-related events.
    due_id              BIGINT        REFERENCES dues (due_id),
    amount              NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    fee                 NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (fee >= 0),
    -- Filled only when fee > 0.
    fee_receiver_acc_no VARCHAR(20)   REFERENCES accounts (acc_no),
    status              event_status  NOT NULL,
    idempotency_key     TEXT          UNIQUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    -- Money cannot go from an account to itself.
    CONSTRAINT events_from_not_to CHECK (from_acc_no <> to_acc_no),

    -- reverses_event_id is filled exactly when the event is a reversal.
    CONSTRAINT events_reversal_rule CHECK (
        (event_type = 'reversal') = (reverses_event_id IS NOT NULL)
    ),

    -- A fee needs a receiver, and no fee means no receiver.
    CONSTRAINT events_fee_receiver_rule CHECK (
        (fee > 0) = (fee_receiver_acc_no IS NOT NULL)
    ),

    -- due_id is filled exactly when the event is due-related.
    CONSTRAINT events_due_rule CHECK (
        (event_type IN ('due_created', 'due_payment', 'write_off')) = (due_id IS NOT NULL)
    )
);


-- -----------------------------------------------------------------------------
-- 1.5 audit_log
-- One row per change on a tracked table. Filled by triggers.
--   INSERT -> old_data is NULL
--   DELETE -> new_data is NULL
-- -----------------------------------------------------------------------------

CREATE TYPE action_type AS ENUM ('INSERT', 'UPDATE', 'DELETE');

CREATE TABLE audit_log (
    audit_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name TEXT        NOT NULL,
    record_id  TEXT        NOT NULL,
    action     action_type NOT NULL,
    old_data   JSONB,
    new_data   JSONB,
    changed_by TEXT        NOT NULL DEFAULT CURRENT_USER,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =============================================================================
-- 2. SEED DATA
-- The System account first, then five users with one account each.
-- Customers: ACC-001, ACC-003, ACC-005.  Merchants: ACC-002, ACC-004.
-- =============================================================================

INSERT INTO accounts (acc_no, user_id, acc_type)
VALUES ('ACC-000', NULL, 'system');

INSERT INTO users (name, phone, shop_name)
VALUES
    ('Karim', '01111111111', NULL),
    ('Rahim', '01111111112', 'Rahim Store'),
    ('Sakib', '01111111113', NULL),
    ('Arif',  '01111111114', 'Arif Store'),
    ('Kabir', '01111111115', NULL);

INSERT INTO accounts (acc_no, user_id, acc_type)
VALUES
    ('ACC-001', 1, 'customer'),
    ('ACC-002', 2, 'merchant'),
    ('ACC-003', 3, 'customer'),
    ('ACC-004', 4, 'merchant'),
    ('ACC-005', 5, 'customer');


-- =============================================================================
-- 3. FUNCTIONS
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 3.1 get_balance
-- Balance of one account, calculated from successful events only:
--     money received - (money sent + fees paid) + fees earned
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_balance(p_acc_no VARCHAR(20))
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN (
        SELECT
            COALESCE(SUM(amount)       FILTER (WHERE to_acc_no           = p_acc_no), 0)
            - COALESCE(SUM(amount + fee) FILTER (WHERE from_acc_no         = p_acc_no), 0)
            + COALESCE(SUM(fee)        FILTER (WHERE fee_receiver_acc_no = p_acc_no), 0)
        FROM events
        WHERE status = 'success'
          AND (
                 to_acc_no           = p_acc_no
              OR from_acc_no         = p_acc_no
              OR fee_receiver_acc_no = p_acc_no
          )
    );
END;
$$;


-- -----------------------------------------------------------------------------
-- 3.2 get_due_remaining
-- How much of a due is still unpaid:
--     remaining = due_amount
--                 - successful due payments
--                 - write-offs
--                 + successful reversals of those due payments
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_due_remaining(p_due_id BIGINT)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_due_amount NUMERIC(12, 2);
    -- Everything that reduced the due: payments and write-offs.
    v_settled    NUMERIC(12, 2);
    -- Due payments that were cancelled again by a reversal.
    v_reversed   NUMERIC(12, 2);
BEGIN
    SELECT due_amount INTO v_due_amount
    FROM dues
    WHERE due_id = p_due_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Due % does not exist', p_due_id;
    END IF;

    -- due_payment events are 'success'; write_off events are 'recorded'
    -- because no cash moves for a write-off.
    SELECT COALESCE(SUM(amount), 0) INTO v_settled
    FROM events
    WHERE due_id = p_due_id
      AND (   (event_type = 'due_payment' AND status = 'success')
           OR (event_type = 'write_off'   AND status = 'recorded'));

    -- A reversal has no due_id of its own, so we reach
    -- the due through the original event that the reversal points to.
    SELECT COALESCE(SUM(r.amount), 0) INTO v_reversed
    FROM events r
    JOIN events o ON o.event_id = r.reverses_event_id
    WHERE r.event_type = 'reversal'
      AND r.status     = 'success'
      AND o.event_type = 'due_payment'
      AND o.due_id     = p_due_id;

    RETURN v_due_amount - v_settled + v_reversed;
END;
$$;


-- -----------------------------------------------------------------------------
-- 3.3 cash_in
-- Moves money from the System account to a user's account.
-- Returns the event_id.
-- Safe to retry with the same idempotency key.
-- The System account is allowed to go negative.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cash_in(
    p_to_acc_no       VARCHAR(20),
    p_amount          NUMERIC(12, 2),
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    -- Type of the destination account.
    v_type       acc_type;
    -- Status of the destination account.
    v_status     acc_status;
    -- acc_no of the System account.
    v_system_acc VARCHAR(20);
    -- Id of the event we find or create.
    v_event_id   BIGINT;
BEGIN
    -- 1. Idempotency: if this key was already used, return the old event.
    IF p_idempotency_key IS NOT NULL THEN
        SELECT event_id INTO v_event_id
        FROM events
        WHERE idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN v_event_id;
        END IF;
    END IF;

    -- 2. The amount must be a positive number.
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive, got %', p_amount;
    END IF;

    -- 3. The destination account must exist.
    SELECT acc_type, acc_status INTO v_type, v_status
    FROM accounts
    WHERE acc_no = p_to_acc_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % does not exist', p_to_acc_no;
    END IF;

    -- 4. It cannot be the System account, and it must be active.
    IF v_type = 'system' THEN
        RAISE EXCEPTION 'Cannot cash in to the system account';
    END IF;

    IF v_status <> 'active' THEN
        RAISE EXCEPTION 'Account % is not active (status: %)', p_to_acc_no, v_status;
    END IF;

    -- 5. Find the System account by type instead of hard-coding 'ACC-000'.
    SELECT acc_no INTO v_system_acc
    FROM accounts
    WHERE acc_type = 'system';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'System account is missing';
    END IF;

    -- 6. Record the event. Fee is 0, so the fee receiver must be NULL
    INSERT INTO events (
        event_type, from_acc_no, to_acc_no, amount,
        fee, fee_receiver_acc_no, status, idempotency_key
    )
    VALUES (
        'cash_in', v_system_acc, p_to_acc_no, p_amount,
        0, NULL, 'success', p_idempotency_key
    )
    RETURNING event_id INTO v_event_id;

    RETURN v_event_id;
END;
$$;


-- -----------------------------------------------------------------------------
-- 3.4 payment
-- Moves money between two user accounts.
-- Flat fee of 5 is paid by the sender on top of the amount and goes to System.
-- Returns the event_id. Safe to retry with the same idempotency key.
--
-- Concurrency: both accounts are locked (FOR UPDATE) BEFORE the balance is
-- read. Without the lock, two simultaneous payments could both see the same
-- balance, both pass the check, and overdraw the account.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION payment(
    p_from_acc_no     VARCHAR(20),
    p_to_acc_no       VARCHAR(20),
    p_amount          NUMERIC(12, 2),
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    -- Flat fee. CONSTANT means it cannot be changed later in the function.
    c_fee         CONSTANT NUMERIC(12, 2) := 5.00;
    v_from_type   acc_type;
    v_from_status acc_status;
    v_to_type     acc_type;
    v_to_status   acc_status;
    v_system_acc  VARCHAR(20);
    v_event_id    BIGINT;
BEGIN
    -- 1. Idempotency: a retry returns the original event and does nothing else.
    IF p_idempotency_key IS NOT NULL THEN
        SELECT event_id INTO v_event_id
        FROM events
        WHERE idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN v_event_id;
        END IF;
    END IF;

    -- 2. Basic input checks.
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive, got %', p_amount;
    END IF;

    IF p_from_acc_no = p_to_acc_no THEN
        RAISE EXCEPTION 'Cannot pay to the same account';
    END IF;

    -- 3. LOCK both accounts, always in sorted order, so two opposite payments
    --    can never deadlock.
    --    The locks are released automatically when this transaction ends.
    PERFORM acc_no
    FROM accounts
    WHERE acc_no IN (p_from_acc_no, p_to_acc_no)
    ORDER BY acc_no
    FOR UPDATE;

    -- 4. Read both accounts AFTER locking.
    SELECT acc_type, acc_status INTO v_from_type, v_from_status
    FROM accounts
    WHERE acc_no = p_from_acc_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sender account % does not exist', p_from_acc_no;
    END IF;

    SELECT acc_type, acc_status INTO v_to_type, v_to_status
    FROM accounts
    WHERE acc_no = p_to_acc_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receiver account % does not exist', p_to_acc_no;
    END IF;

    -- 5. Business rules.
    IF v_from_type = 'system' OR v_to_type = 'system' THEN
        RAISE EXCEPTION 'The system account cannot take part in a payment';
    END IF;

    IF v_from_status <> 'active' THEN
        RAISE EXCEPTION 'Sender account % is not active (status: %)', p_from_acc_no, v_from_status;
    END IF;

    IF v_to_status <> 'active' THEN
        RAISE EXCEPTION 'Receiver account % is not active (status: %)', p_to_acc_no, v_to_status;
    END IF;

    -- 6. Balance check.
    IF get_balance(p_from_acc_no) < p_amount + c_fee THEN
        RAISE EXCEPTION 'Insufficient balance: need %, have %',
            p_amount + c_fee, get_balance(p_from_acc_no);
    END IF;

    -- 7. The fee goes to the System account.
    SELECT acc_no INTO v_system_acc
    FROM accounts
    WHERE acc_type = 'system';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'System account is missing';
    END IF;

    -- 8. Record the event. fee > 0, so fee_receiver_acc_no must be filled.
    INSERT INTO events (
        event_type, from_acc_no, to_acc_no, amount,
        fee, fee_receiver_acc_no, status, idempotency_key
    )
    VALUES (
        'payment', p_from_acc_no, p_to_acc_no, p_amount,
        c_fee, v_system_acc, 'success', p_idempotency_key
    )
    RETURNING event_id INTO v_event_id;

    RETURN v_event_id;
END;
$$;


-- -----------------------------------------------------------------------------
-- 3.5 create_due
-- Records a baki (credit) between a customer (debtor) and a merchant (creditor).
-- Moves NO money. Writes one row in dues and one 'recorded' event for history.
-- Returns the due_id. Safe to retry with the same idempotency key.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_due(
    -- Customer who owes.
    p_debtor_acc_no   VARCHAR(20),
    -- Merchant who is owed.
    p_creditor_acc_no VARCHAR(20),
    p_amount          NUMERIC(12, 2),
    -- Payment deadline.
    p_due_date        DATE,
    p_reason          TEXT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_debtor_type     acc_type;
    v_debtor_status   acc_status;
    v_creditor_type   acc_type;
    v_creditor_status acc_status;
    v_due_id          BIGINT;
BEGIN
    -- 1. Idempotency: a retry returns the original due and creates nothing.
    IF p_idempotency_key IS NOT NULL THEN
        SELECT due_id INTO v_due_id
        FROM events
        WHERE idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN v_due_id;
        END IF;
    END IF;

    -- 2. Input checks.
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Due amount must be positive, got %', p_amount;
    END IF;

    IF p_due_date IS NULL OR p_due_date < CURRENT_DATE THEN
        RAISE EXCEPTION 'Due date must be today or later, got %', p_due_date;
    END IF;

    IF p_debtor_acc_no = p_creditor_acc_no THEN
        RAISE EXCEPTION 'Debtor and creditor must be different accounts';
    END IF;

    -- 3. Both accounts must exist.
    SELECT acc_type, acc_status INTO v_debtor_type, v_debtor_status
    FROM accounts
    WHERE acc_no = p_debtor_acc_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Debtor account % does not exist', p_debtor_acc_no;
    END IF;

    SELECT acc_type, acc_status INTO v_creditor_type, v_creditor_status
    FROM accounts
    WHERE acc_no = p_creditor_acc_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Creditor account % does not exist', p_creditor_acc_no;
    END IF;

    -- 4. Business rules: a due is between a customer (debtor) and a
    --    merchant (creditor). The System account can never be involved.
    IF v_debtor_type <> 'customer' THEN
        RAISE EXCEPTION 'Debtor must be a customer account, % is %', p_debtor_acc_no, v_debtor_type;
    END IF;

    IF v_creditor_type <> 'merchant' THEN
        RAISE EXCEPTION 'Creditor must be a merchant account, % is %', p_creditor_acc_no, v_creditor_type;
    END IF;

    IF v_debtor_status <> 'active' OR v_creditor_status <> 'active' THEN
        RAISE EXCEPTION 'Both accounts must be active';
    END IF;

    -- 5. Create the due itself.
    INSERT INTO dues (debtor_acc_no, creditor_acc_no, due_amount, due_date, reason)
    VALUES (p_debtor_acc_no, p_creditor_acc_no, p_amount, p_due_date, p_reason)
    RETURNING due_id INTO v_due_id;

    -- 6. Record the history event.
    INSERT INTO events (
        event_type, from_acc_no, to_acc_no, due_id, amount,
        fee, fee_receiver_acc_no, status, idempotency_key, notes
    )
    VALUES (
        'due_created', p_creditor_acc_no, p_debtor_acc_no, v_due_id, p_amount,
        0, NULL, 'recorded', p_idempotency_key, p_reason
    );

    RETURN v_due_id;
END;
$$;


-- -----------------------------------------------------------------------------
-- 3.6 pay_due
-- The customer (debtor) pays all or part of a due to the merchant (creditor).
-- The flat fee of 5 is paid by the debtor on top of the amount and goes to System.
-- Only 'amount' reduces the due; the fee does not.
-- Returns the event_id. Safe to retry with the same idempotency key.
--
-- Lock order: 1st the due row, 2nd the two accounts sorted by acc_no.
-- Locking the due stops two payments from overpaying the same baki.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pay_due(
    p_due_id          BIGINT,
    p_amount          NUMERIC(12, 2),
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    c_fee             CONSTANT NUMERIC(12, 2) := 5.00;
    v_debtor_acc      VARCHAR(20);
    v_creditor_acc    VARCHAR(20);
    v_debtor_status   acc_status;
    v_creditor_status acc_status;
    v_remaining       NUMERIC(12, 2);
    v_system_acc      VARCHAR(20);
    v_event_id        BIGINT;
BEGIN
    -- 1. Idempotency: a retry returns the original event and does nothing else.
    IF p_idempotency_key IS NOT NULL THEN
        SELECT event_id INTO v_event_id
        FROM events
        WHERE idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN v_event_id;
        END IF;
    END IF;

    -- 2. Basic input check, before taking any lock.
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive, got %', p_amount;
    END IF;

    -- 3. LOCK 1: the due row. This both reads the due and locks it.
    SELECT debtor_acc_no, creditor_acc_no
    INTO v_debtor_acc, v_creditor_acc
    FROM dues
    WHERE due_id = p_due_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Due % does not exist', p_due_id;
    END IF;

    -- 4. LOCK 2: both accounts, in sorted order.
    PERFORM acc_no
    FROM accounts
    WHERE acc_no IN (v_debtor_acc, v_creditor_acc)
    ORDER BY acc_no
    FOR UPDATE;

    -- 5. Both accounts must be active.
    SELECT acc_status INTO v_debtor_status
    FROM accounts
    WHERE acc_no = v_debtor_acc;

    SELECT acc_status INTO v_creditor_status
    FROM accounts
    WHERE acc_no = v_creditor_acc;

    IF v_debtor_status <> 'active' OR v_creditor_status <> 'active' THEN
        RAISE EXCEPTION 'Both accounts must be active to pay a due';
    END IF;

    -- 6. See the remaining owed amount.
    v_remaining := get_due_remaining(p_due_id);

    IF v_remaining <= 0 THEN
        RAISE EXCEPTION 'Due % is already fully settled', p_due_id;
    END IF;

    IF p_amount > v_remaining THEN
        RAISE EXCEPTION 'Payment % exceeds the remaining due %', p_amount, v_remaining;
    END IF;

    -- 7. The debtor must be able to afford the amount plus the fee.
    IF get_balance(v_debtor_acc) < p_amount + c_fee THEN
        RAISE EXCEPTION 'Insufficient balance: need %, have %',
            p_amount + c_fee, get_balance(v_debtor_acc);
    END IF;

    -- 8. The fee goes to the System account.
    SELECT acc_no INTO v_system_acc
    FROM accounts
    WHERE acc_type = 'system';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'System account is missing';
    END IF;

    -- 9. Record the payment. It moves money, so the status is 'success'.
    INSERT INTO events (
        event_type, from_acc_no, to_acc_no, due_id, amount,
        fee, fee_receiver_acc_no, status, idempotency_key
    )
    VALUES (
        'due_payment', v_debtor_acc, v_creditor_acc, p_due_id, p_amount,
        c_fee, v_system_acc, 'success', p_idempotency_key
    )
    RETURNING event_id INTO v_event_id;

    RETURN v_event_id;
END;
$$;


-- -----------------------------------------------------------------------------
-- 3.7 write_off
-- The creditor (merchant) forgives the REMAINING amount of a due.
-- Moves NO money. Records one 'recorded' event whose amount is whatever was
-- still owed, which brings get_due_remaining to 0.
-- Returns the event_id. Safe to retry with the same idempotency key.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION write_off(
    p_due_id          BIGINT,
    p_reason          TEXT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_debtor_acc   VARCHAR(20);
    v_creditor_acc VARCHAR(20);
    v_remaining    NUMERIC(12, 2);
    v_event_id     BIGINT;
BEGIN
    -- 1. Idempotency: a retry returns the original event and does nothing else.
    IF p_idempotency_key IS NOT NULL THEN
        SELECT event_id INTO v_event_id
        FROM events
        WHERE idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN v_event_id;
        END IF;
    END IF;

    -- 2. LOCK the due row, so a payment and a write-off on the same due
    --    cannot run at the same time and both see the same "remaining".
    --    No account locks are needed: no money moves and no balance is checked.
    SELECT debtor_acc_no, creditor_acc_no
    INTO v_debtor_acc, v_creditor_acc
    FROM dues
    WHERE due_id = p_due_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Due % does not exist', p_due_id;
    END IF;

    -- 3. There must be something left to forgive.
    v_remaining := get_due_remaining(p_due_id);

    IF v_remaining <= 0 THEN
        RAISE EXCEPTION 'Due % is already fully settled, nothing to write off', p_due_id;
    END IF;

    -- 4. Record the write-off.
    INSERT INTO events (
        event_type, from_acc_no, to_acc_no, due_id, amount,
        fee, fee_receiver_acc_no, status, idempotency_key, notes
    )
    VALUES (
        'write_off', v_creditor_acc, v_debtor_acc, p_due_id, v_remaining,
        0, NULL, 'recorded', p_idempotency_key, p_reason
    )
    RETURNING event_id INTO v_event_id;

    RETURN v_event_id;
END;
$$;


-- -----------------------------------------------------------------------------
-- 3.8 reverse_event
-- Cancels an earlier 'payment' or 'due_payment' WITHOUT editing history:
-- it inserts a new 'reversal' event that sends the amount back.
-- Returns the reversal's event_id. Safe to retry with the same idempotency key.
--
-- Rules:
--   * Only a successful payment or due_payment can be reversed. A reversal
--     itself cannot be reversed, and cash_in / due_created / write_off cannot
--     be reversed.
--   * One reversal per event.
--   * The amount goes back, the fee is KEPT by the fee receiver (fee = 0 on
--     the reversal event).
--   * Refused if the receiver no longer has the money.
--   * A due_payment on a due that was written off cannot be reversed,
--     because the write-off already closed the baki.
--
-- Lock order: 1st the due row (due payments only), 2nd the accounts sorted.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION reverse_event(
    p_event_id        BIGINT,
    p_reason          TEXT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    -- The whole original event row, as one variable.
    v_orig        events%ROWTYPE;
    v_from_status acc_status;
    v_to_status   acc_status;
    v_event_id    BIGINT;
BEGIN
    -- 1. Idempotency: a retry returns the original reversal.
    IF p_idempotency_key IS NOT NULL THEN
        SELECT event_id INTO v_event_id
        FROM events
        WHERE idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN v_event_id;
        END IF;
    END IF;

    -- 2. The original event must exist.
    SELECT * INTO v_orig
    FROM events
    WHERE event_id = p_event_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Event % does not exist', p_event_id;
    END IF;

    -- 3. Only successful payments and due payments can be reversed.
    IF v_orig.event_type NOT IN ('payment', 'due_payment') THEN
        RAISE EXCEPTION 'Event % is a %, only payment and due_payment can be reversed',
            p_event_id, v_orig.event_type;
    END IF;

    IF v_orig.status <> 'success' THEN
        RAISE EXCEPTION 'Event % has status %, only successful events can be reversed',
            p_event_id, v_orig.status;
    END IF;

    -- 4. LOCK 1: the due row, but only for a due payment.
    IF v_orig.due_id IS NOT NULL THEN
        PERFORM due_id
        FROM dues
        WHERE due_id = v_orig.due_id
        FOR UPDATE;
    END IF;

    -- 5. LOCK 2: both accounts of the original event, in sorted order.
    PERFORM acc_no
    FROM accounts
    WHERE acc_no IN (v_orig.from_acc_no, v_orig.to_acc_no)
    ORDER BY acc_no
    FOR UPDATE;

    -- 6. Check whether the event was already reversed after acquiring the lock.
    PERFORM 1
    FROM events
    WHERE reverses_event_id = p_event_id;

    IF FOUND THEN
        RAISE EXCEPTION 'Event % was already reversed', p_event_id;
    END IF;

    -- 7. A written-off due cannot have its payments reversed.
    IF v_orig.due_id IS NOT NULL THEN
        PERFORM 1
        FROM events
        WHERE due_id = v_orig.due_id
          AND event_type = 'write_off';

        IF FOUND THEN
            RAISE EXCEPTION 'Due % was written off, its payments cannot be reversed', v_orig.due_id;
        END IF;
    END IF;

    -- 8. Both accounts must be active.
    SELECT acc_status INTO v_from_status
    FROM accounts
    WHERE acc_no = v_orig.from_acc_no;

    SELECT acc_status INTO v_to_status
    FROM accounts
    WHERE acc_no = v_orig.to_acc_no;

    IF v_from_status <> 'active' OR v_to_status <> 'active' THEN
        RAISE EXCEPTION 'Both accounts must be active to reverse an event';
    END IF;

    -- 9. The receiver must still have the money, because a wallet is not
    --    allowed to go negative.
    IF get_balance(v_orig.to_acc_no) < v_orig.amount THEN
        RAISE EXCEPTION 'Cannot reverse: receiver % has % but needs %',
            v_orig.to_acc_no, get_balance(v_orig.to_acc_no), v_orig.amount;
    END IF;

    -- 10. Record the reversal: the same amount, in the opposite direction.
    INSERT INTO events (
        event_type, reverses_event_id, from_acc_no, to_acc_no, amount,
        fee, fee_receiver_acc_no, status, idempotency_key, notes
    )
    VALUES (
        'reversal', p_event_id, v_orig.to_acc_no, v_orig.from_acc_no, v_orig.amount,
        0, NULL, 'success', p_idempotency_key, p_reason
    )
    RETURNING event_id INTO v_event_id;

    RETURN v_event_id;
END;
$$;


-- =============================================================================
-- 4. TRIGGERS
-- Two jobs here:
--   4.1 make events and audit_log append-only
--   4.2 write every change into audit_log
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 4.1 Append-only protection
-- UPDATE, DELETE and TRUNCATE on events and audit_log are blocked.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION prevent_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- TG_TABLE_NAME and TG_OP are filled in by Postgres: the table that fired
    -- the trigger and the operation (UPDATE, DELETE, TRUNCATE).
    RAISE EXCEPTION '% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP;
END;
$$;

-- BEFORE means the trigger runs first and its exception cancels the change.
-- FOR EACH ROW fires once per affected row.
CREATE TRIGGER trg_events_append_only
BEFORE UPDATE OR DELETE ON events
FOR EACH ROW
EXECUTE FUNCTION prevent_modification();

CREATE TRIGGER trg_audit_log_append_only
BEFORE UPDATE OR DELETE ON audit_log
FOR EACH ROW
EXECUTE FUNCTION prevent_modification();

-- TRUNCATE removes all rows at once without firing row triggers, so it needs
-- its own statement-level trigger.
CREATE TRIGGER trg_events_no_truncate
BEFORE TRUNCATE ON events
FOR EACH STATEMENT
EXECUTE FUNCTION prevent_modification();

CREATE TRIGGER trg_audit_log_no_truncate
BEFORE TRUNCATE ON audit_log
FOR EACH STATEMENT
EXECUTE FUNCTION prevent_modification();


-- -----------------------------------------------------------------------------
-- 4.2 Audit logging
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION audit_row_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    -- Name of the primary key column, given in CREATE TRIGGER (TG_ARGV[0]).
    v_pk_column TEXT := TG_ARGV[0];
    v_old       JSONB;
    v_new       JSONB;
    v_record_id TEXT;
BEGIN
    -- OLD does not exist for an INSERT and NEW does not exist for a DELETE,
    -- so each one is only touched in the branch where it exists.
    IF TG_OP = 'INSERT' THEN
        v_new       := to_jsonb(NEW);
        v_record_id := v_new ->> v_pk_column;
    ELSIF TG_OP = 'UPDATE' THEN
        v_old       := to_jsonb(OLD);
        v_new       := to_jsonb(NEW);
        v_record_id := v_new ->> v_pk_column;
    ELSE
        v_old       := to_jsonb(OLD);
        v_record_id := v_old ->> v_pk_column;
    END IF;

    INSERT INTO audit_log (table_name, record_id, action, old_data, new_data)
    VALUES (TG_TABLE_NAME, v_record_id, TG_OP::action_type, v_old, v_new);

    -- The return value of an AFTER row trigger is ignored.
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_users_audit
AFTER INSERT OR UPDATE OR DELETE ON users
FOR EACH ROW
EXECUTE FUNCTION audit_row_change('user_id');

CREATE TRIGGER trg_accounts_audit
AFTER INSERT OR UPDATE OR DELETE ON accounts
FOR EACH ROW
EXECUTE FUNCTION audit_row_change('acc_no');

CREATE TRIGGER trg_dues_audit
AFTER INSERT OR UPDATE OR DELETE ON dues
FOR EACH ROW
EXECUTE FUNCTION audit_row_change('due_id');

CREATE TRIGGER trg_events_audit
AFTER INSERT OR UPDATE OR DELETE ON events
FOR EACH ROW
EXECUTE FUNCTION audit_row_change('event_id');


-- =============================================================================
-- 5. INDEXES
-- =============================================================================
CREATE UNIQUE INDEX uq_events_reverses_event_id
ON events (reverses_event_id);

CREATE INDEX idx_events_from_acc
ON events (from_acc_no)
WHERE status = 'success';

CREATE INDEX idx_events_to_acc
ON events (to_acc_no)
WHERE status = 'success';

CREATE INDEX idx_events_fee_receiver
ON events (fee_receiver_acc_no)
WHERE status = 'success' AND fee_receiver_acc_no IS NOT NULL;

CREATE INDEX idx_events_due_id
ON events (due_id)
WHERE due_id IS NOT NULL;

CREATE INDEX idx_dues_debtor
ON dues (debtor_acc_no);

CREATE INDEX idx_dues_creditor
ON dues (creditor_acc_no);

CREATE INDEX idx_dues_due_date
ON dues (due_date);

CREATE INDEX idx_accounts_user_id
ON accounts (user_id);

CREATE INDEX idx_audit_log_record
ON audit_log (table_name, record_id);


-- =============================================================================
-- 6. REPORTS
-- Views, one function for statements, and the integrity checks.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 6.1 v_account_balances
-- Every account with its owner and current balance.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_account_balances AS
SELECT
    a.acc_no,
    a.acc_type,
    a.acc_status,
    u.name         AS owner_name,
    u.shop_name,
    get_balance(a.acc_no) AS balance
FROM accounts a
-- LEFT JOIN keeps the System account, which has no owner row.
LEFT JOIN users u ON u.user_id = a.user_id
ORDER BY a.acc_no;


-- -----------------------------------------------------------------------------
-- 6.2 v_due_summary
-- Every due with who owes whom, what is left, and its state:
--     settled  nothing left to pay
--     overdue  something left and the deadline has passed
--     open     something left and the deadline is still ahead
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_due_summary AS
SELECT
    d.due_id,
    d.debtor_acc_no,
    du.name        AS debtor_name,
    d.creditor_acc_no,
    COALESCE(cu.shop_name, cu.name) AS creditor_name,
    d.due_amount,
    r.remaining,
    d.due_date,
    CASE
        WHEN r.remaining <= 0           THEN 'settled'
        WHEN d.due_date < CURRENT_DATE  THEN 'overdue'
        ELSE 'open'
    END AS state
FROM dues d
JOIN accounts da ON da.acc_no  = d.debtor_acc_no
JOIN users    du ON du.user_id = da.user_id
JOIN accounts ca ON ca.acc_no  = d.creditor_acc_no
JOIN users    cu ON cu.user_id = ca.user_id
-- LATERAL lets this subquery use the current row (d.due_id), so the remaining
-- amount is calculated once per due and reused in two places above.
CROSS JOIN LATERAL (SELECT get_due_remaining(d.due_id) AS remaining) r
ORDER BY d.due_id;


-- -----------------------------------------------------------------------------
-- 6.3 v_overdue_dues
-- Unpaid dues whose deadline has passed, longest overdue first.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_overdue_dues AS
SELECT
    due_id,
    debtor_acc_no,
    debtor_name,
    creditor_acc_no,
    creditor_name,
    remaining,
    due_date,
    -- Date minus date gives a number of days.
    CURRENT_DATE - due_date AS days_overdue
FROM v_due_summary
WHERE state = 'overdue'
ORDER BY days_overdue DESC;


-- -----------------------------------------------------------------------------
-- 6.4 get_statement
-- The account statement: newest first, with the running balance after each
-- event, and paging through p_limit / p_offset.
--     delta = money in - money out (fees included) + fees earned
-- Example:  SELECT * FROM get_statement('ACC-001', 10, 0);
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_statement(
    p_acc_no VARCHAR(20),
    p_limit  INT DEFAULT 20,
    p_offset INT DEFAULT 0
)
RETURNS TABLE (
    event_id        BIGINT,
    created_at      TIMESTAMPTZ,
    event_type      event_type,
    counterparty    VARCHAR(20),
    delta           NUMERIC(12, 2),
    running_balance NUMERIC(12, 2)
)
LANGUAGE sql
STABLE
AS $$
    -- Step 1: one row per successful event that touches the account,
    --         with its effect on this account (delta).
    WITH legs AS (
        SELECT
            e.event_id,
            e.created_at,
            e.event_type,
            CASE
                WHEN e.to_acc_no   = p_acc_no THEN e.from_acc_no
                WHEN e.from_acc_no = p_acc_no THEN e.to_acc_no
                ELSE e.from_acc_no
            END AS counterparty,
            (
                CASE WHEN e.to_acc_no           = p_acc_no THEN e.amount         ELSE 0 END
                - CASE WHEN e.from_acc_no         = p_acc_no THEN e.amount + e.fee ELSE 0 END
                + CASE WHEN e.fee_receiver_acc_no = p_acc_no THEN e.fee            ELSE 0 END
            ) AS delta
        FROM events e
        WHERE e.status = 'success'
          AND (
                 e.to_acc_no           = p_acc_no
              OR e.from_acc_no         = p_acc_no
              OR e.fee_receiver_acc_no = p_acc_no
          )
    ),
    -- Step 2: a window function adds up the deltas from the oldest event to
    --         each row. Ordering by event_id (not created_at) keeps the order
    --         identical to the order the ledger was written.
    running AS (
        SELECT
            l.*,
            SUM(l.delta) OVER (ORDER BY l.event_id) AS running_balance
        FROM legs l
    )
    -- Step 3: newest first, then cut the page.
    SELECT
        r.event_id,
        r.created_at,
        r.event_type,
        r.counterparty,
        r.delta,
        r.running_balance
    FROM running r
    ORDER BY r.event_id DESC
    LIMIT p_limit OFFSET p_offset;
$$;


-- -----------------------------------------------------------------------------
-- 6.5 check_ledger_integrity
-- Reconciliation. Run it any time to prove the ledger is correct.
-- Every row should show passed = true.
-- Example:  SELECT * FROM check_ledger_integrity();
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_ledger_integrity()
RETURNS TABLE (
    check_name TEXT,
    passed     BOOLEAN,
    detail     TEXT
)
LANGUAGE sql
STABLE
AS $$
    -- 1. Money is never created or lost: all balances add up to exactly 0.
    SELECT
        'All balances add up to zero'::TEXT,
        COALESCE(SUM(get_balance(acc_no)), 0) = 0,
        'sum of balances = ' || COALESCE(SUM(get_balance(acc_no)), 0)::TEXT
    FROM accounts

    UNION ALL

    -- 2. No customer or merchant wallet is overdrawn.
    SELECT
        'No customer or merchant account is negative',
        COUNT(*) = 0,
        COUNT(*)::TEXT || ' negative account(s)'
    FROM accounts
    WHERE acc_type <> 'system'
      AND get_balance(acc_no) < 0

    UNION ALL

    -- 3. No due has been overpaid.
    SELECT
        'No due is overpaid',
        COUNT(*) = 0,
        COUNT(*)::TEXT || ' overpaid due(s)'
    FROM dues
    WHERE get_due_remaining(due_id) < 0

    UNION ALL

    -- 4. Every due has exactly one 'due_created' event.
    SELECT
        'Every due has exactly one due_created event',
        COUNT(*) = 0,
        COUNT(*)::TEXT || ' due(s) with a wrong number of due_created events'
    FROM dues d
    WHERE (
        SELECT COUNT(*)
        FROM events e
        WHERE e.due_id = d.due_id
          AND e.event_type = 'due_created'
    ) <> 1

    UNION ALL

    -- 5. Every reversal is the exact mirror of its original: same amount,
    --    opposite direction.
    SELECT
        'Every reversal mirrors its original event',
        COUNT(*) = 0,
        COUNT(*)::TEXT || ' reversal(s) that do not mirror the original'
    FROM events r
    JOIN events o ON o.event_id = r.reverses_event_id
    WHERE r.event_type = 'reversal'
      AND NOT (
              r.amount      = o.amount
          AND r.from_acc_no = o.to_acc_no
          AND r.to_acc_no   = o.from_acc_no
      );
$$;


-- =============================================================================
-- 7. TESTS
-- Run on the fresh seed data above. Each check prints a NOTICE:
--     PASS: ...                    the result was what we expected
--     PASS (expected error): ...   the database correctly refused bad input
-- and raises an exception (FAIL) if something is wrong, which stops the file.
-- The expected errors are caught inside the test, so the file runs top to bottom.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Test helpers (dropped again at the end of this section)
-- -----------------------------------------------------------------------------

-- t_check: passes when the condition is true.
CREATE OR REPLACE FUNCTION t_check(p_label TEXT, p_ok BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_ok IS TRUE THEN
        RAISE NOTICE 'PASS: %', p_label;
    ELSE
        RAISE EXCEPTION 'FAIL: %', p_label;
    END IF;
END;
$$;

-- t_error: runs a statement and passes only if it raises an error.
CREATE OR REPLACE FUNCTION t_error(p_label TEXT, p_sql TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- The inner block catches the error. The sub-transaction it belongs to is
    -- rolled back, so a refused statement leaves no trace in the data.
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'PASS (expected error): % -> %', p_label, SQLERRM;
        RETURN;
    END;

    RAISE EXCEPTION 'FAIL: "%" should have raised an error but did not', p_label;
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.1 Constraints: bad data must be rejected by the table rules
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    PERFORM t_error(
        'duplicate phone number',
        $q$INSERT INTO users (name, phone) VALUES ('Fake', '01111111111')$q$
    );

    PERFORM t_error(
        'duplicate account number',
        $q$INSERT INTO accounts (acc_no, user_id, acc_type) VALUES ('ACC-001', 1, 'customer')$q$
    );

    PERFORM t_error(
        'system account with an owner',
        $q$INSERT INTO accounts (acc_no, user_id, acc_type) VALUES ('ACC-X1', 1, 'system')$q$
    );

    PERFORM t_error(
        'customer account without an owner',
        $q$INSERT INTO accounts (acc_no, user_id, acc_type) VALUES ('ACC-X2', NULL, 'customer')$q$
    );

    PERFORM t_error(
        'fee greater than 0 without a fee receiver',
        $q$INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, fee_receiver_acc_no, status)
           VALUES ('payment', 'ACC-001', 'ACC-002', 10, 5, NULL, 'success')$q$
    );

    PERFORM t_error(
        'fee receiver given but fee is 0',
        $q$INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, fee_receiver_acc_no, status)
           VALUES ('payment', 'ACC-001', 'ACC-002', 10, 0, 'ACC-000', 'success')$q$
    );

    PERFORM t_error(
        'money from an account to itself',
        $q$INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, status)
           VALUES ('payment', 'ACC-001', 'ACC-001', 10, 0, 'success')$q$
    );

    PERFORM t_error(
        'zero amount',
        $q$INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, status)
           VALUES ('payment', 'ACC-001', 'ACC-002', 0, 0, 'success')$q$
    );

    PERFORM t_error(
        'due-related event without a due_id',
        $q$INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, status)
           VALUES ('due_payment', 'ACC-001', 'ACC-002', 10, 0, 'success')$q$
    );

    PERFORM t_error(
        'reversal without reverses_event_id',
        $q$INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, status)
           VALUES ('reversal', 'ACC-002', 'ACC-001', 10, 0, 'success')$q$
    );

    PERFORM t_error(
        'due where debtor and creditor are the same',
        $q$INSERT INTO dues (debtor_acc_no, creditor_acc_no, due_amount, due_date)
           VALUES ('ACC-001', 'ACC-001', 10, CURRENT_DATE + 1)$q$
    );

    PERFORM t_error(
        'unknown account in an event (foreign key)',
        $q$INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, status)
           VALUES ('payment', 'ACC-999', 'ACC-002', 10, 0, 'success')$q$
    );

    PERFORM t_error(
        'delete a user who still has an account (foreign key)',
        $q$DELETE FROM users WHERE user_id = 1$q$
    );
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.2 cash_in and get_balance
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_first  BIGINT;
    v_second BIGINT;
BEGIN
    v_first := cash_in('ACC-001', 1000, 'test-ci-1');
    PERFORM t_check('cash_in returns an event id', v_first IS NOT NULL);

    -- Same key again: the same event id comes back and nothing new is inserted.
    v_second := cash_in('ACC-001', 1000, 'test-ci-1');
    PERFORM t_check('cash_in is idempotent (same key, same event id)', v_first = v_second);

    PERFORM t_check('balance is 1000, not 2000', get_balance('ACC-001') = 1000);
    PERFORM t_check('System balance is -1000', get_balance('ACC-000') = -1000);

    PERFORM t_error('cash_in with a negative amount',
        $q$SELECT cash_in('ACC-001', -5, 'test-ci-neg')$q$);
    PERFORM t_error('cash_in to an unknown account',
        $q$SELECT cash_in('ACC-999', 100, 'test-ci-unknown')$q$);
    PERFORM t_error('cash_in to the System account',
        $q$SELECT cash_in('ACC-000', 100, 'test-ci-system')$q$);

    PERFORM t_check('all balances add up to zero', (SELECT SUM(get_balance(acc_no)) FROM accounts) = 0);
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.3 payment
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_first  BIGINT;
    v_second BIGINT;
BEGIN
    v_first  := payment('ACC-001', 'ACC-002', 100, 'test-p-1');
    v_second := payment('ACC-001', 'ACC-002', 100, 'test-p-1');
    PERFORM t_check('payment is idempotent', v_first = v_second);

    -- Sender pays 100 + 5 fee once. Receiver gets 100. System earns 5.
    PERFORM t_check('sender paid 105 once (1000 - 105 = 895)', get_balance('ACC-001') = 895);
    PERFORM t_check('receiver got 100', get_balance('ACC-002') = 100);
    PERFORM t_check('System: -1000 + 5 fee = -995', get_balance('ACC-000') = -995);

    PERFORM t_error('payment larger than the balance',
        $q$SELECT payment('ACC-001', 'ACC-002', 999999, 'test-p-big')$q$);
    PERFORM t_error('payment to the same account',
        $q$SELECT payment('ACC-001', 'ACC-001', 10, 'test-p-same')$q$);
    PERFORM t_error('payment from the System account',
        $q$SELECT payment('ACC-000', 'ACC-001', 10, 'test-p-system')$q$);
    PERFORM t_error('payment of zero',
        $q$SELECT payment('ACC-001', 'ACC-002', 0, 'test-p-zero')$q$);
    PERFORM t_error('payment to an unknown account',
        $q$SELECT payment('ACC-001', 'ACC-999', 10, 'test-p-unknown')$q$);

    PERFORM t_check('all balances add up to zero', (SELECT SUM(get_balance(acc_no)) FROM accounts) = 0);
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.4 Only successful events count: a failed event must not move money
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_before NUMERIC(12, 2);
BEGIN
    v_before := get_balance('ACC-001');

    INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, status)
    VALUES ('payment', 'ACC-001', 'ACC-002', 100, 0, 'failed');

    PERFORM t_check('a failed event does not change the balance', get_balance('ACC-001') = v_before);
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.5 Dues: create_due, get_due_remaining, pay_due
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_due_a  BIGINT;
    v_due_b  BIGINT;
    v_before_debtor   NUMERIC(12, 2);
    v_before_creditor NUMERIC(12, 2);
BEGIN
    v_before_debtor   := get_balance('ACC-001');
    v_before_creditor := get_balance('ACC-002');

    v_due_a := create_due('ACC-001', 'ACC-002', 300, CURRENT_DATE + 30, 'groceries', 'test-due-1');
    v_due_b := create_due('ACC-001', 'ACC-002', 300, CURRENT_DATE + 30, 'groceries', 'test-due-1');
    PERFORM t_check('create_due is idempotent', v_due_a = v_due_b);
    PERFORM t_check('remaining of a new due is the full amount', get_due_remaining(v_due_a) = 300);
    PERFORM t_check('create_due moves no money',
        get_balance('ACC-001') = v_before_debtor AND get_balance('ACC-002') = v_before_creditor);

    PERFORM t_error('debtor must be a customer',
        $q$SELECT create_due('ACC-002', 'ACC-001', 100, CURRENT_DATE + 7, NULL, 'test-due-e1')$q$);
    PERFORM t_error('creditor must be a merchant',
        $q$SELECT create_due('ACC-001', 'ACC-000', 100, CURRENT_DATE + 7, NULL, 'test-due-e2')$q$);
    PERFORM t_error('due date in the past',
        $q$SELECT create_due('ACC-001', 'ACC-002', 100, CURRENT_DATE - 1, NULL, 'test-due-e3')$q$);
    PERFORM t_error('due with zero amount',
        $q$SELECT create_due('ACC-001', 'ACC-002', 0, CURRENT_DATE + 7, NULL, 'test-due-e4')$q$);

    -- Partial payment of 100 (plus the 5 fee).
    PERFORM pay_due(v_due_a, 100, 'test-pd-1');
    PERFORM pay_due(v_due_a, 100, 'test-pd-1');
    PERFORM t_check('pay_due is idempotent and reduces the due once', get_due_remaining(v_due_a) = 200);
    PERFORM t_check('debtor paid 105 once', get_balance('ACC-001') = v_before_debtor - 105);
    PERFORM t_check('creditor received 100', get_balance('ACC-002') = v_before_creditor + 100);

    PERFORM t_error('payment larger than the remaining due',
        format('SELECT pay_due(%s, 250, %L)', v_due_a, 'test-pd-over'));

    PERFORM pay_due(v_due_a, 200, 'test-pd-2');
    PERFORM t_check('due is fully paid', get_due_remaining(v_due_a) = 0);

    PERFORM t_error('paying an already settled due',
        format('SELECT pay_due(%s, 1, %L)', v_due_a, 'test-pd-settled'));
    PERFORM t_error('paying a due that does not exist',
        $q$SELECT pay_due(999999, 10, 'test-pd-none')$q$);

    PERFORM t_check('all balances add up to zero', (SELECT SUM(get_balance(acc_no)) FROM accounts) = 0);
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.6 write_off
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_due     BIGINT;
    v_first   BIGINT;
    v_second  BIGINT;
    v_before_debtor   NUMERIC(12, 2);
    v_before_creditor NUMERIC(12, 2);
BEGIN
    v_due := create_due('ACC-003', 'ACC-004', 200, CURRENT_DATE + 30, 'rice', 'test-due-wo');
    PERFORM cash_in('ACC-003', 100, 'test-ci-wo');
    PERFORM pay_due(v_due, 50, 'test-pd-wo');
    PERFORM t_check('150 left after a partial payment', get_due_remaining(v_due) = 150);

    v_before_debtor   := get_balance('ACC-003');
    v_before_creditor := get_balance('ACC-004');

    v_first  := write_off(v_due, 'customer in hardship', 'test-wo-1');
    v_second := write_off(v_due, 'customer in hardship', 'test-wo-1');
    PERFORM t_check('write_off is idempotent', v_first = v_second);
    PERFORM t_check('nothing is left after the write-off', get_due_remaining(v_due) = 0);
    PERFORM t_check('the write-off event carries the forgiven amount (150)',
        (SELECT amount FROM events WHERE event_id = v_first) = 150);
    PERFORM t_check('write_off moves no money',
        get_balance('ACC-003') = v_before_debtor AND get_balance('ACC-004') = v_before_creditor);

    PERFORM t_error('write_off on a settled due',
        format('SELECT write_off(%s, %L, %L)', v_due, 'again', 'test-wo-2'));
    PERFORM t_error('pay_due on a written-off due',
        format('SELECT pay_due(%s, 10, %L)', v_due, 'test-pd-wo-2'));

    PERFORM t_check('all balances add up to zero', (SELECT SUM(get_balance(acc_no)) FROM accounts) = 0);
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.7 reverse_event
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_pay        BIGINT;
    v_rev        BIGINT;
    v_rev_again  BIGINT;
    v_due        BIGINT;
    v_due_pay    BIGINT;
    v_start_payer    NUMERIC(12, 2);
    v_start_receiver NUMERIC(12, 2);
    v_start_system   NUMERIC(12, 2);
    v_cash_in    BIGINT;
BEGIN
    -- A payment is reversed: the amount returns, the fee is kept.
    PERFORM cash_in('ACC-005', 500, 'test-ci-rev');
    v_start_payer    := get_balance('ACC-005');
    v_start_receiver := get_balance('ACC-002');
    v_start_system   := get_balance('ACC-000');

    v_pay := payment('ACC-005', 'ACC-002', 100, 'test-p-rev');
    v_rev := reverse_event(v_pay, 'sent by mistake', 'test-rev-1');
    v_rev_again := reverse_event(v_pay, 'sent by mistake', 'test-rev-1');
    PERFORM t_check('reverse_event is idempotent', v_rev = v_rev_again);

    PERFORM t_check('payer got the amount back and lost only the 5 fee',
        get_balance('ACC-005') = v_start_payer - 5);
    PERFORM t_check('receiver is back to the starting balance',
        get_balance('ACC-002') = v_start_receiver);
    PERFORM t_check('System kept the 5 fee', get_balance('ACC-000') = v_start_system + 5);

    PERFORM t_error('reversing the same event twice',
        format('SELECT reverse_event(%s, %L, %L)', v_pay, 'twice', 'test-rev-2'));
    PERFORM t_error('reversing a reversal',
        format('SELECT reverse_event(%s, %L, %L)', v_rev, 'undo undo', 'test-rev-3'));

    v_cash_in := cash_in('ACC-005', 10, 'test-ci-rev-2');
    PERFORM t_error('reversing a cash_in',
        format('SELECT reverse_event(%s, %L, %L)', v_cash_in, 'no', 'test-rev-4'));
    PERFORM t_error('reversing an event that does not exist',
        $q$SELECT reverse_event(999999, 'no', 'test-rev-5')$q$);

    -- Reversing a due payment puts the amount back on the due.
    v_due     := create_due('ACC-005', 'ACC-004', 100, CURRENT_DATE + 10, 'oil', 'test-due-rev');
    v_due_pay := pay_due(v_due, 60, 'test-pd-rev');
    PERFORM t_check('40 left after paying 60', get_due_remaining(v_due) = 40);
    PERFORM reverse_event(v_due_pay, 'wrong due', 'test-rev-6');
    PERFORM t_check('reversing the due payment restores the full 100', get_due_remaining(v_due) = 100);

    PERFORM t_check('all balances add up to zero', (SELECT SUM(get_balance(acc_no)) FROM accounts) = 0);
END;
$$;

-- A reversal is refused when the receiver has already spent the money, and
-- when the due was already written off.
DO $$
DECLARE
    v_pay       BIGINT;
    v_spare     NUMERIC(12, 2);
    v_due       BIGINT;
    v_due_pay   BIGINT;
BEGIN
    PERFORM cash_in('ACC-005', 500, 'test-ci-spent');

    -- ACC-005 pays 50 to ACC-003 ...
    v_pay := payment('ACC-005', 'ACC-003', 50, 'test-p-spent');

    -- ... then ACC-003 spends everything it has (balance minus the 5 fee).
    v_spare := get_balance('ACC-003') - 5;
    PERFORM payment('ACC-003', 'ACC-001', v_spare, 'test-p-spend-all');
    PERFORM t_check('ACC-003 is now empty', get_balance('ACC-003') = 0);

    PERFORM t_error('reversal when the receiver already spent the money',
        format('SELECT reverse_event(%s, %L, %L)', v_pay, 'too late', 'test-rev-spent'));

    -- A due payment cannot be reversed once the rest of the due was written off.
    v_due     := create_due('ACC-005', 'ACC-002', 100, CURRENT_DATE + 10, 'sugar', 'test-due-wo-rev');
    v_due_pay := pay_due(v_due, 30, 'test-pd-wo-rev');
    PERFORM write_off(v_due, 'forgiven', 'test-wo-rev');

    PERFORM t_error('reversing a due payment on a written-off due',
        format('SELECT reverse_event(%s, %L, %L)', v_due_pay, 'no', 'test-rev-wo'));

    PERFORM t_check('all balances add up to zero', (SELECT SUM(get_balance(acc_no)) FROM accounts) = 0);
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.8 Triggers: append-only protection and audit log
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    -- The row trigger only fires for rows that exist, so the test targets the
    -- oldest event instead of a hard-coded id (failed inserts in 7.1 used up
    -- the first identity numbers, so event_id 1 does not exist).
    PERFORM t_error('UPDATE on events',
        $q$UPDATE events SET amount = 1 WHERE event_id = (SELECT MIN(event_id) FROM events)$q$);
    PERFORM t_error('DELETE on events',
        $q$DELETE FROM events WHERE event_id = (SELECT MIN(event_id) FROM events)$q$);
    PERFORM t_error('TRUNCATE on events',
        $q$TRUNCATE events$q$);
    PERFORM t_error('UPDATE on audit_log',
        $q$UPDATE audit_log SET table_name = 'x'$q$);
    PERFORM t_error('DELETE on audit_log',
        $q$DELETE FROM audit_log$q$);

    -- Every row in events was written after the audit triggers existed, so the
    -- audit log must hold exactly one INSERT entry for each of them.
    PERFORM t_check('every event has exactly one INSERT entry in audit_log',
        (SELECT COUNT(*) FROM events)
        = (SELECT COUNT(*) FROM audit_log WHERE table_name = 'events' AND action = 'INSERT'));
END;
$$;

-- An ordinary table (dues has no append-only trigger) is audited on UPDATE too.
DO $$
DECLARE
    v_due BIGINT;
BEGIN
    v_due := create_due('ACC-001', 'ACC-004', 50, CURRENT_DATE + 5, 'audit demo', 'test-due-audit');

    UPDATE dues SET reason = 'audit demo (edited)' WHERE due_id = v_due;

    PERFORM t_check('an UPDATE on dues is logged with old and new data',
        EXISTS (
            SELECT 1
            FROM audit_log
            WHERE table_name = 'dues'
              AND record_id  = v_due::TEXT
              AND action     = 'UPDATE'
              AND old_data ->> 'reason' = 'audit demo'
              AND new_data ->> 'reason' = 'audit demo (edited)'
        ));
END;
$$;


-- -----------------------------------------------------------------------------
-- 7.9 Final reconciliation
-- Every check must show passed = true.
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    PERFORM t_check('integrity: ' || check_name, passed)
    FROM check_ledger_integrity();
END;
$$;


-- Remove the test helpers so they do not stay in the schema.
DROP FUNCTION t_check(TEXT, BOOLEAN);
DROP FUNCTION t_error(TEXT, TEXT);


-- =============================================================================
-- 7.10 Look at the results
-- Run these one at a time to see the data the tests created.
-- =============================================================================

-- Every account with its balance. The System account is negative on purpose.
SELECT * FROM v_account_balances;

-- The sum of all balances must be 0.
SELECT SUM(get_balance(acc_no)) AS total_of_all_balances
FROM accounts;

-- Reconciliation checks (all should be true).
SELECT * FROM check_ledger_integrity();

-- Every due with what is left and its state.
SELECT * FROM v_due_summary;

-- Unpaid dues past their deadline (empty here, because all test dues are in the future).
SELECT * FROM v_overdue_dues;

-- Statement of ACC-005: newest first, with the running balance.
SELECT * FROM get_statement('ACC-005', 10, 0);

-- The full history of events, oldest first.
SELECT event_id, event_type, from_acc_no, to_acc_no, due_id, reverses_event_id, amount, fee, status
FROM events
ORDER BY event_id;

-- The audit trail of one table.
SELECT audit_id, table_name, record_id, action, changed_at
FROM audit_log
WHERE table_name = 'dues'
ORDER BY audit_id;


-- =============================================================================
-- 8. DEMOS
-- Two experiments for your README and CV. Neither one keeps any data:
-- 8.1 needs two terminal windows, 8.2 ends with ROLLBACK.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 8.1 Concurrency demo: two payments race for the same money
--
-- Setup: ACC-003 must hold exactly 200. Check it, and top up if needed:
--     SELECT get_balance('ACC-003');
--
-- Open two psql windows connected to the ledger database.
--
-- WINDOW 1 (starts a transaction and keeps the lock open):
--     BEGIN;
--     SELECT payment('ACC-003', 'ACC-004', 150, 'race-1');
--     -- succeeds. Do NOT commit yet.
--
-- WINDOW 2 (while window 1 is still open):
--     SELECT payment('ACC-003', 'ACC-005', 150, 'race-2');
--     -- hangs: it waits for the row lock on ACC-003.
--
-- WINDOW 1:
--     COMMIT;
--
-- WINDOW 2 wakes up, reads the balance again (now 45) and fails with:
--     Insufficient balance: need 155.00, have 45.00
--
-- WHY IT WORKS: payment() runs SELECT ... FOR UPDATE on the sender row before
-- it reads the balance, so the second payment cannot read the balance until
-- the first one has committed.
--
-- THE BUG IT PREVENTS: remove the "PERFORM acc_no ... FOR UPDATE" step from
-- payment() and repeat. Window 2 no longer waits, still sees 200, passes the
-- check, and the account is overdrawn (200 - 155 - 155 = -110).
--
-- THE SAME IDEA ONE LEVEL UP: pay_due() locks the due row, so two payments
-- cannot overpay one baki. Create a due of 100, then in window 1 run
--     BEGIN;  SELECT pay_due(<due_id>, 100, 'race-a');
-- and in window 2
--     SELECT pay_due(<due_id>, 100, 'race-b');
-- Window 2 waits, then fails with:
--     Due <due_id> is already fully settled
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 8.2 Index benchmark: the same balance query with and without indexes
--
-- Run this section as one block (psql runs it as is). It creates 2,000 test
-- accounts and 200,000 events inside a transaction, measures the balance
-- query twice with EXPLAIN ANALYZE, and then ROLLBACK removes everything,
-- so your real data is untouched.
--
-- Compare the two plans:
--     Seq Scan on events          reads all 200,000 rows
--     Bitmap Heap Scan / Index    jumps straight to the ~200 rows of one account
-- and the "Execution Time" at the bottom of each plan.
-- -----------------------------------------------------------------------------

BEGIN;

-- Switch off the append-only and audit triggers for this transaction only,
-- so the bulk insert is fast. ROLLBACK at the end brings everything back.
ALTER TABLE events DISABLE TRIGGER USER;
ALTER TABLE users DISABLE TRIGGER USER;
ALTER TABLE accounts DISABLE TRIGGER USER;

-- 2,000 test users and accounts.
INSERT INTO users (name, phone)
SELECT 'Load ' || i, 'L' || LPAD(i::TEXT, 8, '0')
FROM generate_series(1, 2000) AS i;

INSERT INTO accounts (acc_no, user_id, acc_type)
SELECT 'LOAD-' || LPAD(i::TEXT, 5, '0'), u.user_id, 'customer'
FROM generate_series(1, 2000) AS i
JOIN users u ON u.phone = 'L' || LPAD(i::TEXT, 8, '0');

-- 200,000 successful payments between neighbouring test accounts.
-- i % 2000 and (i + 1) % 2000 are never equal, so from <> to always holds.
INSERT INTO events (event_type, from_acc_no, to_acc_no, amount, fee, fee_receiver_acc_no, status)
SELECT
    'payment',
    'LOAD-' || LPAD((1 + i % 2000)::TEXT, 5, '0'),
    'LOAD-' || LPAD((1 + (i + 1) % 2000)::TEXT, 5, '0'),
    1 + (i % 50),
    5,
    'ACC-000',
    'success'
FROM generate_series(1, 200000) AS i;

-- Refresh the planner's statistics so it knows the new table size.
ANALYZE events;

-- Plan 1: indexes switched off, so Postgres must read the whole table.
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;

EXPLAIN (ANALYZE, COSTS OFF, TIMING ON, SUMMARY ON)
SELECT
    COALESCE(SUM(amount)         FILTER (WHERE to_acc_no           = 'LOAD-00042'), 0)
    - COALESCE(SUM(amount + fee) FILTER (WHERE from_acc_no         = 'LOAD-00042'), 0)
    + COALESCE(SUM(fee)          FILTER (WHERE fee_receiver_acc_no = 'LOAD-00042'), 0)
FROM events
WHERE status = 'success'
  AND (
         to_acc_no           = 'LOAD-00042'
      OR from_acc_no         = 'LOAD-00042'
      OR fee_receiver_acc_no = 'LOAD-00042'
  );

-- Plan 2: indexes switched back on.
SET LOCAL enable_indexscan = on;
SET LOCAL enable_bitmapscan = on;

EXPLAIN (ANALYZE, COSTS OFF, TIMING ON, SUMMARY ON)
SELECT
    COALESCE(SUM(amount)         FILTER (WHERE to_acc_no           = 'LOAD-00042'), 0)
    - COALESCE(SUM(amount + fee) FILTER (WHERE from_acc_no         = 'LOAD-00042'), 0)
    + COALESCE(SUM(fee)          FILTER (WHERE fee_receiver_acc_no = 'LOAD-00042'), 0)
FROM events
WHERE status = 'success'
  AND (
         to_acc_no           = 'LOAD-00042'
      OR from_acc_no         = 'LOAD-00042'
      OR fee_receiver_acc_no = 'LOAD-00042'
  );

-- Undo everything: the test accounts, the 200,000 events, the trigger changes.
ROLLBACK;
