resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "image-processor-${var.environment}"
  bucket_name = "${local.name_prefix}-images-${random_id.suffix.hex}"
}
