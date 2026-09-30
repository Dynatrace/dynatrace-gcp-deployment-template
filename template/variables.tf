###############################################################################
# Shared Variables and Locals
###############################################################################

# --- Dynatrace Identity ---

variable "tenant_id" {
  description = "Dynatrace environment/tenant ID"
  type        = string
  default     = ""

  # Used verbatim in the OIDC audience string and to derive the default tenant URL.
  validation {
    condition     = can(regex("^[a-zA-Z0-9-]*$", var.tenant_id))
    error_message = "tenant_id may contain only letters, digits, and hyphens."
  }
}

variable "tenant_url" {
  description = "Dynatrace platform API base URL (e.g. https://abc12345.apps.dynatrace.com). Leave empty for SaaS (defaults to https://{tenant_id}.apps.dynatrace.com); set the full URL for non-SaaS environments (e.g., dev, managed)."
  type        = string
  default     = ""

  validation {
    condition     = var.tenant_url == "" || can(regex("^https://", var.tenant_url))
    error_message = "tenant_url must start with https:// (or be left empty to derive from tenant_id)."
  }
}

variable "dynatrace_settings_token" {
  description = "Dynatrace API token used to enable GCP monitoring"
  type        = string
  sensitive   = true
}

variable "mconfig_id" {
  description = "Dynatrace monitoring configuration ID (GCP connection ID)"
  type        = string
  default     = ""

  # mconfig_id is always a lowercase UUID (36 chars) and is suffixed onto the Dataflow job name
  # and GCS bucket names. Empty is allowed to preserve the default when log forwarding is disabled.
  validation {
    condition     = var.mconfig_id == "" || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.mconfig_id))
    error_message = "mconfig_id must be a lowercase UUID (e.g. abcdef12-3456-7890-abcd-ef1234567890)."
  }
}

variable "mconfig_value" {
  description = "Full monitoring configuration payload as a JSON string. The template injects connectionId, serviceAccount, and enabled into credentials[0]; all other fields (featureSets, filtering, enrichment, customMetrics, version, description) are yours to configure."
  type        = string
  validation {
    condition     = can(jsondecode(var.mconfig_value))
    error_message = "mconfig_value must be a valid JSON string."
  }
}

variable "custom_labels" {
  description = "Custom labels to apply to all created resources. Use this to apply your organization's labeling policy (e.g. cost center, team, environment). Merged with Dynatrace-managed labels; custom_labels values take precedence for the same key."
  type        = map(string)
  default     = {}
}

variable "logs_enabled" {
  description = "Enable Cloud Logging export to Pub/Sub and Dataflow log-forwarding pipeline. When false, no log sink, Pub/Sub, or Dataflow resources are created."
  type        = bool
  default     = false
}

locals {
  # Derive tenant URL from tenant_id unless explicitly overridden.
  # Override is needed for non-SaaS environments (e.g., dev/hard).
  #
  # Two different hosts, derived from the single tenant_url input:
  #   effective_tenant_url — platform API (.apps.): the Dynatrace provider in dynatrace-onboarding.tf.
  #   effective_da_url     — data acquisition (.da.): asset feed push endpoint, log forwarding.
  # Pointing the provider at the data-acquisition host makes onboarding fail with
  # 401 "Invalid app context", so the two must not be conflated.
  effective_tenant_url = var.tenant_url != "" ? var.tenant_url : "https://${var.tenant_id}.apps.dynatrace.com"
  effective_da_url     = replace(local.effective_tenant_url, ".apps.", ".da.")

  enable_logs = var.logs_enabled

  all_labels = merge(
    {
      dt_created_by         = "dynatrace"
      dt_environment_id     = var.tenant_id
      dt_connection_id      = var.mconfig_id
      goog-partner-solution = ""
    },
    var.custom_labels,
  )
}
