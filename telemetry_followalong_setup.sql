-- =============================================================================
-- telemetry_followalong_setup.sql
--
-- Follow-along script for:
--   "Turning Telemetry into a Data Product Your Teams and Customers Actually Use"
--
-- Creates everything the blog describes in the provider account:
--   0. One-time admin setup: warehouse and least-privilege provider role
--   1. Telemetry events table with synthetic data (10 000 rows, 6 customers)
--   2. Entitlements table (customer-to-account mapping)
--   3. Home-region secure views (fleet + customer)
--   4. Semantic views (fleet + customer)
--   5. Cortex Agents (fleet + customer)
--   6. Regional databases with dynamic tables, views, semantic views, agents
--      (AWS us-east-1 and GCP us-central1)
--   7. Shares with all grants
--   8. Change tracking
--   9. Listings (commented out; requires real consumer accounts)
--
-- Section 0 runs once as ACCOUNTADMIN. Everything
-- after it runs as TELEMETRY_PROVIDER, which owns every object it creates.
-- Replace <your_user> and, if needed, TELEMETRY_WH.
-- The script maps CUST_001 to your own account so you can test the filter.
-- =============================================================================


-- ─── 0. One-time admin setup ───────────────────────────────────────────────

USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS TELEMETRY_WH
  WITH WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

CREATE ROLE IF NOT EXISTS TELEMETRY_PROVIDER
  COMMENT = 'Least-privilege role for building and publishing the telemetry data product';
GRANT ROLE TELEMETRY_PROVIDER TO USER <your_user>;

GRANT USAGE, OPERATE ON WAREHOUSE TELEMETRY_WH            TO ROLE TELEMETRY_PROVIDER;
GRANT CREATE DATABASE                 ON ACCOUNT           TO ROLE TELEMETRY_PROVIDER;
GRANT CREATE SHARE                    ON ACCOUNT           TO ROLE TELEMETRY_PROVIDER;
GRANT CREATE LISTING                  ON ACCOUNT           TO ROLE TELEMETRY_PROVIDER;
GRANT CREATE ORGANIZATION LISTING     ON ACCOUNT           TO ROLE TELEMETRY_PROVIDER;
GRANT MANAGE LISTING AUTO FULFILLMENT ON ACCOUNT           TO ROLE TELEMETRY_PROVIDER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER                  TO ROLE TELEMETRY_PROVIDER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER            TO ROLE TELEMETRY_PROVIDER;
GRANT DATABASE ROLE SNOWFLAKE.DATA_SHARING_USAGE_VIEWER    TO ROLE TELEMETRY_PROVIDER;

-- From here on, no admin role is needed.
USE ROLE TELEMETRY_PROVIDER;
USE WAREHOUSE TELEMETRY_WH;

CREATE DATABASE IF NOT EXISTS TELEMETRY_DB;
CREATE SCHEMA IF NOT EXISTS TELEMETRY_DB.RAW;
CREATE SCHEMA IF NOT EXISTS TELEMETRY_DB.PRIVATE;
CREATE SCHEMA IF NOT EXISTS TELEMETRY_DB.PUBLISH;


-- ─── 1. Telemetry events table with synthetic data ──────────────────────────

CREATE OR REPLACE TABLE TELEMETRY_DB.RAW.EVENTS (
    event_id        STRING,
    event_timestamp TIMESTAMP_NTZ,
    customer_id     STRING,
    device_id       STRING,
    event_type      STRING,
    metric_name     STRING,
    metric_value    FLOAT,
    attributes      VARIANT
);

INSERT INTO TELEMETRY_DB.RAW.EVENTS
SELECT UUID_STRING(),
       DATEADD('second', -UNIFORM(0, 7776000, RANDOM()), CURRENT_TIMESTAMP())::TIMESTAMP_NTZ,
       'CUST_00' || c,
       'DEV-CUST_00' || c || '-' || LPAD(UNIFORM(1, 50, RANDOM())::STRING, 3, '0'),
       ARRAY_CONSTRUCT('LOGIN','PAGE_VIEW','API_CALL','ERROR','LATENCY')[t]::STRING,
       ARRAY_CONSTRUCT('login_duration_ms','page_load_ms','api_latency_ms','error_count','response_time_ms')[t]::STRING,
       ROUND(UNIFORM(10::FLOAT, 5000::FLOAT, RANDOM()), 2),
       OBJECT_CONSTRUCT(
         'app_version', ARRAY_CONSTRUCT('2.1.0','2.2.0','2.3.0','3.0.0-beta')[UNIFORM(0, 3, RANDOM())]::STRING,
         'office',      ARRAY_CONSTRUCT('San Francisco','New York','London','Tokyo','Berlin')[UNIFORM(0, 4, RANDOM())]::STRING)
FROM (SELECT UNIFORM(1, 6, RANDOM()) AS c, UNIFORM(0, 4, RANDOM()) AS t
      FROM TABLE(GENERATOR(ROWCOUNT => 10000)));


