# Provider Configuration
provider "aws" {
  region = var.aws_region
}

# Reference existing VPC
data "aws_vpc" "existing" {
  id = "vpc-0f3668f84f0c7b8df"
}

# Find existing public subnet for Fargate
data "aws_subnet_ids" "public" {
  vpc_id = data.aws_vpc.existing.id
  
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Use existing ECR repository
data "aws_ecr_repository" "app" {
  name = var.project_name
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-task-execution-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project_name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  
  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-container",
      image     = "${data.aws_ecr_repository.app.repository_url}:latest",
      cpu       = 256,
      memory    = 512,
      essential = true,
      portMappings = [
        {
          containerPort = 80,
          hostPort      = 80
        }
      ]
    }
  ])
}

# Random string for uniqueness
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}