terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.29.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "5.27.0"
    }
  }
  backend "gcs" {
    bucket = "code-idp-terraform-tfstate"
    prefix = "terraform/gke/state"
  }
}

# google_client_config and kubernetes provider must be explicitly specified like the following.
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "gke-gcloud-auth-plugin"
  }
}

locals {
  node_pool_name = "${var.project_id}-node-pool"
}

module "gke" {
  source                     = "terraform-google-modules/kubernetes-engine/google"
  version                    = "30.2.0"
  project_id                 = var.project_id
  name                       = "${var.project_id}-gke"
  region                     = var.region
  zones                      = var.zones
  network                    = ""
  subnetwork                 = ""
  ip_range_pods              = ""
  ip_range_services          = ""
  http_load_balancing        = false
  network_policy             = false
  horizontal_pod_autoscaling = true
  filestore_csi_driver       = false
  deletion_protection        = false
  create_service_account     = false
  remove_default_node_pool   = true
  service_account            = var.service_account

  node_pools = [
    {
      name               = local.node_pool_name
      machine_type       = "e2-medium"
      min_count          = 1
      max_count          = var.max_node_count
      local_ssd_count    = 0
      spot               = false
      disk_size_gb       = 30
      disk_type          = "pd-standard"
      image_type         = "COS_CONTAINERD"
      enable_gcfs        = false
      enable_gvnic       = false
      logging_variant    = "DEFAULT"
      auto_repair        = true
      auto_upgrade       = true
      service_account    = var.service_account
      preemptible        = true
      initial_node_count = var.initial_node_count
    },
  ]

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }

  node_pools_labels = {
    all = {}


    (local.node_pool_name) = {
      (local.node_pool_name) = true
    }
  }

  node_pools_metadata = {
    all = {}
  }

  node_pools_taints = {
    all = []

    (local.node_pool_name) = [
      {
        key    = local.node_pool_name
        value  = true
        effect = "PREFER_NO_SCHEDULE"
      },
    ]
  }

  node_pools_tags = {
    all = []
  }
}
