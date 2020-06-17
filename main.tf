locals {
  system_gsa    = "${var.cluster_name}-kfp-system"
  user_gsa      = "${var.cluster_name}-kfp-user"
  system_ksa    = ["ml-pipeline-ui", "ml-pipeline-visualizationserver"]
  user_ksa      = ["pipeline-runner", "default"]
  crd_path      = "${path.module}/templates/cluster-scoped-resources/"
  gcp_path      = "${path.module}/templates/"
  db_instance   = "${var.db_name}-${random_id.instance_name_suffix.hex}"
  params        = templatefile("${path.module}/templates/params.env.tpl", { project_id = var.project_id, region = var.region, bucket_name = var.bucket_name, db_instance = local.db_instance })
  params-db     = templatefile("${path.module}/templates/params-db-secret.env.tpl", { password = var.db_password })
}

data "google_client_config" "default" {
}

# Enable Project APIs
module "project-services" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "~> 6.0.0"

  project_id                  = var.project_id
  disable_services_on_destroy = false

  activate_apis = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "container.googleapis.com",
    "ml.googleapis.com",
    "containerregistry.googleapis.com",
    "iap.googleapis.com",
    "sqladmin.googleapis.com"
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
  source                = "terraform-google-modules/gcloud/google"
  module_depends_on     = [module.kubeflow-cluster.endpoint]
  platform              = "linux"
  additional_components = ["kubectl", "beta"]

  create_cmd_entrypoint = "${path.module}/scripts/kubectl_wrapper.sh"
  create_cmd_body       = "https://${module.kubeflow-cluster.endpoint} ${data.google_client_config.default.access_token} ${module.kubeflow-cluster.ca_certificate} kubectl apply -k ${local.crd_path}"

  destroy_cmd_entrypoint = "${path.module}/scripts/kubectl_wrapper.sh"
  destroy_cmd_body       = "https://${module.kubeflow-cluster.endpoint} ${data.google_client_config.default.access_token} ${module.kubeflow-cluster.ca_certificate} kubectl delete -k ${local.crd_path}"
}

resource "local_file" "params" {
  content  = local.params
  filename = "${path.module}/templates/params.env"
}

resource "local_file" "params-db" {
  content  = local.params-db-secret
  filename = "${path.module}/templates/params-db-secret.env"
}

#TODO: re-eval with rmgogogo 
# havent added kubectl wait --for condition=established --timeout=60s crd/applications.app.k8s.io
# yet because setup of gcloud module takes aroud 60s

# Deploy KFP GCP yamls
module "kfp-apply-gcp" {
  source            = "terraform-google-modules/gcloud/google"
  module_depends_on = [module.kfp-apply-crds.wait, local_file.params.content, local_file.params-db.content]

  platform              = "linux"
  additional_components = ["kubectl", "beta"]

  create_cmd_entrypoint = "${path.module}/scripts/kubectl_wrapper.sh"
  create_cmd_body       = "https://${module.kubeflow-cluster.endpoint} ${data.google_client_config.default.access_token} ${module.kubeflow-cluster.ca_certificate} kubectl apply -k ${local.gcp_path}"

  destroy_cmd_entrypoint = "${path.module}/scripts/kubectl_wrapper.sh"
  destroy_cmd_body       = "https://${module.kubeflow-cluster.endpoint} ${data.google_client_config.default.access_token} ${module.kubeflow-cluster.ca_certificate} kubectl delete -k ${local.gcp_path}"
}

# Workload Identity
module "kfp-pipeline-runner-workload-identity" {
  source     = "terraform-google-modules/kubernetes-engine/google//modules/workload-identity"
  project_id = module.project-services.project_id
  # kfp-apply-gcp.wait is a hack to enforce dependency
  name                = trimsuffix("pipeline-runner-wi-${module.kubeflow-cluster.name}-rand${module.kfp-apply-gcp.wait}", "-rand${module.kfp-apply-gcp.wait}")
  namespace           = var.namespace
  use_existing_k8s_sa = true
  k8s_sa_name         = "pipeline-runner"
}

# GSA IAM binding
# TODO: least priv
resource "google_project_iam_member" "project" {
  project = module.project-services.project_id
  role    = "roles/editor"
  member  = module.kfp-pipeline-runner-workload-identity.gcp_service_account_fqn
}

# Identity-Aware Proxy
resource "google_iap_brand" "kfp_iap_brand" {
  support_email     = "project-factory-23247@anshu-seed-project.iam.gserviceaccount.com"
  application_title = "Cloud IAP protected Kubeflow Pipelines"
  project           = module.project-services.project_id
}

resource "google_iap_client" "kfp_iap_client" {
  display_name = "Kubeflow Pipelines Client"
  brand        = google_iap_brand.kfp_iap_brand.name
}

# Cloud SQL
resource "random_id" "instance_name_suffix" {
  byte_length = 4
}

module "mysql-db" {
  source     = "GoogleCloudPlatform/sql-db/google//modules/mysql"
  version    = "3.2.0"
  name       = local.db_instance
  project_id = module.project-services.project_id

  database_version = "MYSQL_5_7"
  region           = var.region
  zone             = "c"
  tier             = "db-n1-standard-1"
  user_name        = "root"
  user_password    = var.db_password

  vpc_network       = google_compute_network.main.network_self_link
  module_depends_on = [module.private-cloudsql-access.peering_completed]
}

# Cloud Storage bucket
resource "google_storage_bucket" "artifact-store" {
  name               = var.bucket_name
  project            = module.project-services.project_id
  location           = "US"
}

# make the cluster
# apply kfp manifests
# Workload Identity
  # ml-pipeline-ui is the service account for kfp
  # wait till the gcloud module is complete

# missing:
  # Cloud SQL:
    # sql-db 4.0 release allows for random instance name - ping in PR
    # Private Cloud SQL - include in PoC
  # IAP:
    # https://github.com/terraform-providers/terraform-provider-google/issues/6100
    # b/154652489
  # Terraform destroy
    # you must be logged in to the server