###############################################################################
# Terraform Template: GCP Asset Feed (Pub/Sub + Cloud Asset Inventory)
###############################################################################

# --- Variables ---

variable "asset_feed_enabled" {
  description = "Master switch for the asset feed. When true, streams GCP resource changes to Dynatrace for the resolved asset-feed scopes (which default to the monitoring scopes). When false, no asset feed resources are created."
  type        = bool
  default     = false
}

variable "project_ids_for_asset_feed" {
  description = "List of project IDs to enable the asset feed on (used when asset_feed_enabled = true). Leave unset (null) to inherit project_ids_for_monitoring; set an explicit list (including []) to override. Avoid overlapping scopes across projects/folders/organizations — overlaps produce duplicate asset events and increase processing costs."
  type        = list(string)
  default     = null

  validation {
    condition     = var.project_ids_for_asset_feed == null || alltrue([for p in coalesce(var.project_ids_for_asset_feed, []) : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", p))])
    error_message = "Each project ID must be 6-30 chars, lowercase letters/digits/hyphens, start with a letter, and not end with a hyphen."
  }
}

variable "folder_ids_for_asset_feed" {
  description = "List of folder IDs to enable the asset feed on (used when asset_feed_enabled = true). Leave unset (null) to inherit folder_ids_for_monitoring; set an explicit list (including []) to override."
  type        = list(string)
  default     = null

  # google_cloud_asset_folder_feed.folder expects the "folders/NNN" resource-name form.
  validation {
    condition     = var.folder_ids_for_asset_feed == null || alltrue([for f in coalesce(var.folder_ids_for_asset_feed, []) : can(regex("^folders/[0-9]+$", f))])
    error_message = "Each folder ID must be of the form folders/NNN (e.g. folders/123456789012)."
  }
}

variable "organization_ids_for_asset_feed" {
  description = "List of organization IDs to enable the asset feed on (used when asset_feed_enabled = true). Leave unset (null) to inherit organization_ids_for_monitoring; set an explicit list (including []) to override."
  type        = list(string)
  default     = null

  # Accept both the "organizations/NNN" form and a bare numeric organization ID.
  validation {
    condition     = var.organization_ids_for_asset_feed == null || alltrue([for o in coalesce(var.organization_ids_for_asset_feed, []) : can(regex("^(organizations/)?[0-9]+$", o))])
    error_message = "Each organization ID must be numeric or of the form organizations/NNN (e.g. organizations/123456789012)."
  }
}

variable "asset_feed_asset_types" {
  description = "List of GCP asset types to monitor via the Asset Feed"
  type        = list(string)
  default = [
    "alloydb.googleapis.com/Cluster",
    "alloydb.googleapis.com/Instance",
    "apigee.googleapis.com/Instance",
    "apigee.googleapis.com/Organization",
    "appengine.googleapis.com/Application",
    "bigquery.googleapis.com/Dataset",
    "bigquery.googleapis.com/Model",
    "bigquerydatatransfer.googleapis.com/TransferConfig",
    "bigtableadmin.googleapis.com/Backup",
    "bigtableadmin.googleapis.com/Cluster",
    "bigtableadmin.googleapis.com/Table",
    "cloudfunctions.googleapis.com/CloudFunction",
    "cloudresourcemanager.googleapis.com/TagBinding",
    "cloudtasks.googleapis.com/Queue",
    "composer.googleapis.com/Environment",
    "compute.googleapis.com/Autoscaler",
    "compute.googleapis.com/BackendService",
    "compute.googleapis.com/Disk",
    "compute.googleapis.com/Instance",
    "compute.googleapis.com/Interconnect",
    "compute.googleapis.com/InterconnectAttachment",
    "compute.googleapis.com/Network",
    "compute.googleapis.com/Router",
    "compute.googleapis.com/ServiceAttachment",
    "compute.googleapis.com/VpnGateway",
    "compute.googleapis.com/VpnTunnel",
    "container.googleapis.com/Cluster",
    "dataflow.googleapis.com/Job",
    "dataproc.googleapis.com/Batch",
    "dataproc.googleapis.com/Cluster",
    "dataproc.googleapis.com/Job",
    "dataproc.googleapis.com/Session",
    "file.googleapis.com/Instance",
    "k8s.io/Node",
    "k8s.io/Pod",
    "k8s.io/Service",
    "logging.googleapis.com/LogSink",
    "netapp.googleapis.com/Volume",
    "pubsub.googleapis.com/Snapshot",
    "pubsub.googleapis.com/Subscription",
    "pubsub.googleapis.com/Topic",
    "recaptchaenterprise.googleapis.com/Key",
    "redis.googleapis.com/Cluster",
    "redis.googleapis.com/Instance",
    "run.googleapis.com/Job",
    "run.googleapis.com/Revision",
    "spanner.googleapis.com/Instance",
    "storage.googleapis.com/Bucket",
  ]
}

# --- Locals ---

locals {
  # Each asset-feed scope list defaults to (null) inheriting the matching monitoring
  # scope; an explicit list — including [] — overrides it.
  effective_project_ids_for_asset_feed = var.project_ids_for_asset_feed != null ? var.project_ids_for_asset_feed : var.project_ids_for_monitoring
  effective_folder_ids_for_asset_feed  = var.folder_ids_for_asset_feed != null ? var.folder_ids_for_asset_feed : var.folder_ids_for_monitoring
  effective_org_ids_for_asset_feed     = var.organization_ids_for_asset_feed != null ? var.organization_ids_for_asset_feed : var.organization_ids_for_monitoring

  # Create asset feed resources only when explicitly enabled AND at least one scope resolves.
  # Computed from the raw effective lists (not the feed_*_scopes below) to avoid a cycle.
  enable_asset_feed = var.asset_feed_enabled && (length(local.effective_project_ids_for_asset_feed) > 0 || length(local.effective_folder_ids_for_asset_feed) > 0 || length(local.effective_org_ids_for_asset_feed) > 0)

  # Per-type scope sets driving the for_each feed resources. Empty unless the feed is enabled,
  # so nothing iterates over these (and references the count=0 topic) while it is disabled.
  feed_project_scopes = local.enable_asset_feed ? toset(local.effective_project_ids_for_asset_feed) : toset([])
  feed_folder_scopes  = local.enable_asset_feed ? toset(local.effective_folder_ids_for_asset_feed) : toset([])
  # google_cloud_asset_organization_feed.org_id expects the bare numeric ID.
  feed_org_scopes = local.enable_asset_feed ? toset([for o in local.effective_org_ids_for_asset_feed : trimprefix(o, "organizations/")]) : toset([])

  # Folder and org feeds publish to the topic using the Cloud Asset service agent of the
  # billing project (var.project_id). If var.project_id is already in feed_project_scopes,
  # that agent is provisioned and granted publisher access by cloudasset_agent_publisher.
  # Otherwise provision it separately so folder/org-only setups can publish.
  needs_billing_project_agent = local.enable_asset_feed && (
    length(local.feed_folder_scopes) > 0 || length(local.feed_org_scopes) > 0
  ) && !contains(local.feed_project_scopes, var.project_id)
}

# --- Data Sources ---

# Used to resolve the project number for the Pub/Sub service agent email.
data "google_project" "project" {
  count      = local.enable_asset_feed ? 1 : 0
  project_id = var.project_id
}

# Provision the Cloud Asset service agent for each monitored project. GCP creates this agent
# lazily, so a fresh project may not have it yet — this forces its creation (and exposes its
# email) before we grant it publish access to the topic below.
resource "google_project_service_identity" "cloudasset_agent" {
  provider = google-beta
  for_each = local.feed_project_scopes
  project  = each.value
  service  = "cloudasset.googleapis.com"
}

# --- Pub/Sub Topic ---

resource "google_pubsub_topic" "asset_feed" {
  count   = local.enable_asset_feed ? 1 : 0
  project = var.project_id
  name    = "dt-asset-feed-${local.effective_mconfig_id}"

  message_retention_duration = "1200s"

  # Strip priorAsset from messages to reduce egress/storage costs.
  # On delete events, copy priorAsset → asset so downstream consumers
  # retain the metadata needed to identify what was removed.
  message_transforms {
    javascript_udf {
      function_name = "removePriorAsset"
      code          = <<-EOF
        function removePriorAsset(message, metadata) {
          try {
            const data = JSON.parse(message.data);
            if (data && data.priorAsset) {
              if (data.deleted) {
                data.asset = data.priorAsset;
              }
              delete data.priorAsset;
              message.data = JSON.stringify(data);
            }
          } catch (e) {}
          return message;
        }
      EOF
    }
  }

  labels = local.all_labels

  depends_on = [google_project_service.enabled_apis]
}

# --- Pub/Sub Push Subscription ---

resource "google_pubsub_subscription" "asset_feed_push" {
  count   = local.enable_asset_feed ? 1 : 0
  project = var.project_id
  name    = "dt-asset-feed-push-${local.effective_mconfig_id}"
  topic   = google_pubsub_topic.asset_feed[0].id

  ack_deadline_seconds       = 30
  message_retention_duration = "1200s"
  retain_acked_messages      = false
  enable_message_ordering    = false

  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "120s"
  }

  push_config {
    push_endpoint = "${local.effective_da_url}/api/gcp/assetfeed/v1/events"

    oidc_token {
      service_account_email = google_service_account.sa.email
      audience              = "dt:gcp:assetfeed:${var.tenant_id}:${local.effective_mconfig_id}"
    }

    # Payload unwrapping: delivers raw asset JSON as the HTTP body.
    # Metadata headers are not used by the receiver — omitting them reduces egress traffic.
    no_wrapper {
      write_metadata = false
    }
  }

  labels = local.all_labels
}

# --- IAM: Pub/Sub service agent → Token Creator on customer SA ---

# GCP creates the Pub/Sub service agent lazily, so explicitly provision it and reference its
# email to order the binding below after the identity exists.
resource "google_project_service_identity" "pubsub_agent" {
  count    = local.enable_asset_feed ? 1 : 0
  provider = google-beta
  project  = var.project_id
  service  = "pubsub.googleapis.com"

  depends_on = [google_project_service.enabled_apis]
}

# Required for the push subscription to generate OIDC tokens using the customer SA.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  count              = local.enable_asset_feed ? 1 : 0
  service_account_id = google_service_account.sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_project_service_identity.pubsub_agent[0].email}"
}

