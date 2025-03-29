# Provider Configuration
provider "aws" {
  region = var.aws_region
}

# Reference all existing resources instead of creating them
data "aws_vpc" "existing" {
  id = "vpc-0f3668f84f0c7b8df"  # Your existing VPC
}

data "aws_ecs_cluster" "main" {
  cluster_name = "gemgem-cluster"  # Your existing cluster
}

data "aws_db_instance" "main" {
  db_instance_identifier = "gemgem-db"  # Your existing RDS instance
}

data "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"  # AWS-managed role
}

# Create a new task definition version - this is the main thing we want to update
resource "aws_ecs_task_definition" "app" {
  family                   = "gemgem-task"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn
  
  container_definitions = jsonencode([
    {
      name      = "gemgem-container"
      image     = var.container_image
      essential = true
      
      portMappings = [
        {
          containerPort = 80
          hostPort      = 0
          protocol      = "tcp"
        }
      ]
      
      environment = [
        { name = "DB_HOST", value = data.aws_db_instance.main.address },
        { name = "DB_NAME", value = "gemgemdb" },
        { name = "DB_USER", value = var.db_username },
        { name = "DB_PASSWORD", value = var.db_password }
      ]
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/gemgem"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# Update the main service with the new task definition
resource "aws_ecs_service" "main" {
  name            = "gemgem-service"  # Your existing service
  cluster         = data.aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2  # Match your current desired count
  
  # Force new deployment to use the new task definition
  force_new_deployment = true
  
  # Keep existing load balancer configuration
  load_balancer {
    target_group_arn = "arn:aws:elasticloadbalancing:us-east-1:851725283026:targetgroup/gemgem-tg/abcdef1234567"  # Replace with actual ARN
    container_name   = "gemgem-container"
    container_port   = 80
  }
  
  # Ignore changes to task_definition when updating
  lifecycle {
    ignore_changes = [task_definition]
  }
}

# Variables
variable "aws_region" {
  default = "us-east-1"
}

variable "db_username" {
  description = "Username for the RDS instance"
}

variable "db_password" {
  description = "Password for the RDS instance"
}

variable "container_image" {
  description = "Container image to deploy"
  default     = "851725283026.dkr.ecr.us-east-1.amazonaws.com/gemgem:latest"
}