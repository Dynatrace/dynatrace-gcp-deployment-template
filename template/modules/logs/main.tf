###############################################################################
# Module: Logs — Cloud Logging Export, Pub/Sub Pipeline, and Dataflow Job
###############################################################################

data "google_project" "project" {
  project_id = var.project_id
}

locals {
  image                     = "dynatrace-gcp-dataflow-template:${var.dataflow_image_tag}"
  log_topic_name            = "${var.dataflow_job_name}-${var.mconfig_id}"
  log_subscription_name     = "${var.dataflow_job_name}-sub-${var.mconfig_id}"
  log_dlq_topic_name        = "${var.dataflow_job_name}-dlq-${var.mconfig_id}"
  log_dlq_subscription_name = "${var.dataflow_job_name}-dlq-sub-${var.mconfig_id}"
  log_dlq_replay_sub_name   = "${var.dataflow_job_name}-dlq-replay-sub-${var.mconfig_id}"
  log_sink_name             = "${var.dataflow_job_name}-sink-${var.mconfig_id}"
  # GCS bucket names are capped at 63 chars. Project number (always 12 digits) is used
  # instead of project ID (up to 30 chars) to keep names safely under the limit.
  template_bucket_name = "${data.google_project.project.number}-logs-${var.mconfig_id}"
  template_object_name = "templates/${var.dataflow_job_name}.json"
  # Dataflow job name carries the image tag so a version bump launches a fresh job.
  # Dots are illegal in Dataflow job names ([a-z]([-a-z0-9]{0,1023})?), so sanitize them.
  job_name = "${var.dataflow_job_name}-${replace(replace(var.dataflow_image_tag, ".", "-"), "_", "-")}-${var.mconfig_id}"
  # Public Dynatrace worker image, pulled directly by Dataflow at job launch.
  image_url = "docker.io/dynatrace/${local.image}"
}

# --- Pub/Sub ---

resource "google_pubsub_topic" "log_forwarder" {
  name    = local.log_topic_name
  project = var.project_id
  labels  = var.labels
}

resource "google_pubsub_topic" "log_forwarder_dlq" {
  name    = local.log_dlq_topic_name
  project = var.project_id
  labels  = var.labels
}

resource "google_pubsub_subscription" "log_forwarder_dlq" {
  name    = local.log_dlq_subscription_name
  topic   = google_pubsub_topic.log_forwarder_dlq.id
  project = var.project_id
  labels  = var.labels

  ack_deadline_seconds       = 120
  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription" "log_forwarder" {
  name    = local.log_subscription_name
  topic   = google_pubsub_topic.log_forwarder.id
  project = var.project_id
  labels  = var.labels

  ack_deadline_seconds       = 120
  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }
}

# In-pipeline replay: the Dataflow job also consumes this subscription to retry retriable
# dead-letter messages. Filtered to non-permanent failures so poison pills / 4xx (which the sink
# marks dt-dlq-permanent="true") are never replayed.
resource "google_pubsub_subscription" "log_forwarder_dlq_replay" {
  name    = local.log_dlq_replay_sub_name
  topic   = google_pubsub_topic.log_forwarder_dlq.id
  project = var.project_id
  labels  = var.labels

  filter = "attributes.dt-dlq-permanent = \"false\""

  ack_deadline_seconds       = 120
  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic_iam_member" "sa_dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.log_forwarder_dlq.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.service_account_email}"
}

# --- Log Sink ---

resource "google_logging_project_sink" "log_forwarder" {
  name        = local.log_sink_name
  project     = var.project_id
  destination = "pubsub.googleapis.com/${google_pubsub_topic.log_forwarder.id}"
  filter      = var.log_filter

  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "sink_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.log_forwarder.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.log_forwarder.writer_identity
}

# --- GCS Buckets ---

resource "google_storage_bucket" "template" {
  name                        = local.template_bucket_name
  location                    = var.region
  project                     = var.project_id
  force_destroy               = true
  uniform_bucket_level_access = true
  labels                      = var.labels
}

resource "google_storage_bucket" "dataflow_temp" {
  name                        = "${data.google_project.project.number}-logs-temp-${var.mconfig_id}"
  location                    = var.region
  project                     = var.project_id
  force_destroy               = true
  uniform_bucket_level_access = true
  labels                      = var.labels
}

# --- Dataflow Service Agent ---

resource "google_project_service_identity" "dataflow" {
  provider = google-beta
  project  = var.project_id
  service  = "dataflow.googleapis.com"
}

# --- Dynatrace API Token (Secret Manager) ---
resource "google_secret_manager_secret" "dynatrace_api_token" {
  secret_id = "${var.dataflow_job_name}-api-token-${var.mconfig_id}"
  project   = var.project_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "dynatrace_api_token" {
  secret      = google_secret_manager_secret.dynatrace_api_token.id
  secret_data = var.dynatrace_api_token
}

# Project-level binding: scoping to the single secret would require the Terraform runner to hold
# secretmanager.secrets.setIamPolicy (roles/secretmanager.admin), which is broader than desired for
# the runner. The project-level binding is set via the runner's existing projectIamAdmin.
resource "google_project_iam_member" "sa_dynatrace_token_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${var.service_account_email}"
}

