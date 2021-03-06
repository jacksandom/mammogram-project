/*
* ECS, or EC2 Container Service, is able to run docker containers natively in AWS cloud. While the module can support classic EC2-based and Fargate,
* features, this module generally prefers "ECS Fargete", which allows dynamic launching of docker containers with no always-on cost and no servers
* to manage or pay for when tasks are not running.
*
* Use in combination with the `ECS-Cluster` component.
*/

data "aws_ecs_cluster" "ecs_cluster" {
  cluster_name = var.ecs_cluster_name
}

resource "random_id" "suffix" {
  byte_length = 2
}

locals {
  env_vars = merge(
    {
      "AWS_DEFAULT_REGION" : var.environment.aws_region,
      "DETECT_HOSTNAME" : "true"
    },
    var.environment_vars
  )
  container_env_vars_str = join(",\n", sort([
    for k, v in local.env_vars :
    "{\"name\": \"${k}\", \"value\": \"${v}\"}"
  ]))
  entrypoint_str = var.container_entrypoint == null ? "" : "\"entryPoint\": [\"${var.container_entrypoint}\"],"
  command_str    = var.container_command == null ? "" : "\"command\": [\"${replace(replace(var.container_command, "\"", "\\\""), " ", "\", \"")}\"],"
  network_mode   = var.use_fargate ? "awsvpc" : "bridge"
  launch_type    = var.use_fargate ? "FARGATE" : "EC2"
  subnets        = var.use_private_subnet ? var.environment.private_subnets : var.environment.public_subnets
}

resource "aws_cloudwatch_log_group" "cw_log_group" {
  name = "${var.task_definition_name}AWSLogs-${random_id.suffix.dec}"
  tags = var.resource_tags
  # lifecycle { prevent_destroy = true }
}

resource "aws_ecs_task_definition" "ecs_task" {
  family                   = var.task_definition_name
  network_mode             = local.network_mode
  requires_compatibilities = [local.launch_type]
  cpu                      = var.container_num_cores * 1024
  memory                   = var.container_ram_gb * 1024
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  tags                     = var.resource_tags
  container_definitions    = <<DEFINITION
[
  {
    "name":       "${var.container_name}",
    "image":      "${var.container_image}",
    "cpu":         ${var.container_num_cores * 1024},
    "memory":      ${var.container_ram_gb * 1024},
    ${local.entrypoint_str}
    ${local.command_str}
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group":          "${aws_cloudwatch_log_group.cw_log_group.name}",
        "awslogs-region":         "${var.environment.aws_region}",
        "awslogs-stream-prefix":  "container-log"
      }
    },
    "portMappings": [
      {
        "containerPort": ${var.app_ports[0]},
        "hostPort":      ${var.app_ports[0]},
        "protocol":      "tcp"
      }
    ],
    "environment": [
      ${local.container_env_vars_str}
    ],
    "secrets": [],
    "mountPoints": [],
    "volumesFrom": [],
    "essential" : true
  }
]
DEFINITION
}

resource "aws_security_group" "ecs_tasks_sg" {
  name        = "${var.task_definition_name}ECSSecurityGroup-${random_id.suffix.dec}"
  description = "allow inbound access on specific ports, outbound on all ports"
  vpc_id      = var.environment.vpc_id
  tags        = var.resource_tags
  dynamic "ingress" {
    for_each = var.app_ports
    content {
      protocol    = "tcp"
      from_port   = ingress.value
      to_port     = ingress.value
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  dynamic "ingress" {
    for_each = var.admin_ports
    content {
      protocol    = "tcp"
      from_port   = ingress.value
      to_port     = ingress.value
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "ecs_always_on_service" {
  count           = var.always_on ? 1 : 0
  name            = "${var.task_definition_name}ECSService-${random_id.suffix.dec}"
  desired_count   = 1
  cluster         = data.aws_ecs_cluster.ecs_cluster.arn
  task_definition = aws_ecs_task_definition.ecs_task.arn
  launch_type     = local.launch_type
  # iam_role        = aws_iam_role.ecs_execution_role.name
  network_configuration {
    subnets          = local.subnets
    security_groups  = [aws_security_group.ecs_tasks_sg.id]
    assign_public_ip = true
  }
  dynamic "load_balancer" {
    for_each = var.use_load_balancer ? toset(var.app_ports) : []
    content {
      target_group_arn = var.use_load_balancer ? aws_lb_target_group.alb_target_group[load_balancer.value].arn : null
      container_name   = var.container_name
      container_port   = load_balancer.value
      # container_name = var.use_load_balancer ? var.container_name : null
      # container_port = var.use_load_balancer ? var.admin_ports["WebPortal"] : null
    }
  }
}

resource "aws_cloudwatch_event_rule" "daily_run_schedule" {
  for_each = var.schedules
  name = "${var.task_definition_name}sched-${random_id.suffix.dec}-${
    replace(replace(replace(replace(replace(
      each.value,
    " ", ""), "(", ""), ")", ""), "*", ""), "?", "")
  }"
  description         = "Daily Execution 'run' @ ${each.value}"
  role_arn            = aws_iam_role.ecs_execution_role.arn
  schedule_expression = each.value
}

resource "aws_cloudwatch_event_target" "daily_run_task" {
  for_each = var.schedules
  rule     = aws_cloudwatch_event_rule.daily_run_schedule[each.value].name
  arn      = data.aws_ecs_cluster.ecs_cluster.arn
  role_arn = aws_iam_role.ecs_execution_role.arn
  ecs_target {
    task_definition_arn = aws_ecs_task_definition.ecs_task.arn
    task_count          = 1
    launch_type         = var.ecs_launch_type
    group               = "${var.task_definition_name}ScheduledTasks"
    network_configuration {
      subnets          = local.subnets
      security_groups  = [aws_security_group.ecs_tasks_sg.id]
      assign_public_ip = true
    }
  }
}
