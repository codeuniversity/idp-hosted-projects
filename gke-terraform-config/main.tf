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
    github = {
      source  = "integrations/github"
      version = "6.2.1"
    }
  }
  backend "gcs" {
    bucket = "code-idp-terraform-tfstate"
    prefix = "terraform/state"
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

resource "kubernetes_service_account" "github_actions_account" {
  depends_on = [module.gke, kubernetes_namespace.submissions_namespace]
  metadata {
    name      = "github-actions-account"
    namespace = kubernetes_namespace.submissions_namespace.metadata[0].name
  }
}

resource "kubernetes_role" "github_actions_role" {
  depends_on = [kubernetes_service_account.github_actions_account]
  metadata {
    name      = "github-actions-role"
    namespace = kubernetes_namespace.submissions_namespace.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/exec", "services", "secrets"]
    verbs      = ["create", "get", "list", "patch", "update", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["create", "get", "list", "patch", "update", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["create", "get", "list", "patch", "update", "delete"]
  }
}

resource "kubernetes_role_binding" "github_actions_rolebinding" {
  depends_on = [kubernetes_role.github_actions_role]
  metadata {
    name      = "github-actions-rolebinding"
    namespace = kubernetes_namespace.submissions_namespace.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.github_actions_role.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.github_actions_account.metadata[0].name
    namespace = kubernetes_namespace.submissions_namespace.metadata[0].name
  }
}

resource "kubernetes_secret" "github_actions_token" {
  depends_on = [kubernetes_role.github_actions_role]
  metadata {
    name      = "github-actions-token"
    namespace = kubernetes_namespace.submissions_namespace.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.github_actions_account.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

data "kubernetes_secret" "github_actions_token_data" {
  metadata {
    name      = kubernetes_secret.github_actions_token.metadata[0].name
    namespace = kubernetes_namespace.submissions_namespace.metadata[0].name
  }
}

resource "github_actions_secret" "kube_service_acc_secret" {
  repository      = "idp-hosted-projects"
  secret_name     = "KUBE_SERVICE_ACC_SECRET"
  plaintext_value = yamlencode(data.kubernetes_secret.github_actions_token_data)
}

resource "github_actions_secret" "kube_server_url" {
  repository      = "idp-hosted-projects"
  secret_name     = "KUBE_SERVER_URL"
  plaintext_value = "https://${module.gke.endpoint}"
}

output "kube_secret" {
  value       = yamlencode(data.kubernetes_secret.github_actions_token_data)
  description = "secret of gha service account"
  sensitive   = true
}

output "kube_server" {
  value       = "https://${module.gke.endpoint}"
  description = "url of gke endpoint"
  sensitive   = true
}
