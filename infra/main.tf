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
  region  = "us-central1"
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
# 3. DATA LAYER (BigQuery Geospatial)
# ==============================================================================
resource "google_bigquery_dataset" "geo_data" {
  dataset_id                  = "dwt_geo_data"
  friendly_name               = "Watchtower Geospatial Data"
  description                 = "Stores fire perimeters and risk points."
  location                    = "US"
  delete_contents_on_destroy  = true 
  depends_on                  = [google_project_service.apis]
}

# ==============================================================================
# 4. ARTIFACT REGISTRY (The Code Vault)
# ==============================================================================
resource "google_artifact_registry_repository" "repo" {
  location      = "us-central1"
  repository_id = "dwt-repo-v2"
  description   = "Docker repository for Watchtower images"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# ==============================================================================
# 5. COMPUTE LAYER (Cloud Run)
# ==============================================================================
resource "google_cloud_run_v2_service" "default" {
  name     = "dwt-mcp-server-prod"
  location = "us-central1"
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.dwt_sa.email

    containers {
      # Placeholder image until we build ours
      image = "us-docker.pkg.dev/cloudrun/container/hello"
      
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
        name  = "BQ_DATASET"
        value = google_bigquery_dataset.geo_data.dataset_id
      }
    }
  }
  depends_on = [google_project_service.apis]
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

resource "google_cloud_run_service_iam_policy" "noauth" {
  location    = google_cloud_run_v2_service.default.location
  project     = google_cloud_run_v2_service.default.project
  service     = google_cloud_run_v2_service.default.name
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