data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda/start_server.py"
  output_path = "${path.module}/../lambda/start_server.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  provider          = aws.us_east_1
  name              = "/aws/lambda/${var.project_name}"
  retention_in_days = 7
}

resource "aws_lambda_function" "start_server" {
  provider         = aws.us_east_1
  function_name    = var.project_name
  role             = aws_iam_role.lambda.arn
  handler          = "start_server.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      INSTANCE_ID = aws_instance.minecraft.id
      AWS_REGION_TARGET = var.aws_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# CloudWatch subscription filter: fire Lambda when our domain is queried
resource "aws_cloudwatch_log_subscription_filter" "route53_to_lambda" {
  provider        = aws.us_east_1
  name            = "${var.project_name}-dns-trigger"
  log_group_name  = aws_cloudwatch_log_group.route53_queries.name
  filter_pattern  = var.domain_name
  destination_arn = aws_lambda_function.start_server.arn
  depends_on      = [aws_lambda_permission.cloudwatch]
}

resource "aws_lambda_permission" "cloudwatch" {
  provider      = aws.us_east_1
  statement_id  = "AllowCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_server.function_name
  principal     = "logs.us-east-1.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.route53_queries.arn}:*"
}
