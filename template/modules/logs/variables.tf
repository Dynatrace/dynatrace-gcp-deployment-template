variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
}

variable "service_account_email" {
  description = "Email of the Dynatrace monitoring service account"
  type        = string
}

variable "log_filter" {
  description = "Logging filter expression"
  type        = string
}

variable "dynatrace_url" {
  description = "Dynatrace Log Ingest API URL (derived from tenant_url — not user-settable)"
  type        = string
}

variable "dynatrace_api_token" {
  description = "Dynatrace API token with logs.ingest scope"
  type        = string
  sensitive   = true

  validation {
    condition     = var.dynatrace_api_token != ""
    error_message = "dynatrace_api_token must be non-empty when the logs module is enabled."
  }
}

variable "dataflow_job_name" {
  description = "Base name for the Dataflow job; derived resource names (topics, subscriptions, sink, secret) are prefixed with this"
  type        = string
}

variable "window_seconds" {
  description = "Fixed window duration in seconds for batching messages"
  type        = number
}

variable "batch_size" {
  description = "Maximum number of log events per Dynatrace ingest request"
  type        = number
}

variable "max_batch_bytes" {
  description = "Maximum uncompressed batch size in bytes before flushing, in addition to batch_size"
  type        = number
}

variable "max_replay_attempts" {
  description = "Maximum dead-letter delivery attempts before a message is marked permanent and excluded from replay"
  type        = number
}

variable "replay_batch_size" {
  description = "Batch size for the 2nd replay tier; de-escalates with retries (1st retry uses batch_size, 2nd uses this, 3rd+ are one-by-one)"
  type        = number
}

variable "mconfig_id" {
  description = "Identifier sent to Dynatrace as the Dt-Configuration-Id header on every forwarded batch"
  type        = string
}

variable "dataflow_image_tag" {
  description = "Tag of the dynatrace-gcp-dataflow-template image to deploy"
  type        = string
}

variable "max_num_workers" {
  description = "Maximum number of Dataflow worker VMs"
  type        = number
}
