variable "environment" {
  type        = string
  description = "El entorno a desplegar (dev, qa o prod)"
  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "El environment debe ser dev, qa o prod."
  }
}

variable "aws_region" {
  type        = string
  description = "La región de AWS"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "El bloque CIDR de la VPC"
  default     = "10.0.0.0/16"
}

variable "alarm_email" {
  type        = string
  description = "El email para enviar alarmas. Dejar vacío para no enviar."
  default     = ""
}
