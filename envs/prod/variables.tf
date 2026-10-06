variable "aws_profile" {
  type        = string
  description = "El profile de AWS a utilizar"
}

variable "aws_region" {
  type        = string
  description = "La región de AWS"
  default     = "us-east-1"
}
