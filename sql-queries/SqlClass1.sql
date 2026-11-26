CREATE DATABASE meridian_retail;

USE meridian_retail;

CREATE TABLE validation_rules (
    rule_id              VARCHAR(10)  NOT NULL,
    applies_to_file      VARCHAR(50)  NOT NULL,
    field_name           VARCHAR(50)  NULL,
    rule_type            VARCHAR(30)  NOT NULL,
    condition_text       TEXT         NOT NULL,
    failure_route        VARCHAR(20)  NOT NULL,
    reason               TEXT         NOT NULL,
    enabled              BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_validation_rules PRIMARY KEY (rule_id),
    CONSTRAINT chk_validation_route
        CHECK (failure_route IN ('REJECT', 'HUMAN_REVIEW', 'PAUSE_LOAD', 'LOAD_WARNING'))
) ENGINE = InnoDB;

CREATE TABLE orders (
    order_id             VARCHAR(12)  NOT NULL,
    product              VARCHAR(100) NOT NULL,
    order_date           DATE         NOT NULL,
    delivery_date        DATE         NULL,
    payment_status       VARCHAR(20)  NOT NULL,
    extract_generated_at DATETIME     NOT NULL,
    CONSTRAINT pk_orders PRIMARY KEY (order_id),
    CONSTRAINT chk_orders_payment_status
        CHECK (payment_status IN ('PAID', 'PENDING', 'FAILED', 'REFUNDED')),
    CONSTRAINT chk_orders_delivery_date
        CHECK (delivery_date IS NULL OR delivery_date >= order_date)
);

