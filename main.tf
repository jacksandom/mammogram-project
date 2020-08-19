provider "aws" {
  version = "~> 2.10"
  region  = var.region
  profile = var.profile
}

# S3 bucket
resource "aws_s3_bucket" "bucket" {
  bucket = var.bucket_name
  acl    = "private"
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

# Upload training script
resource "aws_s3_bucket_object" "training_script" {
  bucket = aws_s3_bucket.bucket.id
  key    = "scripts/train.tar.gz"
  source = "scripts/train.tar.gz"

  etag = filemd5(
    "scripts/train.tar.gz",
  )
}

# ECR Image
module "ecr-image-conversion"{
    source = "./modules/ecr-image"

    name_prefix          = "mammogram"
    resource_tags        = {}
    repository_name      = "conversion"
    source_image_path    = "conversion"
    aws_credentials_file = var.credentials_path
}

module "ecr-image-preprocessing"{
    source = "./modules/ecr-image"

    name_prefix          = "mammogram"
    resource_tags        = {}
    repository_name      = "preprocessing"
    source_image_path    = "conversion"
    aws_credentials_file = var.credentials_path
}

# ECS Cluster
module "ecs-cluster"{
    source = "./modules/ecs-cluster"

    name_prefix    = "mammogram"
    resource_tags  = {}

    ec2_instance_count = 2
    ec2_instance_type  = "m4.xlarge"
}

# ECS Task
module "ecs-task-conversion"{
    source = "./modules/ecs-task"

    name_prefix   = "mammogram"
    environment   = {
        vpc_id          = module.vpc.vpc_id
        aws_region      = var.region
        public_subnets  = module.vpc.public_subnets
        private_subnets = module.vpc.private_subnets

    }
    resource_tags = {}

    container_image      = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/mammogram-conversion:latest"
    container_name       = "mammogram-conversion"
    container_num_cores  = 4
    container_ram_gb     = 8
    ecs_cluster_name     = "mammogram-cluster"
    ecs_launch_type      = "Standard"
    permitted_s3_buckets = [var.bucket_name]
    task_definition_name = "mammogram-conversion"
    use_fargate          = false
}

# ECS Task
module "ecs-task-preprocessing"{
    source = "./modules/ecs-task"

    name_prefix   = "mammogram"
    environment   = {
        vpc_id          = module.vpc.vpc_id
        aws_region      = var.region
        public_subnets  = module.vpc.public_subnets
        private_subnets = module.vpc.private_subnets

    }
    resource_tags = {}

    container_image      = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/mammogram-preprocessing:latest"
    container_name       = "mammogram-preprocessing"
    container_num_cores  = 4
    container_ram_gb     = 8
    ecs_cluster_name     = "mammogram-cluster"
    ecs_launch_type      = "Standard"
    permitted_s3_buckets = [var.bucket_name]
    task_definition_name = "mammogram-preprocessing"
    use_fargate          = false
}

# Lambda function
resource "aws_lambda_function" "unique_job_name" {
  filename      = "scripts/unique_job_name.zip"
  function_name = "unique_job_name"
  role          = aws_iam_role.lambda_role.arn
  handler       = "unique_job_name.lambda_handler"

  runtime = "python3.7"
}

# Step Functions
resource "aws_sfn_state_machine" "state_machine" {
  name       = "mammogram-state-machine"
  role_arn   = aws_iam_role.step_functions_role.arn
  depends_on = [null_resource.delay]

  definition = <<EOF
{
  "StartAt": "Conversion",
  "States": {
    "Generate Unique Job Name": {
      "Resource": "arn:aws:lambda:${var.region}:068255676137:function:unique_job_name",
      "Type": "Task",
      "Next": "Train Model"
    },
    "Conversion": {
      "Type": "Task",
      "Resource": "arn:aws:states:::ecs:runTask.sync",
      "Parameters": {
        "LaunchType": "EC2",
        "Overrides": {
          "ContainerOverrides": [
            {  
              "Name": "mammogram-conversion",
              "Command": ["${var.bucket_name}", "CBIS-DDSM"]
            }
          ]
        },
        "Cluster": "arn:aws:ecs:${var.region}:068255676137:cluster/mammogram-cluster",
        "TaskDefinition": "arn:aws:ecs:${var.region}:068255676137:task-definition/mammogram-conversion"
      },
      "Next": "Preprocess"
    },
    "Preprocess": {
      "Type": "Task",
      "Resource": "arn:aws:states:::ecs:runTask.sync",
      "Parameters": {
        "LaunchType": "EC2",
        "Overrides": {
          "ContainerOverrides": [
            {
              "Name": "mammogram-preprocessing",
              "Command": ["${var.bucket_name}"]
            }
          ]
        },
        "Cluster": "arn:aws:ecs:${var.region}:068255676137:cluster/mammogram-cluster",
        "TaskDefinition": "arn:aws:ecs:${var.region}:068255676137:task-definition/mammogram-preprocessing"
      },
      "Next": "Generate Unique Job Name"
    },
    "Train Model": {
      "Resource": "arn:aws:states:::sagemaker:createTrainingJob.sync",
      "Parameters": {
        "AlgorithmSpecification": {
          "TrainingImage": "763104351884.dkr.ecr.${var.region}.amazonaws.com/pytorch-training:1.3.1-gpu-py3",
          "TrainingInputMode": "File",
          "MetricDefinitions": [
            {
              "Name": "test:accuracy",
              "Regex": "Accuracy: ([0-9\\.]+)"
            }
          ]
        },
        "OutputDataConfig": {
          "S3OutputPath": "s3://${var.bucket_name}/output"
        },
        "StoppingCondition": {
          "MaxRuntimeInSeconds": 86400
        },
        "ResourceConfig": {
          "InstanceCount": 2,
          "InstanceType": "ml.p2.xlarge",
          "VolumeSizeInGB": 30
        },
        "RoleArn": "${aws_iam_role.sagemaker_role.arn}",
        "InputDataConfig": [
          {
            "DataSource": {
              "S3DataSource": {
                "S3DataType": "S3Prefix",
                "S3Uri": "s3://${var.bucket_name}/PNG-Images-Processed/Train",
                "S3DataDistributionType": "FullyReplicated"
              }
            },
            "ChannelName": "training"
          },
          {
            "DataSource": {
              "S3DataSource": {
                "S3DataType": "S3Prefix",
                "S3Uri": "s3://${var.bucket_name}/PNG-Images-Processed/Test",
                "S3DataDistributionType": "FullyReplicated"
              }
            },
            "ChannelName": "testing"
          }
        ],
        "HyperParameters": {
          "epochs": "6",
          "batch-size": "32",
          "test-batch-size": "32",
          "lr": "0.01",
          "backend": "gloo",
          "sagemaker_program": "train.py",
          "sagemaker_submit_directory": "s3://${var.bucket_name}/scripts/train.tar.gz"
        },
        "TrainingJobName.$": "$.JobName"
      },
      "Type": "Task",
      "End": true
    }
  }
}
EOF
}