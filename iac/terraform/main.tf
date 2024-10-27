provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  app_name = "clustermind"
}

# Erstellen einer neuen VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true # DNS-Unterstützung aktivieren
  enable_dns_hostnames = true # DNS-Hostnamen aktivieren
  tags = {
    Name = "${local.app_name}-vpc"
  }
}

# Erstellen eines Internet Gateways
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.app_name}-igw"
  }
}

# Erstellen von Subnetzen
resource "aws_subnet" "subnet1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-west-1a" # Verfügbarkeitszone in eu-west-1
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.app_name}-subnet1"
  }
}

resource "aws_subnet" "subnet2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-west-1b" # Verfügbarkeitszone in eu-west-1
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.app_name}-subnet2"
  }
}

# Erstellen einer Routing-Tabelle
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

# Zuordnen der Routing-Tabelle zu den Subnetzen
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
    command = "GOOS=linux GOARCH=amd64 go build -o ../../build/clustermind ../../main.go"
  }

  triggers = {
    go_file = filemd5("../../main.go")
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "../../build/clustermind"
  output_path = "../../build/clustermind.zip"

  depends_on = [null_resource.build_go]
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
  roles      = [aws_iam_role.lambda_role.name]                                    # Verweist auf die erstellte Rolle
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" # Standard-Richtlinie für Lambda-Logging
}

resource "random_password" "db_password" {
  length  = 16   # Länge des Passworts
  special = true # Ob spezielle Zeichen erlaubt sind
}

resource "aws_secretsmanager_secret" "db_secret" {
  name = "${local.app_name}-db-password" # Der Name des Secrets
}

resource "aws_secretsmanager_secret_version" "db_secret_version" {
  secret_id = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    password = random_password.db_password.result
  })
}

# Sicherheitsgruppe für Lambda und RDS erstellen
resource "aws_security_group" "lambda_rds_sg" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lambda-rds-sg"
  }
}

# Erstellen der RDS MySQL-Datenbank
resource "aws_db_instance" "default" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  username               = "clustermind"
  password               = jsondecode(aws_secretsmanager_secret_version.db_secret_version.secret_string)["password"]
  db_subnet_group_name   = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.lambda_rds_sg.id]
  skip_final_snapshot    = true
  publicly_accessible    = true
  db_name                = "clustermind"
  identifier             = "${local.app_name}-db"
}

# Sicherheitsgruppe für die RDS-Datenbank
resource "aws_security_group" "default" {
  name        = "${local.app_name}-rds-sg"
  description = "Allow access to the RDS MySQL instance"

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Nur zu Testzwecken; für Produktion sicherer machen!
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Erstellen einer Subnetzgruppe für die RDS-Datenbank
resource "aws_db_subnet_group" "default" {
  name       = "${local.app_name}-db-subnet-group"
  subnet_ids = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]

  tags = {
    Name = "${local.app_name}-db-subnet-group"
  }
}

# Subnet-Gruppe für RDS
resource "aws_db_subnet_group" "main" {
  name       = "${local.app_name}-db-subnet-group"
  subnet_ids = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]

  tags = {
    Name = "db-subnet-group"
  }
}

resource "aws_lambda_function" "go_api_lambda" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "${local.app_name}-go-api"
  role          = aws_iam_role.lambda_role.arn
  handler       = "bootstrap"
  runtime       = "provided.al2"


  vpc_config {
    security_group_ids = [aws_security_group.lambda_rds_sg.id]
    subnet_ids         = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
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
