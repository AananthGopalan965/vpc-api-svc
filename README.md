# AWS VPC REST API Service

This repository contains the code and infrastructure configuration for deploying a VPC management API on AWS using Lambda, API Gateway, DynamoDB, and Cognito.

![AWS VPC API Architecture](docs/images/architecture.png)
![VPC Fetch via REST API](docs/images/vpc-not-found.png)
![VPC Creation via REST API](docs/images/vpc-created-by-post-request.png)

## Prerequisites

- AWS CLI installed and configured
- Terraform installed
- Python 3.9+ installed
- Zip utility (e.g., 7-Zip)
- AWS Account

## Deployment Instructions (Windows)

1.  **Clone the Repository:**

    ```bash
    git clone <repository_url>
    cd vpc-api
    ```

2.  **Create a Virtual Environment (Recommended):**

    ```bash
    python -m venv venv
    venv\Scripts\activate
    ```

3.  **Install Lambda Dependencies:**

    ```bash
    cd lambda
    pip install -r requirements.txt
    ```

4.  **Create Lambda Deployment Package:**

    ```bash
    zip -r vpc_api.zip vpc_api.py
    zip -g vpc_api.zip venv/Lib/site-packages/*
    cd ..
    ```

5.  **Initialize Terraform:**

    ```bash
    cd terraform
    terraform init
    ```

6.  **Apply Terraform Configuration:**

    ```bash
    terraform apply -var="aws_region=us-west-2" # Default region is us-west-2
    ```

    * Review the plan and confirm by typing `yes`.

7.  **Retrieve Outputs:**

    ```bash
    terraform output
    terraform output cognito_user_pool_client_secret # Retrieve the sensitive client secret
    ```

8.  **Create a Cognito User:**

    * Use the AWS CLI or AWS Console to create a user in your Cognito User Pool.

    ```bash
    aws cognito-idp sign-up --client-id <user_pool_client_id> --username <username> --password <password> --user-attributes Name=email,Value=<email>
    ```

    * Then confirm the user.

    ```bash
    aws cognito-idp admin-confirm-sign-up --user-pool-id <user_pool_id> --username <username>
    ```

9.  **Obtain an Authentication Token (AWS CLI) or CURL:**

    * Use the AWS CLI to authenticate and obtain an access token.

    ```bash
    aws cognito-idp initiate-auth \
      --client-id <user_pool_client_id> \
      --auth-flow USER_PASSWORD_AUTH \
      --auth-parameters USERNAME=<username>,PASSWORD=<password>
    ```
    * Using Curl
    ```bash
    curl -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -u "<your-client-id>:<your-client-secret>" \
    "https://<your-cognito-domain>.auth.<region>[.amazoncognito.com/oauth2/token](https://www.google.com/search?q=https://.amazoncognito.com/oauth2/token)" \
    -d "grant_type=authorization_code&code=<authorization-code>&redirect_uri=http://localhost:3000"

    * Extract the `AccessToken` from the response.

10. **Test the API:**

    * Use a tool like Postman or `curl` to send requests to the API endpoint, including the access token in the `Authorization` header.

    **Creating a VPC (POST):**

    ```bash
    curl -X POST \
      -H "Authorization: Bearer <access_token>" \
      -H "Content-Type: application/json" \
      -d '{
        "cidr_block": "10.0.0.0/16",
        "region": "us-west-2"
      }' \
      "<api_endpoint>/vpcs"
    ```

    **Retrieving a VPC (GET):**

    ```bash
    curl -X GET \
      -H "Authorization: Bearer <access_token
