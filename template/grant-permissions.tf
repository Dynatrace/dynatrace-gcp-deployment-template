###############################################################################
# Terraform Template: Grant Permissions
###############################################################################

variable "project_ids_for_monitoring" {
  description = "List of project IDs to grant access"
  type        = list(string)

  validation {
    condition     = alltrue([for p in var.project_ids_for_monitoring : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", p))])
    error_message = "Each project ID must be 6-30 chars, lowercase letters/digits/hyphens, start with a letter, and not end with a hyphen."
  }
}

variable "folder_ids_for_monitoring" {
  description = "List of folder IDs to grant access"
  type        = list(string)
  default     = []

  # google_folder_iam_member expects the "folders/NNN" resource-name form.
  validation {
    condition     = alltrue([for f in var.folder_ids_for_monitoring : can(regex("^folders/[0-9]+$", f))])
    error_message = "Each folder ID must be of the form folders/NNN (e.g. folders/123456789012)."
  }
}

variable "organization_ids_for_monitoring" {
  description = "List of organization IDs to grant access"
  type        = list(string)
  default     = []

  # Accept both the "organizations/NNN" form and a bare numeric organization ID.
  validation {
    condition     = alltrue([for o in var.organization_ids_for_monitoring : can(regex("^(organizations/)?[0-9]+$", o))])
    error_message = "Each organization ID must be numeric or of the form organizations/NNN (e.g. organizations/123456789012)."
  }
}

###############################################################################
# Shared data-access roles
#
# Applied at every monitored scope. Each role covers a distinct data domain:
#
# roles/monitoring.viewer - fetch time-series data and metric descriptors
# roles/cloudasset.viewer - fetch resource inventory via Cloud Asset Inventory
# roles/compute.viewer    - fetch compute regions and zones
# roles/browser           - list and get projects, folders, and organizations;
#                           the scope of the IAM binding determines what is
#                           visible: project scope lists projects only, folder
#                           scope lists folders and projects, org scope lists
#                           the organization, its folders, and its projects
###############################################################################

locals {
  monitoring_roles = toset([
    "roles/monitoring.viewer",
    "roles/cloudasset.viewer",
    "roles/compute.viewer",
    "roles/browser",
  ])
}

###############################################################################
# Project-level grants
#
# monitoring_roles applied directly on each project. roles/browser lists
# projects only at this scope - folder listing is not available.
###############################################################################

resource "google_project_iam_member" "sa_project_monitoring" {
  for_each = {
    for pair in setproduct(toset(var.project_ids_for_monitoring), local.monitoring_roles) :
    "${pair[0]}/${pair[1]}" => pair
  }
  project = each.value[0]
  role    = each.value[1]
  member  = "serviceAccount:${google_service_account.sa.email}"
}

###############################################################################
# Folder-level grants
#
# monitoring_roles cascade to every project under the folder. roles/browser
# lists folders and projects at this scope, so all projects under the folder
# are reachable without enumerating them in project_ids_for_monitoring.
###############################################################################

resource "google_folder_iam_member" "sa_folder_monitoring" {
  for_each = {
    for pair in setproduct(toset(var.folder_ids_for_monitoring), local.monitoring_roles) :
    "${pair[0]}/${pair[1]}" => pair
  }
  folder = each.value[0]
  role   = each.value[1]
  member = "serviceAccount:${google_service_account.sa.email}"
}

###############################################################################
# Organization-level grants
#
# monitoring_roles cascade to every project in the organization. roles/browser
# lists the organization, its folders, and its projects at this scope, so
# neither folder_ids_for_monitoring nor project_ids_for_monitoring need to be
# populated when monitoring at org scope.
###############################################################################

resource "google_organization_iam_member" "sa_org_monitoring" {
  for_each = {
    for pair in setproduct(toset(var.organization_ids_for_monitoring), local.monitoring_roles) :
    "${pair[0]}/${pair[1]}" => pair
  }
  org_id = each.value[0]
  role   = each.value[1]
  member = "serviceAccount:${google_service_account.sa.email}"
}
