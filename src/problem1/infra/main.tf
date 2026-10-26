data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
locals {
  azs       = ["${var.region}a", "${var.region}b"]
  image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
  db_secret = aws_db_instance.main.master_user_secret[0].secret_arn
}

resource "aws_vpc" "main" {
  cidr_block           = "10.84.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-vpc" }
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.84.${count.index + 10}.0/24"
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.prefix}-private-${count.index + 1}" }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.prefix}-private" }
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
# This outbound-only subnet is used solely by temporary public-endpoint load tasks.
resource "aws_internet_gateway" "test" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.prefix}-test-egress" }
}
resource "aws_subnet" "test" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.84.30.0/24"
  availability_zone = local.azs[0]
  tags              = { Name = "${var.prefix}-test" }
}
resource "aws_route_table" "test" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.test.id
  }
  tags = { Name = "${var.prefix}-test" }
}
resource "aws_route_table_association" "test" {
  subnet_id      = aws_subnet.test.id
  route_table_id = aws_route_table.test.id
}

resource "aws_security_group" "link" {
  name   = "${var.prefix}-link"
  vpc_id = aws_vpc.main.id
}
resource "aws_security_group" "alb" {
  name   = "${var.prefix}-alb"
  vpc_id = aws_vpc.main.id
}
resource "aws_security_group" "app" {
  name   = "${var.prefix}-app"
  vpc_id = aws_vpc.main.id
}
resource "aws_security_group" "db" {
  name   = "${var.prefix}-db"
  vpc_id = aws_vpc.main.id
}
resource "aws_security_group" "endpoints" {
  name   = "${var.prefix}-endpoints"
  vpc_id = aws_vpc.main.id
}
resource "aws_security_group" "test" {
  name   = "${var.prefix}-load"
  vpc_id = aws_vpc.main.id
}
resource "aws_vpc_security_group_ingress_rule" "alb" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.link.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}
resource "aws_vpc_security_group_egress_rule" "link" {
  security_group_id            = aws_security_group.link.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}
resource "aws_vpc_security_group_ingress_rule" "app" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}
resource "aws_vpc_security_group_egress_rule" "alb" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}
resource "aws_vpc_security_group_ingress_rule" "db" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_vpc_security_group_egress_rule" "db" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_vpc_security_group_ingress_rule" "endpoints" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
resource "aws_vpc_security_group_ingress_rule" "endpoints_test" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.test.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
resource "aws_vpc_security_group_egress_rule" "test" {
  security_group_id = aws_security_group.test.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
resource "aws_vpc_endpoint" "services" {
  for_each            = toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager"])
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  tags                = { Name = "${var.prefix}-${each.key}" }
}
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.prefix}-s3" }
}

resource "aws_ecr_repository" "app" {
  name                 = "${var.prefix}-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy     = jsonencode({ rules = [{ rulePriority = 1, description = "Keep last ten images", selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }, action = { type = "expire" } }] })
}
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.prefix}/app"
  retention_in_days = 7
}
resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/${var.prefix}/gateway"
  retention_in_days = 7
}
resource "aws_db_subnet_group" "main" {
  name       = "${var.prefix}-db"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_db_instance" "main" {
  identifier                      = "${var.prefix}-postgres"
  engine                          = "postgres"
  engine_version                  = "18.3"
  instance_class                  = "db.t4g.medium"
  allocated_storage               = 20
  max_allocated_storage           = 50
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = "trading"
  username                        = "postgres"
  manage_master_user_password     = true
  multi_az                        = true
  publicly_accessible             = false
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  backup_retention_period         = 7
  auto_minor_version_upgrade      = true
  deletion_protection             = false
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${var.prefix}-final"
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  apply_immediately               = true
}

