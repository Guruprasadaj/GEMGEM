# Provider Configuration
provider "aws" {
  region = var.aws_region
}

# Data source for AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Use existing VPC
data "aws_vpc" "existing" {
  id = "vpc-0f3668f84f0c7b8df"
}

# Get existing subnets with MORE SPECIFIC filters
data "aws_subnet" "public" {
  count = 2
  vpc_id = data.aws_vpc.existing.id
  
  # Add specific filter by AZ to get exactly one subnet per AZ
  availability_zone = count.index == 0 ? "us-east-1a" : "us-east-1b"
  
  # Add filter for public subnets
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
  
  # Add a filter for the subnet's position to make it more specific
  # This assumes your subnets follow a typical naming convention
  filter {
    name   = "tag:Name"
    values = ["*public*${count.index + 1}*"]
  }
}

# Security Groups
resource "aws_security_group" "ecs" {
  name        = "gemgem-ecs"
  description = "ECS security group"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS Security Group
resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS"
  vpc_id      = data.aws_vpc.existing.id # FIX: Use existing VPC

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EFS Security Group
resource "aws_security_group" "efs_sg" {
  name        = "${var.project_name}-efs-sg"
  description = "Security group for EFS"
  vpc_id      = data.aws_vpc.existing.id # FIX: Use existing VPC

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "gemgem-cluster"
}

# IAM Roles and Policies
resource "aws_iam_role" "ecs_role" {
  name = "ecs-instance-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_policy" {
  role       = aws_iam_role.ecs_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_profile" {
  name = "ecs-instance-profile-${random_string.suffix.result}"
  role = aws_iam_role.ecs_role.name
}

# ECS Launch Template
resource "aws_launch_template" "ecs" {
  name_prefix   = "ecs-template"
  image_id      = var.ecs_ami_id
  instance_type = var.instance_type

  user_data = base64encode(<<-EOF
              #!/bin/bash
              echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
              EOF
  )

  vpc_security_group_ids = [aws_security_group.ecs.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_profile.name
  }
}

# Get subnet IDs from data source
locals {
  subnet_ids = [for s in data.aws_subnet.public : s.id]
}

# Auto Scaling Group
resource "aws_autoscaling_group" "ecs" {
  name                = "gemgem-asg-${random_string.suffix.result}"
  vpc_zone_identifier = local.subnet_ids
  target_group_arns   = [aws_lb_target_group.ecs.arn]
  health_check_type   = "EC2"
  min_size            = 1
  max_size            = 4
  desired_capacity    = 2

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "gemgem-ecs-instance"
    propagate_at_launch = true
  }
}

# ALB Security Group
resource "aws_security_group" "alb" {
  name        = "gemgem-alb-sg-${random_string.suffix.result}"
  description = "ALB Security Group"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Application Load Balancer
resource "aws_lb" "ecs" {
  name               = "gemgem-alb-${random_string.suffix.result}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids
}

# ALB Target Group
resource "aws_lb_target_group" "ecs" {
  name        = "gemgem-tg-${random_string.suffix.result}"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.existing.id
  target_type = "instance"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }
}

# ALB Listener
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.ecs.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs.arn
  }
}

# S3 Bucket for static files
resource "aws_s3_bucket" "app_bucket" {
  bucket        = "gemgem-app-bucket-${random_string.suffix.result}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# RDS Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "gemgem-db-subnet-group-${random_string.suffix.result}"
  subnet_ids = local.subnet_ids
}

# RDS Instance - MariaDB
resource "aws_db_instance" "main" {
  identifier        = "gemgem-db-${random_string.suffix.result}"
  engine            = "mariadb"
  engine_version    = "10.5"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  username = var.db_username
  password = var.db_password

  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name

  skip_final_snapshot = true
  deletion_protection = false
}

# EFS File System
resource "aws_efs_file_system" "main" {
  creation_token = "gemgem-efs-${random_string.suffix.result}"
  encrypted      = true

  tags = {
    Name = "${var.project_name}-efs"
  }
}

# EFS Mount Targets
resource "aws_efs_mount_target" "main" {
  count           = length(local.subnet_ids)
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = local.subnet_ids[count.index]
  security_groups = [aws_security_group.efs_sg.id]
}

# CloudFront Origin Access Identity
resource "aws_cloudfront_origin_access_identity" "main" {
  comment = "OAI for ${var.project_name}"
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name = aws_s3_bucket.app_bucket.bucket_regional_domain_name
    origin_id   = "S3Origin"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.main.cloudfront_access_identity_path
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# S3 bucket policy for CloudFront
resource "aws_s3_bucket_policy" "app_bucket_policy" {
  bucket = aws_s3_bucket.app_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "s3:GetObject"
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.app_bucket.arn}/*"
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.main.iam_arn
        }
      }
    ]
  })
}

# ECS Task Definition - EC2 launch type
resource "aws_ecs_task_definition" "app" {
  family                   = "gemgem-app"
  requires_compatibilities = ["EC2"] # FIX: Use EC2 launch type, not FARGATE
  network_mode             = "bridge" # FIX: EC2 instances use bridge networking

  # Add volume for EFS
  volume {
    name = "efs-storage"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.main.id
      root_directory = "/"
    }
  }

  container_definitions = jsonencode([
    {
      name      = "gemgem-container"
      image     = "${data.aws_ecr_repository.app.repository_url}:latest"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
      environment = [
        {
          name  = "DB_HOST", 
          value = aws_db_instance.main.address
        },
        {
          name  = "DB_USER",
          value = var.db_username
        },
        {
          name  = "DB_PASSWORD",
          value = var.db_password
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "efs-storage",
          containerPath = "/mnt/efs"
        }
      ]
    }
  ])
}

# ECS Service with EC2 launch type
resource "aws_ecs_service" "main" {
  name            = "gemgem-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "EC2" # FIX: Use EC2 launch type
  
  # Use load balancer
  load_balancer {
    target_group_arn = aws_lb_target_group.ecs.arn
    container_name   = "gemgem-container"
    container_port   = 80
  }
}

# Use existing ECR repository
data "aws_ecr_repository" "app" {
  name = "gemgem"
}

# Random string for uniqueness
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}