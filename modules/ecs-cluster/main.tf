/*
* ECS, or EC2 Container Service, is able to run docker containers natively in AWS cloud. While the module can support classic EC2-based and Fargate,
* features, this module generally prefers "ECS Fargete", which allows dynamic launching of docker containers with no always-on cost and no servers
* to manage or pay for when tasks are not running.
*
* Use in combination with the `ECS-Task` component.
*/

data "aws_availability_zones" "az_list" {}

resource "random_id" "suffix" {
  byte_length = 2
}

locals {
  project_shortname = substr(var.name_prefix, 0, length(var.name_prefix) - 1)
}

resource "aws_launch_configuration" "ecs_instance_launch_config" {
  count                       = var.ec2_instance_count == 0 ? 0 : 1
  name_prefix                 = "${var.name_prefix}launch-"
  associate_public_ip_address = true
  ebs_optimized               = true
  enable_monitoring           = true
  instance_type               = var.ec2_instance_type
  image_id                    = data.aws_ami.ecs_linux_ami.id
  iam_instance_profile        = aws_iam_instance_profile.ecs_iam_instance_profile.id

  user_data = <<USER_DATA
#!/usr/bin/env bash
echo ECS_CLUSTER=${aws_ecs_cluster.ecs_cluster.name} >> /etc/ecs/ecs.config
USER_DATA
}

resource "aws_autoscaling_group" "ecs_asg" {
  count                = var.ec2_instance_count == 0 ? 0 : 1
  name                 = "${var.name_prefix}ECSASG"
  availability_zones   = slice(data.aws_availability_zones.az_list.names, 0, 2)
  desired_capacity     = var.ec2_instance_count
  min_size             = var.ec2_instance_count
  max_size             = var.ec2_instance_count
  launch_configuration = aws_launch_configuration.ecs_instance_launch_config[0].id
}

data "aws_ami" "ecs_linux_ami" {
  # https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html
  owners      = ["amazon"] # AWS
  most_recent = true
  filter {
    name = "name"
    values = [
      "*ecs*optimized*",
      "*amazon-linux-2*"
    ]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  # filter {
  #   name   = "virtualization-type"
  #   values = ["hvm"]
  # }
  # filter {
  #   name   = "root-device-type"
  #   values = ["ebs"]
  # }
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "mammogram-cluster"
  tags = var.resource_tags
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_iam_instance_profile" "ecs_iam_instance_profile" {
  name = "${var.name_prefix}ecs_iam_instance_profile-${random_id.suffix.dec}"
  role = aws_iam_role.ecs_instance_role.id
}