CREATE TABLE support_cases (
    case_id              VARCHAR(12)  NOT NULL,
    order_id             VARCHAR(12)  NULL,
    received_at          DATETIME     NOT NULL,
    customer_question    TEXT         NOT NULL,
    case_type            VARCHAR(20)  NOT NULL,
    review_status        VARCHAR(20)  NOT NULL,
    extract_generated_at DATETIME     NOT NULL,
    CONSTRAINT pk_support_cases PRIMARY KEY (case_id),
    CONSTRAINT fk_support_cases_order
        FOREIGN KEY (order_id) REFERENCES orders (order_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_support_case_type
        CHECK (case_type IN ('RETURN', 'DAMAGE', 'DELIVERY', 'BILLING', 'GENERAL')),
    CONSTRAINT chk_support_review_status
        CHECK (review_status IN ('PENDING', 'APPROVED', 'REJECTED'))
) ENGINE = InnoDB;


CREATE TABLE issue_records (
    case_id               VARCHAR(12) NOT NULL,
    issue_type            VARCHAR(30) NOT NULL,
    issue_details         TEXT        NOT NULL,
    reported_delivery_date DATE       NULL,
    evidence_status       VARCHAR(20) NOT NULL,
    extract_generated_at  DATETIME    NOT NULL,
    CONSTRAINT pk_issue_records PRIMARY KEY (case_id),
    CONSTRAINT fk_issue_records_case
        FOREIGN KEY (case_id) REFERENCES support_cases (case_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_issue_evidence_status
        CHECK (evidence_status IN ('VERIFIED', 'PENDING_PROOF', 'NOT_REQUIRED', 'CONFLICTING'))
) ENGINE = InnoDB;

CREATE TABLE human_reviews (
    review_id             VARCHAR(14) NOT NULL,
    case_id               VARCHAR(12) NOT NULL,
    triggered_rule_id     VARCHAR(10) NULL,
    reviewer_role         VARCHAR(50) NOT NULL,
    decision              VARCHAR(30) NOT NULL,
    decision_reason       TEXT        NOT NULL,
    reviewed_at           DATETIME    NOT NULL,
    handling_minutes      SMALLINT UNSIGNED NULL,
    extract_generated_at  DATETIME    NOT NULL,
    CONSTRAINT pk_human_reviews PRIMARY KEY (review_id),
    CONSTRAINT fk_human_reviews_case
        FOREIGN KEY (case_id) REFERENCES support_cases (case_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_human_reviews_rule
        FOREIGN KEY (triggered_rule_id) REFERENCES validation_rules (rule_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_human_review_decision
        CHECK (decision IN ('APPROVED', 'REJECTED', 'NEEDS_INFO', 'ESCALATED')),
    CONSTRAINT chk_human_review_minutes
        CHECK (handling_minutes IS NULL OR handling_minutes BETWEEN 1 AND 1440)
) ENGINE = InnoDB;


Select * from orders;

USE meridian_retail;

START TRANSACTION;

INSERT INTO validation_rules
    (rule_id, applies_to_file, field_name, rule_type, condition_text, failure_route, reason, enabled)
VALUES
    ('VR-001', 'support_cases.csv', 'case_id', 'REQUIRED',
     'case_id must be present', 'REJECT',
     'A support case without an identifier cannot be traced or connected safely.', TRUE),
    ('VR-002', 'support_cases.csv', 'case_id', 'UNIQUE',
     'case_id must be unique within the incoming support load', 'REJECT',
     'Both occurrences of a duplicated case identifier require investigation.', TRUE),
    ('VR-003', 'support_cases.csv', 'order_id', 'CONDITIONAL_REQUIRED',
     'order_id is required when case_type is RETURN or DAMAGE', 'REJECT',
     'Purchase-related cases require an order link.', TRUE),
    ('VR-004', 'support_cases.csv', 'review_status', 'ALLOWED_VALUES',
     'review_status must be PENDING, APPROVED or REJECTED', 'REJECT',
     'Unknown workflow states must be confirmed before publication.', TRUE),
    ('VR-005', 'orders.csv', 'delivery_date', 'DATE_FORMAT',
     'A present delivery_date must be a valid YYYY-MM-DD calendar date', 'REJECT',
     'Malformed dates cannot support delivery analysis.', TRUE),
    ('VR-006', 'issue_records.csv', 'reported_delivery_date', 'CROSS_SOURCE_MATCH',
     'Reported and order delivery dates must agree when both are present', 'HUMAN_REVIEW',
     'A person must resolve a readable disagreement between two sources.', TRUE),
    ('VR-007', 'all_required_files', NULL, 'SCHEMA_CONTRACT',
     'Every required file and required column must exist', 'PAUSE_LOAD',
     'The affected path cannot publish until the delivery structure is confirmed.', TRUE),
    ('VR-008', 'all_required_files', 'extract_generated_at', 'FRESHNESS',
     'extract_generated_at must be within 24 hours of the scheduled daily load', 'LOAD_WARNING',
     'Older data may still be usable, but only for questions that do not require current state.', TRUE),
    ('VR-009', 'trusted_tables', NULL, 'IDEMPOTENCY',
     'Rerunning the same content and identifiers must create no additional trusted rows', 'PAUSE_LOAD',
     'A repeated load must not duplicate published evidence.', TRUE),
    ('VR-010', 'issue_records.csv', 'evidence_status', 'EVIDENCE_REQUIRED',
     'PENDING_PROOF cases require human review before a consequential decision', 'HUMAN_REVIEW',
     'The available evidence is not yet sufficient for an automated outcome.', TRUE),
    ('VR-011', 'orders.csv', 'payment_status', 'PAYMENT_EXCEPTION',
     'FAILED payment evidence connected to a billing case requires human review', 'HUMAN_REVIEW',
     'Payment exceptions may require reconciliation across systems.', TRUE),
    ('VR-012', 'support_cases.csv', 'received_at', 'AGEING_CASE',
     'A PENDING case older than the operating threshold requires human review', 'HUMAN_REVIEW',
     'Ageing cases need explicit ownership rather than remaining silently open.', TRUE);


-- Class 5 anchor records remain visible with their original identifiers.
INSERT INTO orders
    (order_id, product, order_date, delivery_date, payment_status, extract_generated_at)
VALUES
    ('MR-501', 'Pro Wireless Headphones', '2026-09-10', '2026-09-13', 'PAID', '2026-09-18 11:30:00'),
    ('MR-502', 'USB-C Multi-Port Hub',    '2026-09-09', '2026-09-12', 'PAID', '2026-09-18 11:30:00');

INSERT INTO support_cases
    (case_id, order_id, received_at, customer_question, case_type, review_status, extract_generated_at)
VALUES
    ('MCS-501', 'MR-501', '2026-09-14 09:15:00',
     'The replacement headphones are still producing static.', 'DAMAGE', 'APPROVED', '2026-09-18 11:35:00'),
    ('MCS-502', 'MR-502', '2026-09-14 10:20:00',
     'The delivery date in my message differs from the order record. Which date is correct?',
     'DELIVERY', 'PENDING', '2026-09-18 11:35:00');



INSERT INTO issue_records
    (case_id, issue_type, issue_details, reported_delivery_date, evidence_status, extract_generated_at)
VALUES
    ('MCS-501', 'HARDWARE_FAULT',
     'Audio static continues after replacement and basic troubleshooting.', '2026-09-13',
     'VERIFIED', '2026-09-18 11:40:00'),
    ('MCS-502', 'LATE_DELIVERY',
     'Customer message reports a delivery date that differs from the order export.', '2026-09-13',
     'CONFLICTING', '2026-09-18 11:40:00');

INSERT INTO human_reviews
    (review_id, case_id, triggered_rule_id, reviewer_role, decision, decision_reason,
     reviewed_at, handling_minutes, extract_generated_at)
VALUES
    ('MHR-502', 'MCS-502', 'VR-006', 'OPERATIONS_REVIEWER', 'NEEDS_INFO',
     'Waiting for source ownership confirmation before choosing a delivery date.',
     '2026-09-14 11:05:00', 45, '2026-09-16 10:00:00');

-- Small temporary number generator: 1 through 25,000.
CREATE TEMPORARY TABLE seed_digits (digit TINYINT UNSIGNED NOT NULL PRIMARY KEY);
INSERT INTO seed_digits (digit)
VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9);

#select * from seed_digits;


CREATE TEMPORARY TABLE seed_numbers (n INT UNSIGNED NOT NULL PRIMARY KEY);
/*INSERT INTO seed_numbers (n)
SELECT generated.n
FROM (
    SELECT
        ones.digit
        + tens.digit * 10
        + hundreds.digit * 100
        + thousands.digit * 1000
        + ten_thousands.digit * 10000
        + 1 AS n
    FROM seed_digits AS ones
    CROSS JOIN seed_digits AS tens
    CROSS JOIN seed_digits AS hundreds
    CROSS JOIN seed_digits AS thousands
    CROSS JOIN seed_digits AS ten_thousands
) AS generated
WHERE generated.n <= 25000;*/

SET SESSION cte_max_recursion_depth = 25001;

INSERT INTO seed_numbers (n)
WITH RECURSIVE numbers AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1
    FROM numbers
    WHERE n < 25000
)
SELECT n
FROM numbers;

select * from seed_numbers;


-- 19,998 generated orders plus the two Class 5 anchors = 20,000.
                                                                                     
select * from orders;

-- 19,998 generated orders plus the two Class 5 anchors = 20,000.
INSERT INTO orders
    (order_id, product, order_date, delivery_date, payment_status, extract_generated_at)
SELECT
    CONCAT('MR-', LPAD(n, 6, '0')) AS order_id,
    CASE MOD(n * 7 + FLOOR(n / 20), 20)
        WHEN 0 THEN 'Pro Wireless Headphones'
        WHEN 1 THEN 'Pro Wireless Headphones'
        WHEN 2 THEN 'Pro Wireless Headphones'
        WHEN 3 THEN 'USB-C Multi-Port Hub'
        WHEN 4 THEN 'USB-C Multi-Port Hub'
        WHEN 5 THEN 'Mechanical RGB Keyboard'
        WHEN 6 THEN 'Mechanical RGB Keyboard'
        WHEN 7 THEN 'Ergonomic Mesh Chair'
        WHEN 8 THEN 'Standing Desk Converter'
        WHEN 9 THEN 'Smartwatch Series V'
        WHEN 10 THEN 'Noise Cancelling Earbuds'
        WHEN 11 THEN 'HD Webcam 1080p'
        WHEN 12 THEN 'Pro Wireless Mouse'
        WHEN 13 THEN 'Laptop Cooling Stand'
        WHEN 14 THEN 'Portable SSD 1TB'
        WHEN 15 THEN '27-inch 4K Monitor'
        WHEN 16 THEN 'Smart LED Desk Lamp'
        WHEN 17 THEN 'Bluetooth Speaker Mini'
        WHEN 18 THEN 'Fitness Tracker Band'
        ELSE 'Compact Mechanical Keypad'
    END AS product,
    DATE_ADD('2026-01-01', INTERVAL MOD(n * 7, 240) DAY) AS order_date,
    CASE
        WHEN MOD(n, 17) = 0 OR MOD(n, 23) = 0 THEN NULL
        ELSE DATE_ADD(
            DATE_ADD('2026-01-01', INTERVAL MOD(n * 7, 240) DAY),
            INTERVAL (2 + MOD(n, 7)) DAY
        )
    END AS delivery_date,
    CASE
        WHEN MOD(n, 20) < 14 THEN 'PAID'
        WHEN MOD(n, 20) < 16 THEN 'PENDING'
        WHEN MOD(n, 20) < 18 THEN 'FAILED'
        ELSE 'REFUNDED'
    END AS payment_status,
    CASE
        WHEN MOD(n, 29) = 0 THEN '2026-09-16 10:00:00'
        ELSE '2026-09-18 11:30:00'
    END AS extract_generated_at
FROM seed_numbers
WHERE n <= 19998;

-- 24,998 generated cases plus the two Class 5 anchors = 25,000.
INSERT INTO support_cases
    (case_id, order_id, received_at, customer_question, case_type, review_status, extract_generated_at)
SELECT
    CONCAT('MCS-', LPAD(n, 6, '0')) AS case_id,
    CASE
        WHEN MOD(n, 10) = 0 THEN NULL
        ELSE CONCAT('MR-', LPAD(1 + MOD(n * 13 - 1, 19998), 6, '0'))
    END AS order_id,
    DATE_ADD('2026-09-01 08:00:00', INTERVAL MOD(n * 37, 18720) MINUTE) AS received_at,
    CASE
        WHEN MOD(n, 10) = 0 THEN 'Can you explain how the warranty process works?'
        WHEN MOD(n, 10) IN (1, 2) THEN 'I want to return this item. What should I do next?'
        WHEN MOD(n, 10) IN (3, 4) THEN 'The item arrived damaged and I need help.'
        WHEN MOD(n, 10) IN (5, 6, 7) THEN 'Where is my package? The delivery appears delayed.'
        ELSE 'The payment or refund status does not look correct.'
    END AS customer_question,
    CASE
        WHEN MOD(n, 10) = 0 THEN 'GENERAL'
        WHEN MOD(n, 10) IN (1, 2) THEN 'RETURN'
        WHEN MOD(n, 10) IN (3, 4) THEN 'DAMAGE'
        WHEN MOD(n, 10) IN (5, 6, 7) THEN 'DELIVERY'
        ELSE 'BILLING'
    END AS case_type,
    CASE
        WHEN MOD(n, 20) < 11 THEN 'APPROVED'
        WHEN MOD(n, 20) < 16 THEN 'PENDING'
        ELSE 'REJECTED'
    END AS review_status,
    CASE
        WHEN MOD(n, 31) = 0 THEN '2026-09-16 09:00:00'
        ELSE '2026-09-18 11:35:00'
    END AS extract_generated_at
FROM seed_numbers
WHERE n <= 24998;

select * from issue_records;

-- One issue row per trusted support case at the Class 6-7 baseline.
INSERT INTO issue_records
    (case_id, issue_type, issue_details, reported_delivery_date, evidence_status, extract_generated_at)
SELECT
    sc.case_id,
    CASE
        WHEN sc.case_type = 'RETURN' AND MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 3) = 0 THEN 'REFUND_DELAY'
        WHEN sc.case_type = 'RETURN' THEN 'RETURN_REQUEST'
        WHEN sc.case_type = 'DAMAGE' AND MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 2) = 0 THEN 'HARDWARE_FAULT'
        WHEN sc.case_type = 'DAMAGE' THEN 'PHYSICAL_DAMAGE'
        WHEN sc.case_type = 'DELIVERY' AND MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 5) = 0 THEN 'MISSING_ITEM'
        WHEN sc.case_type = 'DELIVERY' AND MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 5) = 1 THEN 'WRONG_ITEM'
        WHEN sc.case_type = 'DELIVERY' THEN 'LATE_DELIVERY'
        WHEN sc.case_type = 'BILLING' AND MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 3) = 0 THEN 'DOUBLE_CHARGE'
        WHEN sc.case_type = 'BILLING' AND MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 3) = 1 THEN 'PAYMENT_FAILURE'
        WHEN sc.case_type = 'BILLING' THEN 'REFUND_DELAY'
        WHEN MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 2) = 0 THEN 'USER_GUIDANCE'
        ELSE 'ACCOUNT_QUERY'
    END AS issue_type,
    CASE
        WHEN sc.case_type = 'RETURN' THEN 'Customer requested a return or refund review.'
        WHEN sc.case_type = 'DAMAGE' THEN 'Customer reported damage or a continuing product fault.'
        WHEN sc.case_type = 'DELIVERY' THEN 'Customer reported a delivery exception.'
        WHEN sc.case_type = 'BILLING' THEN 'Customer reported a payment or refund exception.'
        ELSE 'Customer requested guidance that does not require an order link.'
    END AS issue_details,
    CASE
        WHEN sc.order_id IS NULL OR o.delivery_date IS NULL THEN NULL
        WHEN MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 37) = 0 THEN DATE_ADD(o.delivery_date, INTERVAL 1 DAY)
        ELSE o.delivery_date
    END AS reported_delivery_date,
    CASE
        WHEN MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 37) = 0 AND o.delivery_date IS NOT NULL THEN 'CONFLICTING'
        WHEN MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 11) = 0 THEN 'PENDING_PROOF'
        WHEN sc.case_type = 'GENERAL' THEN 'NOT_REQUIRED'
        ELSE 'VERIFIED'
    END AS evidence_status,
    CASE
        WHEN MOD(CAST(SUBSTRING_INDEX(sc.case_id, '-', -1) AS UNSIGNED), 43) = 0 THEN '2026-09-16 09:30:00'
        ELSE '2026-09-18 11:40:00'
    END AS extract_generated_at
