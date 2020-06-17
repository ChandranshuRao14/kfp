
resource "google_compute_network" "main" {
  name                    = var.network
  auto_create_subnetworks = false
  project                 = module.project-services.project_id
}

resource "google_compute_subnetwork" "main" {
  name          = var.subnetwork
  project       = module.project-services.project_id
  ip_cidr_range = "10.0.0.0/17"
  region        = var.region
  network       = google_compute_network.main.self_link

  secondary_ip_range {
    range_name    = var.ip_range_pods
    ip_cidr_range = "192.168.0.0/18"
  }

  secondary_ip_range {
    range_name    = var.ip_range_services
    ip_cidr_range = "192.168.64.0/18"
  }
}

# VPC Peering for Private Cloud SQL access
module "private-cloudsql-access" {
  source      = "../../modules/private_service_access"
  project_id  = module.project-services.project_id
  vpc_network = google_compute_network.main.name
}