-- ─── 1b. OPTIONAL: if your telemetry is in a data lake (example: Amazon S3) ──
-- Use this instead of the synthetic INSERT above when your telemetry already
-- sits in Apache Iceberg(TM) tables in Amazon S3, registered in AWS Glue.
-- Snowflake registers the lake tables in a catalog-linked database without
-- copying them; the INSERT at the end loads them into TELEMETRY_DB.RAW.EVENTS
-- so everything after this section runs unchanged.
--
-- Prerequisites outside Snowflake (one-time, in AWS):
--   - An S3 bucket/prefix holding the Iceberg data, e.g. s3://<bucket>/helio_telemetry/
--   - A Glue database (namespace), e.g. helio_telemetry, with tables events and entitlements
--   - An IAM role Snowflake can assume, with s3:GetObject/ListBucket on the prefix and
--     glue:GetCatalog, glue:GetDatabase(s), glue:GetTable(s) on the Glue catalog
-- Creating integrations and external volumes needs ACCOUNTADMIN or a role
-- granted CREATE INTEGRATION and CREATE EXTERNAL VOLUME on the account. Then
-- grant TELEMETRY_PROVIDER USAGE on HELIO_LAKE_DB and SELECT on its tables.
-- Replace every <placeholder> before running.

/*
-- 1. External volume: where the Iceberg data and metadata files live.
CREATE EXTERNAL VOLUME HELIO_ICEBERG_VOL
  STORAGE_LOCATIONS = ((
    NAME                 = 'helio-s3'
    STORAGE_PROVIDER     = 'S3'
    STORAGE_BASE_URL     = 's3://<bucket>/helio_telemetry/'
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<aws_account_id>:role/<snowflake_iceberg_role>'
    STORAGE_AWS_EXTERNAL_ID = '<external_id>'
  ))
  ALLOW_WRITES = FALSE;

-- 2. Catalog integration: the AWS Glue Iceberg REST endpoint.
CREATE CATALOG INTEGRATION HELIO_GLUE_CAT_INT
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT   = ICEBERG
  REST_CONFIG = (
    CATALOG_URI            = 'https://glue.<aws_region>.amazonaws.com/iceberg'
    CATALOG_API_TYPE       = AWS_GLUE
    CATALOG_NAME           = '<aws_account_id>'
    ACCESS_DELEGATION_MODE = EXTERNAL_VOLUME_CREDENTIALS
  )
  REST_AUTHENTICATION = (
    TYPE                 = SIGV4
    SIGV4_IAM_ROLE       = 'arn:aws:iam::<aws_account_id>:role/<snowflake_iceberg_role>'
    SIGV4_SIGNING_REGION = '<aws_region>'
  )
  ENABLED = TRUE;

-- 3. Copy the Snowflake principal into the IAM role's trust policy.
--    Use API_AWS_IAM_USER_ARN / API_AWS_EXTERNAL_ID from the first command and
--    STORAGE_AWS_IAM_USER_ARN / STORAGE_AWS_EXTERNAL_ID from the second.
DESCRIBE CATALOG INTEGRATION HELIO_GLUE_CAT_INT;
DESCRIBE EXTERNAL VOLUME HELIO_ICEBERG_VOL;

-- 4. Catalog-linked database. EXTERNAL_VOLUME goes after the LINKED_CATALOG
--    block, not inside it.
CREATE DATABASE HELIO_LAKE_DB
  LINKED_CATALOG = (
    CATALOG            = 'HELIO_GLUE_CAT_INT'
    ALLOWED_NAMESPACES = ('helio_telemetry')
  )
  EXTERNAL_VOLUME = 'HELIO_ICEBERG_VOL';

-- 5. Confirm the lake tables were discovered (names are lowercase, so quote them).
SELECT SYSTEM$CATALOG_LINK_STATUS('HELIO_LAKE_DB');
SHOW ICEBERG TABLES IN DATABASE HELIO_LAKE_DB;
SELECT COUNT(*) FROM HELIO_LAKE_DB."helio_telemetry"."events";

-- 6. Load the lake telemetry into the governed table the rest of this script uses.
--    In production, schedule this as a task or use a dynamic table, refreshing
--    only new rows. Streams and dynamic tables are not supported on shared
--    Iceberg v2 tables, which is why the product reads from a standard table.
TRUNCATE TABLE TELEMETRY_DB.RAW.EVENTS;
INSERT INTO TELEMETRY_DB.RAW.EVENTS
SELECT "event_id", "event_timestamp", "customer_id", "device_id", "event_type",
       "metric_name", "metric_value", PARSE_JSON("attributes")
FROM HELIO_LAKE_DB."helio_telemetry"."events";
*/


-- ─── 2. Entitlements ────────────────────────────────────────────────────────
-- CUST_001 maps to your own account so you can test the secure view.

CREATE OR REPLACE TABLE TELEMETRY_DB.PRIVATE.ENTITLEMENTS (
    customer_id      STRING,
    consumer_account STRING,
    consumer_region  STRING,
    is_active        BOOLEAN
);

INSERT INTO TELEMETRY_DB.PRIVATE.ENTITLEMENTS VALUES
  ('CUST_001', CURRENT_ACCOUNT(),              'AWS_US_WEST_2',   TRUE),
  ('CUST_002', 'CUSTOMER_A_ACCOUNT_LOCATOR',   'AWS_US_WEST_2',   TRUE),
  ('CUST_003', 'CUSTOMER_B_ACCOUNT_LOCATOR',   'AWS_US_WEST_2',   TRUE),
  ('CUST_004', 'CUSTOMER_C_ACCOUNT_LOCATOR',   'AWS_US_EAST_1',   TRUE),
  ('CUST_005', 'CUSTOMER_D_ACCOUNT_LOCATOR',   'GCP_US_CENTRAL1', FALSE),
  ('CUST_006', 'CUSTOMER_E_ACCOUNT_LOCATOR',   'GCP_US_CENTRAL1', TRUE);


-- ─── 3. Home-region secure views ────────────────────────────────────────────

