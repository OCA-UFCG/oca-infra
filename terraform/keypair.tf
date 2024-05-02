resource "openstack_compute_keypair_v2" "oca-keypair" {
  name       = "oca-keypair"
  public_key = file("${var.keypair_path}")
  }