FROM support_cases AS sc
LEFT JOIN orders AS o
    ON o.order_id = sc.order_id
WHERE sc.case_id LIKE 'MCS-0%';

-- The two anchor issues were inserted before the generated set.
-- Generated reviews: 7,999 first reviews + 2,000 follow-up reviews.
-- Adding MHR-502 produces 10,000 review events across 8,000 distinct cases.
select * from human_reviews;
INSERT INTO human_reviews
    (review_id, case_id, triggered_rule_id, reviewer_role, decision, decision_reason,
     reviewed_at, handling_minutes, extract_generated_at)
SELECT
    CONCAT('MHR-', LPAD(review_seed.n, 6, '0')) AS review_id,
    review_seed.case_id,
    CASE
        WHEN ir.evidence_status = 'CONFLICTING' THEN 'VR-006'
        WHEN ir.evidence_status = 'PENDING_PROOF' THEN 'VR-010'
        WHEN sc.case_type = 'BILLING' AND o.payment_status = 'FAILED' THEN 'VR-011'
        WHEN sc.review_status = 'PENDING' THEN 'VR-012'
        ELSE NULL
    END AS triggered_rule_id,
    CASE MOD(review_seed.n, 4)
        WHEN 0 THEN 'OPERATIONS_REVIEWER'
        WHEN 1 THEN 'PAYMENTS_SPECIALIST'
        WHEN 2 THEN 'LOGISTICS_SPECIALIST'
        ELSE 'TIER_2_SUPPORT'
    END AS reviewer_role,
    CASE
        WHEN MOD(review_seed.n, 20) < 8 THEN 'APPROVED'
        WHEN MOD(review_seed.n, 20) < 13 THEN 'NEEDS_INFO'
        WHEN MOD(review_seed.n, 20) < 17 THEN 'REJECTED'
        ELSE 'ESCALATED'
    END AS decision,
    CASE
        WHEN MOD(review_seed.n, 20) < 8 THEN 'Available evidence supports the requested action.'
        WHEN MOD(review_seed.n, 20) < 13 THEN 'More source evidence is required before a final decision.'
        WHEN MOD(review_seed.n, 20) < 17 THEN 'The request does not meet the current policy or evidence requirement.'
        ELSE 'The case requires a specialist decision outside the first review boundary.'
    END AS decision_reason,
    DATE_ADD(sc.received_at, INTERVAL (15 + MOD(review_seed.n * 7, 240)) MINUTE) AS reviewed_at,
    CASE
        WHEN MOD(review_seed.n, 997) = 0 THEN 480
        WHEN MOD(review_seed.n, 211) = 0 THEN 300
        ELSE 10 + MOD(review_seed.n * 17, 171)
    END AS handling_minutes,
    CASE
        WHEN MOD(review_seed.n, 41) = 0 THEN '2026-09-16 10:00:00'
        ELSE '2026-09-18 11:45:00'
    END AS extract_generated_at