-- Fleet view: internal teams, all customers, no filter.
CREATE OR REPLACE SECURE VIEW TELEMETRY_DB.PUBLISH.V_FLEET_EVENTS AS
SELECT e.event_id, e.event_timestamp, e.customer_id, e.device_id, e.event_type,
       e.metric_name, e.metric_value,
       e.attributes:app_version::STRING AS app_version,
       e.attributes:office::STRING      AS office
FROM TELEMETRY_DB.RAW.EVENTS e;

-- Customer view: external consumers, filtered by CURRENT_ACCOUNT().
CREATE OR REPLACE SECURE VIEW TELEMETRY_DB.PUBLISH.V_CUSTOMER_EVENTS AS
SELECT e.event_id, e.event_timestamp, e.device_id, e.event_type,
       e.metric_name, e.metric_value,
       e.attributes:app_version::STRING AS app_version,
       e.attributes:office::STRING      AS office
FROM TELEMETRY_DB.RAW.EVENTS e
JOIN TELEMETRY_DB.PRIVATE.ENTITLEMENTS ent
  ON  ent.customer_id      = e.customer_id
  AND ent.consumer_account = CURRENT_ACCOUNT()
  AND ent.is_active;


USE DATABASE TELEMETRY_DB;
USE SCHEMA TELEMETRY_DB.PUBLISH;


-- ─── 4. Semantic views ──────────────────────────────────────────────────────

-- Fleet semantic view: fleet-wide metrics for internal teams.
CREATE OR REPLACE SEMANTIC VIEW TELEMETRY_DB.PUBLISH.SV_FLEET

  TABLES (
    events AS TELEMETRY_DB.PUBLISH.V_FLEET_EVENTS
      PRIMARY KEY (event_id)
      COMMENT = 'Product telemetry events across all customers'
  )

  DIMENSIONS (
    events.customer AS customer_id
      COMMENT = 'Customer identifier',
    events.event_date AS event_timestamp
      COMMENT = 'When the event occurred',
    events.event_category AS event_type
      WITH SYNONYMS = ('event kind', 'type')
      COMMENT = 'LOGIN, PAGE_VIEW, API_CALL, ERROR, or LATENCY',
    events.app_release AS app_version
      WITH SYNONYMS = ('version', 'release')
      COMMENT = 'Application version that generated the event',
    events.location AS office
      WITH SYNONYMS = ('city', 'site')
      COMMENT = 'Office location of the device'
  )

  METRICS (
    events.weekly_active_accounts AS COUNT(DISTINCT customer_id)
      COMMENT = 'Number of distinct customers with at least one event',
    events.event_count AS COUNT(event_id)
      COMMENT = 'Total number of events',
    events.error_count AS SUM(IFF(event_type = 'ERROR', 1, 0))
      COMMENT = 'Number of error events',
    events.crash_rate AS SUM(IFF(event_type = 'ERROR', 1, 0)) / NULLIF(COUNT(*), 0)
      COMMENT = 'Fraction of events that are errors',
    events.avg_latency AS AVG(IFF(event_type = 'LATENCY', metric_value, NULL))
      COMMENT = 'Average response time for latency events in milliseconds',
    events.active_devices AS COUNT(DISTINCT device_id)
      COMMENT = 'Number of distinct devices with events'
  )

  COMMENT = 'Fleet-wide telemetry: weekly active accounts, crash rate per release, feature adoption by plan';


-- Customer semantic view: per-customer metrics for external consumers.
CREATE OR REPLACE SEMANTIC VIEW TELEMETRY_DB.PUBLISH.SV_CUSTOMER

  TABLES (
    events AS TELEMETRY_DB.PUBLISH.V_CUSTOMER_EVENTS
      PRIMARY KEY (event_id)
      COMMENT = 'Product telemetry events for the querying customer only'
  )

  DIMENSIONS (
    events.event_date AS event_timestamp
      COMMENT = 'When the event occurred',
    events.event_category AS event_type
      WITH SYNONYMS = ('event kind', 'type')
      COMMENT = 'LOGIN, PAGE_VIEW, API_CALL, ERROR, or LATENCY',
    events.app_release AS app_version
      WITH SYNONYMS = ('version', 'release')
      COMMENT = 'Application version that generated the event',
    events.location AS office
      WITH SYNONYMS = ('city', 'site')
      COMMENT = 'Office location of the device'
  )

  METRICS (
    events.active_users AS COUNT(DISTINCT device_id)
      COMMENT = 'Number of distinct devices (proxy for active users)',
    events.event_count AS COUNT(event_id)
      COMMENT = 'Total number of events',
    events.error_rate AS SUM(IFF(event_type = 'ERROR', 1, 0)) / NULLIF(COUNT(*), 0)
      COMMENT = 'Fraction of events that are errors, by office or app version',
    events.avg_latency AS AVG(IFF(event_type = 'LATENCY', metric_value, NULL))
      COMMENT = 'Average response time for latency events in milliseconds'
  )

  COMMENT = 'Customer-scoped telemetry: active users, error rate by office, license utilization';


-- ─── 5. Cortex Agents ───────────────────────────────────────────────────────

