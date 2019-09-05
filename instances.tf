#################################
# Configure the VMware vSphere Provider
##################################
provider "vsphere" {
  version        = "~> 1.1"
  vsphere_server = "${var.vsphere_server}"

  # if you have a self-signed cert
  allow_unverified_ssl = "${var.allow_unverified_ssl}"
}

data "vsphere_virtual_machine" "template" {
  name              = "${var.template}"
  datacenter_id   = "${var.vsphere_datacenter_id}"
}

locals {
  node_count = "${var.bastion["nodes"] + var.master["nodes"] + var.infra["nodes"] + var.worker["nodes"] + var.storage["nodes"]}"
  gateways = ["${compact(list(var.public_gateway, var.private_gateway))}"]
}

data "template_file" "private_ips" {
  count = "${local.node_count}"

  template = "${cidrhost(var.private_staticipblock, 1 + var.private_staticipblock_offset + count.index)}"
}

data "template_file" "public_ips" {
  count = "${var.public_network_id != "" ? var.bastion["nodes"] : 0}"

  template = "${cidrhost(var.public_staticipblock, 1 + var.public_staticipblock_offset + count.index)}"
}

##################################
#### Create the Bastion VM
##################################
resource "vsphere_virtual_machine" "bastion" {
  #depends_on = ["vsphere_folder.ocpenv"]
  folder     = "${var.folder_path}"

  #####
  # VM Specifications
  ####
  count            = "${var.datastore_id != "" ? var.bastion["nodes"] : 0}"
  resource_pool_id = "${var.vsphere_resource_pool_id}"

  name      = "${format("${lower(var.instance_name)}-bastion-%02d", count.index + 1) }"
  num_cpus  = "${var.bastion["vcpu"]}"
  memory    = "${var.bastion["memory"]}"

  scsi_controller_count = 1

  ####
  # Disk specifications
  ####
  datastore_id  = "${var.datastore_id}"
  guest_id      = "${data.vsphere_virtual_machine.template.guest_id}"
  scsi_type     = "${data.vsphere_virtual_machine.template.scsi_type}"

  disk {
    label            = "disk0"
    size             = "${var.bastion["disk_size"]        != "" ? var.bastion["disk_size"]        : data.vsphere_virtual_machine.template.disks.0.size}"
    eagerly_scrub    = "${var.bastion["eagerly_scrub"]    != "" ? var.bastion["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.bastion["thin_provisioned"] != "" ? var.bastion["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.bastion["keep_disk_on_remove"]}"
    unit_number      = 0
  }

  ####
  # Network specifications
  ####
  dynamic "network_interface" {
    for_each = compact(concat(list(var.public_network_id, var.private_network_id)))
    content {
      network_id   = "${network_interface.value}"
      adapter_type = "${data.vsphere_virtual_machine.template.network_interface_types[0]}"
    }
  }

  ####
  # VM Customizations
  ####
  clone {
    template_uuid = "${data.vsphere_virtual_machine.template.id}"

    customize {
      linux_options {
        host_name = "${var.instance_name}-bastion"
        domain    = "${var.private_domain != "" ? var.private_domain : format("%s.local", var.instance_name)}"
      }

      dynamic "network_interface" {
        for_each = compact(concat(list(var.public_network_id, var.private_network_id)))
        content {
          ipv4_address = "${element(concat(data.template_file.public_ips.*.rendered, data.template_file.private_ips.*.rendered), network_interface.key)}"
          ipv4_netmask = "${element(compact(concat(list(var.public_netmask), list(var.private_netmask))), network_interface.key)}"
        }
      }

      # set the default gateway to public if available.  TODO: static routes for private network
      ipv4_gateway    = "${var.public_gateway != "" ? var.public_gateway : var.private_gateway}"

      dns_server_list = compact(concat(var.private_dns_servers, var.public_dns_servers))
      dns_suffix_list = compact(list(var.private_domain, var.public_domain))
    }
  }

  # Specify the ssh connection
  connection {
    host          = "${self.default_ip_address}"
    user          = "${var.template_ssh_user}"
    password      = "${var.template_ssh_password}"
    private_key   = "${var.template_ssh_private_key}"
  }

  provisioner "file" {
    source      = "${path.module}/scripts"
    destination = "/tmp/terraform_scripts"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod u+x /tmp/terraform_scripts/*.sh",
      "/tmp/terraform_scripts/add-private-ssh-key.sh \"${var.ssh_private_key}\" \"${var.ssh_user}\"",
      "/tmp/terraform_scripts/add-public-ssh-key.sh \"${var.ssh_public_key}\""
    ]
  }

}


##################################
#### Create the Master VM
##################################
resource "vsphere_virtual_machine" "master" {
  #depends_on = ["vsphere_folder.ocpenv"]
  folder      = "${var.folder_path}"

  #####
  # VM Specifications
  ####
  count            = "${var.datastore_id != "" ? var.master["nodes"] : 0}"
  resource_pool_id = "${var.vsphere_resource_pool_id}"

  name      = "${format("${lower(var.instance_name)}-master-%02d", count.index + 1) }"
  num_cpus  = "${var.master["vcpu"]}"
  memory    = "${var.master["memory"]}"

  scsi_controller_count = 1

  ####
  # Disk specifications
  ####
  datastore_id  = "${var.datastore_id}"
  guest_id      = "${data.vsphere_virtual_machine.template.guest_id}"
  scsi_type     = "${data.vsphere_virtual_machine.template.scsi_type}"

  disk {
    label            = "disk0"
    size             = "${var.master["disk_size"]        != "" ? var.master["disk_size"]        : data.vsphere_virtual_machine.template.disks.0.size}"
    eagerly_scrub    = "${var.master["eagerly_scrub"]    != "" ? var.master["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.master["thin_provisioned"] != "" ? var.master["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.master["keep_disk_on_remove"]}"
    unit_number      = 0
  }

  disk {
    label            = "disk1"
    size             = "${var.master["docker_disk_size"]}"
    eagerly_scrub    = "${var.master["eagerly_scrub"]    != "" ? var.master["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.master["thin_provisioned"] != "" ? var.master["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.master["keep_disk_on_remove"]}"
    unit_number      = 1
  }

  ####
  # Network specifications
  ####
  network_interface {
    network_id   = "${var.private_network_id}"
    adapter_type = "${data.vsphere_virtual_machine.template.network_interface_types[0]}"
  }

  ####
  # VM Customizations
  ####
  clone {
    template_uuid = "${data.vsphere_virtual_machine.template.id}"

    customize {
      linux_options {
        host_name = "${format("${lower(var.instance_name)}-master-%02d", count.index + 1) }"
        domain    = "${var.private_domain != "" ? var.private_domain : format("%s.local", var.instance_name)}"
      }

      network_interface {
        ipv4_address  = "${element(data.template_file.private_ips.*.rendered, var.bastion["nodes"] + count.index)}"
        ipv4_netmask  = "${var.private_netmask}"
      }

      ipv4_gateway    = "${var.private_gateway}"
      dns_server_list = "${var.private_dns_servers}"
      dns_suffix_list = ["${var.private_domain}"]
    }
  }

  # Specify the ssh connection
  connection {
    host          = "${self.default_ip_address}"
    user          = "${var.template_ssh_user}"
    password      = "${var.template_ssh_password}"
    private_key   = "${var.template_ssh_private_key}"

    bastion_host          = "${vsphere_virtual_machine.bastion.0.default_ip_address}"
    bastion_user          = "${var.template_ssh_user}"
    bastion_password      = "${var.template_ssh_password}"
    bastion_private_key   = "${var.template_ssh_private_key}"
  }

  provisioner "file" {
    source      = "${path.module}/scripts"
    destination = "/tmp/terraform_scripts"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod u+x /tmp/terraform_scripts/*.sh",
      "/tmp/terraform_scripts/add-public-ssh-key.sh \"${var.ssh_public_key}\""
    ]
  }

}

##################################
### Create the Infra VM
##################################
resource "vsphere_virtual_machine" "infra" {
  #depends_on = ["vsphere_folder.ocpenv"]
  folder      = "${var.folder_path}"

  #####
  # VM Specifications
  ####
  count            = "${var.datastore_id != "" ? var.infra["nodes"] : 0}"
  resource_pool_id = "${var.vsphere_resource_pool_id}"

  name     = "${format("${lower(var.instance_name)}-infra-%02d", count.index + 1) }"
  num_cpus = "${var.infra["vcpu"]}"
  memory   = "${var.infra["memory"]}"


  ####
  # Disk specifications
  ####
  datastore_id  = "${var.datastore_id}"
  guest_id      = "${data.vsphere_virtual_machine.template.guest_id}"
  scsi_type     = "${data.vsphere_virtual_machine.template.scsi_type}"

  disk {
    label            = "disk0"
    size             = "${var.infra["disk_size"]        != "" ? var.infra["disk_size"]        : data.vsphere_virtual_machine.template.disks.0.size}"
    eagerly_scrub    = "${var.infra["eagerly_scrub"]    != "" ? var.infra["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.infra["thin_provisioned"] != "" ? var.infra["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.infra["keep_disk_on_remove"]}"
    unit_number      = 0
  }

  disk {
    label            = "disk1"
    size             = "${var.infra["docker_disk_size"]}"
    eagerly_scrub    = "${var.infra["eagerly_scrub"]    != "" ? var.infra["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.infra["thin_provisioned"] != "" ? var.infra["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.infra["keep_disk_on_remove"]}"
    unit_number      = 1
  }

  ####
  # Network specifications
  ####
  network_interface {
    network_id   = "${var.private_network_id}"
    adapter_type = "${data.vsphere_virtual_machine.template.network_interface_types[0]}"
  }

  ####
  # VM Customizations
  ####
  clone {
    template_uuid = "${data.vsphere_virtual_machine.template.id}"

    customize {
      linux_options {
        host_name = "${format("${lower(var.instance_name)}-infra-%02d", count.index + 1) }"
        domain    = "${var.private_domain != "" ? var.private_domain : format("%s.local", var.instance_name)}"
      }

      network_interface {
        ipv4_address  = "${element(data.template_file.private_ips.*.rendered, 
          var.bastion["nodes"] + 
          var.master["nodes"] + 
          count.index)}"
        ipv4_netmask  = "${var.private_netmask}"
      }

      ipv4_gateway    = "${var.private_gateway}"
      dns_server_list = "${var.private_dns_servers}"
      dns_suffix_list = ["${var.private_domain}"]
    }
  }

  # Specify the ssh connection
  connection {
    host          = "${self.default_ip_address}"
    user          = "${var.template_ssh_user}"
    password      = "${var.template_ssh_password}"
    private_key   = "${var.template_ssh_private_key}"
 
    bastion_host          = "${vsphere_virtual_machine.bastion.0.default_ip_address}"
    bastion_user          = "${var.template_ssh_user}"
    bastion_password      = "${var.template_ssh_password}"
    bastion_private_key   = "${var.template_ssh_private_key}"
   
  }

  provisioner "file" {
    source      = "${path.module}/scripts"
    destination = "/tmp/terraform_scripts"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod u+x /tmp/terraform_scripts/*.sh",
      "/tmp/terraform_scripts/add-public-ssh-key.sh \"${var.ssh_public_key}\""
    ]
  }
}

##################################
### Create the Worker VM
##################################
resource "vsphere_virtual_machine" "worker" {
  #depends_on = ["vsphere_folder.ocpenv"]
  folder      = "${var.folder_path}"

  #####
  # VM Specifications
  ####
  count            = "${var.datastore_id != "" ? var.worker["nodes"] : 0}"
  resource_pool_id = "${var.vsphere_resource_pool_id}"

  name     = "${format("${lower(var.instance_name)}-worker-%02d", count.index + 1) }"
  num_cpus = "${var.worker["vcpu"]}"
  memory   = "${var.worker["memory"]}"

  #####
  # Disk Specifications
  ####
  datastore_id  = "${var.datastore_id}"
  guest_id      = "${data.vsphere_virtual_machine.template.guest_id}"
  scsi_type     = "${data.vsphere_virtual_machine.template.scsi_type}"

  disk {
    label            = "disk0"
    size             = "${var.worker["disk_size"]        != "" ? var.worker["disk_size"]        : data.vsphere_virtual_machine.template.disks.0.size}"
    eagerly_scrub    = "${var.worker["eagerly_scrub"]    != "" ? var.worker["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.worker["thin_provisioned"] != "" ? var.worker["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.worker["keep_disk_on_remove"]}"
    unit_number      = 0
  }

  disk {
    label            = "disk1"
    size             = "${var.worker["docker_disk_size"]}"
    eagerly_scrub    = "${var.worker["eagerly_scrub"]    != "" ? var.worker["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.worker["thin_provisioned"] != "" ? var.worker["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.worker["keep_disk_on_remove"]}"
    unit_number      = 1
  }

  ####
  # Network specifications
  ####
  network_interface {
    network_id   = "${var.private_network_id}"
    adapter_type = "${data.vsphere_virtual_machine.template.network_interface_types[0]}"
  }


  #####
  # VM Customizations
  ####
  clone {
    template_uuid = "${data.vsphere_virtual_machine.template.id}"

    customize {
      linux_options {
        host_name = "${format("${lower(var.instance_name)}-worker-%02d", count.index + 1) }"
        domain    = "${var.private_domain != "" ? var.private_domain : format("%s.local", var.instance_name)}"
      }

      network_interface {
        ipv4_address  = "${element(data.template_file.private_ips.*.rendered, 
          var.bastion["nodes"] + 
          var.master["nodes"] + 
          var.infra["nodes"] + 
          count.index)}"
        ipv4_netmask  = "${var.private_netmask}"
      }

      ipv4_gateway    = "${var.private_gateway}"
      dns_server_list = "${var.private_dns_servers}"
      dns_suffix_list = ["${var.private_domain}"]
    }
  }

  # Specify the ssh connection
  connection {
    host          = "${self.default_ip_address}"
    user          = "${var.template_ssh_user}"
    password      = "${var.template_ssh_password}"
    private_key   = "${var.template_ssh_private_key}"
 
    bastion_host          = "${vsphere_virtual_machine.bastion.0.default_ip_address}"
    bastion_user          = "${var.template_ssh_user}"
    bastion_password      = "${var.template_ssh_password}"
    bastion_private_key   = "${var.template_ssh_private_key}"
   
  }

  provisioner "file" {
    source      = "${path.module}/scripts"
    destination = "/tmp/terraform_scripts"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod u+x /tmp/terraform_scripts/*.sh",
      "/tmp/terraform_scripts/add-public-ssh-key.sh \"${var.ssh_public_key}\""
    ]
  }

}

##################################
### Create the Storage VM
##################################
resource "vsphere_virtual_machine" "storage" {
  #depends_on = ["vsphere_folder.ocpenv"]
  folder      = "${var.folder_path}"

  #####
  # VM Specifications
  ####
  count            = "${var.datastore_id != "" ? var.storage["nodes"] : 0}"
  resource_pool_id = "${var.vsphere_resource_pool_id}"

  name     = "${format("${lower(var.instance_name)}-storage-%02d", count.index + 1) }"
  num_cpus = "${var.storage["vcpu"]}"
  memory   = "${var.storage["memory"]}"


  #####
  # Disk Specifications
  ####
  datastore_id  = "${var.datastore_id}"
  guest_id      = "${data.vsphere_virtual_machine.template.guest_id}"
  scsi_type     = "${data.vsphere_virtual_machine.template.scsi_type}"

  disk {
    label            = "disk0"
    size             = "${var.storage["disk_size"]        != "" ? var.storage["disk_size"]        : data.vsphere_virtual_machine.template.disks.0.size}"
    eagerly_scrub    = "${var.storage["eagerly_scrub"]    != "" ? var.storage["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.storage["thin_provisioned"] != "" ? var.storage["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.storage["keep_disk_on_remove"]}"
    unit_number      = 0
  }

  disk {
    label            = "disk1"
    size             = "${var.storage["docker_disk_size"]}"
    eagerly_scrub    = "${var.storage["eagerly_scrub"]    != "" ? var.storage["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.storage["thin_provisioned"] != "" ? var.storage["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.storage["keep_disk_on_remove"]}"
    unit_number      = 1
  }

  disk {
    label            = "disk2"
    size             = "${var.storage["gluster_disk_size"]}"
    eagerly_scrub    = "${var.storage["eagerly_scrub"]    != "" ? var.storage["eagerly_scrub"]    : data.vsphere_virtual_machine.template.disks.0.eagerly_scrub}"
    thin_provisioned = "${var.storage["thin_provisioned"] != "" ? var.storage["thin_provisioned"] : data.vsphere_virtual_machine.template.disks.0.thin_provisioned}"
    keep_on_remove   = "${var.storage["keep_disk_on_remove"]}"
    unit_number      = 2
  }

  ####
  # Network specifications
  ####
  network_interface {
    network_id   = "${var.private_network_id}"
    adapter_type = "${data.vsphere_virtual_machine.template.network_interface_types[0]}"
  }


  #####
  # VM Customizations
  ####
  clone {
    template_uuid = "${data.vsphere_virtual_machine.template.id}"

    customize {
      linux_options {
        host_name = "${format("${lower(var.instance_name)}-storage-%02d", count.index + 1) }"
        domain    = "${var.private_domain != "" ? var.private_domain : format("%s.local", var.instance_name)}"
      }

      network_interface {
        ipv4_address  = "${element(data.template_file.private_ips.*.rendered, 
          var.bastion["nodes"] + 
          var.master["nodes"] + 
          var.infra["nodes"] + 
          var.worker["nodes"] + 
          count.index)}"
        ipv4_netmask  = "${var.private_netmask}"
      }

      ipv4_gateway    = "${var.private_gateway}"
      dns_server_list = "${var.private_dns_servers}"
      dns_suffix_list = ["${var.private_domain}"]
    }
  }

  # Specify the ssh connection
  connection {
    host          = "${self.default_ip_address}"
    user          = "${var.template_ssh_user}"
    password      = "${var.template_ssh_password}"
    private_key   = "${var.template_ssh_private_key}"

    bastion_host          = "${vsphere_virtual_machine.bastion.0.default_ip_address}"
    bastion_user          = "${var.template_ssh_user}"
    bastion_password      = "${var.template_ssh_password}"
    bastion_private_key   = "${var.template_ssh_private_key}"
   
  }

  provisioner "file" {
    source      = "${path.module}/scripts"
    destination = "/tmp/terraform_scripts"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod u+x /tmp/terraform_scripts/*.sh",
      "/tmp/terraform_scripts/add-public-ssh-key.sh \"${var.ssh_public_key}\""
    ]
  }
}



