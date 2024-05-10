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
    helm = {
      source  = "hashicorp/helm"
      version = "2.13.1"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.0.4"
    }
    namedotcom = {
      source  = "lexfrei/namedotcom"
      version = "1.3.1"
    }
  }
  backend "gcs" {
   bucket  = "code-idp-terraform-tfstate"
   prefix  = "terraform/state"
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

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.gke.ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "gke-gcloud-auth-plugin"
    }
  }
}
provider "kubectl" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "gke-gcloud-auth-plugin"
  }
}

provider "namedotcom" {
  username = var.namedotcom_username
  token    = var.namedotcom_token
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

resource "kubernetes_namespace" "traefik_namespace" {
  metadata {
    name = "traefik"
  }
  depends_on = [module.gke]
}

resource "kubernetes_namespace" "submissions_namespace" {
  metadata {
    name = "submissions-2024"
  }
  depends_on = [module.gke]
}

resource "helm_release" "traefik_ingress" {
  depends_on = [module.gke, kubernetes_namespace.traefik_namespace]

  name      = "traefik"
  namespace = kubernetes_namespace.traefik_namespace.metadata[0].name


  repository = "https://helm.traefik.io/traefik"
  chart      = "traefik"

  set {
    name  = "deployment.replicas"
    value = 3
  }
}

module "cert_manager" {
  depends_on = [module.gke]

  source  = "terraform-iaac/cert-manager/kubernetes"
  version = "2.6.3"

  cluster_issuer_email                   = var.certificate_issuer_email
  cluster_issuer_name                    = "letsencrypt-prod"
  cluster_issuer_private_key_secret_name = "letsencrypt-prod-key"
  cluster_issuer_server                  = "https://acme-v02.api.letsencrypt.org/directory"
  solvers = [{
    http01 = {
      ingress = {
        class = "traefik"
      }
    }
  }]
}

data "kubernetes_service" "traefik_service" {
  depends_on = [module.gke, helm_release.traefik_ingress]
  metadata {
    namespace = kubernetes_namespace.traefik_namespace.metadata[0].name
    name      = "traefik"
  }
}


resource "namedotcom_record" "idp_domain" {
  depends_on  = [module.gke, helm_release.traefik_ingress, data.kubernetes_service.traefik_service]
  domain_name = var.idp_domain_name
  record_type = "A"

  host   = var.idp_domain_host
  answer = data.kubernetes_service.traefik_service.status[0].load_balancer[0].ingress[0].ip
}
