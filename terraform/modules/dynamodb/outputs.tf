output "table_name" {
  value = aws_dynamodb_table.jobs.name
}

output "table_arn" {
  value = aws_dynamodb_table.jobs.arn
}

output "status_index_name" {
  value = "status-created_at-index"
}
