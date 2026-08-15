output "topic_arn" {
  value = aws_sns_topic.notifications.arn
}

output "topic_name" {
  value = aws_sns_topic.notifications.name
}
