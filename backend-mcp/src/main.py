from fastmcp import FastMCP
from google.cloud import bigquery
import os
import asyncio 
from pydantic import Field

# 1. Initialize
mcp = FastMCP("DiMarC WatchTower")

# 2. Infrastructure Setup
PROJECT_ID = os.getenv("PROJECT_ID", "dimarc-watchtower-01")
BQ_DATASET_RAW = os.getenv("BQ_DATASET_RAW", "dwt_raw")
BQ_DATASET_ANALYTICS_WILDFIRE = os.getenv("BQ_DATASET_ANALYTICS_WILDFIRE", "dwt_analytics_wildfire")

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
            status_msg += f"✅ Analytics Wildfire Geospatial Database ({BQ_DATASET_ANALYTICS_WILDFIRE}): CONNECTED"
        except Exception as e:
            status_msg += f"🔴 Analytics Wildfire Geospatial Database Error: {str(e)}"
    else:
        status_msg += "⚪ Database Client not initialized"
    return status_msg

# Get Wildfires Near Coordinates
@mcp.tool()
def get_wildfires_near_coordinates(
    latitude: float = Field(
        ..., 
        ge=-90.0, 
        le=90.0, 
        description="Latitude must be between -90 and 90 degrees."
    ), 
    longitude: float = Field(
        ..., 
        ge=-180.0, 
        le=180.0, 
        description="Longitude must be between -180 and 180 degrees."
    ), 
    radius_km: float = Field(
        100.0, 
        gt=0.0, 
        le=1000.0, 
        description="Search radius in kilometers. Must be greater than 0 and max 1000."
    )
) -> str:
    """Queries BigQuery for active wildfire hotspots within a specified radius (in kilometers)
    of a given latitude and longitude. Applies an urban mask to flag industrial false positives,
    and cross-references historical NIFC perimeters to determine virgin fuel vs. reburn risks.
    """
    if not bq_client:
        return "Error: BigQuery client is not initialized."

    radius_meters = radius_km * 1000.0

    query = f"""
        SELECT
            hotspot_id,
            satellite_instrument,
            confidence_pct,
            radiative_power_mw,
            detected_at,
            ST_Y(location_geog) AS latitude,
            ST_X(location_geog) AS longitude,
            ROUND(ST_DISTANCE(location_geog, ST_GEOGPOINT(@user_lon, @user_lat)) / 1000.0, 2) AS distance_km,
            CASE 
                WHEN EXISTS (
                    SELECT 1 
                    FROM `dimarc-watchtower-01.{BQ_DATASET_ANALYTICS_WILDFIRE}.urban_areas` u
                    WHERE ST_Intersects(location_geog, u.urban_area_geom)
                ) AND radiative_power_mw < 2.0 THEN 'Probable Industrial/Urban Anomaly'
                WHEN EXISTS (
                    SELECT 1 
                    FROM `dimarc-watchtower-01.{BQ_DATASET_ANALYTICS_WILDFIRE}.nifc_fire_perimeters` p
                    WHERE ST_Intersects(location_geog, p.perimeter_geog)
                ) THEN 'Wildfire Threat (Reburn)'
                ELSE 'Wildfire Threat (Virgin Fuel)'
            END AS classification
        FROM
            `dimarc-watchtower-01.{BQ_DATASET_ANALYTICS_WILDFIRE}.wildfire_hotspots`
        WHERE
            ST_DWITHIN(location_geog, ST_GEOGPOINT(@user_lon, @user_lat), @radius_meters)
        ORDER BY
            distance_km ASC
        LIMIT 25;
    """

    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("user_lat", "FLOAT64", latitude),
            bigquery.ScalarQueryParameter("user_lon", "FLOAT64", longitude),
            bigquery.ScalarQueryParameter("radius_meters", "FLOAT64", radius_meters),
        ]
    )

    try:
        query_job = bq_client.query(query, job_config=job_config)
        results = list(query_job.result())

        if not results:
            return f"No active wildfire hotspots detected within {radius_km} km of ({latitude}, {longitude})."

        output = [f"Found {len(results)} hotspot(s) within {radius_km} km:"]
        for row in results:
            output.append(
                f"- Distance: {row.distance_km} km | "
                f"Confidence: {row.confidence_pct}% | "
                f"FRP: {row.radiative_power_mw} MW | "
                f"Classification: {row.classification} | "
                f"Detected: {row.detected_at.strftime('%Y-%m-%d %H:%M UTC')} | "
                f"Coords: ({row.latitude:.4f}, {row.longitude:.4f})"
            )
        return "\n".join(output)

    except Exception as e:
        return f"Database query failed: {str(e)}"
  
#   Get Historical Fire  
@mcp.tool()
def get_historical_fire_context(
    latitude: float, 
    longitude: float, 
    radius_km: float = 5.0
) -> str:
    """Checks for historical burn scars (NIFC fire perimeters) within a specific radius (in kilometers)
    of a coordinate. Useful for determining if an active hotspot is burning inside or near old fuels.
    Run this after discovering a hotspot's coordinates.
    """
    if not bq_client:
        return "Error: BigQuery client is not initialized."

    radius_meters = radius_km * 1000.0

    query = f"""
        SELECT
            incident_name,
            fire_year,
            gis_acres,
            agency,
            ROUND(ST_DISTANCE(perimeter_geog, ST_GEOGPOINT(@user_lon, @user_lat)) / 1000.0, 2) AS distance_km
        FROM
            `dimarc-watchtower-01.{BQ_DATASET_ANALYTICS_WILDFIRE}.nifc_fire_perimeters`
        WHERE
            ST_DWITHIN(perimeter_geog, ST_GEOGPOINT(@user_lon, @user_lat), @radius_meters)
        ORDER BY
            distance_km ASC
        LIMIT 10;
    """

    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("user_lat", "FLOAT64", latitude),
            bigquery.ScalarQueryParameter("user_lon", "FLOAT64", longitude),
            bigquery.ScalarQueryParameter("radius_meters", "FLOAT64", radius_meters),
        ]
    )

    try:
        query_job = bq_client.query(query, job_config=job_config)
        results = list(query_job.result())

        if not results:
            return f"No historical burn scars found within {radius_km} km of ({latitude}, {longitude})."

        output = [f"Found {len(results)} historical burn scar(s) within {radius_km} km:"]
        for row in results:
            output.append(
                f"- Incident: {row.incident_name} ({row.fire_year}) | "
                f"Size: {row.gis_acres:,.1f} acres | "
                f"Agency: {row.agency} | "
                f"Distance: {row.distance_km} km"
            )
        return "\n".join(output)

    except Exception as e:
        return f"Database query failed: {str(e)}"

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