resource "openstack_compute_instance_v2" "oca-server" {
  name            = "oca-server"
  image_id        = tolist(data.openstack_images_image_ids_v2.image.ids)[0]
  flavor_id       = data.openstack_compute_flavor_v2.medium.id
  key_pair        = openstack_compute_keypair_v2.oca-keypair.name
  security_groups = ["default", openstack_networking_secgroup_v2.oca_sg.name]

  network {
    uuid = data.openstack_networking_network_v2.network.id
  }

}
