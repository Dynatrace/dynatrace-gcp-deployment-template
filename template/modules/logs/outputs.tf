output "log_forwarder_topic_id" {
  description = "Fully-qualified Pub/Sub topic ID (projects/<project>/topics/<name>) that log sinks must target"
  value       = google_pubsub_topic.log_forwarder.id
}
