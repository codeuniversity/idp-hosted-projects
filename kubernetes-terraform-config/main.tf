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
    prefix = "terraform/kube/state"
  }
}

provider "google" {}

data "google_container_cluster" "default" {
  project = var.project_id
  name = "${var.project_id}-gke"
  location = var.region
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.default.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.default.master_auth[0].cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "gke-gcloud-auth-plugin"
  }
}

provider "helm" {
  kubernetes {
    host                   = "https://${data.google_container_cluster.default.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.default.master_auth[0].cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "gke-gcloud-auth-plugin"
    }
  }
}
provider "kubectl" {
  host                   = "https://${data.google_container_cluster.default.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.default.master_auth[0].cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "gke-gcloud-auth-plugin"
  }
}

provider "namedotcom" {
  username = var.namedotcom_username
  token    = var.namedotcom_token
}


resource "kubernetes_namespace" "traefik_namespace" {
  metadata {
    name = "traefik"
  }
}

resource "kubernetes_namespace" "submissions_namespace" {
  metadata {
    name = "submissions-2024"
  }
}

resource "helm_release" "traefik_ingress" {
  depends_on = [kubernetes_namespace.traefik_namespace]

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
  depends_on = [helm_release.traefik_ingress]
  metadata {
    namespace = kubernetes_namespace.traefik_namespace.metadata[0].name
    name      = "traefik"
  }
}


resource "namedotcom_record" "idp_domain" {
  depends_on  = [helm_release.traefik_ingress, data.kubernetes_service.traefik_service]
  domain_name = var.idp_domain_name
  record_type = "A"

  host   = var.idp_domain_host
  answer = data.kubernetes_service.traefik_service.status[0].load_balancer[0].ingress[0].ip
}

resource "kubernetes_service_account" "github_actions_account" {
  depends_on = [kubernetes_namespace.submissions_namespace]
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

  subject {
    kind      = "User"
    name      = "kube-deploy-student-projects@code-idp.iam.gserviceaccount.com"
    namespace = kubernetes_namespace.submissions_namespace.metadata[0].name
    api_group = "rbac.authorization.k8s.io"
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

#data "kubernetes_secret" "github_actions_token_data" {
#  metadata {
#    name      = kubernetes_secret.github_actions_token.metadata[0].name
#    namespace = kubernetes_namespace.submissions_namespace.metadata[0].name
#  }
#}
#
#data "github_actions_public_key" "idp_public_key" {
#  repository = "idp-hosted-projects"
#}
#
#resource "github_actions_secret" "kube_service_acc_secret" {
#  repository      = "idp-hosted-projects"
#  secret_name     = "KUBE_SERVICE_ACC_SECRET"
#  plaintext_value = data.kubernetes_secret.github_actions_token_data.data.token
#}
#
#resource "github_actions_secret" "kube_server_url" {
#  repository      = "idp-hosted-projects"
#  secret_name     = "KUBE_SERVER_URL"
#  plaintext_value = "https://${module.gke.endpoint}"
#}
#
#resource "github_actions_secret" "kube_ca_certificate" {
#  repository      = "idp-hosted-projects"
#  secret_name     = "KUBE_CA_CERTIFICATE"
#  plaintext_value = module.gke.ca_certificate
#}

