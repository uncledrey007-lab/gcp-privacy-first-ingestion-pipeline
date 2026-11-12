output "load_balancer_ip" {
  description = "Global Anycast IP address of the External Application Load Balancer"
  value       = google_compute_global_forwarding_rule.forwarding_rule.ip_address
}

output "bigquery_dataset_id" {
  description = "BigQuery Revenue Attribution Dataset ID"
  value       = google_bigquery_dataset.attribution_dataset.dataset_id
}

output "cloud_run_service_name" {
  description = "Scale-to-Zero Ingestion Gateway Service Name"
  value       = google_cloud_run_v2_service.ingestion_service.name
}
