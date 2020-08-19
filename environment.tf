data "aws_caller_identity" "current" {}

locals {
  is_windows_host      = substr(pathexpand("~"), 0, 1) == "/" ? false : true
  user_home            = pathexpand("~")
}

module "vpc" {
  source               = "./modules/vpc"
  name_prefix          = "mammogram"
  aws_region           = var.region
  aws_profile          = var.profile
  resource_tags        = {}
}
