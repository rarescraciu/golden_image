variable "vm_name" { 
  type = string  
  default = "ubuntu-dev-golden" 
}
variable "switch_name" { 
  type = string  
  default = "Default Switch" 
}
variable "iso_path" { 
  type = string # e.g. C:/ISOs/ubuntu-24.04.3-live-server-amd64.iso
} 
variable "cpus" { 
  type = number  
  default = 4 
}
variable "memory_mb" { 
  type = number  
  default = 4096 
}
variable "disk_size_mb" { 
  type = number  
  default = 81920 
}
variable "ssh_username" { 
  type = string  
  default = "devops" 
}
  
variable "output_dir" { 
  type = string  
  default = "output-hyperv" 
}

variable "packer_private_key_path" {
  type = string
}