-- Fleet agent: internal teams ask fleet-wide questions.
CREATE OR REPLACE AGENT TELEMETRY_DB.PUBLISH.FLEET_AGENT
  COMMENT = 'Fleet-wide telemetry agent for internal teams'
  PROFILE = '{"display_name": "Fleet Intelligence Agent"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  instructions:
    response: "Answer questions about fleet-wide product telemetry across all customers. Format numbers with commas and percentages with one decimal place."
    orchestration: "Use the Fleet_Analyst tool for any question about customers, events, adoption, crash rates, latency, or product metrics."
    sample_questions:
      - question: "How many active accounts did we have this week?"
      - question: "What is the crash rate by app version?"
      - question: "Which offices have the highest average latency?"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "Fleet_Analyst"
        description: "Generates SQL over fleet telemetry including weekly active accounts, crash rate per release, error counts, and latency metrics."

  tool_resources:
    Fleet_Analyst:
      semantic_view: "TELEMETRY_DB.PUBLISH.SV_FLEET"
      execution_environment:
        type: "warehouse"
        warehouse: "TELEMETRY_WH"
  $$;

-- Customer agent: external consumers ask about their own telemetry.
CREATE OR REPLACE AGENT TELEMETRY_DB.PUBLISH.CUSTOMER_AGENT
  COMMENT = 'Customer-scoped telemetry agent for external consumers'
  PROFILE = '{"display_name": "Product Insights Agent"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  instructions:
    response: "Answer questions about your product telemetry. You see only your own data. Format numbers with commas."
    orchestration: "Use the Customer_Analyst tool for any question about events, active users, errors, latency, or usage metrics."
    sample_questions:
      - question: "How many active devices do I have this month?"
      - question: "What is my error rate by office?"
      - question: "Show me average latency by app version over the last 30 days."

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "Customer_Analyst"
        description: "Generates SQL over your telemetry including active users, error rates by office, and latency metrics."

  tool_resources:
    Customer_Analyst:
      semantic_view: "TELEMETRY_DB.PUBLISH.SV_CUSTOMER"
      execution_environment:
        type: "warehouse"
        warehouse: "TELEMETRY_WH"
  $$;


-- ─── 6. Regional databases ──────────────────────────────────────────────────
-- One per remote region. Each is self-contained (required for auto-fulfillment).

-- ── AWS us-east-1 ──

CREATE DATABASE IF NOT EXISTS TELEMETRY_AWS_US_EAST_1;
CREATE SCHEMA IF NOT EXISTS TELEMETRY_AWS_US_EAST_1.PUBLISH;

CREATE OR REPLACE DYNAMIC TABLE TELEMETRY_AWS_US_EAST_1.PUBLISH.DT_EVENTS
  TARGET_LAG   = '1 hour'
  WAREHOUSE    = TELEMETRY_WH
  REFRESH_MODE = INCREMENTAL
AS
SELECT e.event_id, e.event_timestamp, e.customer_id, e.device_id, e.event_type,
       e.metric_name, e.metric_value,
       e.attributes:app_version::STRING AS app_version,
       e.attributes:office::STRING      AS office
FROM TELEMETRY_DB.RAW.EVENTS e
JOIN (SELECT DISTINCT customer_id
      FROM TELEMETRY_DB.PRIVATE.ENTITLEMENTS
      WHERE consumer_region = 'AWS_US_EAST_1' AND is_active) r
  ON r.customer_id = e.customer_id;

CREATE OR REPLACE DYNAMIC TABLE TELEMETRY_AWS_US_EAST_1.PUBLISH.DT_ENTITLEMENTS
  TARGET_LAG   = '1 hour'
  WAREHOUSE    = TELEMETRY_WH
  REFRESH_MODE = INCREMENTAL
AS
SELECT customer_id, consumer_account
FROM TELEMETRY_DB.PRIVATE.ENTITLEMENTS
WHERE consumer_region = 'AWS_US_EAST_1' AND is_active;

CREATE OR REPLACE SECURE VIEW TELEMETRY_AWS_US_EAST_1.PUBLISH.V_CUSTOMER_EVENTS AS
SELECT d.event_id, d.event_timestamp, d.device_id, d.event_type,
       d.metric_name, d.metric_value, d.app_version, d.office
FROM TELEMETRY_AWS_US_EAST_1.PUBLISH.DT_EVENTS d
JOIN TELEMETRY_AWS_US_EAST_1.PUBLISH.DT_ENTITLEMENTS ent
  ON  ent.customer_id      = d.customer_id
  AND ent.consumer_account = CURRENT_ACCOUNT();

CREATE OR REPLACE SEMANTIC VIEW TELEMETRY_AWS_US_EAST_1.PUBLISH.SV_CUSTOMER
  TABLES (
    events AS TELEMETRY_AWS_US_EAST_1.PUBLISH.V_CUSTOMER_EVENTS
      PRIMARY KEY (event_id)
      COMMENT = 'Product telemetry events for customers in AWS us-east-1'
  )
  DIMENSIONS (
    events.event_date AS event_timestamp COMMENT = 'When the event occurred',
    events.event_category AS event_type COMMENT = 'LOGIN, PAGE_VIEW, API_CALL, ERROR, or LATENCY',
    events.app_release AS app_version COMMENT = 'Application version',
    events.location AS office COMMENT = 'Office location'
  )
  METRICS (
    events.active_users AS COUNT(DISTINCT device_id) COMMENT = 'Distinct devices (proxy for active users)',
    events.event_count AS COUNT(event_id) COMMENT = 'Total events',
    events.error_rate AS SUM(IFF(event_type = 'ERROR', 1, 0)) / NULLIF(COUNT(*), 0) COMMENT = 'Error fraction',
    events.avg_latency AS AVG(IFF(event_type = 'LATENCY', metric_value, NULL)) COMMENT = 'Avg latency ms'
  )
  COMMENT = 'Customer-scoped telemetry for AWS us-east-1 region';

