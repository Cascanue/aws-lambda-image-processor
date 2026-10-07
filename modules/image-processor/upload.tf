# -----------------------------------------------------------------------------
# upload.tf (Integrante 4)
# Tramo del diagrama: cliente -> API Gateway HTTP API (POST /upload)
#                     -> upload-lambda (subredes privadas) -> S3 uploads/
# -----------------------------------------------------------------------------

# --- IAM: identidad con la que corre la upload-lambda --------------------------

# Rol que asume el servicio Lambda al ejecutar la función.
resource "aws_iam_role" "upload_lambda" {
  name = "${local.name_prefix}-upload-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Permite escribir logs en CloudWatch.
resource "aws_iam_role_policy_attachment" "upload_lambda_basic" {
  role       = aws_iam_role.upload_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permite crear las interfaces de red (ENI) para vivir en las subredes privadas.
resource "aws_iam_role_policy_attachment" "upload_lambda_vpc" {
  role       = aws_iam_role.upload_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Mínimo privilegio: solo puede subir objetos bajo uploads/ (flecha upload-lambda -> S3).
resource "aws_iam_role_policy" "upload_lambda_s3" {
  name = "${local.name_prefix}-upload-lambda-s3"
  role = aws_iam_role.upload_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.images.arn}/uploads/*"
    }]
  })
}

# --- Lambda: upload-lambda ------------------------------------------------------

# Log group creado por Terraform para controlar la retención (si no, Lambda lo crea sin expiración).
resource "aws_cloudwatch_log_group" "upload_lambda" {
  name              = "/aws/lambda/${local.name_prefix}-upload"
  retention_in_days = 14
}

# Empaqueta el código (index.js + node_modules) en un zip.
# Requiere haber ejecutado `npm install` en src/upload-lambda antes del plan.
data "archive_file" "upload_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/upload-lambda"
  output_path = "${path.module}/../../build/upload-lambda.zip"
}

resource "aws_lambda_function" "upload" {
  function_name = "${local.name_prefix}-upload"
  role          = aws_iam_role.upload_lambda.arn
  runtime       = "nodejs20.x"
  handler       = "index.handler"
  memory_size   = 256
  timeout       = 30

  filename = data.archive_file.upload_lambda.output_path
  # Si cambia el código, cambia el hash y Terraform vuelve a desplegar la función.
  source_code_hash = data.archive_file.upload_lambda.output_base64sha256

  environment {
    variables = {
      S3_BUCKET     = aws_s3_bucket.images.bucket
      UPLOAD_PREFIX = "uploads/"
    }
  }

  # La Lambda corre en las subredes privadas y llega a S3 por el S3 Gateway Endpoint.
  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.upload_lambda.id]
  }

  depends_on = [
    aws_cloudwatch_log_group.upload_lambda,
    aws_iam_role_policy_attachment.upload_lambda_basic,
    aws_iam_role_policy_attachment.upload_lambda_vpc,
  ]
}

# --- API Gateway HTTP API: punto de entrada del cliente -------------------------

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"

  # API Gateway responde el preflight OPTIONS y agrega los headers CORS,
  # por eso la Lambda no los incluye.
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = 14
}

# Stage $default: la URL queda sin sufijo de stage (https://<id>.execute-api.../upload).
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  # Un registro JSON por cada request que pasa por el API.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      ip                      = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    throttling_rate_limit  = 10000
    throttling_burst_limit = 5000
  }
}

# Integración proxy: API Gateway reenvía el request completo a la Lambda (payload 2.0).
resource "aws_apigatewayv2_integration" "upload_lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.upload.invoke_arn
  payload_format_version = "2.0"
}

# Flecha "cliente -> POST /upload" del diagrama.
resource "aws_apigatewayv2_route" "upload" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /upload"
  target    = "integrations/${aws_apigatewayv2_integration.upload_lambda.id}"
}

# Autoriza a API Gateway (solo este API) a invocar la upload-lambda.
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.upload.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

# --- Outputs --------------------------------------------------------------------

output "api_endpoint" {
  description = "URL base del HTTP API"
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "upload_url" {
  description = "URL completa para subir imágenes (POST multipart, campo file)"
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/upload"
}

output "upload_lambda_name" {
  description = "Nombre de la upload-lambda"
  value       = aws_lambda_function.upload.function_name
}