FROM (
    SELECT
        n,
        CASE
            WHEN n <= 7999 THEN CONCAT('MCS-', LPAD(n, 6, '0'))
            ELSE CONCAT('MCS-', LPAD(n - 7999, 6, '0'))
        END AS case_id
    FROM seed_numbers
    WHERE n <= 9999
) AS review_seed
JOIN support_cases AS sc
    ON sc.case_id = review_seed.case_id
JOIN issue_records AS ir
    ON ir.case_id = sc.case_id
LEFT JOIN orders AS o
    ON o.order_id = sc.order_id;

DROP TEMPORARY TABLE seed_numbers;
DROP TEMPORARY TABLE seed_digits;



COMMIT;

--------------------------------------------------------------------------------------

-- to fetch all the rows from order table
SELECT * from Orders;

Select * from support_cases;
Select * from human_reviews;

-- Count all the rows in orders table
Select COUNT(*) from orders;
Select count(order_date) from ORDERS;

-- where clause is used to filter the rows on a particular condition 
Select * from orders where order_id = 'MR-000003';

-- Show the data where payment status is paid
Select * from orders where payment_status = 'paid';

-- Count the number of entries where payment status is paid
Select Count(*) from orders where payment_status = 'paid';

--  Get all the orders which were placed after 15th March, 2026
select * from orders where order_date > "2026-03-15";

