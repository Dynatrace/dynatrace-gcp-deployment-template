###############################################################################
# Terraform Template: GCP Service Account Creation
###############################################################################

# Configure the Google provider
provider "google" {
  project = var.project_id
  region  = var.region
}

# Aliased provider for Cloud Asset Inventory feeds. The cloudasset API strictly
# requires a quota project (X-Goog-User-Project header), which the provider only
# sends when user_project_override = true. Scoped to feed resources only so the
# override doesn't affect API enablement (Service Usage rejects the header there).
provider "google" {
  alias                 = "asset"
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Variables
variable "project_id" {
  description = "The GCP project ID where the SA will be created"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 6-30 characters, lowercase letters/digits/hyphens, start with a letter, and not end with a hyphen."
  }
}

variable "service_account_id" {
  description = "Unique ID for the SA (without domain suffix)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][-a-z0-9]{4,28}[a-z0-9]$", var.service_account_id))
    error_message = "service_account_id must be 6-30 characters, lowercase letters/digits/hyphens, start with a letter, and not end with a hyphen (GCP service account ID limit)."
  }
}

variable "service_account_display_name" {
  description = "Display name for the SA"
  type        = string
  default     = "Dynatrace monitoring account"

  # GCP caps service account display names at 100 characters.
  validation {
    condition     = length(var.service_account_display_name) <= 100
    error_message = "service_account_display_name must be 100 characters or fewer (GCP limit)."
  }
}

variable "region" {
  description = "GCP region for created resources"
  type        = string
  default     = "us-central1"
}

# Create the customer SA
resource "google_service_account" "sa" {
  account_id   = var.service_account_id
  display_name = var.service_account_display_name
  project      = var.project_id

  # iam.googleapis.com must be enabled before the SA can be created.
  depends_on = [google_project_service.enabled_apis]
}
