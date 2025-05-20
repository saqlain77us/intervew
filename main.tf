# VPC and Networking
resource "aws_vpc" "main" {
    cidr_block           = var.vpc_cidr
    enable_dns_hostnames = true
    enable_dns_support   = true

    tags = {
        Name = "${var.autoscaling_group_name}-vpc"
    }
}

# IAM Role for EC2 instances
resource "aws_iam_role" "instance_role" {
  name = "${var.autoscaling_group_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for CloudWatch Logs
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "${var.autoscaling_group_name}-cloudwatch-logs"
  role = aws_iam_role.instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:aws:logs:*:*:log-group:${var.autoscaling_group_name}-*",
          "arn:aws:logs:*:*:log-group:${var.autoscaling_group_name}-*:log-stream:*"
        ]
      }
    ]
  })
}

# Instance Profile
resource "aws_iam_instance_profile" "main" {
  name = "${var.autoscaling_group_name}-instance-profile"
  role = aws_iam_role.instance_role.name
}


# Public and Private Subnets
resource "aws_subnet" "public" {
    count                   = 2
    vpc_id                  = aws_vpc.main.id
    cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
    availability_zone       = data.aws_availability_zones.available.names[count.index]
    map_public_ip_on_launch = true

    tags = {
        Name = "${var.autoscaling_group_name}-public-${count.index + 1}"
    }
}

resource "aws_subnet" "private" {
    count                   = 2
    vpc_id                  = aws_vpc.main.id
    cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 2)
    availability_zone       = data.aws_availability_zones.available.names[count.index]
    map_public_ip_on_launch = false

    tags = {
        Name = "${var.autoscaling_group_name}-private-${count.index + 1}"
    }
}

# NAT Gateway and Internet Gateway
resource "aws_internet_gateway" "main" {
    vpc_id = aws_vpc.main.id
}

resource "aws_eip" "nat" {
    domain = "vpc"
}

resource "aws_nat_gateway" "main" {
    allocation_id = aws_eip.nat.id
    subnet_id     = aws_subnet.public[0].id
}

# Route Tables
resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.main.id
    }
}

resource "aws_route_table" "private" {
    vpc_id = aws_vpc.main.id

    route {
        cidr_block     = "0.0.0.0/0"
        nat_gateway_id = aws_nat_gateway.main.id
    }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
    count          = 2
    subnet_id      = aws_subnet.public[count.index].id
    route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
    count          = 2
    subnet_id      = aws_subnet.private[count.index].id
    route_table_id = aws_route_table.private.id
}

# Security Groups
resource "aws_security_group" "alb" {
    name_prefix = "alb-sg-"
    vpc_id      = aws_vpc.main.id

    ingress {
        from_port   = 443
        to_port     = 443
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

resource "aws_security_group" "instance" {
    name_prefix = "instance-sg-"
    vpc_id      = aws_vpc.main.id

    ingress {
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        security_groups = [aws_security_group.alb.id]
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

# Attach SSM Managed Policy to the Instance Role
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Launch Template
resource "aws_launch_template" "main" {
    name_prefix   = "lt-"
    image_id      = data.aws_ami.amazon_linux_2023.id
    instance_type = "t3.micro"

    user_data = base64encode(<<-EOF
        #!/bin/bash
        dnf update -y
        dnf install -y nginx amazon-cloudwatch-agent
        systemctl start nginx
        systemctl enable nginx

        # Configure CloudWatch agent
        cat > /opt/aws/amazon-cloudwatch-agent/config.json <<'CONFIG'
        {
            "logs": {
                "logs_collected": {
                    "files": {
                        "collect_list": [
                            {
                                "file_path": "/var/log/messages",
                                "log_group_name": "${var.autoscaling_group_name}-messages",
                                "log_stream_name": "{instance_id}"
                            }
                        ]
                    }
                }
            }
        }
        CONFIG

        /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/config.json
        systemctl start amazon-cloudwatch-agent
        systemctl enable amazon-cloudwatch-agent
    EOF
    )

    iam_instance_profile {
        name = aws_iam_instance_profile.main.name
    }

    network_interface {
        associate_public_ip_address = false
        security_groups            = [aws_security_group.instance.id]
    }

    tag_specifications {
        resource_type = "instance"
        tags = {
            Name = var.autoscaling_group_name
        }
    }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "main" {
    name                = var.autoscaling_group_name
    desired_capacity    = 2
    max_size           = 4
    min_size           = 1
    target_group_arns  = [aws_lb_target_group.main.arn]
    vpc_zone_identifier = aws_subnet.private[*].id

    launch_template {
        id      = aws_launch_template.main.id
        version = "$Latest"
    }

    instance_refresh {
        strategy = "Rolling"
        preferences {
            min_healthy_percentage = 50
            instance_warmup       = 300
        }
        triggers = ["tag"]
    }

    tag {
        key                 = "Instance-Refresh"
        value              = formatdate("YYYY-MM-DD", timeadd(timestamp(), "720h"))
        propagate_at_launch = true
    }
}

# Application Load Balancer
resource "aws_lb" "main" {
    name               = var.load_balancer_url
    internal           = false
    load_balancer_type = "application"
    security_groups    = [aws_security_group.alb.id]
    subnets           = aws_subnet.public[*].id
}

resource "aws_lb_listener" "main" {
    load_balancer_arn = aws_lb.main.arn
    port              = 443
    protocol          = "HTTPS"
    ssl_policy        = "ELBSecurityPolicy-2016-08"
    certificate_arn   = var.certificate_arn

    default_action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.main.arn
    }
}

resource "aws_lb_target_group" "main" {
    name     = "${var.autoscaling_group_name}-tg"
    port     = 80
    protocol = "HTTP"
    vpc_id   = aws_vpc.main.id

    health_check {
        enabled             = true
        healthy_threshold   = 2
        interval            = 30
        matcher            = "200"
        path               = "/"
        timeout            = 5
        unhealthy_threshold = 2
    }
}