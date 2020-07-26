variable "project_id" {
  description = "The project ID to host the cluster in"
  default     = "kfp-test-project"
}

variable "cluster_name" {
  description = "The name of cluster"
  default     = "kfp-cluster"
}
variable "namespace" {
  description = "The namespace for kfp"
  default     = "kubeflow"
}

variable "region" {
  description = "The region to host the cluster in"
  default     = "us-east4"
}

variable "network" {
  description = "The VPC network to host the cluster in"
  default     = "kfp-network"
}

variable "subnetwork" {
  description = "The subnetwork to host the cluster in"
  default     = "kfp-subnet"
}

variable "ip_range_pods" {
  description = "The secondary ip range to use for pods"
  default     = "kfp-ip-range-pods"
}

variable "ip_range_services" {
  description = "The secondary ip range to use for services"
  default     = "kfp-ip-range-services"
}

variable "node_pools" {
  type        = list(map(string))
  description = "List of maps containing node pools"

  default = [
    {
      name         = "kubeflow-pool"
      machine_type = "n1-standard-4"
      min_count    = 4
      max_count    = 10
      auto_upgrade = true
    },
  ]
}

variable "bucket_name" {
  description = "GCS bucket name for GCS-Minio managed storage"
  default     = "kfp-bucket"
}

variable "db_name" {
  description = "Cloud SQL metadata db name"
  default     = "kfp-db"
}

variable "db_password" {
  description = "Cloud SQL db password"
  default     = "root"
}
