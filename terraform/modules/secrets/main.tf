# Secrets module — creates the AWS Secrets Manager entries that ESO will sync
# into Kubernetes Secrets at runtime.
#
# IMPORTANT: The actual secret VALUES are NOT set here.
# Terraform creates the secret resources (name + metadata). The bootstrap script
# (05-create-secrets.sh) writes the values after infrastructure is provisioned.
# This keeps sensitive values out of Terraform state.
#
# If you want Terraform to manage values too, use sensitive variables +
# terraform.tfvars (gitignored). For a learning project, the script approach
# is more transparent.

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.secret_prefix}/db-password"
  description             = "PostgreSQL password for the Mattermost mmuser database account"
  recovery_window_in_days = var.secret_recovery_window

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "database"
  }
}

resource "aws_secretsmanager_secret" "openclaw_gateway_token" {
  name                    = "${var.secret_prefix}/openclaw-gateway-token"
  description             = "Bearer token for OpenClaw gateway access"
  recovery_window_in_days = var.secret_recovery_window

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "openclaw"
  }
}

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name                    = "${var.secret_prefix}/anthropic-api-key"
  description             = "Anthropic API key used by OpenClaw LiteLLM"
  recovery_window_in_days = var.secret_recovery_window

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "openclaw"
  }
}

resource "aws_secretsmanager_secret" "gemini_api_key" {
  name                    = "${var.secret_prefix}/gemini-api-key"
  description             = "Google Gemini API key used by OpenClaw LiteLLM"
  recovery_window_in_days = var.secret_recovery_window

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "openclaw"
  }
}

resource "aws_secretsmanager_secret" "litellm_master_key" {
  name                    = "${var.secret_prefix}/litellm-master-key"
  description             = "LiteLLM master key used by OpenClaw"
  recovery_window_in_days = var.secret_recovery_window

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "openclaw"
  }
}

resource "aws_secretsmanager_secret" "mattermost_bot_token" {
  name                    = "${var.secret_prefix}/mattermost-bot-token"
  description             = "Mattermost bot token used by OpenClaw"
  recovery_window_in_days = var.secret_recovery_window

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "openclaw"
  }
}
