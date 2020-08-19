##############################################
### Standard variables for all AWS modules ###
##############################################

variable "name_prefix" {
  description = "Standard `name_prefix` module input."
  type        = string
}

variable "resource_tags" {
  description = "Standard `resource_tags` module input."
  type        = map(string)
}

########################################
### Custom variables for this module ###
########################################

variable "ec2_instance_type" {
  description = "Optional. Overrides default instance type if using always-on EC2 instances (i.e. `ec2_instance_count` > 0)."
  default     = "m4.xlarge"
}
variable "ec2_instance_count" {
  description = "Optional. Number of 'always-on' EC2 instances. (Default is 0, meaning no always-on EC2 resources.)."
  default     = 0
}
