data "openstack_networking_network_v2" "network" {
  external = false
  status = "active"
}

resource "openstack_compute_floatingip_v2" "float_ip" {
  pool = "public"
  
}

