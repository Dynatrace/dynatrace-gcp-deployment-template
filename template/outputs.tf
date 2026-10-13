output "log_forwarder_topic_id" {
  description = "Fully-qualified Pub/Sub topic ID for log sink targets; null when logs_enabled = false"
  value       = local.enable_logs ? module.logs[0].log_forwarder_topic_id : null
}
