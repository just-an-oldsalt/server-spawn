locals {
  hosted_zone_id = var.hosted_zone_id != "" ? var.hosted_zone_id : aws_route53_zone.minecraft[0].zone_id
}

# Only created if no existing zone is provided
resource "aws_route53_zone" "minecraft" {
  count = var.hosted_zone_id == "" ? 1 : 0
  name  = var.domain_name
}

# Placeholder A record — watchdog updates this to the real IP on boot
resource "aws_route53_record" "minecraft" {
  zone_id = local.hosted_zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 30

  records = ["1.2.3.4"]

  lifecycle {
    # Watchdog updates this record at runtime; ignore drift
    ignore_changes = [records]
  }
}

# Enable Route53 query logging so DNS lookups trigger Lambda
resource "aws_route53_query_log" "minecraft" {
  provider                         = aws.us_east_1
  depends_on                       = [aws_cloudwatch_log_resource_policy.route53]
  cloudwatch_log_group_arn         = aws_cloudwatch_log_group.route53_queries.arn
  zone_id                          = local.hosted_zone_id
}

resource "aws_cloudwatch_log_group" "route53_queries" {
  provider          = aws.us_east_1
  name              = "/aws/route53/${var.domain_name}"
  retention_in_days = 7
}

# Route53 needs permission to write to the log group
resource "aws_cloudwatch_log_resource_policy" "route53" {
  provider    = aws.us_east_1
  policy_name = "${var.project_name}-route53-query-logging"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "route53.amazonaws.com"
        }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.route53_queries.arn}:*"
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:route53:::hostedzone/${local.hosted_zone_id}"
          }
        }
      }
    ]
  })
}
