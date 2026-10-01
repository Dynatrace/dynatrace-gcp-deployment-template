###############################################################################
# Terraform Template: Dataflow Flex Template Job
###############################################################################


variable "dynatrace_api_token" {
  description = "Dynatrace API token with logs.ingest scope"
  type        = string
  sensitive   = true
  default     = ""

  # Dynatrace API tokens are prefixed dt0<public>. Empty is allowed (set only when logs enabled).
  validation {
    condition     = var.dynatrace_api_token == "" || can(regex("^dt0[a-z][0-9]{2}\\.", var.dynatrace_api_token))
    error_message = "dynatrace_api_token must be a Dynatrace API token (starts with dt0…) or left empty."
  }
}

variable "dataflow_job_name" {
  description = "Base name for the Dataflow job and derived log forwarder resources (Pub/Sub topics, subscriptions, log sink, secret)"
  type        = string
  default     = "dt-logs"

  # Must satisfy the Dataflow job name regex (lowercase, letter-first) and stay short enough
  # that the derived Cloud Logging sink name ("<name>-sink-<mconfig_id>") fits its 100-char limit
  # (36-char UUID mconfig_id + "-sink-" = 42 chars of overhead).
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.dataflow_job_name)) && length(var.dataflow_job_name) <= 58
    error_message = "dataflow_job_name must match ^[a-z][a-z0-9-]*$ (lowercase, digits, hyphens; start with a letter) and be <= 58 characters (Cloud Logging sink name limit)."
  }
}

variable "window_seconds" {
  description = "Fixed window duration in seconds for batching messages before forwarding"
  type        = number
  default     = 10

  validation {
    condition     = var.window_seconds > 0
    error_message = "window_seconds must be greater than 0."
  }
}

variable "batch_size" {
  description = "Maximum number of log events per Dynatrace ingest request"
  type        = number
  default     = 1000

  validation {
    condition     = var.batch_size > 0
    error_message = "batch_size must be greater than 0."
  }
}

variable "max_batch_bytes" {
  description = "Maximum uncompressed batch size in bytes before flushing, in addition to batch_size"
  type        = number
  default     = 10485760

  validation {
    condition     = var.max_batch_bytes > 0
    error_message = "max_batch_bytes must be greater than 0."
  }
}

variable "max_replay_attempts" {
  description = "Maximum dead-letter delivery attempts before a message is marked permanent and excluded from replay"
  type        = number
  default     = 5

  # 0 is valid and disables replay (messages are marked permanent on first dead-letter).
  validation {
    condition     = var.max_replay_attempts >= 0
    error_message = "max_replay_attempts must be 0 or greater."
  }
}

variable "replay_batch_size" {
  description = "Batch size for the 2nd replay tier; de-escalates with retries (1st retry uses batch_size, 2nd uses this, 3rd+ are one-by-one)"
  type        = number
  default     = 50

  validation {
    condition     = var.replay_batch_size > 0
    error_message = "replay_batch_size must be greater than 0."
  }
}

variable "dataflow_image_tag" {
  description = "Tag of the dynatrace-gcp-dataflow-template image to deploy"
  type        = string
  default     = "0.0.35"

  # Dots are sanitized to hyphens when building the Dataflow job name, but other characters
  # (e.g. '+' build metadata, uppercase) would produce an invalid job name and fail at apply.
  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.dataflow_image_tag))
    error_message = "dataflow_image_tag may only contain letters, digits, dots, hyphens, and underscores."
  }
}

variable "log_filter" {
  description = "Logging filter expression (empty string exports all logs)"
  type        = string
  default     = ""
}

variable "max_num_workers" {
  description = "Maximum number of Dataflow worker VMs. Caps autoscaling to prevent runaway scale-out when the Dynatrace log endpoint is unavailable."
  type        = number
  default     = 4

  validation {
    condition     = var.max_num_workers >= 1
    error_message = "max_num_workers must be at least 1."
  }
}

module "logs" {
  count  = local.enable_logs ? 1 : 0
  source = "./modules/logs"

  providers = {
    google      = google
    google-beta = google-beta
  }

  project_id            = var.project_id
  region                = var.region
  labels                = local.all_labels
  service_account_email = google_service_account.sa.email

  log_filter          = var.log_filter
  dynatrace_url       = "${local.effective_da_url}/api/gcp/pubsub/v1/logs"
  dynatrace_api_token = var.dynatrace_api_token
  dataflow_job_name   = var.dataflow_job_name
  window_seconds      = var.window_seconds
  batch_size          = var.batch_size
  max_batch_bytes     = var.max_batch_bytes
  max_replay_attempts = var.max_replay_attempts
  replay_batch_size   = var.replay_batch_size
  mconfig_id          = local.effective_mconfig_id
  dataflow_image_tag  = var.dataflow_image_tag
  max_num_workers     = var.max_num_workers
  depends_on          = [google_project_service.enabled_apis]
}
