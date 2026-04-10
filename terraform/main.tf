provider "aws" {
  region = "us-east-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

variable "pin_secret_arn" {
  description = "ARN of the existing Secrets Manager secret containing the PIN"
  type        = string
}

resource "aws_key_pair" "deployer" {
  key_name   = "dumbbudget-key"
  public_key = file("../dumbbudget-key.pub")
}

resource "aws_iam_role" "ec2_role" {
  name = "dumbbudget-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "secrets_policy" {
  name = "dumbbudget-secrets-policy"
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = ["secretsmanager:GetSecretValue"],
      Resource = var.pin_secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "profile" {
  name = "dumbbudget-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_security_group" "sg" {
  name = "dumbbudget-sg"
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 9090
    to_port     = 9090
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

resource "aws_instance" "server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.deployer.key_name
  iam_instance_profile = aws_iam_instance_profile.profile.name
  vpc_security_group_ids = [aws_security_group.sg.id]

  user_data = <<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    set -x

    export AWS_DEFAULT_REGION=us-east-1

    echo "Starting user_data script"

    retry() {
      local n=1
      local max=10
      local delay=10
      while true; do
        "$@" && break || {
          if [[ $$n -lt $$max ]]; then
            ((n++))
            echo "Command failed: $*. Attempt $$n/$$max. Retrying in $${delay}s..."
            sleep $$delay
          else
            echo "FATAL: Command failed after $$n attempts: $*"
            return 1
          fi
        }
      done
    }

    retry apt-get update -y
    retry apt-get install -y docker.io curl awscli

    systemctl start docker
    systemctl enable docker
    usermod -aG docker ubuntu

    retry curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    mkdir -p /opt/dumbbudget
    cd /opt/dumbbudget

    echo "Checking IAM identity..."
    aws sts get-caller-identity || echo "WARNING: No IAM role detected"

    echo "Fetching secret from AWS Secrets Manager..."
    PIN=$(retry aws secretsmanager get-secret-value --secret-id dumbbudget-pin --query SecretString --output text)
    if [[ -z "$$PIN" ]]; then
      echo "ERROR: Failed to retrieve PIN. Check secret existence and IAM permissions."
      exit 1
    fi

    echo "PIN retrieved successfully."

    cat > docker-compose.yml <<EOT
    version: "3.8"
    services:
      app:
        image: dreyjt/dumbbudget:latest
        ports:
          - "3000:3000"
        environment:
          DUMBBUDGET_PIN: "$${PIN}"
        restart: always
      node_exporter:
        image: prom/node-exporter:latest
        restart: always
      prometheus:
        image: prom/prometheus:latest
        ports:
          - "9090:9090"
        restart: always
      grafana:
        image: grafana/grafana:latest
        ports:
          - "3001:3000"
        restart: always
    EOT

    sleep 5
    /usr/local/bin/docker-compose up -d
    echo "user_data script finished successfully"
  EOF

  tags = { Name = "dumbbudget-server" }
}

resource "aws_eip" "eip" {
  domain = "vpc"
}
resource "aws_eip_association" "assoc" {
  instance_id   = aws_instance.server.id
  allocation_id = aws_eip.eip.id
}