# --- IAM: Cloud Asset service agent → Publisher on asset feed topic ---

# The Cloud Asset feed publishes to the topic as the monitored project's Cloud Asset service
# agent. GCP does not auto-grant this (even same-project), so grant it explicitly here.
resource "google_pubsub_topic_iam_member" "cloudasset_agent_publisher" {
  for_each = local.feed_project_scopes
  project  = var.project_id
  topic    = google_pubsub_topic.asset_feed[0].name
  role     = "roles/pubsub.publisher"
  member   = "serviceAccount:${google_project_service_identity.cloudasset_agent[each.value].email}"
}

# Cloud Asset service agent for the billing project, used when folder or org feeds are
# configured but var.project_id is not itself a monitored project (absent from
# feed_project_scopes, so its agent is not provisioned by cloudasset_agent above).
resource "google_project_service_identity" "cloudasset_agent_billing" {
  count    = local.needs_billing_project_agent ? 1 : 0
  provider = google-beta
  project  = var.project_id
  service  = "cloudasset.googleapis.com"
}

resource "google_pubsub_topic_iam_member" "cloudasset_agent_billing_publisher" {
  count   = local.needs_billing_project_agent ? 1 : 0
  project = var.project_id
  topic   = google_pubsub_topic.asset_feed[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_project_service_identity.cloudasset_agent_billing[0].email}"
}

