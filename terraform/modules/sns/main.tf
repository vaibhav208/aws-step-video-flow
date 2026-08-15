# ---------------------------------------------------------------------------
# SNS — Phase 4
#
# One topic for both success and failure notifications, rather than two
# separate topics. The three ASL states that publish to it (NotifySuccess,
# NotifyValidationFailure, NotifyProcessingFailure — see
# step-functions/state-machine.asl.json.tpl) each set a distinct Subject, so
# a single email subscription still lets a human tell success from failure
# at a glance without managing two subscriptions for a learning project.
# Splitting into success/failure/ops topics is a reasonable next step for a
# real deployment with routing rules (e.g. failures page on-call, successes
# just log) — not done here to keep Phase 4 proportionate to what it's
# demonstrating.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "notifications" {
  name = "${var.name_prefix}-notifications"
  tags = var.tags
}

# Optional: an email subscription is convenient for a learning project (get
# a real email when a test execution succeeds/fails) but requires the
# subscriber to click a confirmation link AWS emails them before delivery
# starts — Terraform can't complete that step, so this is opt-in via
# var.notification_email rather than always-on with a fake placeholder
# address.
resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
