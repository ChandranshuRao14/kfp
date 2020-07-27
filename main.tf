locals {
  system_gsa  = "${var.cluster_name}-kfp-system"
  user_gsa    = "${var.cluster_name}-kfp-user"
  system_ksa  = ["ml-pipeline-ui", "ml-pipeline-visualizationserver", "kubeflow-pipelines-cloudsql-proxy", "kubeflow-pipelines-minio-gcs-gateway"]
  user_ksa    = ["pipeline-runner", "default"]
  crd_path    = "${path.module}/templates/cluster-scoped-resources/"
  gcp_path    = "${path.module}/templates/"
  gcs_bucket  = "${var.bucket_name}-${random_id.suffix.hex}"
  db_instance = "${var.db_name}-${random_id.instance_name_suffix.hex}"
  params      = templatefile("${path.module}/templates/params.env.tpl", { project_id = var.project_id, region = var.region, bucket_name = local.gcs_bucket, db_instance = local.db_instance })
  params-db   = templatefile("${path.module}/templates/params-db-secret.env.tpl", { password = var.db_password })
}

# Enable Project APIs
module "project-services" {
  source                      = "terraform-google-modules/project-factory/google//modules/project_services"
  version                     = "~> 6.0.0"
  project_id                  = var.project_id
  disable_services_on_destroy = false

  activate_apis = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "container.googleapis.com",
    "ml.googleapis.com",
    "containerregistry.googleapis.com",
    "iap.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudresourcemanager.googleapis.com"
  ]
}

module "kubeflow-cluster" {
  source                   = "terraform-google-modules/kubernetes-engine/google//modules/beta-public-cluster"
  project_id               = module.project-services.project_id
  name                     = var.cluster_name
  region                   = var.region
  network                  = google_compute_network.main.name
  subnetwork               = google_compute_subnetwork.main.name
  ip_range_pods            = google_compute_subnetwork.main.secondary_ip_range[0].range_name
  ip_range_services        = google_compute_subnetwork.main.secondary_ip_range[1].range_name
  remove_default_node_pool = true
  service_account          = "create"
  identity_namespace       = "${module.project-services.project_id}.svc.id.goog"
  node_metadata            = "GKE_METADATA_SERVER"
  node_pools               = var.node_pools
}

# Deploy KFP CRDs
module "kfp-apply-crds" {
  source = "github.com/terraform-google-modules/terraform-google-gcloud//modules/kubectl-wrapper"

  module_depends_on = [module.kubeflow-cluster.endpoint, local_file.params.content, local_file.params-db.content]
  cluster_name      = module.kubeflow-cluster.name
  cluster_location  = module.kubeflow-cluster.location
  project_id        = var.project_id

  kubectl_create_command  = "kubectl apply -k ${local.crd_path}"
  kubectl_destroy_command = "kubectl delete -k ${local.crd_path}"
}

resource "local_file" "params" {
  content  = local.params
  filename = "${path.module}/templates/params.env"
}

resource "local_file" "params-db" {
  content  = local.params-db
  filename = "${path.module}/templates/params-db-secret.env"
}

# Deploy KFP GCP yamls
module "kfp-apply-gcp" {
  source = "github.com/terraform-google-modules/terraform-google-gcloud//modules/kubectl-wrapper"

  module_depends_on = [module.kfp-apply-crds.wait, local_file.params.content, local_file.params-db.content]
  cluster_name      = module.kubeflow-cluster.name
  cluster_location  = module.kubeflow-cluster.location
  project_id        = module.project-services.project_id


  kubectl_create_command  = "kubectl apply -k ${local.gcp_path}"
  kubectl_destroy_command = "kubectl delete -k ${local.gcp_path}"
}

# Workload Identity for pipeline-runner
module "kfp-pipeline-runner-workload-identity" {
  source = "github.com/terraform-google-modules/terraform-google-kubernetes-engine//modules/workload-identity?ref=fix-gcloud-install"

