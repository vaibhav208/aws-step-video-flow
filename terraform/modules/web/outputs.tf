output "web_api_function_name" {
  value = aws_lambda_function.web_api.function_name
}

output "web_api_function_arn" {
  value = aws_lambda_function.web_api.arn
}

output "api_invoke_url" {
  description = "Base URL the frontend calls for /presign and /status/{job_id}. Same value baked into the deployed index.html."
  value       = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.id
}

output "frontend_url" {
  description = "Open this in a browser to use the live demo frontend."
  value       = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
}
