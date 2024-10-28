variable "aws_region" {
  description = "AWS region"
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS profile"
  default     = "default"
}

variable "cost_alert_email" {
  description = "Email address to send cost alerts to"
}