# infra/main.tf

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
  }
}

provider "google" {
  # MUST MATCH the Project ID you just created in the console
  project = "dimarc-watchtower-01" 
  region  = "us-west4"
}

# ==============================================================================
# 1. ENABLE APIS (The Switchboard)
# ==============================================================================
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",              # Cloud Run
    "artifactregistry.googleapis.com", # Docker Storage
    "bigquery.googleapis.com",         # Geospatial Database
    "aiplatform.googleapis.com",       # Vertex AI (The Brain)
    "cloudbuild.googleapis.com",       # CI/CD
    "iam.googleapis.com"               # Identity
  ])
  service            = each.key
  disable_on_destroy = false
}

# ==============================================================================
# 2. IDENTITY (Service Account)
# ==============================================================================
resource "google_service_account" "dwt_sa" {
  account_id   = "sa-dwt-mcp-prod"
  display_name = "DiMarC Watchtower Service Account"
  description  = "Identity for the Watchtower MCP Server"
  depends_on   = [google_project_service.apis]
}

# ==============================================================================
# 3. DATA LAYER (BigQuery Medallion Architecture)
# ==============================================================================

# Bronze Layer: Raw Data Landing
resource "google_bigquery_dataset" "raw" {
  dataset_id                 = "dwt_raw"
  friendly_name              = "Raw Data"
  description                = "Bronze layer: Unprocessed WatchTower data."
  location                   = "us-west4"
  delete_contents_on_destroy = false
  depends_on                 = [google_project_service.apis]
}

# Silver Layer: Cleaned and Standardized
resource "google_bigquery_dataset" "staging" {
  dataset_id                 = "dwt_staging"
  friendly_name              = "Staging Data"
  description                = "Silver layer: Cleansed and standardized WatchTower data."
  location                   = "us-west4"
  delete_contents_on_destroy = false
  depends_on                 = [google_project_service.apis]
}

# Gold Layer: Ready for MCP/Analytics
resource "google_bigquery_dataset" "analytics" {
  dataset_id                 = "dwt_analytics_wildfire"
  friendly_name              = "Analytics Wildfire Data"
  description                = "Gold layer: Final views and tables optimized for WatchTower wildfire geospatial queries."
  location                   = "us-west4"
  delete_contents_on_destroy = false
  depends_on                 = [google_project_service.apis]
}

# ==============================================================================
# EXISTING GOLD LAYER TABLES (Analytics)
# ==============================================================================

resource "google_bigquery_table" "analytics_nifc_perimeters" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "nifc_fire_perimeters"
  deletion_protection = true

  schema = <<EOF
[
  {"name": "incident_id", "type": "STRING", "mode": "NULLABLE"},
  {"name": "incident_name", "type": "STRING", "mode": "NULLABLE"},
  {"name": "fire_year", "type": "INTEGER", "mode": "NULLABLE"},
  {"name": "gis_acres", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "agency", "type": "STRING", "mode": "NULLABLE"},
  {"name": "perimeter_geog", "type": "GEOGRAPHY", "mode": "NULLABLE"}
]
EOF
}

resource "google_bigquery_table" "analytics_urban_areas" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "urban_areas"
  deletion_protection = true

  schema = <<EOF
[
  {"name": "geo_id", "type": "INTEGER", "mode": "NULLABLE"},
  {"name": "name", "type": "STRING", "mode": "NULLABLE"},
  {"name": "lsad_name", "type": "STRING", "mode": "NULLABLE"},
  {"name": "urban_area_geom", "type": "GEOGRAPHY", "mode": "NULLABLE"}
]
EOF
}

resource "google_bigquery_table" "analytics_wildfire_hotspots" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "wildfire_hotspots"
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "detected_at"
  }

  clustering = ["location_geog", "satellite_instrument"]

  schema = <<EOF
[
  {"name": "hotspot_id", "type": "STRING", "mode": "NULLABLE"},
  {"name": "satellite_instrument", "type": "STRING", "mode": "NULLABLE"},
  {"name": "confidence_pct", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "radiative_power_mw", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "detected_at", "type": "TIMESTAMP", "mode": "NULLABLE"},
  {"name": "location_geog", "type": "GEOGRAPHY", "mode": "NULLABLE"}
]
EOF
}

