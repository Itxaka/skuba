data "template_file" "master_repositories" {
  template = file("cloud-init/repository.tpl")
  count    = length(var.repositories)

  vars = {
    repository_url  = element(values(var.repositories), count.index)
    repository_name = element(keys(var.repositories), count.index)
  }
}

data "template_file" "master_register_scc" {
  template = file("cloud-init/register-scc.tpl")
  count    = var.caasp_registry_code == "" ? 0 : 1

  vars = {
    caasp_registry_code = var.caasp_registry_code

    # no need to enable the SLE HA product on this kind of nodes
    ha_registry_code = ""
  }
}

data "template_file" "master_register_rmt" {
  template = file("cloud-init/register-rmt.tpl")
  count    = var.rmt_server_name == "" ? 0 : 1

  vars = {
    rmt_server_name = var.rmt_server_name
  }
}

data "template_file" "master_commands" {
  template = file("cloud-init/commands.tpl")
  count    = join("", var.packages) == "" ? 0 : 1

  vars = {
    packages = join(", ", var.packages)
  }
}

data "template_file" "master-cloud-init" {
  template = file("cloud-init/common.tpl")
  count    = var.masters

  vars = {
    authorized_keys    = join("\n", formatlist("  - %s", var.authorized_keys))
    repositories       = join("\n", data.template_file.master_repositories.*.rendered)
    register_scc       = join("\n", data.template_file.master_register_scc.*.rendered)
    register_rmt       = join("\n", data.template_file.master_register_rmt.*.rendered)
    commands           = join("\n", data.template_file.master_commands.*.rendered)
    username           = var.username
    ntp_servers        = join("\n", formatlist("    - %s", var.ntp_servers))
    hostname           = "${var.stack_name}-master-${count.index}"
    hostname_from_dhcp = var.hostname_from_dhcp == true ? "yes" : "no"
  }
}

resource "libvirt_volume" "master" {
  name           = "${var.stack_name}-master-volume-${count.index}"
  pool           = var.pool
  size           = var.master_disk_size
  base_volume_id = libvirt_volume.img.id
  count          = var.masters
}

resource "libvirt_cloudinit_disk" "master" {
  # needed when 0 master nodes are defined
  count     = var.masters
  name      = "${var.stack_name}-master-cloudinit-disk-${count.index}"
  pool      = var.pool
  user_data = data.template_file.master-cloud-init[count.index].rendered
}

resource "libvirt_domain" "master" {
  count      = var.masters
  name       = "${var.stack_name}-master-domain-${count.index}"
  memory     = var.master_memory
  vcpu       = var.master_vcpu
  cloudinit  = element(libvirt_cloudinit_disk.master.*.id, count.index)
  depends_on = [libvirt_domain.lb]

  cpu = {
    mode = "host-passthrough"
  }

  disk {
    volume_id = element(libvirt_volume.master.*.id, count.index)
  }

  network_interface {
    network_name   = var.network_name
    network_id     = var.network_name == "" ? libvirt_network.network.0.id : null
    hostname       = "${var.stack_name}-master-${count.index}"
    wait_for_lease = true
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }
}

resource "null_resource" "master_wait_cloudinit" {
  depends_on = [libvirt_domain.master]
  count      = var.masters

  connection {
    host = element(
      libvirt_domain.master.*.network_interface.0.addresses.0,
      count.index
    )
    user     = var.username
    type     = "ssh"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait > /dev/null",
    ]
  }
}

resource "null_resource" "master_reboot" {
  depends_on = [null_resource.master_wait_cloudinit]
  count      = var.masters

  provisioner "local-exec" {
    environment = {
      user = var.username
      host = element(
        libvirt_domain.master.*.network_interface.0.addresses.0,
        count.index
      )
    }

    command = <<EOT
export sshopts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -oConnectionAttempts=60"
if ! ssh $sshopts $user@$host 'sudo needs-restarting -r'; then
    ssh $sshopts $user@$host sudo reboot || :
    export delay=5
    # wait for node reboot completed
    while ! ssh $sshopts $user@$host 'sudo needs-restarting -r'; do
        sleep $delay
        delay=$((delay+1))
        [ $delay -gt 30 ] && exit 1
    done
fi
EOT
  }
}