CREATE OR REPLACE AGENT TELEMETRY_AWS_US_EAST_1.PUBLISH.CUSTOMER_AGENT
  COMMENT = 'Customer telemetry agent for AWS us-east-1'
  PROFILE = '{"display_name": "Product Insights Agent"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  instructions:
    response: "Answer questions about your product telemetry. You see only your own data."
    orchestration: "Use the Customer_Analyst tool for any question about events, active users, errors, or latency."
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "Customer_Analyst"
        description: "Generates SQL over your telemetry including active users, error rates, and latency."
  tool_resources:
    Customer_Analyst:
      semantic_view: "TELEMETRY_AWS_US_EAST_1.PUBLISH.SV_CUSTOMER"
      execution_environment:
        type: "warehouse"
        warehouse: "TELEMETRY_WH"
  $$;


-- ── Google Cloud us-central1 ──

CREATE DATABASE IF NOT EXISTS TELEMETRY_GCP_US_CENTRAL1;
CREATE SCHEMA IF NOT EXISTS TELEMETRY_GCP_US_CENTRAL1.PUBLISH;

CREATE OR REPLACE DYNAMIC TABLE TELEMETRY_GCP_US_CENTRAL1.PUBLISH.DT_EVENTS
  TARGET_LAG   = '1 hour'
  WAREHOUSE    = TELEMETRY_WH
  REFRESH_MODE = INCREMENTAL
AS
SELECT e.event_id, e.event_timestamp, e.customer_id, e.device_id, e.event_type,
       e.metric_name, e.metric_value,
       e.attributes:app_version::STRING AS app_version,
       e.attributes:office::STRING      AS office
FROM TELEMETRY_DB.RAW.EVENTS e
JOIN (SELECT DISTINCT customer_id
      FROM TELEMETRY_DB.PRIVATE.ENTITLEMENTS
      WHERE consumer_region = 'GCP_US_CENTRAL1' AND is_active) r
  ON r.customer_id = e.customer_id;

CREATE OR REPLACE DYNAMIC TABLE TELEMETRY_GCP_US_CENTRAL1.PUBLISH.DT_ENTITLEMENTS
  TARGET_LAG   = '1 hour'
  WAREHOUSE    = TELEMETRY_WH
  REFRESH_MODE = INCREMENTAL
AS
SELECT customer_id, consumer_account
FROM TELEMETRY_DB.PRIVATE.ENTITLEMENTS
WHERE consumer_region = 'GCP_US_CENTRAL1' AND is_active;

CREATE OR REPLACE SECURE VIEW TELEMETRY_GCP_US_CENTRAL1.PUBLISH.V_CUSTOMER_EVENTS AS
SELECT d.event_id, d.event_timestamp, d.device_id, d.event_type,
       d.metric_name, d.metric_value, d.app_version, d.office
FROM TELEMETRY_GCP_US_CENTRAL1.PUBLISH.DT_EVENTS d
JOIN TELEMETRY_GCP_US_CENTRAL1.PUBLISH.DT_ENTITLEMENTS ent
  ON  ent.customer_id      = d.customer_id
  AND ent.consumer_account = CURRENT_ACCOUNT();

CREATE OR REPLACE SEMANTIC VIEW TELEMETRY_GCP_US_CENTRAL1.PUBLISH.SV_CUSTOMER
  TABLES (
    events AS TELEMETRY_GCP_US_CENTRAL1.PUBLISH.V_CUSTOMER_EVENTS
      PRIMARY KEY (event_id)
      COMMENT = 'Product telemetry events for customers in GCP us-central1'
  )
  DIMENSIONS (
    events.event_date AS event_timestamp COMMENT = 'When the event occurred',
    events.event_category AS event_type COMMENT = 'LOGIN, PAGE_VIEW, API_CALL, ERROR, or LATENCY',
    events.app_release AS app_version COMMENT = 'Application version',
    events.location AS office COMMENT = 'Office location'
  )
  METRICS (
    events.active_users AS COUNT(DISTINCT device_id) COMMENT = 'Distinct devices (proxy for active users)',
    events.event_count AS COUNT(event_id) COMMENT = 'Total events',
    events.error_rate AS SUM(IFF(event_type = 'ERROR', 1, 0)) / NULLIF(COUNT(*), 0) COMMENT = 'Error fraction',
    events.avg_latency AS AVG(IFF(event_type = 'LATENCY', metric_value, NULL)) COMMENT = 'Avg latency ms'
  )
  COMMENT = 'Customer-scoped telemetry for GCP us-central1 region';

CREATE OR REPLACE AGENT TELEMETRY_GCP_US_CENTRAL1.PUBLISH.CUSTOMER_AGENT
  COMMENT = 'Customer telemetry agent for GCP us-central1'
  PROFILE = '{"display_name": "Product Insights Agent"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  instructions:
    response: "Answer questions about your product telemetry. You see only your own data."
    orchestration: "Use the Customer_Analyst tool for any question about events, active users, errors, or latency."
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "Customer_Analyst"
        description: "Generates SQL over your telemetry including active users, error rates, and latency."
  tool_resources:
    Customer_Analyst:
      semantic_view: "TELEMETRY_GCP_US_CENTRAL1.PUBLISH.SV_CUSTOMER"
      execution_environment:
        type: "warehouse"
        warehouse: "TELEMETRY_WH"
  $$;


-- ─── 7. Shares ──────────────────────────────────────────────────────────────

