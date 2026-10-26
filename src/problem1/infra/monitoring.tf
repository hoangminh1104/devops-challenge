resource "aws_cloudwatch_log_metric_filter" "command_age" {
  name           = "${var.prefix}-command-age"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.event = \"worker_progress\" }"
  metric_transformation {
    name          = "OldestCommandSeconds"
    namespace     = var.prefix
    value         = "$.oldest_command_seconds"
    default_value = 0
    unit          = "Seconds"
  }
}
resource "aws_cloudwatch_metric_alarm" "command_age" {
  alarm_name          = "${var.prefix}-command-age"
  namespace           = var.prefix
  metric_name         = "OldestCommandSeconds"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 2
  period              = 60
  statistic           = "Maximum"
  treat_missing_data  = "breaching"
}
resource "aws_cloudwatch_metric_alarm" "api_p99" {
  alarm_name          = "${var.prefix}-api-p99"
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiId = aws_apigatewayv2_api.main.id }
  comparison_operator = "GreaterThanThreshold"
  threshold           = 100
  evaluation_periods  = 3
  period              = 60
  extended_statistic  = "p99"
  treat_missing_data  = "notBreaching"
}