--  Get all the orders which has delivery date as null
select * from orders where delivery_date IS NULL;

-- give the order_id, product, order_date and delivery_date of each order then we have sorted 
-- them in descending order, and looked at the top 5.
select order_id, product, order_date, delivery_date from orders
Order by Order_id desc
LIMIT 5;

Select * from support_cases;

-- Get all the pending cases which are of type delivery or billing
select * from support_cases 
where review_status ='PENDING'
AND (case_type ='DELIVERY' or case_type ='BILLING');

select * from support_cases 
where review_status ='PENDING'
AND case_type IN ('DELIVERY' , 'BILLING');



-- cond1 (cond2 cond3)

Select * from Human_reviews;

Select Count(*) from Human_reviews;
Select DISTINCT(Count(review_id)) from Human_reviews;
SELECT count(distinct review_id) FROM human_reviews;


-- Homework

-- Return the ten most recently received PENDING support cases.
-- Count orders by payment_status and sort the largest group first.
-- Return issue types that appear more than 2500 times in issue_records.
-- Show review-event count, distinct reviewed-case count, and average handling_minutes, grouped by reviewer_role.
-- Return review_id, case_id, decision and reviewed_at for every review event where triggered_rule_id = 'VR-006'.
-- In one sentence, explain why task 5 still cannot tell you the issue type of those cases without touching a second table.




