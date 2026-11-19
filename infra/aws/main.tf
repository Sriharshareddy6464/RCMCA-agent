locals {
  name          = var.project_name
  azs           = slice(data.aws_availability_zones.available.names, 0, 2)
  public_cidrs  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = aws_vpc.main.id
  dynamic "ingress" {
    for_each = toset(var.allowed_ingress_cidrs)
    content {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "api" {
  name   = "${local.name}-api"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "db" {
  name   = "${local.name}-db"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "cache" {
  name   = "${local.name}-cache"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "osrm" {
  name   = "${local.name}-osrm"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_db_instance" "main" {
  identifier                      = "${local.name}-postgres"
  engine                          = "postgres"
  engine_version                  = var.db_engine_version
  instance_class                  = var.db_instance_class
  allocated_storage               = 50
  max_allocated_storage           = 200
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = var.db_name
  username                        = var.db_username
  manage_master_user_password     = true
  port                            = 5432
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  backup_retention_period         = 7
  multi_az                        = true
  publicly_accessible             = false
  deletion_protection             = true
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${local.name}-postgres-final"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
}
resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name}-cache"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${local.name}-redis"
  description                = "RCMCA live hazard cache"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.t4g.small"
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.cache.id]
}

resource "aws_s3_bucket" "evidence" {
  bucket_prefix = "${local.name}-evidence-"
  force_destroy = false
}
resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"

    }

  }
}
resource "aws_s3_bucket_cors_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  cors_rule {
    allowed_headers = ["Content-Type"]
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = var.upload_allowed_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 3000

  }
}
resource "aws_cloudfront_origin_access_control" "evidence" {
  name                              = "${local.name}-evidence-oac"
  description                       = "Private S3 origin for road evidence"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
resource "aws_cloudfront_distribution" "evidence" {
  enabled     = true
  comment     = "RCMCA road evidence"
  price_class = "PriceClass_100"
  origin {
    domain_name              = aws_s3_bucket.evidence.bucket_regional_domain_name
    origin_id                = "private-evidence-bucket"
    origin_access_control_id = aws_cloudfront_origin_access_control.evidence.id

  }
  default_cache_behavior {
    target_origin_id       = "private-evidence-bucket"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
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
resource "aws_s3_bucket_policy" "evidence_cloudfront" {
  bucket = aws_s3_bucket.evidence.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontReadOnly"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.evidence.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.evidence.arn
        }
      }

    }]

  })
}

