locals {
  cloud_init_volume_name = var.cloud_init_volume_name == "" ? "${var.name}-cloud-init.iso" : var.cloud_init_volume_name
  network_interfaces = concat(
    [for libvirt_network in var.libvirt_networks: {
      network_name = libvirt_network.network_name != "" ? libvirt_network.network_name : null
      network_id = libvirt_network.network_id != "" ? libvirt_network.network_id : null
      macvtap = null
      addresses = null
      mac = libvirt_network.mac
      hostname = null
    }],
    [for macvtap_interface in var.macvtap_interfaces: {
      network_name = null
      network_id = null
      macvtap = macvtap_interface.interface
      addresses = null
      mac = macvtap_interface.mac
      hostname = null
    }]
  )
}

module "network_configs" {
  source             = "git::https://github.com/Ferlab-Ste-Justine/terraform-cloudinit-templates.git//network?ref=v0.8.0"
  network_interfaces = concat(
    [for idx, libvirt_network in var.libvirt_networks: {
      ip = libvirt_network.ip
      gateway = libvirt_network.gateway
      prefix_length = libvirt_network.prefix_length
      interface = "libvirt${idx}"
      mac = libvirt_network.mac
      dns_servers = libvirt_network.dns_servers
    }],
    [for idx, macvtap_interface in var.macvtap_interfaces: {
      ip = macvtap_interface.ip
      gateway = macvtap_interface.gateway
      prefix_length = macvtap_interface.prefix_length
      interface = "macvtap${idx}"
      mac = macvtap_interface.mac
      dns_servers = macvtap_interface.dns_servers
    }]
  )
}

module "vault_configs" {
  source               = "git::https://github.com/Ferlab-Ste-Justine/terraform-cloudinit-templates.git//vault?ref=v0.27.4"
  install_dependencies = var.install_dependencies
  hostname             = var.hostname 
  release_version      = var.release_version
  tls                  = var.tls
  etcd_backend         = var.etcd_backend
}

module "prometheus_node_exporter_configs" {
  source               = "git::https://github.com/Ferlab-Ste-Justine/terraform-cloudinit-templates.git//prometheus-node-exporter?ref=v0.8.0"
  install_dependencies = var.install_dependencies
}

module "chrony_configs" {
  source               = "git::https://github.com/Ferlab-Ste-Justine/terraform-cloudinit-templates.git//chrony?ref=v0.8.0"
  install_dependencies = var.install_dependencies
  chrony               = {
    servers  = var.chrony.servers
    pools    = var.chrony.pools
    makestep = var.chrony.makestep
  }
}

locals {
  cloudinit_templates = concat([
      {
        filename     = "base.cfg"
        content_type = "text/cloud-config"
        content      = templatefile(
          "${path.module}/files/user_data.yaml.tpl", 
          {
            hostname             = var.name
            ssh_admin_public_key = var.ssh_admin_public_key
            ssh_admin_user       = var.ssh_admin_user
            admin_user_password  = var.admin_user_password
          }
        )
      },
      {
        filename     = "vault.cfg"
        content_type = "text/cloud-config"
        content      = module.vault_configs.configuration
      },
      {
        filename     = "node_exporter.cfg"
        content_type = "text/cloud-config"
        content      = module.prometheus_node_exporter_configs.configuration
      }
    ],
    var.chrony.enabled ? [{
      filename     = "chrony.cfg"
      content_type = "text/cloud-config"
      content      = module.chrony_configs.configuration
    }] : [],
  )
}

data "template_cloudinit_config" "user_data" {
  gzip          = false
  base64_encode = false
  dynamic "part" {
    for_each = local.cloudinit_templates
    content {
      filename     = part.value["filename"]
      content_type = part.value["content_type"]
      content      = part.value["content"]
    }
  }
}

resource "libvirt_cloudinit_disk" "vault_node" {
  name           = local.cloud_init_volume_name
  user_data      = data.template_cloudinit_config.user_data.rendered
  network_config = module.network_configs.configuration
  pool           = var.cloud_init_volume_pool
}

resource "libvirt_domain" "vault_node" {
  name = var.name

  cpu {
    mode = "host-passthrough"
  }

  vcpu   = var.vcpus
  memory = var.memory

  disk {
    volume_id = var.volume_id
  }

  dynamic "network_interface" {
    for_each = local.network_interfaces
    content {
      network_id   = network_interface.value["network_id"]
      network_name = network_interface.value["network_name"]
      macvtap      = network_interface.value["macvtap"]
      addresses    = network_interface.value["addresses"]
      mac          = network_interface.value["mac"]
      hostname     = network_interface.value["hostname"]
    }
  }

  autostart = true

  cloudinit = libvirt_cloudinit_disk.vault_node.id

  //https://github.com/dmacvicar/terraform-provider-libvirt/blob/main/examples/v0.13/ubuntu/ubuntu-example.tf#L61
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }
}