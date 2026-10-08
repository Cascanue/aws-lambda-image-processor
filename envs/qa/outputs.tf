output "bucket_name" {
  value = module.image_processor.bucket_name
}
output "sqs_queue_url" {
  value = module.image_processor.queue_url
}
output "dlq_queue_url" {
  value = module.image_processor.dlq_url
}
output "api_endpoint" {
  value = module.image_processor.api_endpoint
}
output "upload_url" {
  value = module.image_processor.upload_url
}
output "upload_lambda_name" {
  value = module.image_processor.upload_lambda_name
}
output "crop_lambda_name" {
  value = module.image_processor.crop_lambda_name
}
