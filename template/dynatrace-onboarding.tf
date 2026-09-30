###############################################################################
# Terraform Template: Dynatrace Onboarding
#
# Two modes, controlled by var.mconfig_id:
#
#   App-flow  (mconfig_id provided): imports the existing monitoring
#             configuration created in the Dynatrace UI and enables it.
#
#   IaC-flow  (mconfig_id = ""): creates a new monitoring configuration
#             using var.mconfig_value as the base payload.
#
# In both modes the template injects connectionId, serviceAccount, and enabled
# into credentials[0]. App-flow fetches the live payload first to preserve all
# existing operator settings; IaC-flow uses var.mconfig_value as-is.
#
# Prerequisites:
#   - A Dynatrace API token exported before running terraform apply:
#       export TF_VAR_dynatrace_settings_token="<token>"
#     Required token scopes:
#       settings.read, settings.write,
#       extensions:configurations:read, extensions:configurations:write
###############################################################################

provider "dynatrace" {
  dt_env_url     = local.effective_tenant_url
  dt_api_token   = var.dynatrace_settings_token
  platform_token = var.dynatrace_settings_token
}

# App-flow only: fetch the current mconfig to preserve existing operator settings
# (featureSets, filtering, enrichment, customMetrics, etc.) and only patch the
# credential fields Terraform manages (connectionId, serviceAccount, enabled).
data "http" "mconfig_current" {
  for_each = var.mconfig_id != "" ? toset([var.mconfig_id]) : toset([])

  url = "${local.effective_tenant_url}/platform/extensions/v2/extensions/com.dynatrace.extension.da-gcp/monitoring-configurations/${each.key}"

  request_headers = {
    Authorization = "Api-Token ${var.dynatrace_settings_token}"
  }

  lifecycle {
    postcondition {
      condition     = contains([200, 404], self.status_code)
      error_message = "Failed to fetch mconfig ${each.key}: HTTP ${self.status_code}. Verify the mconfig ID and that the token has extensions:configurations:read scope."
    }
  }
}

locals {
  # App-flow: use the fetched live payload as the base (preserves operator settings).
  # IaC-flow or 404: fall through to var.mconfig_value.
  _mconfig_base = try(
    jsondecode(data.http.mconfig_current[var.mconfig_id].response_body).value,
    jsondecode(var.mconfig_value)
  )
  _mconfig_gc = try(local._mconfig_base.googleCloud, {})
  _first_cred = try(local._mconfig_gc.credentials[0], {})

  mconfig_payload = merge(local._mconfig_base, {
    enabled = true
    googleCloud = merge(local._mconfig_gc, {
      credentials = [
        merge(local._first_cred, {
          connectionId   = dynatrace_gcp_connection.gcp_conn.id
          serviceAccount = google_service_account.sa.email
          enabled        = true
        })
      ]
    })
  })

  # Resolved mconfig UUID used by downstream resources (asset feed, dataflow).
  # App-flow:  var.mconfig_id (caller-supplied UUID)
  # IaC-flow:  UUID extracted from the newly created resource's composite ID
  #            (format: com.dynatrace.extension.da-gcp#-#<uuid>)
  _created_raw_id = try(dynatrace_hub_extension_v2_config.da_gcp_new[0].id, "")
  effective_mconfig_id = var.mconfig_id != "" ? var.mconfig_id : (
    length(split("#-#", local._created_raw_id)) > 1
    ? split("#-#", local._created_raw_id)[1]
    : local._created_raw_id
  )
}

# Retrieve the Dynatrace-managed GCP principal (singleton per tenant).
resource "dynatrace_gcp_principal" "dt" {}


###############################################################################
# Impersonation
#
# roles/iam.serviceAccountTokenCreator — allows the Dynatrace-managed SA
# to generate tokens for the customer SA.
###############################################################################

resource "google_service_account_iam_member" "dt_principal_impersonation" {
  service_account_id = google_service_account.sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${dynatrace_gcp_principal.dt.principal}"
}

# Create a HAS GCP connection for the customer SA.
# The Settings objectId returned by the API is the encoded entity reference,
# so dynatrace_gcp_connection.gcp_conn.id can be used directly as connectionId.
resource "dynatrace_gcp_connection" "gcp_conn" {
  name = coalesce(try(local._mconfig_base.description, ""), var.service_account_display_name)
  type = "serviceAccountImpersonation"

  service_account_impersonation {
    service_account_id = google_service_account.sa.email
    consumers          = ["SVC:com.dynatrace.da"]
  }

  depends_on = [google_service_account_iam_member.dt_principal_impersonation]
}


###############################################################################
# App-flow: import and enable an existing monitoring configuration
###############################################################################

import {
  for_each = var.mconfig_id != "" ? toset([var.mconfig_id]) : toset([])
  to       = dynatrace_hub_extension_v2_config.da_gcp_existing[each.key]
  id       = "com.dynatrace.extension.da-gcp#-#${each.key}"
}

resource "dynatrace_hub_extension_v2_config" "da_gcp_existing" {
  for_each = var.mconfig_id != "" ? toset([var.mconfig_id]) : toset([])
  name     = "com.dynatrace.extension.da-gcp"
  scope    = "integration-gcp"

  depends_on = [
    dynatrace_gcp_connection.gcp_conn,
    google_project_iam_member.sa_project_monitoring,
    google_folder_iam_member.sa_folder_monitoring,
    google_organization_iam_member.sa_org_monitoring,
  ]

  value = jsonencode(local.mconfig_payload)
}


###############################################################################
# IaC-flow: create a new monitoring configuration with var.mconfig_value payload
###############################################################################

resource "dynatrace_hub_extension_v2_config" "da_gcp_new" {
  count = var.mconfig_id == "" ? 1 : 0
  name  = "com.dynatrace.extension.da-gcp"
  scope = "integration-gcp"

  depends_on = [
    dynatrace_gcp_connection.gcp_conn,
    google_project_iam_member.sa_project_monitoring,
    google_folder_iam_member.sa_folder_monitoring,
    google_organization_iam_member.sa_org_monitoring,
  ]

  value = jsonencode(local.mconfig_payload)
}