resource "aws_iam_role" "execution" {
  name               = "${var.prefix}-execution"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy" "secret" {
  name   = "${var.prefix}-database-secret"
  role   = aws_iam_role.execution.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [local.db_secret, aws_secretsmanager_secret.load_tokens.arn] }] })
}
resource "aws_secretsmanager_secret" "demo" {
  name                    = "${var.prefix}-demo-accounts"
  recovery_window_in_days = 7
}
resource "aws_secretsmanager_secret" "load_tokens" {
  name                    = "${var.prefix}-load-tokens"
  recovery_window_in_days = 7
}
resource "aws_iam_role" "task" {
  name               = "${var.prefix}-task"
  assume_role_policy = aws_iam_role.execution.assume_role_policy
}
resource "aws_ecs_cluster" "main" {
  name = "${var.prefix}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_lb" "main" {
  name                       = "${var.prefix}-alb"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = aws_subnet.private[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}
resource "aws_lb_target_group" "api" {
  name                 = "${var.prefix}-api"
  port                 = 3000
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "ip"
  deregistration_delay = 10
  health_check {
    path                = "/health/live"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
resource "aws_ecs_task_definition" "app" {
  for_each                 = { api = { cpu = 512, memory = 1024 }, worker = { cpu = 256, memory = 512 } }
  family                   = "${var.prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name         = each.key, image = local.image, essential = true,
    command      = ["node", "src/${each.key == "api" ? "server" : "worker"}.js"],
    portMappings = each.key == "api" ? [{ containerPort = 3000, protocol = "tcp" }] : [],
    environment = [
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_NAME", value = "trading" },
      { name = "DB_USER", value = "postgres" },
      { name = "DB_SSL", value = "true" },
      { name = "DB_POOL_MAX", value = each.key == "api" ? "12" : "4" },
      { name = "WORKER_BATCH_SIZE", value = "1" },
      { name = "NODE_ENV", value = "production" }
    ],
    secrets          = [{ name = "DB_PASSWORD", valueFrom = "${local.db_secret}:password::" }],
    linuxParameters  = { initProcessEnabled = true },
    stopTimeout      = 30,
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.app.name, awslogs-region = var.region, awslogs-stream-prefix = each.key } },
    healthCheck = each.key == "api" ? {
      command = ["CMD-SHELL", "node -e \"require('http').get('http://127.0.0.1:3000/health/live',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))\""], interval = 15, timeout = 5, retries = 3, startPeriod = 20
      } : {
      command = ["CMD-SHELL", "node -e \"const fs=require('fs');process.exit(Date.now()-fs.statSync('/tmp/worker-heartbeat').mtimeMs<30000?0:1)\""], interval = 15, timeout = 5, retries = 3, startPeriod = 30
    }
  }])
}
resource "aws_ecs_service" "api" {
  name                               = "${var.prefix}-api"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app["api"].arn
  desired_count                      = var.running ? 2 : 0
  launch_type                        = "FARGATE"
  availability_zone_rebalancing      = "ENABLED"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3000
  }
  depends_on = [aws_lb_listener.api, aws_iam_role_policy.secret, aws_vpc_endpoint.services]
}
resource "aws_ecs_service" "worker" {
  name                          = "${var.prefix}-worker"
  cluster                       = aws_ecs_cluster.main.id
  task_definition               = aws_ecs_task_definition.app["worker"].arn
  desired_count                 = var.running ? 2 : 0
  launch_type                   = "FARGATE"
  availability_zone_rebalancing = "ENABLED"
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
  depends_on = [aws_iam_role_policy.secret, aws_vpc_endpoint.services]
}
resource "aws_appautoscaling_target" "api" {
  max_capacity       = 4
  min_capacity       = var.running ? 2 : 0
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.prefix}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = "ecs"
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 30
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}

resource "aws_cognito_user_pool" "main" {
  name = "${var.prefix}-users"
  admin_create_user_config { allow_admin_create_user_only = true }
  password_policy {
    minimum_length    = 16
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }
}
resource "aws_cognito_user_pool_client" "main" {
  name                          = "${var.prefix}-client"
  user_pool_id                  = aws_cognito_user_pool.main.id
  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  access_token_validity         = 1
  id_token_validity             = 1
  refresh_token_validity        = 1
}
resource "aws_apigatewayv2_api" "main" {
  name          = "${var.prefix}-api"
  protocol_type = "HTTP"
}
resource "aws_apigatewayv2_vpc_link" "main" {
  name               = "${var.prefix}-link"
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.link.id]
}
resource "aws_apigatewayv2_integration" "api" {
  for_each               = toset(["public", "private"])
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_lb_listener.api.arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.main.id
  payload_format_version = "1.0"
  timeout_milliseconds   = 5000
  request_parameters = {
    "overwrite:path"              = "$request.path"
    "overwrite:header.x-user-sub" = each.key == "private" ? "$context.authorizer.claims.sub" : "'anonymous'"
  }
}
resource "aws_apigatewayv2_authorizer" "main" {
  api_id           = aws_apigatewayv2_api.main.id
  name             = "${var.prefix}-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}
locals {
  public_routes  = toset(["GET /health/live", "GET /health/ready", "GET /v1/markets", "GET /v1/markets/{symbol}/orderbook", "GET /v1/markets/{symbol}/trades"])
  private_routes = toset(["GET /v1/balances", "POST /v1/orders", "GET /v1/orders", "GET /v1/orders/{id}", "DELETE /v1/orders/{id}"])
}
resource "aws_apigatewayv2_route" "public" {
  for_each  = local.public_routes
  api_id    = aws_apigatewayv2_api.main.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.api["public"].id}"
}
resource "aws_apigatewayv2_route" "private" {
  for_each             = local.private_routes
  api_id               = aws_apigatewayv2_api.main.id
  route_key            = each.key
  target               = "integrations/${aws_apigatewayv2_integration.api["private"].id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.main.id
  authorization_scopes = ["aws.cognito.signin.user.admin"]
}
resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit   = 1500
    throttling_rate_limit    = 1000
    detailed_metrics_enabled = true
  }
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.gateway.arn
    format          = jsonencode({ requestId = "$context.requestId", route = "$context.routeKey", status = "$context.status", latency = "$context.responseLatency", integrationError = "$context.integrationErrorMessage" })
  }
}
resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  alarm_name          = "${var.prefix}-db-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.id }
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 3
  period              = 60
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
}
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.prefix}-target-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix }
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 1
  period              = 60
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"
}
