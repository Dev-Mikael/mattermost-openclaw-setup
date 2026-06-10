variable "environment" { type = string }
variable "secret_prefix" {
  description = "AWS Secrets Manager prefix used by External Secrets Operator"
  type        = string
}
variable "secret_recovery_window" {
  description = "Days before a deleted secret is permanently removed. Use 0 to allow immediate deletion (useful for staging teardown)."
  type        = number
  default     = 7
}
