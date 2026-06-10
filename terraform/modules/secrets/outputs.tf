output "db_password_secret_arn" {
  value = aws_secretsmanager_secret.db_password.arn
}

output "db_password_secret_name" {
  value = aws_secretsmanager_secret.db_password.name
}

output "openclaw_secret_names" {
  value = [
    aws_secretsmanager_secret.openclaw_gateway_token.name,
    aws_secretsmanager_secret.anthropic_api_key.name,
    aws_secretsmanager_secret.gemini_api_key.name,
    aws_secretsmanager_secret.litellm_master_key.name,
    aws_secretsmanager_secret.mattermost_bot_token.name,
  ]
}