resource "aws_ecr_repository" "app" {
  for_each             = toset(["api", "osrm"])
  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
}
resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = toset(["api", "municipal-sync", "vision-worker", "osrm"])
  name              = "/ecs/${local.name}/${each.key}"
  retention_in_days = 30
}
resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role_policy" "task_s3" {
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [
      {
        Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.evidence.arn}/evidence/*"
      },
      {
        Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.evidence.arn}/models/*"
      },
      {
        Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [aws_db_instance.main.master_user_secret[0].secret_arn]
      },
      {
        Effect = "Allow", Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"], Resource = "*"
      }
    ]
  })
}

resource "aws_lb" "api" {
  name               = "${local.name}-api"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}
resource "aws_lb_target_group" "api" {
  name        = "${local.name}-api"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}
resource "aws_lb_listener" "https" {
  count             = var.acm_certificate_arn == "" ? 0 : 1
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name = "api", image = var.container_image, essential = true
    portMappings = [{
      containerPort = 8000, protocol = "tcp"
    }]
    environment = [
      {
        name = "DATABASE_SECRET_ARN", value = aws_db_instance.main.master_user_secret[0].secret_arn
      },
      {
        name = "REDIS_URL", value = "rediss://${aws_elasticache_replication_group.main.primary_endpoint_address}:6379/0?ssl_cert_reqs=required"
      },
      {
        name = "OSRM_URL", value = "http://${aws_service_discovery_service.osrm.name}.${aws_service_discovery_private_dns_namespace.main.name}:5000"
      },
      {
        name = "LLM_PROVIDER", value = "bedrock"
      },
      {
        name = "LLM_MODEL", value = var.bedrock_model_id
      },
      {
        name = "AWS_REGION", value = var.aws_region
      },
      {
        name = "DATABASE_NAME", value = var.db_name
      },
      {
        name = "S3_BUCKET", value = aws_s3_bucket.evidence.bucket
      },
      {
        name = "S3_PUBLIC_BASE_URL", value = "https://${aws_cloudfront_distribution.evidence.domain_name}"
      }
    ]
    logConfiguration = {
      logDriver = "awslogs", options = {
        awslogs-group = aws_cloudwatch_log_group.ecs["api"].name, awslogs-region = var.aws_region, awslogs-stream-prefix = "app"
      }
    }

  }])
}
resource "aws_ecs_service" "api" {
  name                               = "api"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.deploy_services ? 2 : 0
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8000
  }
  depends_on = [aws_lb_listener.https]
  lifecycle {
    precondition {
      condition     = !var.deploy_services || var.acm_certificate_arn != ""
      error_message = "Set an issued ACM certificate ARN before deploying API tasks."
    }
    precondition {
      condition     = !var.deploy_services || length(var.allowed_ingress_cidrs) > 0
      error_message = "Set explicit allowed_ingress_cidrs before deploying the unauthenticated API."
    }
    precondition {
      condition     = alltrue([for cidr in var.allowed_ingress_cidrs : !contains(["0.0.0.0/0", "::/0"], cidr)])
      error_message = "Do not expose the unauthenticated API ALB to all IPv4 or IPv6 addresses."
    }
    precondition {
      condition     = !var.deploy_services || var.container_image != "public.ecr.aws/docker/library/python:3.11-slim"
      error_message = "Set container_image to the built immutable RCMCA API image before deploying tasks."
    }
    precondition {
      condition     = !var.deploy_services || var.osrm_image != "ghcr.io/project-osrm/osrm-backend:v5.27.1"
      error_message = "Set osrm_image to the built Hyderabad OSRM image before deploying tasks."
    }
  }
}

resource "aws_ecs_task_definition" "municipal_sync" {
  family                   = "${local.name}-municipal-sync"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name    = "municipal-sync", image = var.container_image, essential = true
    command = ["python", "-m", "backend.app.worker"]
    environment = [
      { name = "DATABASE_SECRET_ARN", value = aws_db_instance.main.master_user_secret[0].secret_arn },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "DATABASE_NAME", value = var.db_name },
      { name = "GHMC_FEED_URL", value = var.ghmc_feed_url },
      { name = "PRAJAVANI_FEED_URL", value = var.prajavani_feed_url },
      { name = "GEOCODER_USER_AGENT", value = "RCMCA-road-condition-monitor/1.0" }
    ]
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.ecs["municipal-sync"].name, awslogs-region = var.aws_region, awslogs-stream-prefix = "worker" } }
  }])
}
resource "aws_ecs_service" "municipal_sync" {
  name            = "municipal-sync"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.municipal_sync.arn
  desired_count   = var.deploy_services ? 1 : 0
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "vision_worker" {
  family                   = "${local.name}-vision-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name    = "vision-worker", image = var.container_image, essential = true
    command = ["python", "-m", "scripts.start_vision_worker"]
    environment = [
      { name = "DATABASE_SECRET_ARN", value = aws_db_instance.main.master_user_secret[0].secret_arn },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "DATABASE_NAME", value = var.db_name },
      { name = "VISION_MODEL_BUCKET", value = aws_s3_bucket.evidence.bucket },
      { name = "VISION_MODEL_KEY", value = var.vision_model_key },
      { name = "VISION_MODEL_PATH", value = "/tmp/road_damage.onnx" },
      { name = "VISION_CLASS_NAMES", value = "[\"pothole\"]" }
    ]
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.ecs["vision-worker"].name, awslogs-region = var.aws_region, awslogs-stream-prefix = "worker" } }
  }])
}
resource "aws_ecs_service" "vision_worker" {
  name            = "vision-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.vision_worker.arn
  desired_count   = var.deploy_services ? 1 : 0
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${local.name}.internal"
  vpc  = aws_vpc.main.id
}
resource "aws_service_discovery_service" "osrm" {
  name = "osrm"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}
resource "aws_ecs_task_definition" "osrm" {
  family                   = "${local.name}-osrm"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "2048"
  memory                   = "4096"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name = "osrm", image = var.osrm_image, essential = true
    portMappings = [{
      containerPort = 5000, protocol = "tcp"
    }]
    command = ["osrm-routed", "--algorithm", "mld", "/data/hyderabad.osrm"]
    logConfiguration = {
      logDriver = "awslogs", options = {
        awslogs-group = aws_cloudwatch_log_group.ecs["osrm"].name, awslogs-region = var.aws_region, awslogs-stream-prefix = "app"
      }
    }

  }])
}
resource "aws_ecs_service" "osrm" {
  name            = "osrm"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.osrm.arn
  desired_count   = var.deploy_services ? 2 : 0
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.osrm.id]
    assign_public_ip = true
  }
  service_registries {
    registry_arn = aws_service_discovery_service.osrm.arn
  }
}