# --- Asset Feeds (one per monitoring scope) ---

resource "google_cloud_asset_project_feed" "asset_feed" {
  provider = google.asset
  for_each = local.feed_project_scopes

  project      = each.value
  feed_id      = "dt-asset-feed-${local.effective_mconfig_id}"
  content_type = "RESOURCE"
  asset_types  = var.asset_feed_asset_types

  feed_output_config {
    pubsub_destination {
      topic = google_pubsub_topic.asset_feed[0].id
    }
  }

  depends_on = [google_pubsub_topic.asset_feed, google_pubsub_topic_iam_member.cloudasset_agent_publisher]
}

resource "google_cloud_asset_folder_feed" "asset_feed" {
  provider = google.asset
  for_each = local.feed_folder_scopes

  billing_project = var.project_id
  folder          = each.value
  feed_id         = "dt-asset-feed-${local.effective_mconfig_id}"
  content_type    = "RESOURCE"
  asset_types     = var.asset_feed_asset_types

  feed_output_config {
    pubsub_destination {
      topic = google_pubsub_topic.asset_feed[0].id
    }
  }

  depends_on = [
    google_pubsub_topic.asset_feed,
    google_pubsub_topic_iam_member.cloudasset_agent_publisher,
    google_pubsub_topic_iam_member.cloudasset_agent_billing_publisher,
  ]
}

resource "google_cloud_asset_organization_feed" "asset_feed" {
  provider = google.asset
  for_each = local.feed_org_scopes

  billing_project = var.project_id
  org_id          = each.value
  feed_id         = "dt-asset-feed-${local.effective_mconfig_id}"
  content_type    = "RESOURCE"
  asset_types     = var.asset_feed_asset_types

  feed_output_config {
    pubsub_destination {
      topic = google_pubsub_topic.asset_feed[0].id
    }
  }

  depends_on = [
    google_pubsub_topic.asset_feed,
    google_pubsub_topic_iam_member.cloudasset_agent_publisher,
    google_pubsub_topic_iam_member.cloudasset_agent_billing_publisher,
  ]
}