# --- IAM ---

resource "google_project_iam_member" "sa_dataflow_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${var.service_account_email}"
}

# Consume messages from the log-forwarder subscription (scoped to that subscription only).
resource "google_pubsub_subscription_iam_member" "sa_pubsub_subscriber" {
  subscription = google_pubsub_subscription.log_forwarder.name
  project      = var.project_id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${var.service_account_email}"
}

# Read subscription metadata (subscriptions.get); scoped to the forwarder subscription only.
resource "google_pubsub_subscription_iam_member" "sa_pubsub_viewer" {
  subscription = google_pubsub_subscription.log_forwarder.name
  project      = var.project_id
  role         = "roles/pubsub.viewer"
  member       = "serviceAccount:${var.service_account_email}"
}

# Consume + read the replay subscription (scoped to that subscription only).
resource "google_pubsub_subscription_iam_member" "sa_replay_subscriber" {
  subscription = google_pubsub_subscription.log_forwarder_dlq_replay.name
  project      = var.project_id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${var.service_account_email}"
}

resource "google_pubsub_subscription_iam_member" "sa_replay_viewer" {
  subscription = google_pubsub_subscription.log_forwarder_dlq_replay.name
  project      = var.project_id
  role         = "roles/pubsub.viewer"
  member       = "serviceAccount:${var.service_account_email}"
}

resource "google_storage_bucket_iam_member" "sa_dataflow_temp_bucket" {
  bucket = google_storage_bucket.dataflow_temp.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.service_account_email}"
}

# Read the flex template spec; scoped to the template bucket only.
resource "google_storage_bucket_iam_member" "sa_template_bucket_viewer" {
  bucket = google_storage_bucket.template.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.service_account_email}"
}

resource "google_project_iam_member" "sa_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${var.service_account_email}"
}

# Allows the Dataflow service agent to launch workers using the custom service account.
resource "google_service_account_iam_member" "dataflow_sa_user" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_project_service_identity.dataflow.email}"
}

# --- Flex Template Spec ---

# Declarative equivalent of `gcloud dataflow flex-template build`: the spec is a
# JSON object ({image, sdkInfo, metadata}) uploaded to GCS. The image is pulled
# directly from the public Docker Hub repository at job launch.
resource "google_storage_bucket_object" "flex_template_spec" {
  name   = local.template_object_name
  bucket = google_storage_bucket.template.name

  content_type = "application/json"
  content = jsonencode({
    image    = local.image_url
    sdkInfo  = { language = "JAVA" }
    metadata = jsondecode(file("${path.module}/metadata.json"))
  })
}

# --- Dataflow Flex Template Job ---

resource "google_dataflow_flex_template_job" "log_forwarder" {
  provider                = google-beta
  project                 = var.project_id
  name                    = local.job_name
  region                  = var.region
  container_spec_gcs_path = "gs://${google_storage_bucket.template.name}/${google_storage_bucket_object.flex_template_spec.name}"

  service_account_email   = var.service_account_email
  temp_location           = "${google_storage_bucket.dataflow_temp.url}/tmp"
  enable_streaming_engine = true
  labels                  = var.labels

  parameters = {
    subscription              = "projects/${var.project_id}/subscriptions/${local.log_subscription_name}"
    dynatraceUrl              = var.dynatrace_url
    dynatraceApiTokenSecret   = "${google_secret_manager_secret.dynatrace_api_token.id}/versions/latest"
    windowSeconds             = tostring(var.window_seconds)
    batchSize                 = tostring(var.batch_size)
    maxBatchBytes             = tostring(var.max_batch_bytes)
    deadLetterTopic           = "projects/${var.project_id}/topics/${local.log_dlq_topic_name}"
    maxReplayAttempts         = tostring(var.max_replay_attempts)
    replaySubscription        = "projects/${var.project_id}/subscriptions/${local.log_dlq_replay_sub_name}"
    replayBatchSize           = tostring(var.replay_batch_size)
    monitoringConfigurationId = var.mconfig_id
    maxNumWorkers             = tostring(var.max_num_workers)
  }

  depends_on = [
    google_pubsub_subscription.log_forwarder,
    google_pubsub_subscription.log_forwarder_dlq_replay,
    google_project_iam_member.sa_dynatrace_token_accessor,
    google_project_iam_member.sa_dataflow_worker,
    google_pubsub_subscription_iam_member.sa_pubsub_subscriber,
    google_pubsub_subscription_iam_member.sa_pubsub_viewer,
    google_pubsub_subscription_iam_member.sa_replay_subscriber,
    google_pubsub_subscription_iam_member.sa_replay_viewer,
    google_storage_bucket_iam_member.sa_dataflow_temp_bucket,
    google_storage_bucket_iam_member.sa_template_bucket_viewer,
    google_pubsub_topic_iam_member.sa_dlq_publisher,
    google_service_account_iam_member.dataflow_sa_user,
  ]
}
