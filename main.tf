terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 1. CLOUD ARMOR WAF SECURITY POLICY
resource "google_compute_security_policy" "waf_policy" {
  name        = "sec-policy-ingestion-waf"
  description = "Cloud Armor policy enforcing OWASP SQLi/XSS & Rate Limiting"

  rule {
    action   = "deny(403)"
    priority = "1000"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})"
      }
    }
    description = "Block OWASP SQL Injection attacks"
  }

  rule {
    action   = "deny(403)"
    priority = "1001"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})"
      }
    }
    description = "Block OWASP XSS attacks"
  }

  rule {
    action   = "rate_based_ban"
    priority = "2000"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_threshold {
      count        = 100
      interval_sec = 60
    }
    ban_threshold {
      count        = 200
      interval_sec = 60
    }
    ban_duration_sec = 300
    description      = "Throttle abusive volumetric client IPs"
  }

  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow rule"
  }
}

# 2. SERVERLESS CLOUD RUN BACKEND
resource "google_service_account" "cloud_run_sa" {
  account_id   = "sa-ingestion-pipeline"
  display_name = "Serverless Ingestion Pipeline Service Account"
}

resource "google_cloud_run_v2_service" "ingestion_service" {
  name     = "cr-ingestion-gateway"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.cloud_run_sa.email

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/app-repo/ingestion-gateway:v1.0.0"
      
      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }

      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "BIGQUERY_DATASET"
        value = google_bigquery_dataset.attribution_dataset.dataset_id
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 100
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.ingestion_service.location
  name     = google_cloud_run_v2_service.ingestion_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# 3. GLOBAL LOAD BALANCER & SERVERLESS NEG
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "neg-serverless-ingestion"
  network_endpoint_type = "SERVERLESS"
  region                = var.region

  cloud_run {
    service = google_cloud_run_v2_service.ingestion_service.name
  }
}

resource "google_compute_backend_service" "ingestion_backend" {
  name                  = "bs-ingestion-gateway"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.waf_policy.id

  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }
}

resource "google_compute_url_map" "url_map" {
  name            = "urlmap-ingestion-lb"
  default_service = google_compute_backend_service.ingestion_backend.id
}

resource "google_compute_target_https_proxy" "https_proxy" {
  name             = "proxy-ingestion-https"
  url_map          = google_compute_url_map.url_map.id
  ssl_certificates = [var.ssl_certificate_id]
}

resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name                  = "fwdrule-ingestion-global"
  target                = google_compute_target_https_proxy.https_proxy.id
  port_range            = "443"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# 4. BIGQUERY ANALYTICS DATASET & PARTITIONED TABLE
resource "google_bigquery_dataset" "attribution_dataset" {
  dataset_id                  = "ds_revenue_attribution"
  friendly_name               = "Closed-Loop Revenue Attribution Warehouse"
  location                    = var.region
  default_table_expiration_ms = 315360000000
}

resource "google_bigquery_table" "conversion_events" {
  dataset_id          = google_bigquery_dataset.attribution_dataset.dataset_id
  table_id            = "fact_conversion_events"
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "event_timestamp"
  }

  clustering = ["event_type", "campaign_id"]

  schema = jsonencode([
    {"name": "event_id", "type": "STRING", "mode": "REQUIRED"},
    {"name": "event_timestamp", "type": "TIMESTAMP", "mode": "REQUIRED"},
    {"name": "user_pseudo_id", "type": "STRING", "mode": "REQUIRED"},
    {"name": "hashed_email", "type": "STRING", "mode": "NULLABLE"},
    {"name": "event_type", "type": "STRING", "mode": "REQUIRED"},
    {"name": "conversion_value", "type": "NUMERIC", "mode": "NULLABLE"},
    {"name": "currency", "type": "STRING", "mode": "NULLABLE"},
    {"name": "campaign_id", "type": "STRING", "mode": "NULLABLE"},
    {"name": "gclid", "type": "STRING", "mode": "NULLABLE"}
  ])
}
