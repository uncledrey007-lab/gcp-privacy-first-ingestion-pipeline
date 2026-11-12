variable "project_id" {
  description = "The GCP Project ID"
  type        = string
  default     = "my-gcp-project-id"
}

variable "region" {
  description = "Primary GCP Region for resources"
  type        = string
  default     = "us-central1"
}

variable "ssl_certificate_id" {
  description = "Self-link of existing Managed SSL Certificate"
  type        = string
  default     = "projects/my-gcp-project-id/global/sslCertificates/ingestion-ssl-cert"
}
