from fastmcp import FastMCP
from google.cloud import bigquery
import os
import asyncio 

# 1. Initialize
mcp = FastMCP("DiMarC WatchTower")

# 2. Infrastructure Setup
PROJECT_ID = os.getenv("PROJECT_ID", "dimarc-watchtower-01")
BQ_DATASET = os.getenv("BQ_DATASET", "dwt_geo_data")

try:
    bq_client = bigquery.Client(project=PROJECT_ID)
except Exception as e:
    print(f"WARNING: Could not connect to BigQuery: {e}")
    bq_client = None

@mcp.tool()
def get_watchtower_status() -> str:
    """Returns the operational status of the Watchtower system."""
    status_msg = "🟢 DiMarC WatchTower Systems: ONLINE\n"
    if bq_client:
        try:
            query = "SELECT 1"
            query_job = bq_client.query(query)
            query_job.result()
            status_msg += f"✅ Geospatial Database ({BQ_DATASET}): CONNECTED"
        except Exception as e:
            status_msg += f"🔴 Geospatial Database Error: {str(e)}"
    else:
        status_msg += "⚪ Database Client not initialized"
    return status_msg

# ------------------------------------------------------------------
# 3. Server Entry Point (The Correct "HTTP Mode")
# ------------------------------------------------------------------
if __name__ == "__main__":
    print("🚀 Starting DiMarC WatchTower in HTTP Mode...")
    
    # We use the internal async runner which configures the /sse routes for us
    # We must wrap it in asyncio.run() because it is an async function
    asyncio.run(mcp.run_http_async(
        transport="sse",
        host="0.0.0.0", 
        port=int(os.getenv("PORT", 8080))
    ))