-- Fleet share: internal teams, all customers.
CREATE OR REPLACE SHARE fleet_share;
GRANT USAGE  ON DATABASE      TELEMETRY_DB                           TO SHARE fleet_share;
GRANT USAGE  ON SCHEMA        TELEMETRY_DB.PUBLISH                   TO SHARE fleet_share;
GRANT SELECT ON VIEW          TELEMETRY_DB.PUBLISH.V_FLEET_EVENTS    TO SHARE fleet_share;
GRANT SELECT, REFERENCES ON SEMANTIC VIEW TELEMETRY_DB.PUBLISH.SV_FLEET          TO SHARE fleet_share;
GRANT USAGE  ON AGENT         TELEMETRY_DB.PUBLISH.FLEET_AGENT       TO SHARE fleet_share;

-- Customer share: home region (AWS us-west-2).
CREATE OR REPLACE SHARE customer_share;
GRANT USAGE  ON DATABASE      TELEMETRY_DB                           TO SHARE customer_share;
GRANT USAGE  ON SCHEMA        TELEMETRY_DB.PUBLISH                   TO SHARE customer_share;
GRANT SELECT ON VIEW          TELEMETRY_DB.PUBLISH.V_CUSTOMER_EVENTS TO SHARE customer_share;
GRANT SELECT, REFERENCES ON SEMANTIC VIEW TELEMETRY_DB.PUBLISH.SV_CUSTOMER       TO SHARE customer_share;
GRANT USAGE  ON AGENT         TELEMETRY_DB.PUBLISH.CUSTOMER_AGENT    TO SHARE customer_share;

-- Regional: AWS us-east-1.
CREATE OR REPLACE SHARE customer_share_aws_us_east_1;
GRANT USAGE  ON DATABASE      TELEMETRY_AWS_US_EAST_1                           TO SHARE customer_share_aws_us_east_1;
GRANT USAGE  ON SCHEMA        TELEMETRY_AWS_US_EAST_1.PUBLISH                   TO SHARE customer_share_aws_us_east_1;
GRANT SELECT ON VIEW          TELEMETRY_AWS_US_EAST_1.PUBLISH.V_CUSTOMER_EVENTS TO SHARE customer_share_aws_us_east_1;
GRANT SELECT, REFERENCES ON SEMANTIC VIEW TELEMETRY_AWS_US_EAST_1.PUBLISH.SV_CUSTOMER       TO SHARE customer_share_aws_us_east_1;
GRANT USAGE  ON AGENT         TELEMETRY_AWS_US_EAST_1.PUBLISH.CUSTOMER_AGENT    TO SHARE customer_share_aws_us_east_1;

-- Regional: GCP us-central1.
CREATE OR REPLACE SHARE customer_share_gcp_us_central1;
GRANT USAGE  ON DATABASE      TELEMETRY_GCP_US_CENTRAL1                           TO SHARE customer_share_gcp_us_central1;
GRANT USAGE  ON SCHEMA        TELEMETRY_GCP_US_CENTRAL1.PUBLISH                   TO SHARE customer_share_gcp_us_central1;
GRANT SELECT ON VIEW          TELEMETRY_GCP_US_CENTRAL1.PUBLISH.V_CUSTOMER_EVENTS TO SHARE customer_share_gcp_us_central1;
GRANT SELECT, REFERENCES ON SEMANTIC VIEW TELEMETRY_GCP_US_CENTRAL1.PUBLISH.SV_CUSTOMER       TO SHARE customer_share_gcp_us_central1;
GRANT USAGE  ON AGENT         TELEMETRY_GCP_US_CENTRAL1.PUBLISH.CUSTOMER_AGENT    TO SHARE customer_share_gcp_us_central1;


-- ─── 8. Change tracking ─────────────────────────────────────────────────────

ALTER TABLE TELEMETRY_DB.RAW.EVENTS                                SET CHANGE_TRACKING = TRUE;
ALTER TABLE TELEMETRY_DB.PRIVATE.ENTITLEMENTS                      SET CHANGE_TRACKING = TRUE;
ALTER VIEW  TELEMETRY_DB.PUBLISH.V_CUSTOMER_EVENTS                 SET CHANGE_TRACKING = TRUE;
ALTER VIEW  TELEMETRY_AWS_US_EAST_1.PUBLISH.V_CUSTOMER_EVENTS      SET CHANGE_TRACKING = TRUE;
ALTER VIEW  TELEMETRY_GCP_US_CENTRAL1.PUBLISH.V_CUSTOMER_EVENTS    SET CHANGE_TRACKING = TRUE;


-- ─── 9. Listings (commented out; requires real consumer accounts) ──────────
-- Uncomment and replace account names with real targets to publish.

