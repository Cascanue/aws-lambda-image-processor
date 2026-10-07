# =============================================================================
# crop.tf - Integrante 5
# Diagrama: cola SQS -> crop-lambda (Event Source Mapping, lotes de 5)
#           -> PNG circular 40x40 -> s3://<bucket>/processed/<nombre>_circular.png
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Rol IAM de la crop-lambda
# -----------------------------------------------------------------------------

# Permite que el servicio Lambda "asuma" este rol al ejecutar la función.
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

# Escribir logs en CloudWatch.
resource "aws_iam_role_policy_attachment" "crop_lambda_basic" {
  role       = aws_iam_role.crop_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Crear las interfaces de red (ENI) en las subredes privadas de la VPC.
resource "aws_iam_role_policy_attachment" "crop_lambda_vpc" {
  role       = aws_iam_role.crop_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Mínimo privilegio: solo lo que la Lambda necesita según el diagrama.
data "aws_iam_policy_document" "crop_lambda" {
  # Leer las imágenes originales (flecha S3 uploads/ -> crop-lambda).
  statement {
    sid       = "ReadUploads"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.images.arn}/uploads/*"]
  }

  # Escribir los PNG circulares (flecha crop-lambda -> S3 processed/).
  statement {
    sid       = "WriteProcessed"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.images.arn}/processed/*"]
  }

  # Consumir la cola principal (flecha SQS -> crop-lambda). El Event Source
  # Mapping usa estos permisos del rol para leer y borrar mensajes.
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

# -----------------------------------------------------------------------------
# 2. Log group (se crea antes que la Lambda para controlar la retención)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "crop_lambda" {
  name              = "/aws/lambda/${local.name_prefix}-crop"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# 3. Empaquetado del código (src/crop-lambda, incluye node_modules con sharp)
#    Antes de desplegar hay que ejecutar npm install en src/crop-lambda.
# -----------------------------------------------------------------------------
data "archive_file" "crop_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/crop-lambda"
  output_path = "${path.module}/../../build/crop-lambda.zip"
}

# -----------------------------------------------------------------------------
# 4. Función Lambda "crop" (dentro de la VPC, subredes privadas)
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 5. Event Source Mapping: conecta la cola SQS con la Lambda
#    Lambda hace polling de la cola y la invoca con lotes de hasta 5 mensajes.
# -----------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "crop_sqs" {
  event_source_arn        = aws_sqs_queue.main.arn
  function_name           = aws_lambda_function.crop.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]

  # Sin los permisos SQS del rol, la creación del mapping falla.
  depends_on = [aws_iam_role_policy.crop_lambda]
}

# -----------------------------------------------------------------------------
# 6. Outputs
# -----------------------------------------------------------------------------
output "crop_lambda_name" {
  description = "Nombre de la función Lambda que recorta las imágenes"
  value       = aws_lambda_function.crop.function_name
}
