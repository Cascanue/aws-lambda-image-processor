resource "aws_s3_bucket" "images"{
  bucket =local.bucket_name
  force_destroy =true
}
resource "aws_s3_bucket_versioning" "images"{
  bucket = aws_s3_bucket.images.id
  versioning_configuration{
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "images"{
  bucket =aws_s3_bucket.images.id
  rule {
    apply_server_side_encryption_by_default{
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "images"{
  bucket = aws_s3_bucket.images.id

  block_public_acls = true
  block_public_policy =true
  ignore_public_acls = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "images"{
  bucket = aws_s3_bucket.images.id

  rule{
    id = "expire-uploads"
    status ="Enabled"
    filter{
      prefix = "uploads/"
    }
    expiration {
      days = 30
    }
  }

  rule{
    id = "expire-processed"
    status = "Enabled"
    filter {
      prefix ="processed/"
    }
    expiration {
      days = 90
    }
  }
}

resource "aws_sqs_queue" "dlq"{
  name = "${local.name_prefix}-image-dlq"
  message_retention_seconds =1209600
}

resource "aws_sqs_queue" "main"{
  name                       = "${local.name_prefix}-image-queue"
  visibility_timeout_seconds = 360   
  message_retention_seconds =86400 
  receive_wait_time_seconds =20    

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount =3
  })
}

resource "aws_sqs_queue_policy" "main"{
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action = "sqs:SendMessage"
      Resource = aws_sqs_queue.main.arn
      Condition ={
        ArnEquals ={
          "aws:SourceArn" =aws_s3_bucket.images.arn
        }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "images"{
  bucket =aws_s3_bucket.images.id

  queue {
    queue_arn =aws_sqs_queue.main.arn
    events = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
  }

  depends_on = [aws_sqs_queue_policy.main]
}
resource "aws_sns_topic" "alarms"{
  name = "${local.name_prefix}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email"{
  count = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol = "email"
  endpoint = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages"{
  alarm_name = "${local.name_prefix}-dlq-messages-alarm"
  namespace = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions ={
    QueueName = aws_sqs_queue.dlq.name
  }
  statistic = "Maximum"
  period = 60
  evaluation_periods = 1
  threshold = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data = "notBreaching"
  alarm_actions = [aws_sns_topic.alarms.arn]
}

output "bucket_name"{
  value = aws_s3_bucket.images.bucket
}
output "queue_url"{
  value = aws_sqs_queue.main.id
}
output "dlq_url"{
  value = aws_sqs_queue.dlq.id
}