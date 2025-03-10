output "api_gateway_invoke_url" {
  description = "API Gateway invoke URL"
  value       = "${aws_api_gateway_deployment.deploy.invoke_url}prod/vpcs"
}

output "api_gateway_stage_invoke_url" {
  value = "${aws_api_gateway_deployment.deploy.invoke_url}"
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.user_pool.id
}

output "cognito_user_pool_client_id" {
  description = "Cognito User Pool Client ID"
  value       = aws_cognito_user_pool_client.client.id
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.user_pool.arn
}

output "lambda_function_arn" {
  description = "Lambda Function ARN"
  value       = aws_lambda_function.vpc_api.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB Table Name"
  value       = aws_dynamodb_table.vpc_table.name
}