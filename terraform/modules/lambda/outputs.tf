output "validate_function_arn" {
  value = aws_lambda_function.validate.arn
}
output "validate_function_name" {
  value = aws_lambda_function.validate.function_name
}

output "database_function_arn" {
  value = aws_lambda_function.database.arn
}
output "database_function_name" {
  value = aws_lambda_function.database.function_name
}

output "metadata_function_arn" {
  value = aws_lambda_function.metadata.arn
}
output "metadata_function_name" {
  value = aws_lambda_function.metadata.function_name
}

output "thumbnail_function_arn" {
  value = aws_lambda_function.thumbnail.arn
}
output "thumbnail_function_name" {
  value = aws_lambda_function.thumbnail.function_name
}

output "lambda_ffmpeg_ecr_repository_url" {
  value = aws_ecr_repository.lambda_ffmpeg.repository_url
}
output "lambda_ffmpeg_ecr_repository_name" {
  value = aws_ecr_repository.lambda_ffmpeg.name
}
