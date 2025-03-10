variable "aws_region" {
  description = "AWS Region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "cognito_user_pool_name" {
  description = "Name of the Cognito User Pool"
  type        = string
  default     = "vpc-api-user-pool"
}

variable "cognito_client_name" {
  description = "Name of the Cognito User Pool Client"
  type        = string
  default     = "vpc-api-client"
}

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  type        = string
  default     = "vpcs"
}