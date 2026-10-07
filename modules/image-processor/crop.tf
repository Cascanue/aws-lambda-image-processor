data "aws_iam_policy_document" "crop_lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crop_lambda" {
  name               = "${local.name_prefix}-crop-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.crop_lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "crop_lambda_basic" {
  role       = aws_iam_role.crop_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "crop_lambda_vpc" {
  role       = aws_iam_role.crop_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "crop_lambda" {
  statement {
    sid       = "ReadUploads"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.images.arn}/uploads/*"]
  }

  statement {
    sid       = "WriteProcessed"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.images.arn}/processed/*"]
  }

  # El Event Source Mapping usa estos permisos del rol para leer y borrar mensajes.
  statement {
    sid = "ConsumeMainQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.main.arn]
  }
}

resource "aws_iam_role_policy" "crop_lambda" {
  name   = "${local.name_prefix}-crop-lambda-policy"
  role   = aws_iam_role.crop_lambda.id
  policy = data.aws_iam_policy_document.crop_lambda.json
}

resource "aws_cloudwatch_log_group" "crop_lambda" {
  name              = "/aws/lambda/${local.name_prefix}-crop"
  retention_in_days = 14
}

# Requiere npm install en src/crop-lambda antes de empaquetar (node_modules no está en git).
data "archive_file" "crop_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/crop-lambda"
  output_path = "${path.module}/../../build/crop-lambda.zip"
}

resource "aws_lambda_function" "crop" {
  function_name = "${local.name_prefix}-crop"
  role          = aws_iam_role.crop_lambda.arn
  runtime       = "nodejs20.x"
  architectures = ["x86_64"]
  handler       = "index.handler"
  memory_size   = 512
  timeout       = 60 # menor que el visibility timeout de la cola (360 s)

  filename         = data.archive_file.crop_lambda.output_path
  source_code_hash = data.archive_file.crop_lambda.output_base64sha256

  environment {
    variables = {
      S3_BUCKET        = aws_s3_bucket.images.bucket
      PROCESSED_PREFIX = "processed/"
    }
  }

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.crop_lambda.id]
  }

  depends_on = [
    aws_cloudwatch_log_group.crop_lambda,
    aws_iam_role_policy_attachment.crop_lambda_basic,
    aws_iam_role_policy_attachment.crop_lambda_vpc,
  ]
}

resource "aws_lambda_event_source_mapping" "crop_sqs" {
  event_source_arn        = aws_sqs_queue.main.arn
  function_name           = aws_lambda_function.crop.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]

  depends_on = [aws_iam_role_policy.crop_lambda]
}

output "crop_lambda_name" {
  description = "Nombre de la función Lambda que recorta las imágenes"
  value       = aws_lambda_function.crop.function_name
}
