resource "aws_cloudwatch_log_group" "build" {
  name              = "/${var.prefix}/build"
  retention_in_days = 7
}
resource "aws_iam_role" "build" {
  name               = "${var.prefix}-build"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "codebuild.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy" "build" {
  name = "${var.prefix}-build"
  role = aws_iam_role.build.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"], Resource = aws_ecr_repository.app.arn },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = "arn:aws:s3:::${var.prefix}-state-${data.aws_caller_identity.current.account_id}/build/*" },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.build.arn}:*" }
  ] })
}
resource "aws_codebuild_project" "main" {
  name           = "${var.prefix}-build"
  service_role   = aws_iam_role.build.arn
  build_timeout  = 20
  queued_timeout = 30
  artifacts { type = "NO_ARTIFACTS" }
  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
    environment_variable {
      name  = "ECR_REPO"
      value = aws_ecr_repository.app.repository_url
    }
    environment_variable {
      name  = "APP_TAG"
      value = var.image_tag
    }
  }
  source {
    type      = "S3"
    location  = "${var.prefix}-state-${data.aws_caller_identity.current.account_id}/build/source.zip"
    buildspec = file("${path.module}/../buildspec.yml")
  }
  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.build.name
      stream_name = "images"
    }
  }
  depends_on = [aws_iam_role_policy.build]
}
