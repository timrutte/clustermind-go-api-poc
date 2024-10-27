output "api_url" {
  value       = "${aws_apigatewayv2_api.go_api.api_endpoint}/"
  description = "Die URL der Go-API über API Gateway"
}