/*
-- Organizational listing: internal teams.
CREATE ORGANIZATION LISTING FLEET_INTELLIGENCE
SHARE fleet_share AS
$$
title: "Fleet Intelligence"
description: |
  Product telemetry for every Helio customer in one governed data product.

  **What's inside**
  - `V_FLEET_EVENTS`: one row per event, with device, app version, office, and metric values.
  - `SV_FLEET`: governed definitions for error rate, crash rate, and average latency.
  - `FLEET_AGENT`: ask questions in plain English, answered from the semantic view.

  **Who it's for**
  Product engineering, customer success, finance, and regional teams who need
  fleet-wide adoption, reliability, and performance metrics without building a pipeline.

  **Freshness**
  Events land within an hour. Teams in other regions receive refreshes every 60 minutes.
resources:
  documentation: "https://docs.helio.example/data-products/fleet-intelligence"
listing_terms:
  type: "CUSTOM"
  link: "https://docs.helio.example/data-products/internal-use-policy"
data_dictionary:
  featured:
    database: "TELEMETRY_DB"
    objects:
      - name: "V_FLEET_EVENTS"
        schema: "PUBLISH"
        domain: "VIEW"
usage_examples:
  - title: "Error rate by customer, last 7 days"
    description: "Find the customers with the most errors this week."
    query: "SELECT customer_id, COUNT_IF(event_type = 'ERROR') / COUNT(*) AS error_rate FROM PUBLISH.V_FLEET_EVENTS WHERE event_timestamp >= DATEADD(day, -7, CURRENT_TIMESTAMP()) GROUP BY customer_id ORDER BY error_rate DESC;"
  - title: "Average latency by app version"
    description: "Compare performance across releases."
    query: "SELECT app_version, AVG(metric_value) AS avg_latency_ms FROM PUBLISH.V_FLEET_EVENTS WHERE event_type = 'LATENCY' GROUP BY app_version ORDER BY app_version;"
  - title: "Daily active devices"
    description: "Track adoption across the fleet."
    query: "SELECT DATE_TRUNC('day', event_timestamp) AS day, COUNT(DISTINCT device_id) AS active_devices FROM PUBLISH.V_FLEET_EVENTS GROUP BY day ORDER BY day;"
data_attributes:
  refresh_rate: HOURLY
  geography:
    geo_option: NOT_APPLICABLE
  time:
    granularity: EVENT_BASED
    time_range:
      time_frame: LAST
      units: DAYS
      value: 90
organization_profile: "INTERNAL"
organization_targets:
  discovery:
    - all_internal_accounts: true
  access:
    - account: "PRODUCT_ENG"
    - account: "CS_FINANCE"
    - account: "US_EAST_REGIONAL"
support_contact: "data-products@helio.example"
approver_contact: "data-products@helio.example"
request_approval_type: "REQUEST_AND_APPROVE_IN_SNOWFLAKE"
locations:
  access_regions:
    - name: "ALL"
auto_fulfillment:
  refresh_type: SUB_DATABASE
  refresh_schedule: 60 MINUTE
$$;

-- Private listings: one per region.
-- Home region: customers in AWS us-west-2, nothing replicated.
CREATE EXTERNAL LISTING PRODUCT_INSIGHTS
SHARE customer_share AS
$$
title: "Product Insights"
subtitle: "Your Helio telemetry, ready to query and join to your own data"
description: |
  Your organization's Helio product telemetry, delivered into your Snowflake account.
  You see only your own data, queried with your own compute.

  **What's inside**
  - `V_CUSTOMER_EVENTS`: one row per event from your devices, with app version, office, and metric values.
  - `SV_CUSTOMER`: governed definitions for error rate and average latency, the same ones Helio uses.
  - `CUSTOMER_AGENT`: ask questions about your usage and performance in plain English.

  **Common uses**
  Join telemetry to your HR, IT asset, or ticketing data, track adoption of new releases,
  and spot offices with degraded performance.
resources:
  documentation: "https://docs.helio.example/data-products/product-insights"
listing_terms:
  type: "OFFLINE"
targets:
  accounts: ["CUSTOMER_A_ORG.CUSTOMER_A", "CUSTOMER_B_ORG.CUSTOMER_B"]
categories:
  - BUSINESS
business_needs:
  - name: "Product Usage Analytics"
    description: "Measure adoption, reliability, and performance of Helio across your organization."
    type: CUSTOM
data_dictionary:
  featured:
    database: "TELEMETRY_DB"
    objects:
      - name: "V_CUSTOMER_EVENTS"
        schema: "PUBLISH"
        domain: "VIEW"
usage_examples:
  - title: "Error rate by office, last 7 days"
    description: "Find the offices with the most errors this week."
    query: "SELECT office, COUNT_IF(event_type = 'ERROR') / COUNT(*) AS error_rate FROM PUBLISH.V_CUSTOMER_EVENTS WHERE event_timestamp >= DATEADD(day, -7, CURRENT_TIMESTAMP()) GROUP BY office ORDER BY error_rate DESC;"
  - title: "Adoption of each app version"
    description: "See how many devices run each release."
    query: "SELECT app_version, COUNT(DISTINCT device_id) AS devices FROM PUBLISH.V_CUSTOMER_EVENTS GROUP BY app_version ORDER BY devices DESC;"
data_attributes:
  refresh_rate: HOURLY
  geography:
    geo_option: NOT_APPLICABLE
  time:
    granularity: EVENT_BASED
    time_range:
      time_frame: LAST
      units: DAYS
      value: 90
data_preview:
  has_pii: FALSE
resharing:
  enabled: false
$$;

-- AWS us-east-1: only that region's customers and data.
CREATE EXTERNAL LISTING PRODUCT_INSIGHTS_AWS_US_EAST_1
SHARE customer_share_aws_us_east_1 AS
$$
title: "Product Insights"
subtitle: "Your Helio telemetry, ready to query and join to your own data"
description: |
  Your organization's Helio product telemetry, delivered into your Snowflake account.
  You see only your own data, queried with your own compute.

  **What's inside**
  - `V_CUSTOMER_EVENTS`: one row per event from your devices, with app version, office, and metric values.
  - `SV_CUSTOMER`: governed definitions for error rate and average latency, the same ones Helio uses.
  - `CUSTOMER_AGENT`: ask questions about your usage and performance in plain English.

  **Common uses**
  Join telemetry to your HR, IT asset, or ticketing data, track adoption of new releases,
  and spot offices with degraded performance.
resources:
  documentation: "https://docs.helio.example/data-products/product-insights"
listing_terms:
  type: "OFFLINE"
targets:
  accounts: ["CUSTOMER_C_ORG.CUSTOMER_C"]
auto_fulfillment:
  refresh_type: SUB_DATABASE
  refresh_schedule: 60 MINUTE
categories:
  - BUSINESS
business_needs:
  - name: "Product Usage Analytics"
    description: "Measure adoption, reliability, and performance of Helio across your organization."
    type: CUSTOM
data_dictionary:
  featured:
    database: "TELEMETRY_AWS_US_EAST_1"
    objects:
      - name: "V_CUSTOMER_EVENTS"
        schema: "PUBLISH"
        domain: "VIEW"
usage_examples:
  - title: "Error rate by office, last 7 days"
    description: "Find the offices with the most errors this week."
    query: "SELECT office, COUNT_IF(event_type = 'ERROR') / COUNT(*) AS error_rate FROM PUBLISH.V_CUSTOMER_EVENTS WHERE event_timestamp >= DATEADD(day, -7, CURRENT_TIMESTAMP()) GROUP BY office ORDER BY error_rate DESC;"
  - title: "Adoption of each app version"
    description: "See how many devices run each release."
    query: "SELECT app_version, COUNT(DISTINCT device_id) AS devices FROM PUBLISH.V_CUSTOMER_EVENTS GROUP BY app_version ORDER BY devices DESC;"
data_attributes:
  refresh_rate: HOURLY
  geography:
    geo_option: NOT_APPLICABLE
  time:
    granularity: EVENT_BASED
    time_range:
      time_frame: LAST
      units: DAYS
      value: 90
data_preview:
  has_pii: FALSE
resharing:
  enabled: false
$$;

-- Google Cloud us-central1: only that region's customers and data.
CREATE EXTERNAL LISTING PRODUCT_INSIGHTS_GCP_US_CENTRAL1
SHARE customer_share_gcp_us_central1 AS
$$
title: "Product Insights"
subtitle: "Your Helio telemetry, ready to query and join to your own data"
description: |
  Your organization's Helio product telemetry, delivered into your Snowflake account.
  You see only your own data, queried with your own compute.

  **What's inside**
  - `V_CUSTOMER_EVENTS`: one row per event from your devices, with app version, office, and metric values.
  - `SV_CUSTOMER`: governed definitions for error rate and average latency, the same ones Helio uses.
  - `CUSTOMER_AGENT`: ask questions about your usage and performance in plain English.

  **Common uses**
  Join telemetry to your HR, IT asset, or ticketing data, track adoption of new releases,
  and spot offices with degraded performance.
resources:
  documentation: "https://docs.helio.example/data-products/product-insights"
listing_terms:
  type: "OFFLINE"
targets:
  accounts: ["CUSTOMER_D_ORG.CUSTOMER_D", "CUSTOMER_E_ORG.CUSTOMER_E"]
auto_fulfillment:
  refresh_type: SUB_DATABASE
  refresh_schedule: 60 MINUTE
categories:
  - BUSINESS
business_needs:
  - name: "Product Usage Analytics"
    description: "Measure adoption, reliability, and performance of Helio across your organization."
    type: CUSTOM
data_dictionary:
  featured:
    database: "TELEMETRY_GCP_US_CENTRAL1"
    objects:
      - name: "V_CUSTOMER_EVENTS"
        schema: "PUBLISH"
        domain: "VIEW"
usage_examples:
  - title: "Error rate by office, last 7 days"
    description: "Find the offices with the most errors this week."
    query: "SELECT office, COUNT_IF(event_type = 'ERROR') / COUNT(*) AS error_rate FROM PUBLISH.V_CUSTOMER_EVENTS WHERE event_timestamp >= DATEADD(day, -7, CURRENT_TIMESTAMP()) GROUP BY office ORDER BY error_rate DESC;"
  - title: "Adoption of each app version"
    description: "See how many devices run each release."
    query: "SELECT app_version, COUNT(DISTINCT device_id) AS devices FROM PUBLISH.V_CUSTOMER_EVENTS GROUP BY app_version ORDER BY devices DESC;"
data_attributes:
  refresh_rate: HOURLY
  geography:
    geo_option: NOT_APPLICABLE
  time:
    granularity: EVENT_BASED
    time_range:
      time_frame: LAST
      units: DAYS
      value: 90
data_preview:
  has_pii: FALSE
resharing:
  enabled: false
$$;
*/


-- ─── Verification ───────────────────────────────────────────────────────────

-- Test 1: Your account should see only CUST_001.
-- ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = '<your_account_locator>';
-- SELECT COUNT(*) FROM TELEMETRY_DB.PUBLISH.V_CUSTOMER_EVENTS;

-- Test 2: An unentitled account should see zero rows.
-- ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'NONEXISTENT';
-- SELECT COUNT(*) FROM TELEMETRY_DB.PUBLISH.V_CUSTOMER_EVENTS;
-- ALTER SESSION UNSET SIMULATED_DATA_SHARING_CONSUMER;

-- Test 3: Fleet view should return all customers.
-- SELECT customer_id, COUNT(*) FROM TELEMETRY_DB.PUBLISH.V_FLEET_EVENTS GROUP BY 1;

-- Test 4: Semantic view.
-- SELECT * FROM SEMANTIC_VIEW(
--     TELEMETRY_DB.PUBLISH.SV_FLEET
--     DIMENSIONS events.event_category
--     METRICS events.weekly_active_accounts, events.crash_rate
-- );