# ==============================================================================
# EXISTING BRONZE LAYER TABLES (Raw Ingestion)
# ==============================================================================

resource "google_bigquery_table" "raw_firms_hotspots" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "firms_hotspots"
  deletion_protection = true

  schema = <<EOF
[
  {"name": "latitude", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "longitude", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "bright_ti4", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "scan", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "track", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "acq_date", "type": "DATE", "mode": "NULLABLE"},
  {"name": "acq_time", "type": "INTEGER", "mode": "NULLABLE"},
  {"name": "satellite", "type": "STRING", "mode": "NULLABLE"},
  {"name": "confidence", "type": "STRING", "mode": "NULLABLE"},
  {"name": "version", "type": "STRING", "mode": "NULLABLE"},
  {"name": "bright_ti5", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "frp", "type": "FLOAT", "mode": "NULLABLE"},
  {"name": "daynight", "type": "STRING", "mode": "NULLABLE"}
]
EOF
}

resource "google_bigquery_table" "raw_nifc_perimeters" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "nifc_perimeters_raw"
  deletion_protection = true

  # Ignore schema drift for massive raw API tables
  lifecycle {
    ignore_changes = [
      schema
    ]
  }
}

# ==============================================================================
# 4. ARTIFACT REGISTRY (The Code Vault)
# ==============================================================================
resource "google_artifact_registry_repository" "repo" {
  location      = "us-west4"
  repository_id = "dimarc-watchtower-repo"
  description   = "Official Docker repository for Watchtower images"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# ==============================================================================
# 5. COMPUTE LAYER (Cloud Run)
# ==============================================================================
resource "google_cloud_run_v2_service" "default" {
  name     = "dimarc-watchtower-backend-prod"
  location = "us-west4"
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.dwt_sa.email

    containers {
      # Points to your actual compiled MCP server image, not the placeholder
      image = "us-west4-docker.pkg.dev/dimarc-watchtower-01/dimarc-watchtower-repo/mcp-server:v10"
      
      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }
      
      env {
        name  = "PROJECT_ID"
        value = "dimarc-watchtower-01"
      }
      env {
        name  = "BQ_DATASET_RAW"
        value = google_bigquery_dataset.raw.dataset_id
      }
      env {
        name  = "BQ_DATASET_ANALYTICS_WILDFIRE"
        value = google_bigquery_dataset.analytics.dataset_id
      }
    }
  }
  depends_on = [google_project_service.apis]

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image
    ]
  }
}

# ==============================================================================
# 6. PUBLIC ACCESS (Temporary for Showcase)
# ==============================================================================
data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = ["allUsers"]
  }
}

resource "google_cloud_run_v2_service_iam_policy" "noauth" {
  location    = google_cloud_run_v2_service.default.location
  project     = google_cloud_run_v2_service.default.project
  name        = google_cloud_run_v2_service.default.name
  policy_data = data.google_iam_policy.noauth.policy_data
}

# ==============================================================================
# 7. CI/CD PERMISSIONS (The "Right" Way)
# ==============================================================================
# Fetch the project number automatically
data "google_project" "project" {
}

# Grant Cloud Build the "Writer" role (Least Privilege)
resource "google_artifact_registry_repository_iam_member" "cloudbuild_writer" {
  project    = google_artifact_registry_repository.repo.project
  location   = google_artifact_registry_repository.repo.location
  repository = google_artifact_registry_repository.repo.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

# ==============================================================================
# 8. MCP SERVER PERMISSIONS (BigQuery Access)
# ==============================================================================
# Allows the Cloud Run service to read data from BigQuery tables
resource "google_project_iam_member" "mcp_bq_viewer" {
  project = "dimarc-watchtower-01"
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.dwt_sa.email}"
}

# Allows the Cloud Run service to execute query jobs and use compute resources
resource "google_project_iam_member" "mcp_bq_job_user" {
  project = "dimarc-watchtower-01"
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dwt_sa.email}"
}