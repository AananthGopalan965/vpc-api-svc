terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_dynamodb_table" "vpc_table" {
  name           = "VpcTable"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "vpc_id"

  attribute {
    name = "vpc_id"
    type = "S"
  }
}

resource "aws_cognito_user_pool" "user_pool" {
  name = "VpcUserPool"
  auto_verified_attributes = ["email"]
}

resource "aws_lambda_function" "vpc_api" {
  filename      = "../lambda/lambda-v12.zip"
  function_name = "VpcApi"
  role          = aws_iam_role.lambda_role.arn
  handler       = "vpc_api.lambda_handler"
  runtime       = "python3.9"
  timeout       = 600
  memory_size   = 256

  ephemeral_storage {
    size = 1024
  }

  environment {
    variables = {
      DYNAMODB_TABLE        = aws_dynamodb_table.vpc_table.name
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.user_pool.id
    }
  }
}

resource "aws_cloudwatch_log_group" "vpc_api_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.vpc_api.function_name}"
  retention_in_days = 7
}

resource "aws_iam_role" "api_gateway_cloudwatch_logs" {
  name = "ApiGatewayCloudWatchLogsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "api_gateway_cloudwatch_logs_policy_attach" {
  name       = "ApiGatewayCloudWatchLogsRole-attach"
  roles      = [aws_iam_role.api_gateway_cloudwatch_logs.name]
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role" "lambda_role" {
  name = "VpcApiLambdaRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.vpc_api.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*/*"
}

resource "aws_iam_policy" "lambda_policy" {
  name = "VpcApiLambdaPolicy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:UpdateItem",
        ],
        Effect   = "Allow",
        Resource = aws_dynamodb_table.vpc_table.arn
      },
      {
        Action = [
          "ec2:Describe*",
          "ec2:CreateVpc",
          "ec2:CreateSubnet",
          "ec2:CreateInternetGateway",
          "ec2:AttachInternetGateway",
          "ec2:CreateNatGateway",
          "ec2:AllocateAddress",
          "ec2:CreateRouteTable",
          "ec2:CreateRoute",
          "ec2:AssociateRouteTable",
          "ec2:DeleteVpc",
          "ec2:DeleteSubnet",
          "ec2:DeleteInternetGateway",
          "ec2:DeleteNatGateway",
          "ec2:ReleaseAddress",
          "ec2:DeleteRouteTable",
          "ec2:DeleteRoute",
          "ec2:DisassociateRouteTable",
          "ec2:CreateTags",
          "ec2:ModifyVpcAttribute" 
        ],
        Effect   = "Allow",
        Resource = "*"
      },
      {
        Action = [
          "ec2:CreateRoute",
        ],
        Resource = [
            "arn:aws:ec2:*:*:route-table/*"
        ],
        Effect   = "Allow",
      },
      {
        Action = [
          "cognito-idp:GetUser"
        ],
        Effect = "Allow",
        Resource = aws_cognito_user_pool.user_pool.arn
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
          "logs:GetLogEvents",
          "logs:FilterLogEvents"
        ],
        Effect: "Allow",
        Resource: "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_api_gateway_rest_api" "api" {
  name = "VpcApiGateway"
}

resource "aws_api_gateway_resource" "vpcs_resource" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "vpcs"
}

resource "aws_api_gateway_method" "vpcs_post" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.vpcs_resource.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.authorizer.id
}

resource "aws_api_gateway_method" "vpcs_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.vpcs_resource.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.authorizer.id
}

resource "aws_api_gateway_integration" "vpcs_post_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.vpcs_resource.id
  http_method             = aws_api_gateway_method.vpcs_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.vpc_api.invoke_arn
  request_templates = {
        "application/json" = <<EOF
    {
        "body": $input.json('$'),
        "requestContext": {
            "authorizer": {
                "claims": {
                    #foreach($key in $context.authorizer.claims.keySet())
                    "$key": "$context.authorizer.claims.get($key)",
                    #end
                }
            }
        }
    }
    EOF
    }
}

resource "aws_api_gateway_integration" "vpcs_get_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.vpcs_resource.id
  http_method             = aws_api_gateway_method.vpcs_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.vpc_api.invoke_arn
  request_templates = {
        "application/json" = <<EOF
    {
        "body": $input.json('$'),
        "requestContext": {
            "authorizer": {
                "claims": {
                    #foreach($key in $context.authorizer.claims.keySet())
                    "$key": "$context.authorizer.claims.get($key)",
                    #end
                }
            }
        }
    }
    EOF
    }
}

resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  depends_on = [
    aws_api_gateway_integration.vpcs_post_integration,
    aws_api_gateway_integration.vpcs_get_integration
  ]
}

resource "aws_api_gateway_stage" "stage" {
  deployment_id = aws_api_gateway_deployment.deploy.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "prod"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format            = "$context.identity.sourceIp $context.identity.caller $context.requestTime $context.httpMethod $context.resourcePath $context.protocol $context.status $context.responseLength $context.requestId"
  }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/api_gateway/${aws_api_gateway_rest_api.api.name}"
  retention_in_days = 7
}

resource "aws_api_gateway_authorizer" "authorizer" {
  name            = "cognito_authorizer"
  rest_api_id     = aws_api_gateway_rest_api.api.id
  type            = "COGNITO_USER_POOLS"
  identity_source = "method.request.header.Authorization"
  provider_arns   = [aws_cognito_user_pool.user_pool.arn]
}

resource "aws_cognito_user_pool_client" "client" {
  name                                 = "VpcApiUserPoolClient"
  user_pool_id                         = aws_cognito_user_pool.user_pool.id
  generate_secret                      = false
  explicit_auth_flows                  = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_PASSWORD_AUTH"]
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = ["http://localhost:3000"]
}
