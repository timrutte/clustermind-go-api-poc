terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    archive = {
      source = "hashicorp/archive"
    }
    null = {
      source = "hashicorp/null"
    }
  }

  required_version = ">= 1.3.7"

  backend "s3" {
    bucket  = "clustermind-terraform-backend"
    key     = "terraform.tfstate"
    region  = "eu-west-1"
    profile = "clustermind"
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  app_name     = "clustermind"
  binary_path  = "../../build/bootstrap"
  src_path     = "../../main.go"
  archive_path = "../../build/clustermind.zip"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${local.app_name}-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${local.app_name}-igw"
  }
}

resource "aws_subnet" "subnet1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "${local.app_name}-subnet1"
  }
}

resource "aws_subnet" "subnet2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = true
  tags = {
    Name = "${local.app_name}-subnet2"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = {
    Name = "${local.app_name}-public-rt"
  }
}

resource "aws_route_table_association" "subnet1_assoc" {
  subnet_id      = aws_subnet.subnet1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "subnet2_assoc" {
  subnet_id      = aws_subnet.subnet2.id
  route_table_id = aws_route_table.public.id
}

resource "null_resource" "build_go" {
  provisioner "local-exec" {
    command = <<EOT
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 GOFLAGS=-trimpath go build -mod=readonly -ldflags='-s -w' -o ${local.binary_path} ${local.src_path}
    chmod +x ${local.binary_path}
    EOT
  }

  triggers = {
    always_run = timestamp()
  }
}

data "archive_file" "function_archive" {
  depends_on = [null_resource.build_go]

  type        = "zip"
  source_file = local.binary_path
  output_path = local.archive_path
}

resource "aws_iam_role" "lambda_role" {
  name = "${local.app_name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Effect = "Allow"
      Sid    = ""
    }]
  })
}

resource "aws_iam_policy_attachment" "lambda_logging" {
  name       = "${local.app_name}-lambda-logging"
  roles      = [aws_iam_role.lambda_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_ec2_permissions" {
  name = "${local.app_name}-lambda-ec2-permissions"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_cloudwatch_policy" {
  name = "lambda_cloudwatch_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "log_group" {
  name              = "/aws/lambda/${aws_lambda_function.go_api_lambda.function_name}"
  retention_in_days = 7
}

resource "random_password" "db_password" {
  length  = 16
  special = true
}

resource "aws_secretsmanager_secret" "db_secret" {
  name = "${local.app_name}-db-password"
}

resource "aws_secretsmanager_secret_version" "db_secret_version" {
  secret_id = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    password = random_password.db_password.result
  })
}

resource "aws_db_instance" "default" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  username               = local.app_name
  password               = jsondecode(aws_secretsmanager_secret_version.db_secret_version.secret_string)["password"]
  db_subnet_group_name   = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.default.id]
  skip_final_snapshot    = true
  publicly_accessible    = true
  db_name                = local.app_name
  identifier             = "${local.app_name}-db"
}

resource "aws_security_group" "default" {
  vpc_id      = aws_vpc.main.id
  name        = "${local.app_name}-sg"
  description = "Allow access to the RDS MySQL instance"
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "default" {
  name       = "${local.app_name}-db-subnet-group"
  subnet_ids = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
  tags = {
    Name = "${local.app_name}-db-subnet-group"
  }
}

resource "aws_lambda_function" "go_api_lambda" {
  filename         = local.archive_path
  source_code_hash = data.archive_file.function_archive.output_base64sha256
  function_name    = "${local.app_name}-go-api"
  role             = aws_iam_role.lambda_role.arn
  handler          = local.app_name
  runtime          = "provided.al2"

  vpc_config {
    security_group_ids = [aws_security_group.default.id]
    subnet_ids         = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
  }

  environment {
    variables = {
      DB_HOST     = aws_db_instance.default.address
      DB_PORT     = aws_db_instance.default.port
      DB_USER     = local.app_name
      DB_PASSWORD = jsondecode(aws_secretsmanager_secret_version.db_secret_version.secret_string)["password"]
      DB_NAME     = local.app_name
    }
  }
}

resource "aws_apigatewayv2_api" "go_api" {
  name          = "${local.app_name}-go-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.go_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.go_api_lambda.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "lambda_route" {
  api_id    = aws_apigatewayv2_api.go_api.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# Lambda Integration für POST /nodes
resource "aws_apigatewayv2_integration" "post_nodes_integration" {
  api_id             = aws_apigatewayv2_api.go_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.go_api_lambda.invoke_arn
  integration_method = "POST"
}

# Route für POST /nodes
resource "aws_apigatewayv2_route" "post_nodes_route" {
  api_id    = aws_apigatewayv2_api.go_api.id
  route_key = "POST /nodes"
  target    = "integrations/${aws_apigatewayv2_integration.post_nodes_integration.id}"
}

# Lambda Integration für GET /nodes
resource "aws_apigatewayv2_integration" "get_nodes_integration" {
  api_id             = aws_apigatewayv2_api.go_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.go_api_lambda.invoke_arn
  integration_method = "POST"
}

# Route für GET /nodes
resource "aws_apigatewayv2_route" "get_nodes_route" {
  api_id    = aws_apigatewayv2_api.go_api.id
  route_key = "GET /nodes"
  target    = "integrations/${aws_apigatewayv2_integration.get_nodes_integration.id}"
}

# Lambda Integration für GET /health
resource "aws_apigatewayv2_integration" "health_integration" {
  api_id             = aws_apigatewayv2_api.go_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.go_api_lambda.invoke_arn
  integration_method = "POST"
}

# Route für GET /health
resource "aws_apigatewayv2_route" "health_route" {
  api_id    = aws_apigatewayv2_api.go_api.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.health_integration.id}"
}

# Stage für das API Gateway
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.go_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.go_api_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.go_api.execution_arn}/*/*"
}

resource "aws_sns_topic" "cost_alert" {
  name = "${local.app_name}-cost-alert-topic"
}

resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.cost_alert.arn
  protocol  = "email"
  endpoint  = var.cost_alert_email
}

resource "aws_sns_topic_policy" "cost_alert_policy" {
  arn    = aws_sns_topic.cost_alert.arn
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "budgets.amazonaws.com"
      },
      "Action": "sns:Publish",
      "Resource": "${aws_sns_topic.cost_alert.arn}"
    }
  ]
}
EOF
}

resource "aws_budgets_budget" "monthly_cost_budget" {
  name         = "Monthly Cost Budget"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = "1"
  limit_unit   = "USD"

  notification {
    notification_type         = "ACTUAL"
    comparison_operator       = "GREATER_THAN"
    threshold                 = 1
    threshold_type            = "PERCENTAGE"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alert.arn]
  }
}