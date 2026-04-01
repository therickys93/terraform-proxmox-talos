# Copyright (c) 2024 BB Tech Systems LLC

locals {
  # Resolve IP for each control node: prefer static IP if provided, else read from VM after boot
  control_node_ips = [
    for vm in keys(var.control_nodes) :
    length(var.control_plane_ip_addresses) > 0
      ? split("/", lookup(var.control_plane_ip_addresses, vm, ""))[0]
      : proxmox_virtual_environment_vm.talos_control_vm[vm].ipv4_addresses[7][0]
  ]

  # Resolve IP for each worker node: prefer static IP if provided, else read from VM after boot
  worker_node_ips = [
    for vm in keys(var.worker_nodes) :
    length(var.worker_ip_addresses) > 0
      ? split("/", lookup(var.worker_ip_addresses, vm, ""))[0]
      : proxmox_virtual_environment_vm.talos_worker_vm[vm].ipv4_addresses[7][0]
  ]

  primary_control_node_ip = local.control_node_ips[0]

  node_ips = concat(
    local.control_node_ips,
    local.worker_node_ips
  )

  # Talos machine config patch for static IP on control plane nodes.
  # Generated only for nodes that have an entry in control_plane_ip_addresses.
  control_static_ip_patches = {
    for name, cidr in var.control_plane_ip_addresses :
    name => yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              deviceSelector = {
                driver = "virtio_net"
              }
              addresses = [cidr]
              dhcp      = false
              routes = var.network_gateway != null ? [
                {
                  network = "0.0.0.0/0"
                  gateway = var.network_gateway
                }
              ] : []
            }
          ]
        }
      }
    })
  }

  # Talos machine config patch for static IP on worker nodes.
  # Generated only for nodes that have an entry in worker_ip_addresses.
  worker_static_ip_patches = {
    for name, cidr in var.worker_ip_addresses :
    name => yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              deviceSelector = {
                driver = "virtio_net"
              }
              addresses = [cidr]
              dhcp      = false
              routes = var.network_gateway != null ? [
                {
                  network = "0.0.0.0/0"
                  gateway = var.network_gateway
                }
              ] : []
            }
          ]
        }
      }
    })
  }
}

resource "proxmox_virtual_environment_download_file" "talos_image" {
  content_type = "iso"
  datastore_id = var.proxmox_iso_datastore
  node_name    = values(var.control_nodes)[0]

  url       = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/metal-${var.talos_arch}.qcow2"
  file_name = "${var.talos_cluster_name}-talos_linux-${var.talos_schematic_id}-${var.talos_version}-${var.talos_arch}.img"
}

resource "proxmox_virtual_environment_vm" "talos_control_vm" {
  for_each = var.control_nodes

  name      = each.key
  node_name = each.value
  pool_id   = var.proxmox_control_pool_id

  agent {
    enabled = true
  }

  cpu {
    cores = var.proxmox_control_vm_cores
    type  = var.proxmox_vm_type
  }

  memory {
    dedicated = var.proxmox_control_vm_memory
    floating  = var.proxmox_control_vm_memory
  }

  disk {
    datastore_id = var.proxmox_image_datastore
    file_id      = proxmox_virtual_environment_download_file.talos_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.proxmox_control_vm_disk_size
  }

  network_device {
    vlan_id     = var.proxmox_network_vlan_id
    bridge      = var.proxmox_network_bridge
    mac_address = lookup(var.control_plane_mac_addresses, each.key, null)
  }

  operating_system {
    type = "l26"
  }
}

resource "proxmox_virtual_environment_vm" "talos_worker_vm" {
  for_each = var.worker_nodes

  name      = each.key
  node_name = each.value
  pool_id   = var.proxmox_worker_pool_id

  agent {
    enabled = true
  }

  cpu {
    cores = var.proxmox_worker_vm_cores
    type  = var.proxmox_vm_type
  }

  memory {
    dedicated = var.proxmox_worker_vm_memory
    floating  = var.proxmox_worker_vm_memory
  }

  disk {
    datastore_id = var.proxmox_image_datastore
    file_id      = proxmox_virtual_environment_download_file.talos_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.proxmox_worker_vm_disk_size
  }

  network_device {
    vlan_id     = var.proxmox_network_vlan_id
    bridge      = var.proxmox_network_bridge
    mac_address = lookup(var.worker_mac_addresses, each.key, null)
  }

  dynamic "disk" {
    for_each = lookup(var.worker_extra_disks, each.key, [])
    content {
      datastore_id = disk.value.datastore_id
      file_format  = disk.value.file_format
      file_id      = disk.value.file_id
      interface    = "virtio${disk.key + 1}"
      iothread     = true
      discard      = "on"
      size         = disk.value.size
    }
  }

  operating_system {
    type = "l26"
  }
}

resource "talos_machine_secrets" "talos_secrets" {}

data "talos_machine_configuration" "control_mc" {
  cluster_name = var.talos_cluster_name
  machine_type = "controlplane"

  # TODO - Should we allow the user to override this?
  # This is a single point of failure but without a proxy or load balancer
  # it is required to be a single point of failure.
  cluster_endpoint = "https://${local.primary_control_node_ip}:6443"
  machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_machine_configuration" "worker_mc" {
  cluster_name = var.talos_cluster_name
  machine_type = "worker"

  # TODO - Should we allow the user to override this?
  # This is a single point of failure but without a proxy or load balancer
  # it is required to be a single point of failure.
  cluster_endpoint = "https://${local.primary_control_node_ip}:6443"
  machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_client_configuration" "talos_client_config" {
  cluster_name         = var.talos_cluster_name
  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
  endpoints            = local.control_node_ips
  nodes                = local.node_ips
}

resource "talos_machine_configuration_apply" "talos_control_mc_apply" {
  for_each = var.control_nodes

  client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_mc.machine_configuration
  node                        = local.control_node_ips[index(keys(var.control_nodes), each.key)]

  config_patches = concat(
    var.control_machine_config_patches,
    contains(keys(local.control_static_ip_patches), each.key)
      ? [local.control_static_ip_patches[each.key]]
      : []
  )
}

resource "talos_machine_configuration_apply" "talos_worker_mc_apply" {
  for_each = var.worker_nodes

  client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker_mc.machine_configuration
  node                        = local.worker_node_ips[index(keys(var.worker_nodes), each.key)]

  config_patches = concat(
    var.worker_machine_config_patches,
    contains(keys(local.worker_static_ip_patches), each.key)
      ? [local.worker_static_ip_patches[each.key]]
      : []
  )
}

# You only need to bootstrap 1 control node, we pick the first one
resource "talos_machine_bootstrap" "talos_bootstrap" {
  node                 = local.primary_control_node_ip
  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
}

resource "talos_cluster_kubeconfig" "talos_kubeconfig" {
  depends_on = [
    talos_machine_bootstrap.talos_bootstrap
  ]

  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
  node                 = local.primary_control_node_ip
}
