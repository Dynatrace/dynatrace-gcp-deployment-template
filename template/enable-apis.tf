###############################################################################
# Terraform Template: GCP APIs Enablement
###############################################################################

locals {
  base_apis = [
    "compute.googleapis.com",              # zones and regions
    "cloudresourcemanager.googleapis.com", # projects, folders and organizations
    "cloudasset.googleapis.com",           # assets
    "monitoring.googleapis.com",           # metrics
    "pubsub.googleapis.com",               # pub/sub topic, subscription, and log forwarding
    "iam.googleapis.com",                  # service account IAM (OIDC token creation)
  ]

  log_forwarder_apis = local.enable_logs ? [
    "logging.googleapis.com",       # cloud logging sink
    "dataflow.googleapis.com",      # dataflow flex template jobs
    "storage.googleapis.com",       # GCS buckets for dataflow
    "secretmanager.googleapis.com", # Secret Manager for the Dynatrace API token
  ] : []
}

# Enable the GCP APIs
resource "google_project_service" "enabled_apis" {
  for_each = toset(concat(local.base_apis, local.log_forwarder_apis))
  project  = var.project_id
  service  = each.value

  # Prevents APIs from being disabled when the resource is destroyed.
  # Disabling core APIs (e.g. compute, pubsub) on a shared project would break unrelated workloads.
  disable_on_destroy = false
}