  project_id          = module.project-services.project_id
  cluster_name        = module.kubeflow-cluster.name
  name                = can(module.kfp-apply-gcp.wait) ? "pipeline-runner-wi-${module.kubeflow-cluster.name}" : ""
  location            = module.kubeflow-cluster.location
  namespace           = var.namespace
  use_existing_k8s_sa = true
  k8s_sa_name         = "pipeline-runner"
}

# Workload Identity for cloudsql-proxy
module "kfp-cloudsql-proxy-workload-identity" {
  source       = "github.com/terraform-google-modules/terraform-google-kubernetes-engine//modules/workload-identity?ref=fix-gcloud-install"
  project_id   = module.project-services.project_id
  cluster_name = module.kubeflow-cluster.name

  name                = can(module.kfp-apply-gcp.wait) ? "cloudsql-proxy-wi-${module.kubeflow-cluster.name}" : ""
  location            = module.kubeflow-cluster.location
  namespace           = var.namespace
  use_existing_k8s_sa = true
  k8s_sa_name         = "kubeflow-pipelines-cloudsql-proxy"
}

# Workload Identity for minio
module "kfp-minio-gcs-gateway-workload-identity" {
  source              = "github.com/terraform-google-modules/terraform-google-kubernetes-engine//modules/workload-identity?ref=fix-gcloud-install"
  project_id          = module.project-services.project_id
  cluster_name        = module.kubeflow-cluster.name
  name                = can(module.kfp-apply-gcp.wait) ? "minio-wi-${module.kubeflow-cluster.name}-rand${module.kfp-apply-gcp.wait}" : ""
  location            = module.kubeflow-cluster.location
  namespace           = var.namespace
  use_existing_k8s_sa = true
  k8s_sa_name         = "kubeflow-pipelines-minio-gcs-gateway"
}

# GSA: IAM binding for Pipeline Runner
# TODO: least priv
resource "google_project_iam_member" "pipelinerunner" {
  project = module.project-services.project_id
  role    = "roles/editor"
  member  = module.kfp-pipeline-runner-workload-identity.gcp_service_account_fqn
}

# GSA: CloudSQL Client binding for CloudSQL proxy SA
resource "google_project_iam_member" "cloudsqlproxy" {
  project = module.project-services.project_id
  role    = "roles/cloudsql.client"
  member  = module.kfp-cloudsql-proxy-workload-identity.gcp_service_account_fqn
}

# GSA: Storage Admin binding for Minio SA
resource "google_storage_bucket_iam_member" "miniogcsgateway" {
  bucket  = google_storage_bucket.artifact-store.name
  role    = "roles/storage.admin"
  member  = module.kfp-minio-gcs-gateway-workload-identity.gcp_service_account_fqn
}

# Identity-Aware Proxy
# Currently IAP brand update/deletion is blocked by https://github.com/terraform-providers/terraform-provider-google/issues/6100
# TODO: use https://www.terraform.io/docs/providers/google/r/cloud_identity_group.html to create new group for support_email
# resource "google_iap_brand" "kfp_iap_brand" {
#   support_email     = ""
#   application_title = "Cloud IAP protected Kubeflow Pipelines"
#   project           = module.project-services.project_id
# }

# resource "google_iap_client" "kfp_iap_client" {
#   display_name = "Kubeflow Pipelines Client"
#   brand        = google_iap_brand.kfp_iap_brand.name
# }

# Cloud SQL
resource "random_id" "instance_name_suffix" {
  byte_length = 4
}

module "mysql-db" {
  source     = "GoogleCloudPlatform/sql-db/google//modules/safer_mysql"
  version    = "3.2.0"
  name       = local.db_instance
  project_id = module.project-services.project_id

  database_version = "MYSQL_5_7"
  region           = var.region
  zone             = "c"
  tier             = "db-n1-standard-1"
  user_name        = "root"
  user_password    = var.db_password

  vpc_network       = google_compute_network.main.self_link
  module_depends_on = [module.private-cloudsql-access.peering_completed]
}

resource "random_id" "suffix" {
  byte_length = 4
}

# Cloud Storage bucket
resource "google_storage_bucket" "artifact-store" {
  name     = local.gcs_bucket
  project  = module.project-services.project_id
  location = "US"
}
