# Telemetry data product: follow-along setup

This repo holds the setup script for the Snowflake Developers Blog post **Turning Telemetry into a Data Product Your Teams and Customers Actually Use**.

The post walks through Helio, a fictional SaaS provider, turning its product telemetry into a governed data product. Internal teams get it through an organizational listing, and customers get it through private listings, all from one copy of the data.

## What the script creates

`telemetry_followalong_setup.sql` builds the provider side of the post:

- A warehouse and a least-privilege `TELEMETRY_PROVIDER` role.
- A telemetry events table with synthetic data (10,000 rows across 6 customers) and an entitlements table that maps customers to consumer accounts.
- Secure views, semantic views, and Cortex Agents for the internal fleet view and the per-customer view.
- Regional databases with dynamic tables, views, semantic views, and agents for AWS us-east-1 and GCP us-central1.
- Shares with all grants, and change tracking.

The listing statements are commented out because they need real consumer accounts.

## How to use it

1. Open the script and replace `<your_user>` with your Snowflake user name. Change `TELEMETRY_WH` if you want a different warehouse name.
2. Run section 0 as ACCOUNTADMIN. It creates the warehouse and the provider role.
3. Run the rest of the script as `TELEMETRY_PROVIDER`, which owns every object it creates.
4. Follow the post from Section 4, "How to set this up".

The script maps `CUST_001` to your own account so you can test the customer row filter. The data is synthetic. Running the script creates objects and uses compute in your account, so drop them when you're done.
